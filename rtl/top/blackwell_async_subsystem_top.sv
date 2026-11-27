module blackwell_async_subsystem_top
  import blackwell_async_pkg::*;
  import blackwell_tc_pkg::*;
  import blackwell_tmem_pkg::*;
  import blackwell_smem_pkg::*;
  import blackwell_tma_pkg::*;
  import blackwell_mbarrier_pkg::*;
#(
  parameter bit SHARE_FP_DOT_ADDER_TREE = 1
) (
  input logic clk,
  input logic rst_n,
  input logic lsu_quiescent,
  input logic isolated,
  input logic open_req_valid,
  output logic open_req_ready,
  input logic [15:0] open_req_payload,
  output logic open_rsp_valid,
  input logic open_rsp_ready,
  input logic close_req_valid,
  output logic close_req_ready,
  output logic close_rsp_valid,
  input logic close_rsp_ready,
  output logic [15:0] epoch,
  output logic stopped,
  output logic drained,
  input logic mma_cmd_valid,
  output logic mma_cmd_ready,
  input mma_cmd_t mma_cmd_payload,
  output logic tc_op_done_valid,
  input logic tc_op_done_ready,
  output op_done_t tc_op_done_payload,
  input logic tc_commit_valid,
  output logic tc_commit_ready,
  input tc_commit_t tc_commit_payload,
  output logic tc_commit_done_valid,
  input logic tc_commit_done_ready,
  output op_done_t tc_commit_done_payload,
  input logic tmem_manage_valid,
  output logic tmem_manage_ready,
  input tmem_manage_cmd_t tmem_manage_payload,
  output logic tmem_manage_rsp_valid,
  input logic tmem_manage_rsp_ready,
  output tmem_manage_rsp_t tmem_manage_rsp_payload,
  input logic tmem_ldst_valid,
  output logic tmem_ldst_ready,
  input tmem_ldst_cmd_t tmem_ldst_payload,
  output logic tmem_ldst_done_valid,
  input logic tmem_ldst_done_ready,
  output op_done_t tmem_ldst_done_payload,
  input logic tmem_wait_valid,
  output logic tmem_wait_ready,
  input tmem_wait_cmd_t tmem_wait_payload,
  output logic tmem_wait_done_valid,
  input logic tmem_wait_done_ready,
  output op_done_t tmem_wait_done_payload,
  input logic rf_store_valid,
  output logic rf_store_ready,
  input rf_beat_t rf_store_payload,
  output logic rf_load_valid,
  input logic rf_load_ready,
  output rf_beat_t rf_load_payload,
  input logic tma_cmd_valid,
  output logic tma_cmd_ready,
  input tma_cmd_t tma_cmd_payload,
  output logic tma_rsp_valid,
  input logic tma_rsp_ready,
  output tma_rsp_t tma_rsp_payload,
  input logic bar_cmd_valid,
  output logic bar_cmd_ready,
  input bar_cmd_t bar_cmd_payload,
  output logic bar_rsp_valid,
  input logic bar_rsp_ready,
  output bar_rsp_t bar_rsp_payload,
  output logic gmem_req_valid,
  input logic gmem_req_ready,
  output gmem_req_t gmem_req_payload,
  input logic gmem_rsp_valid,
  output logic gmem_rsp_ready,
  input gmem_rsp_t gmem_rsp_payload,
  output logic order_req_valid,
  input logic order_req_ready,
  output order_req_t order_req_payload,
  input logic order_rsp_valid,
  output logic order_rsp_ready,
  input order_rsp_t order_rsp_payload,
  input logic [7:0] smem_rd_valid,
  output logic [7:0] smem_rd_ready,
  input smem_rd_req_t smem_rd_payload[8],
  output logic [7:0] smem_rd_rsp_valid,
  input logic [7:0] smem_rd_rsp_ready,
  output smem_rd_rsp_t smem_rd_rsp_payload[8],
  input logic [7:0] smem_wr_valid,
  output logic [7:0] smem_wr_ready,
  input smem_wr_req_t smem_wr_payload[8],
  output logic [7:0] smem_wr_ack_valid,
  input logic [7:0] smem_wr_ack_ready,
  output smem_wr_ack_t smem_wr_ack_payload[8],
  output logic tmem_alloc_credit
);
  logic engine_drained, tracker_drained, bridge_drained;
  logic sm_drained, tm_drained;
  logic engine_ready, register_ready;
  logic commit_blocked, commit_addr_busy;
  logic [31:0] commit_busy_addr;
  logic tc_req_valid, tc_req_ready, tc_rsp_valid, tc_rsp_ready;
  tc_commit_t  bridge_request;
  tc_bar_req_t tc_req_payload;
  assign tc_req_payload = '{id: bridge_request.id, addr: bridge_request.barrier_addr};
  op_done_t tc_rsp_payload;
  logic engine_done_valid, engine_done_ready;
  op_done_t engine_done_payload;
  logic ready_commit_valid, ready_commit_ready, commit_retire_valid, commit_retire_ready;
  tc_ready_commit_t ready_commit_payload;
  tc_commit_retire_t commit_retire_payload;
  logic tracker_commit_ready;
  mma_live_t [2:0] live;
  mma_live_t live_unpacked[3];
  for (genvar i = 0; i < 3; i++) assign live_unpacked[i] = live[i];
  logic
      mma_pin_req_valid,
      mma_pin_req_ready,
      mma_pin_rsp_valid,
      mma_pin_rsp_ready,
      mma_unpin_valid,
      mma_unpin_ready;
  tmem_pin_req_t mma_pin_req_payload;
  op_done_t mma_pin_rsp_payload;
  tmem_unpin_t mma_unpin_payload;
  logic [4:0][7:0] tc_smem_req_valid, tc_smem_req_ready, tc_smem_rsp_valid, tc_smem_rsp_ready;
  smem_rd_req_t tc_smem_req_payload[5][8];
  smem_rd_rsp_t tc_smem_rsp_payload[5][8];
  logic [4:0][127:0] tc_rd_req_valid, tc_rd_req_ready, tc_rd_rsp_valid, tc_rd_rsp_ready;
  logic [4:0][127:0] tc_wr_req_valid, tc_wr_req_ready, tc_wr_ack_valid, tc_wr_ack_ready;
  tmem_rd_req_t tc_rd_req_payload[5][128];
  tmem_rd_rsp_t tc_rd_rsp_payload[5][128];
  tmem_wr_req_t tc_wr_req_payload[5][128];
  tmem_wr_ack_t tc_wr_ack_payload[5][128];

  assign mma_cmd_ready = engine_ready && register_ready && !stopped;
  assign tc_commit_ready = tracker_commit_ready && !commit_blocked && !stopped;
  blackwell_tc_mma_engine #(
    .SHARE_FP_DOT_ADDER_TREE(SHARE_FP_DOT_ADDER_TREE)
  ) engine (
    .epoch_i(epoch),
    .stop_i(stopped),
    .cmd_valid(mma_cmd_valid && register_ready && !stopped),
    .cmd_ready(engine_ready),
    .cmd_payload(mma_cmd_payload),
    .done_valid(engine_done_valid),
    .done_ready(engine_done_ready),
    .done_payload(engine_done_payload),
    .pin_req_valid(mma_pin_req_valid),
    .pin_req_ready(mma_pin_req_ready),
    .pin_req_payload(mma_pin_req_payload),
    .pin_rsp_valid(mma_pin_rsp_valid),
    .pin_rsp_ready(mma_pin_rsp_ready),
    .pin_rsp_payload(mma_pin_rsp_payload),
    .unpin_valid(mma_unpin_valid),
    .unpin_ready(mma_unpin_ready),
    .unpin_payload(mma_unpin_payload),
    .live_o(live),
    .idle_o(),
    .drained_o(engine_drained),
    .*
  );
  blackwell_tc_completion_tracker tracker (
    .epoch_i(epoch),
    .stop_i(stopped),
    .register_op_valid(mma_cmd_valid && engine_ready && !stopped),
    .register_op_ready(register_ready),
    .register_op_payload(mma_cmd_payload.id),
    .op_done_valid(tc_op_done_valid),
    .op_done_ready(tc_op_done_ready),
    .op_done_payload(tc_op_done_payload),
    .commit_cmd_valid(tc_commit_valid && !commit_blocked && !stopped),
    .commit_cmd_ready(tracker_commit_ready),
    .commit_cmd_payload(tc_commit_payload),
    .busy_addr(commit_busy_addr),
    .addr_busy(commit_addr_busy),
    .drained_o(tracker_drained),
    .*
  );
  blackwell_tc_async_completion bridge (
    .stop_i(stopped),
    .epoch_i(epoch),
    .tc_bar_req_valid(tc_req_valid),
    .tc_bar_req_ready(tc_req_ready),
    .tc_bar_req_payload(bridge_request),
    .tc_bar_rsp_valid(tc_rsp_valid),
    .tc_bar_rsp_ready(tc_rsp_ready),
    .tc_bar_rsp_payload(tc_rsp_payload),
    .commit_done_valid(tc_commit_done_valid),
    .commit_done_ready(tc_commit_done_ready),
    .commit_done_payload(tc_commit_done_payload),
    .drained_o(bridge_drained),
    .*
  );
  logic
      epoch_end_valid,
      epoch_end_ready,
      flush_req_valid,
      flush_req_ready,
      flush_rsp_valid,
      flush_rsp_ready;
  logic [2:0] src_req_valid, src_req_ready, src_rsp_valid, src_rsp_ready;
  order_req_t src_req_payload[3];
  op_done_t src_rsp_payload[3];
  // The physical memory always returns its actual ACK. The integration
  // fixture can interpose a stall on one core/lane route.
`ifdef ALLEGRO_TEST_MEMORY_ACK
  logic [4:0][127:0] mem_ack_valid, mem_ack_ready;
  tmem_wr_ack_t mem_ack_payload[5][128];
  for (genvar c = 0; c < 5; c++) begin : ack_client
    for (genvar l = 0; l < 128; l++) begin : ack_route
      if (c == 0 && l == 0) begin : observed
        blackwell_test_memory_ack probe (
          .in_valid(mem_ack_valid[c][l]),
          .in_ready(mem_ack_ready[c][l]),
          .in_payload(mem_ack_payload[c][l]),
          .out_valid(tc_wr_ack_valid[c][l]),
          .out_ready(tc_wr_ack_ready[c][l]),
          .out_payload(tc_wr_ack_payload[c][l])
        );
      end else begin
        assign tc_wr_ack_valid[c][l] = mem_ack_valid[c][l];
        assign mem_ack_ready[c][l] = tc_wr_ack_ready[c][l];
        assign tc_wr_ack_payload[c][l] = mem_ack_payload[c][l];
      end
    end
  end
`endif
  blackwell_tmem_subsystem tmem (
    .stop_i(stopped),
    .epoch_i(epoch),
    .live_i(live),
`ifdef ALLEGRO_TEST_MEMORY_ACK
    .tc_wr_ack_valid(mem_ack_valid),
    .tc_wr_ack_ready(mem_ack_ready),
    .tc_wr_ack_payload(mem_ack_payload),
`endif
    .empty_o(),
    .drained_o(tm_drained),
    .*
  );
  blackwell_smem_subsystem sm (
    .stop(stopped),
    .live(live_unpacked),
    .order_req_valid(src_req_valid),
    .order_req_ready(src_req_ready),
    .order_req_payload(src_req_payload),
    .order_rsp_valid(src_rsp_valid),
    .order_rsp_ready(src_rsp_ready),
    .order_rsp_payload(src_rsp_payload),
    .commit_candidate_addr(tc_commit_payload.barrier_addr),
    .drained(sm_drained),
    .*
  );

  typedef enum logic [3:0] {
    CLOSED,
    OPEN_RESULT,
    RUN,
    DRAIN,
    FLUSH,
    FLUSH_WAIT,
    CLOSE_ORDER,
    CLOSE_WAIT,
    END_EPOCH,
    CLOSE_RESULT
  } phase_t;
  phase_t phase;
  logic order_locked, order_outstanding;
  logic [1:0] order_cursor, locked_src, outstanding_src, pick;
  logic [3:0] candidates;
  logic candidate_found;
  wire all_drained = engine_drained && tracker_drained && bridge_drained && sm_drained &&
      tm_drained && !order_outstanding && !order_locked && lsu_quiescent;
  assign stopped = phase != RUN;
  assign drained = all_drained;
  assign open_req_ready = phase == CLOSED && isolated && open_req_payload != epoch;
  assign open_rsp_valid = phase == OPEN_RESULT;
  assign close_req_ready = phase == RUN &&
      !(mma_cmd_valid || tc_commit_valid || tmem_manage_valid || tmem_ldst_valid ||
        tmem_wait_valid || tma_cmd_valid || bar_cmd_valid);
  assign close_rsp_valid = phase == CLOSE_RESULT;
  assign flush_req_valid = phase == FLUSH;
  assign flush_rsp_ready = phase == FLUSH_WAIT;
  assign epoch_end_valid = phase == END_EPOCH;
  always_comb begin
    candidates = {phase == CLOSE_ORDER, src_req_valid};
    candidate_found = order_locked;
    pick = locked_src;
    for (int off = 0; off < 4; off++)
    if (!candidate_found && !order_outstanding &&
        candidates[2'(int'(order_cursor)+off)]) begin
      candidate_found = 1;
      pick = 2'(int'(order_cursor) + off);
    end
    order_req_valid = candidate_found;
    if (pick == 3)
      order_req_payload = '{'{epoch, 10'h3ff, 32'hffffffff}, 3'd4, 2'd0, 2'd1, 2'd0, 64'd0, 32'd0};
    else order_req_payload = src_req_payload[pick];
    src_req_ready = 0;
    if (candidate_found && pick < 3) src_req_ready[pick] = order_req_ready;
    src_rsp_valid = 0;
    foreach (src_rsp_payload[i]) src_rsp_payload[i] = '{id: order_rsp_payload.id};
    order_rsp_ready = 1;
    if (order_outstanding && outstanding_src < 3) begin
      src_rsp_valid[outstanding_src] = order_rsp_valid;
      order_rsp_ready = src_rsp_ready[outstanding_src];
    end
  end
`ifndef SYNTHESIS
  // Instruction sequence numbers share one namespace across ingress ports.
  localparam int INGRESS_PORTS = 7;
  wire [INGRESS_PORTS-1:0] cmd_valid = {bar_cmd_valid, tma_cmd_valid, tmem_wait_valid,
      tmem_ldst_valid, tmem_manage_valid, tc_commit_valid, mma_cmd_valid};
  wire [INGRESS_PORTS-1:0] cmd_ready = {bar_cmd_ready, tma_cmd_ready, tmem_wait_ready,
      tmem_ldst_ready, tmem_manage_ready, tc_commit_ready, mma_cmd_ready};
  async_id_t cmd_id[INGRESS_PORTS];
  assign cmd_id = '{mma_cmd_payload.id, tc_commit_payload.id,
      tmem_manage_payload.id, tmem_ldst_payload.id, tmem_wait_payload.id,
      tma_cmd_payload.id, bar_cmd_payload.id};
  logic [1023:0] issuer_seen;
  logic [31:0] last_seq[1024];
  always @(posedge clk) begin
    if (!rst_n || (open_req_valid && open_req_ready)) begin
      issuer_seen = '0;
    end else begin
      for (int i = 0; i < INGRESS_PORTS; i++) begin
        if (cmd_valid[i]) begin
          assert (cmd_id[i].epoch == epoch && cmd_id[i].seq != '1 &&
                  (!issuer_seen[cmd_id[i].issuer] || cmd_id[i].seq > last_seq[cmd_id[i].issuer]))
            else $fatal(1, "Invalid command identity on port %0d", i);
          for (int j = 0; j < i; j++)
            if (cmd_valid[j]) assert (cmd_id[i] != cmd_id[j]);
        end
      end
      // Same-edge transfers have no port ordering. Keep the greatest sequence.
      for (int i = 0; i < INGRESS_PORTS; i++) begin
        if (cmd_valid[i] && cmd_ready[i]) begin
          if (!issuer_seen[cmd_id[i].issuer] || cmd_id[i].seq > last_seq[cmd_id[i].issuer])
            last_seq[cmd_id[i].issuer] = cmd_id[i].seq;
          issuer_seen[cmd_id[i].issuer] = 1;
        end
      end
    end
  end

  async_id_t outstanding_id;
  always_ff @(posedge clk) begin
    if (rst_n && order_req_valid && order_req_ready) outstanding_id <= order_req_payload.id;
    if (rst_n && order_rsp_valid)
      assert (order_outstanding && order_rsp_payload.id == outstanding_id && order_rsp_payload.status == OK)
        else $fatal(1, "Invalid ordering response");
  end
  property held_until_transfer(valid, ready, payload);
    @(posedge clk) disable iff (!rst_n) valid && !ready |=> valid && $stable(payload);
  endproperty
  assert property (held_until_transfer(order_rsp_valid, order_rsp_ready, order_rsp_payload));
  assert property (held_until_transfer(gmem_rsp_valid, gmem_rsp_ready, gmem_rsp_payload));
  assert property (held_until_transfer(mma_cmd_valid, mma_cmd_ready, mma_cmd_payload));
  assert property (held_until_transfer(tc_commit_valid, tc_commit_ready, tc_commit_payload));
  assert property (held_until_transfer(tmem_manage_valid, tmem_manage_ready, tmem_manage_payload));
  assert property (held_until_transfer(tmem_ldst_valid, tmem_ldst_ready, tmem_ldst_payload));
  assert property (held_until_transfer(rf_store_valid, rf_store_ready, rf_store_payload));
  assert property (held_until_transfer(tmem_wait_valid, tmem_wait_ready, tmem_wait_payload));
  assert property (held_until_transfer(tma_cmd_valid, tma_cmd_ready, tma_cmd_payload));
  assert property (held_until_transfer(bar_cmd_valid, bar_cmd_ready, bar_cmd_payload));
  assert property (held_until_transfer(open_req_valid, open_req_ready, open_req_payload));
  assert property (@(posedge clk) disable iff (!rst_n)
      close_req_valid && !close_req_ready |=> close_req_valid);
  for (genvar g = 0; g < 8; g++) begin : check_lsu_inputs
    logic read_held, write_held;
    smem_rd_req_t held_read;
    smem_wr_req_t held_write;
    always_ff @(posedge clk) begin
      if (rst_n && read_held) assert (smem_rd_valid[g] && smem_rd_payload[g] == held_read);
      if (rst_n && write_held) assert (smem_wr_valid[g] && smem_wr_payload[g] == held_write);
      read_held <= rst_n && smem_rd_valid[g] && !smem_rd_ready[g];
      write_held <= rst_n && smem_wr_valid[g] && !smem_wr_ready[g];
      held_read <= smem_rd_payload[g];
      held_write <= smem_wr_payload[g];
    end
  end
`endif
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      phase <= CLOSED;
      epoch <= 0;
      order_locked <= 0;
      order_outstanding <= 0;
      order_cursor <= 0;
    end else begin
      order_locked <= order_req_valid && !order_req_ready;
      if (order_req_valid) locked_src <= pick;
      if (order_req_valid && order_req_ready) begin
        order_outstanding <= 1;
        outstanding_src <= pick;
        order_cursor <= pick + 1'b1;
      end
      if (order_rsp_valid && order_rsp_ready) order_outstanding <= 0;
      case (phase)
        CLOSED:
        if (open_req_valid && open_req_ready) begin
          epoch <= open_req_payload;
          phase <= OPEN_RESULT;
        end
        OPEN_RESULT: if (open_rsp_ready) phase <= RUN;
        RUN: if (close_req_valid && close_req_ready) phase <= DRAIN;
        DRAIN: if (all_drained) phase <= FLUSH;
        FLUSH: if (flush_req_ready) phase <= FLUSH_WAIT;
        FLUSH_WAIT: if (flush_rsp_valid) phase <= CLOSE_ORDER;
        CLOSE_ORDER: if (order_req_valid && order_req_ready && pick == 3) phase <= CLOSE_WAIT;
        CLOSE_WAIT:
        if (order_rsp_valid && order_rsp_ready && order_outstanding && outstanding_src == 3)
          phase <= END_EPOCH;
        END_EPOCH: if (epoch_end_ready) phase <= CLOSE_RESULT;
        CLOSE_RESULT: if (close_rsp_ready) phase <= CLOSED;
        default: phase <= CLOSED;
      endcase
    end
  end
endmodule
