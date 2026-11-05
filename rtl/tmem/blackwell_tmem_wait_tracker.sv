// Implements frozen A1: doc/specs/blackwell_tmem_wait_tracker.md
module blackwell_tmem_wait_tracker
  import blackwell_async_pkg::*;
#(
  parameter int unsigned OPERATIONS = 16,
  parameter int unsigned WAITS = 16,
  parameter int unsigned TAG_W = ASYNC_TAG_W
) (
  input logic clk,
  input logic rst_n,
  input logic op_vld_i,
  input logic [CTX_ID_W-1:0] op_ctx_i,
  input logic [EPOCH_W-1:0] op_epoch_i,
  input logic [WARP_ID_W-1:0] op_warp_i,
  input logic op_store_i,
  input logic [TAG_W-1:0] op_tag_i,
  input logic [SEQ_W-1:0] op_seq_i,
  input logic finish_vld_i,
  input logic [CTX_ID_W-1:0] finish_ctx_i,
  input logic [EPOCH_W-1:0] finish_epoch_i,
  input logic [WARP_ID_W-1:0] finish_warp_i,
  input logic finish_store_i,
  input logic [TAG_W-1:0] finish_tag_i,
  input logic [SEQ_W-1:0] finish_seq_i,
  input logic [STATUS_W-1:0] finish_status_i,
  input logic wait_vld_i,
  input logic [CTX_ID_W-1:0] wait_ctx_i,
  input logic [EPOCH_W-1:0] wait_epoch_i,
  input logic [WARP_ID_W-1:0] wait_warp_i,
  input logic wait_store_i,
  input logic [TAG_W-1:0] wait_tag_i,
  input logic clear_ctx_vld_i,
  input logic [CTX_ID_W-1:0] clear_ctx_i,
  input logic rsp_rdy_i,
  output logic op_rdy_o,
  output logic finish_rdy_o,
  output logic wait_rdy_o,
  output logic rsp_vld_o,
  output logic [CTX_ID_W-1:0] rsp_ctx_o,
  output logic [EPOCH_W-1:0] rsp_epoch_o,
  output logic [WARP_ID_W-1:0] rsp_warp_o,
  output logic rsp_store_o,
  output logic [TAG_W-1:0] rsp_tag_o,
  output logic [STATUS_W-1:0] rsp_status_o,
  output logic protocol_error_o,
  output logic idle_o,
  output logic drained_o
);

  localparam int unsigned WAIT_INDEX_W = (WAITS > 1) ? $clog2(WAITS) : 1;
  typedef struct packed {
    logic [CTX_ID_W-1:0] ctx;
    logic [EPOCH_W-1:0] epoch;
    logic [WARP_ID_W-1:0] warp;
    logic store;
    logic [TAG_W-1:0] tag;
    logic [SEQ_W-1:0] seq;
  } operation_t;
  typedef struct packed {
    logic [CTX_ID_W-1:0] ctx;
    logic [EPOCH_W-1:0] epoch;
    logic [WARP_ID_W-1:0] warp;
    logic store;
    logic [TAG_W-1:0] tag;
  } wait_t;
  typedef struct packed {
    wait_t payload;
    logic [OPERATIONS-1:0] pending;
    logic [WAITS-1:0] predecessors;
    logic [STATUS_W-1:0] status;
  } snapshot_t;
  logic [OPERATIONS-1:0] live_q, live_d;
  logic [WAITS-1:0] wait_live_q, wait_live_d;
  operation_t [OPERATIONS-1:0] operations_q, operations_d;
  snapshot_t [WAITS-1:0] waits_q, waits_d;
  // Class faults remember an epoch; they are dependency state, not bank permissions.
  logic [31:0][63:0] poisoned_q, poisoned_d;
  logic [31:0][EPOCH_W-1:0] epoch_q, epoch_d;
  logic [31:0] epoch_valid_q, epoch_valid_d;
  logic rsp_vld_q, rsp_vld_d;
  wait_t rsp_q, rsp_d;
  logic [STATUS_W-1:0] rsp_status_q, rsp_status_d;
  logic [WAIT_INDEX_W-1:0] rr_q, rr_d;
  logic protocol_error_q, protocol_error_d;
  operation_t op_key, finish_key;
  wait_t wait_key;
  integer free_operation, free_wait, matched_operation, selected_wait, scan;
  logic duplicate, clear_busy, clear_has_work, finish_failed;
  logic op_fire, finish_fire, wait_fire;
  logic [OPERATIONS-1:0] completed_mask;
  logic [WAITS-1:0] released_wait_mask;
  snapshot_t accepted_wait;

  function automatic logic same_class(input operation_t op, input wait_t waiter);
    return op.ctx == waiter.ctx && op.epoch == waiter.epoch &&
        op.warp == waiter.warp && op.store == waiter.store;
  endfunction
  assign op_key = {op_ctx_i,op_epoch_i,op_warp_i,op_store_i,op_tag_i,op_seq_i};
  assign finish_key = {finish_ctx_i,finish_epoch_i,finish_warp_i,finish_store_i,finish_tag_i,finish_seq_i};
  assign wait_key = {wait_ctx_i,wait_epoch_i,wait_warp_i,wait_store_i,wait_tag_i};
  assign finish_rdy_o = 1'b1;
  assign op_fire = op_vld_i && op_rdy_o;
  assign finish_fire = finish_vld_i && finish_rdy_o;
  assign wait_fire = wait_vld_i && wait_rdy_o;
  assign finish_failed = finish_fire && matched_operation >= 0 && finish_status_i != ASYNC_OK;
  assign rsp_vld_o = rsp_vld_q;
  assign {rsp_ctx_o,rsp_epoch_o,rsp_warp_o,rsp_store_o,rsp_tag_o} = rsp_q;
  assign rsp_status_o = rsp_status_q;
  assign protocol_error_o = protocol_error_q;
  assign idle_o = !(|live_q);
  assign drained_o = idle_o && !(|wait_live_q) && !rsp_vld_q;
  always_comb begin
    int op;
    int wait_slot;
    op = 0;
    wait_slot = 0;
    free_operation = -1;
    free_wait = -1;
    matched_operation = -1;
    duplicate = 1'b0;
    clear_has_work = rsp_vld_q && rsp_q.ctx == clear_ctx_i;
    for (op = 0; op < OPERATIONS; op++) begin
      if (!live_q[op] && free_operation < 0) free_operation = op;
      if (live_q[op] && operations_q[op] == op_key) duplicate = 1'b1;
      if (live_q[op] && operations_q[op] == finish_key) matched_operation = op;
      if (live_q[op] && operations_q[op].ctx == clear_ctx_i) clear_has_work = 1'b1;
    end
    for (wait_slot = 0; wait_slot < WAITS; wait_slot++) begin
      if (!wait_live_q[wait_slot] && free_wait < 0) free_wait = wait_slot;
      if (wait_live_q[wait_slot] && waits_q[wait_slot].payload.ctx == clear_ctx_i) clear_has_work = 1'b1;
    end
    op_rdy_o = free_operation >= 0 && !duplicate;
    wait_rdy_o = free_wait >= 0;
  end
  assign clear_busy = clear_has_work ||
      (op_vld_i && op_rdy_o && op_ctx_i == clear_ctx_i) ||
      (wait_vld_i && wait_rdy_o && wait_ctx_i == clear_ctx_i);
  // The accepting snapshot is formed from q only: exclude a new operation,
  // include a matched completion, and retain a failure on that same edge.
  always_comb begin
    int op;
    int waiter;
    op = 0;
    waiter = 0;
    completed_mask = '0;
    accepted_wait = '0;
    accepted_wait.payload = wait_key;
    if (epoch_valid_q[wait_ctx_i] && epoch_q[wait_ctx_i] == wait_epoch_i &&
        poisoned_q[wait_ctx_i][{wait_warp_i,wait_store_i}]) accepted_wait.status = 8'd16;
    for (op = 0; op < OPERATIONS; op++) begin
      completed_mask[op] = finish_fire && matched_operation == op;
      accepted_wait.pending[op] = live_q[op] && same_class(operations_q[op],wait_key) &&
          !completed_mask[op];
      if (finish_failed && completed_mask[op] && same_class(operations_q[op],wait_key))
        accepted_wait.status = 8'd16;
    end
    for (waiter = 0; waiter < WAITS; waiter++) begin
      accepted_wait.predecessors[waiter] = wait_live_q[waiter] &&
          waits_q[waiter].payload.ctx == wait_ctx_i &&
          waits_q[waiter].payload.epoch == wait_epoch_i &&
          waits_q[waiter].payload.warp == wait_warp_i &&
          waits_q[waiter].payload.store == wait_store_i;
    end
  end
  always_comb begin
    int offset;
    int waiter;
    offset = 0;
    waiter = 0;
    selected_wait = -1;
    scan = 0;
    released_wait_mask = '0;
    if (!rsp_vld_q || rsp_rdy_i) begin
      for (offset = 0; offset < WAITS; offset++) begin
        scan = (int'(rr_q) + offset) % WAITS;
        if (selected_wait < 0 && wait_live_q[scan] &&
            !(|(waits_q[scan].pending & ~completed_mask)) &&
            !(|waits_q[scan].predecessors)) selected_wait = scan;
      end
      for (waiter = 0; waiter < WAITS; waiter++)
        released_wait_mask[waiter] = selected_wait == waiter;
    end
  end
  // Constant record targets avoid dynamic partial writes to a CAM payload.
  // Epoch/class faults are dependency state; the bank remains the permission authority.
  for (genvar ctx = 0; ctx < (1 << CTX_ID_W); ctx++) begin : g_class_fault
    always_comb begin
      poisoned_d[ctx] = poisoned_q[ctx];
      epoch_d[ctx] = epoch_q[ctx];
      epoch_valid_d[ctx] = epoch_valid_q[ctx];
      if (clear_ctx_vld_i && !clear_busy && clear_ctx_i == CTX_ID_W'(ctx)) begin
        poisoned_d[ctx] = '0;
        epoch_d[ctx] = '0;
        epoch_valid_d[ctx] = 1'b0;
      end else if (finish_failed && finish_ctx_i == CTX_ID_W'(ctx)) begin
        poisoned_d[ctx] = (epoch_valid_q[ctx] && epoch_q[ctx] == finish_epoch_i ?
            poisoned_q[ctx] : 64'd0) | (64'd1 << {finish_warp_i,finish_store_i});
        epoch_d[ctx] = finish_epoch_i;
        epoch_valid_d[ctx] = 1'b1;
      end
    end
  end
  always_comb begin
    int op;
    int waiter;
    op = 0;
    waiter = 0;
    live_d = live_q & ~completed_mask;
    wait_live_d = wait_live_q & ~released_wait_mask;
    rsp_vld_d = rsp_vld_q && !rsp_rdy_i;
    rsp_d = rsp_q;
    rsp_status_d = rsp_status_q;
    rr_d = rr_q;
    protocol_error_d = (finish_fire && matched_operation < 0) ||
        (clear_ctx_vld_i && clear_busy) || (op_vld_i && duplicate);
    for (op = 0; op < OPERATIONS; op++) begin
      operations_d[op] = operations_q[op];
      if (op_fire && free_operation == op) begin
        live_d[op] = 1'b1;
        operations_d[op] = op_key;
      end
    end
    for (waiter = 0; waiter < WAITS; waiter++) begin
      waits_d[waiter] = waits_q[waiter];
      waits_d[waiter].pending = waits_q[waiter].pending & ~completed_mask;
      waits_d[waiter].predecessors = waits_q[waiter].predecessors & ~released_wait_mask;
      if (finish_failed && (|(waits_q[waiter].pending & completed_mask)))
        waits_d[waiter].status = 8'd16;
      if (wait_fire && free_wait == waiter) begin
        wait_live_d[waiter] = 1'b1;
        waits_d[waiter] = accepted_wait;
        waits_d[waiter].predecessors = accepted_wait.predecessors & ~released_wait_mask;
      end
    end
    if (selected_wait >= 0) begin
      rsp_vld_d = 1'b1;
      rsp_d = waits_q[selected_wait].payload;
      rsp_status_d = waits_q[selected_wait].status;
      if (finish_failed && (|(waits_q[selected_wait].pending & completed_mask)))
        rsp_status_d = 8'd16;
      rr_d = WAIT_INDEX_W'((selected_wait + 1) % WAITS);
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      live_q <= '0;
      wait_live_q <= '0;
      operations_q <= '0;
      waits_q <= '0;
      poisoned_q <= '0;
      epoch_q <= '0;
      epoch_valid_q <= '0;
      rsp_vld_q <= 1'b0;
      rsp_q <= '0;
      rsp_status_q <= ASYNC_OK;
      rr_q <= '0;
      protocol_error_q <= 1'b0;
    end else begin
      live_q <= live_d;
      wait_live_q <= wait_live_d;
      operations_q <= operations_d;
      waits_q <= waits_d;
      poisoned_q <= poisoned_d;
      epoch_q <= epoch_d;
      epoch_valid_q <= epoch_valid_d;
      rsp_vld_q <= rsp_vld_d;
      rsp_q <= rsp_d;
      rsp_status_q <= rsp_status_d;
      rr_q <= rr_d;
      protocol_error_q <= protocol_error_d;
    end
  end
  initial if (OPERATIONS < 1 || WAITS < 1 || TAG_W < 1) $fatal(1, "RF tracker parameters");
`ifndef SYNTHESIS
  assert property (@(posedge clk) disable iff (!rst_n)
      rsp_vld_o && !rsp_rdy_i |=> rsp_vld_o && $stable({rsp_ctx_o,rsp_epoch_o,rsp_warp_o,rsp_store_o,rsp_tag_o,rsp_status_o}));

  assert property (@(posedge clk) disable iff (!rst_n)
      $onehot0(completed_mask) && $onehot0(released_wait_mask));
`endif
endmodule
