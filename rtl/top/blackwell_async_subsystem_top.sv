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
  output status_t open_rsp_payload,
  input logic close_req_valid,
  output logic close_req_ready,
  output logic close_rsp_valid,
  input logic close_rsp_ready,
  output status_t close_rsp_payload,
  output logic [15:0] epoch,
  output logic stopped,
  output logic drained,
  output logic fault,
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
  logic engine_drained, engine_fault, tracker_drained, tracker_fault, bridge_drained, bridge_fault;
  logic
      sm_drained,
      sm_fault,
      tm_drained,
      tm_fault,
      loader_drained,
      loader_fault,
      snapshot_drained,
      snapshot_fault;
  logic [3:0] core_fault, core_drained;
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
  logic [3:0]
      prepare_valid,
      prepare_ready,
      b_select_valid,
      b_select_ready,
      local_done_valid,
      local_done_ready,
      first_ready;
  prepare_t prepare_payload[4], start_payload;
  b_select_t b_select_payload  [4];
  op_done_t  local_done_payload[4];
  logic
      first_valid,
      launch,
      start_valid,
      start_ready,
      release_valid,
      release_ready,
      load_valid,
      load_ready,
      result_valid,
      result_ready;
  async_id_t first_id, release_payload;
  b_load_t  load_payload;
  op_done_t result_payload;
  logic [3:0][2:0] input_free, writes_done;
  logic [2:0][3:0] older_writes_clear;
  logic [2:0] snapshot_ready, quiescent;
  mma_live_t [2:0] live;
  mma_live_t live_unpacked[3];
  for (genvar i = 0; i < 3; i++) assign live_unpacked[i] = live[i];
  logic [3:0] data_valid, data_ready;
  b_data_t data_payload;
  logic [3:0][71:0] sb_query;
  logic [3:0][256:0] sb_view;
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
  blackwell_tc_mma_engine engine (
    .epoch_i(epoch),
    .halt_i(fault),
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
    .fault_o(engine_fault),
    .*
  );
  blackwell_tc_completion_tracker tracker (
    .epoch_i(epoch),
    .halt_i(fault),
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
    .fault_o(tracker_fault),
    .*
  );
  blackwell_tc_async_completion bridge (
    .stop_i(stopped),
    .epoch_i(epoch),
    .halt_i(fault),
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
    .fault_o(bridge_fault),
    .*
  );
  for (genvar i = 0; i < 4; i++) begin : cores
    blackwell_tc_mma_core #(
      .CORE(i),
      .SHARE_FP_DOT_ADDER_TREE(SHARE_FP_DOT_ADDER_TREE)
    ) core (
      .epoch_i(epoch),
      .halt_i(fault),
      .live_i(live),
      .prepare_valid(prepare_valid[i]),
      .prepare_ready(prepare_ready[i]),
      .prepare_payload(prepare_payload[i]),
      .b_select_valid(b_select_valid[i]),
      .b_select_ready(b_select_ready[i]),
      .b_select_payload(b_select_payload[i]),
      .first_id_valid(first_valid),
      .first_ready(first_ready[i]),
      .input_free(input_free[i]),
      .writes_done(writes_done[i]),
      .local_done_valid(local_done_valid[i]),
      .local_done_ready(local_done_ready[i]),
      .local_done_payload(local_done_payload[i]),
      .data_valid(data_valid[i]),
      .data_ready(data_ready[i]),
      .sb_query(sb_query[i]),
      .sb_view(sb_view[i]),
      .sm_rd_req_valid(tc_smem_req_valid[i]),
      .sm_rd_req_ready(tc_smem_req_ready[i]),
      .sm_rd_req_payload(tc_smem_req_payload[i]),
      .sm_rd_rsp_valid(tc_smem_rsp_valid[i]),
      .sm_rd_rsp_ready(tc_smem_rsp_ready[i]),
      .sm_rd_rsp_payload(tc_smem_rsp_payload[i]),
      .tm_rd_req_valid(tc_rd_req_valid[i]),
      .tm_rd_req_ready(tc_rd_req_ready[i]),
      .tm_rd_req_payload(tc_rd_req_payload[i]),
      .tm_rd_rsp_valid(tc_rd_rsp_valid[i]),
      .tm_rd_rsp_ready(tc_rd_rsp_ready[i]),
      .tm_rd_rsp_payload(tc_rd_rsp_payload[i]),
      .tm_wr_req_valid(tc_wr_req_valid[i]),
      .tm_wr_req_ready(tc_wr_req_ready[i]),
      .tm_wr_req_payload(tc_wr_req_payload[i]),
      .tm_wr_ack_valid(tc_wr_ack_valid[i]),
      .tm_wr_ack_ready(tc_wr_ack_ready[i]),
      .tm_wr_ack_payload(tc_wr_ack_payload[i]),
      .idle_o(),
      .drained_o(core_drained[i]),
      .fault_o(core_fault[i]),
      .*
    );
  end
  blackwell_tc_b_loader b_loader (
    .epoch_i(epoch),
    .halt_i(fault),
    .live_i(live),
    .sm_rd_req_valid(tc_smem_req_valid[4]),
    .sm_rd_req_ready(tc_smem_req_ready[4]),
    .sm_rd_req_payload(tc_smem_req_payload[4]),
    .sm_rd_rsp_valid(tc_smem_rsp_valid[4]),
    .sm_rd_rsp_ready(tc_smem_rsp_ready[4]),
    .sm_rd_rsp_payload(tc_smem_rsp_payload[4]),
    .drained_o(loader_drained),
    .fault_o(loader_fault),
    .*
  );
  blackwell_tc_scale_b_snapshot sb (
    .epoch_i(epoch),
    .halt_i(fault),
    .live_i(live),
    .rd_req_valid(tc_rd_req_valid[4]),
    .rd_req_ready(tc_rd_req_ready[4]),
    .rd_req_payload(tc_rd_req_payload[4]),
    .rd_rsp_valid(tc_rd_rsp_valid[4]),
    .rd_rsp_ready(tc_rd_rsp_ready[4]),
    .rd_rsp_payload(tc_rd_rsp_payload[4]),
    .query(sb_query),
    .view(sb_view),
    .ready(snapshot_ready),
    .drained_o(snapshot_drained),
    .fault_o(snapshot_fault),
    .*
  );
  assign tc_wr_req_valid[4] = 0;
  assign tc_wr_ack_ready[4] = '1;
  for (genvar l = 0; l < 128; l++) assign tc_wr_req_payload[4][l] = '0;

  logic
      epoch_end_valid,
      epoch_end_ready,
      flush_req_valid,
      flush_req_ready,
      flush_rsp_valid,
      flush_rsp_ready;
  status_t flush_rsp_payload;
  logic [2:0] src_req_valid, src_req_ready, src_rsp_valid, src_rsp_ready;
  order_req_t src_req_payload[3];
  order_rsp_t src_rsp_payload[3];
  // The physical memory always returns its actual ACK. The integration
  // fixture can interpose a stall or ECC failure on one core/lane route.
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
    .halt_i(fault),
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
    .fault_o(tm_fault),
    .*
  );
  blackwell_smem_subsystem sm (
    .stop(stopped),
    .live(live_unpacked),
    .halt_i(fault),
    .order_req_valid(src_req_valid),
    .order_req_ready(src_req_ready),
    .order_req_payload(src_req_payload),
    .order_rsp_valid(src_rsp_valid),
    .order_rsp_ready(src_rsp_ready),
    .order_rsp_payload(src_rsp_payload),
    .commit_candidate_addr(tc_commit_payload.barrier_addr),
    .drained(sm_drained),
    .fault(sm_fault),
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
    CLOSE_RESULT,
    HALTED
  } phase_t;
  phase_t phase;
  logic order_locked, order_outstanding, order_error;
  logic [1:0] order_cursor, locked_src, outstanding_src, pick;
  async_id_t outstanding_id;
  logic [3:0] candidates;
  logic candidate_found;
  wire child_fault = engine_fault || tracker_fault || bridge_fault || loader_fault ||
      snapshot_fault || (|core_fault) || sm_fault || tm_fault;
  wire all_drained = engine_drained && tracker_drained && bridge_drained && loader_drained &&
      snapshot_drained && (&core_drained) && sm_drained && tm_drained && !order_outstanding &&
      !order_locked && lsu_quiescent;
  assign stopped = phase != RUN || fault;
  assign drained = all_drained;
  assign open_req_ready = phase == CLOSED && !fault && isolated && open_req_payload != epoch;
  assign open_rsp_valid = phase == OPEN_RESULT;
  assign open_rsp_payload = OK;
  assign close_req_ready = phase == RUN && !fault &&
      !(mma_cmd_valid || tc_commit_valid || tmem_manage_valid || tmem_ldst_valid ||
        tmem_wait_valid || tma_cmd_valid || bar_cmd_valid);
  assign close_rsp_valid = phase == CLOSE_RESULT;
  assign close_rsp_payload = OK;
  assign flush_req_valid = phase == FLUSH;
  assign flush_rsp_ready = phase == FLUSH_WAIT;
  assign epoch_end_valid = phase == END_EPOCH;
  always_comb begin
    candidates = {phase == CLOSE_ORDER, src_req_valid};
    candidate_found = order_locked;
    pick = locked_src;
    for (int off = 0; off < 4; off++)
    if (!candidate_found && !fault && !order_outstanding &&
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
    foreach (src_rsp_payload[i]) src_rsp_payload[i] = order_rsp_payload;
    order_rsp_ready = 1;
    if (order_outstanding && order_rsp_payload.id == outstanding_id && outstanding_src < 3) begin
      src_rsp_valid[outstanding_src] = order_rsp_valid;
      order_rsp_ready = src_rsp_ready[outstanding_src];
    end
    order_error = order_rsp_valid && order_rsp_ready &&
        (!order_outstanding || order_rsp_payload.id != outstanding_id ||
         order_rsp_payload.status != OK);
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      phase <= CLOSED;
      epoch <= 0;
      fault <= 0;
      order_locked <= 0;
      order_outstanding <= 0;
      order_cursor <= 0;
    end else begin
      if (child_fault || order_error ||
          (flush_rsp_valid && flush_rsp_ready && flush_rsp_payload != OK))
        fault <= 1;
      order_locked <= order_req_valid && !order_req_ready;
      if (order_req_valid) locked_src <= pick;
      if (order_req_valid && order_req_ready) begin
        order_outstanding <= 1;
        outstanding_id <= order_req_payload.id;
        outstanding_src <= pick;
        order_cursor <= pick + 1'b1;
      end
      if (order_rsp_valid && order_rsp_ready) order_outstanding <= 0;
      if (!fault && !child_fault && !order_error)
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
          FLUSH_WAIT: if (flush_rsp_valid && flush_rsp_payload == OK) phase <= CLOSE_ORDER;
          CLOSE_ORDER: if (order_req_valid && order_req_ready && pick == 3) phase <= CLOSE_WAIT;
          CLOSE_WAIT:
          if (order_rsp_valid && order_rsp_ready && order_outstanding && outstanding_src == 3)
            phase <= END_EPOCH;
          END_EPOCH: if (epoch_end_ready) phase <= CLOSE_RESULT;
          CLOSE_RESULT: if (close_rsp_ready) phase <= CLOSED;
          default: phase <= CLOSED;
        endcase
      // A fault may coincide with an already visible lifecycle output.
      // Consume it exactly once, even when its peer releases backpressure
      // after halt. No following normal lifecycle transaction is created.
      else
        case (phase)
          OPEN_RESULT: if (open_rsp_ready) phase <= HALTED;
          CLOSE_RESULT: if (close_rsp_ready) phase <= HALTED;
          FLUSH: if (flush_req_ready) phase <= HALTED;
          END_EPOCH: if (epoch_end_ready) phase <= HALTED;
          default: phase <= HALTED;
        endcase
    end
  end
endmodule
