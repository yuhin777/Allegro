module blackwell_tmem_subsystem
  import blackwell_async_pkg::*;
  import blackwell_tmem_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic stop_i,
  input logic [15:0] epoch_i,
  input logic [2:0][60:0] live_i,
  input logic epoch_end_valid,
  output logic epoch_end_ready,
  input logic tmem_manage_valid,
  output logic tmem_manage_ready,
  input tmem_manage_cmd_t tmem_manage_payload,
  output logic tmem_manage_rsp_valid,
  input logic tmem_manage_rsp_ready,
  output tmem_manage_rsp_t tmem_manage_rsp_payload,
  output logic tmem_alloc_credit,
  input logic tmem_ldst_valid,
  output logic tmem_ldst_ready,
  input tmem_ldst_cmd_t tmem_ldst_payload,
  output logic tmem_ldst_done_valid,
  input logic tmem_ldst_done_ready,
  output op_done_t tmem_ldst_done_payload,
  input logic rf_store_valid,
  output logic rf_store_ready,
  input rf_beat_t rf_store_payload,
  output logic rf_load_valid,
  input logic rf_load_ready,
  output rf_beat_t rf_load_payload,
  input logic tmem_wait_valid,
  output logic tmem_wait_ready,
  input tmem_wait_cmd_t tmem_wait_payload,
  output logic tmem_wait_done_valid,
  input logic tmem_wait_done_ready,
  output op_done_t tmem_wait_done_payload,
  input logic mma_pin_req_valid,
  output logic mma_pin_req_ready,
  input tmem_pin_req_t mma_pin_req_payload,
  output logic mma_pin_rsp_valid,
  input logic mma_pin_rsp_ready,
  output tmem_pin_rsp_t mma_pin_rsp_payload,
  input logic mma_unpin_valid,
  output logic mma_unpin_ready,
  input tmem_unpin_t mma_unpin_payload,
  input logic [4:0][127:0] tc_rd_req_valid,
  output logic [4:0][127:0] tc_rd_req_ready,
  input tmem_rd_req_t tc_rd_req_payload[5][128],
  output logic [4:0][127:0] tc_rd_rsp_valid,
  input logic [4:0][127:0] tc_rd_rsp_ready,
  output tmem_rd_rsp_t tc_rd_rsp_payload[5][128],
  input logic [4:0][127:0] tc_wr_req_valid,
  output logic [4:0][127:0] tc_wr_req_ready,
  input tmem_wr_req_t tc_wr_req_payload[5][128],
  output logic [4:0][127:0] tc_wr_ack_valid,
  input logic [4:0][127:0] tc_wr_ack_ready,
  output tmem_wr_ack_t tc_wr_ack_payload[5][128],
  output logic drained_o,
  output logic empty_o
);
  logic mgr_drained, tracker_drained, engine_drained;
  logic fabric_drained;
  logic alloc_valid, alloc_ready, slot_valid, slot_ready, issue_valid, issue_ready;
  rf_track_alloc_t alloc_payload;
  rf_track_slot_t slot_payload;
  ldst_issue_t issue_payload;
  logic complete_valid, complete_ready;
  rf_track_done_t complete_payload;

  typedef enum logic [1:0] {
    RF_EMPTY,
    RF_SLOT,
    RF_ISSUE
  } issue_stage_t;
  issue_stage_t issue_stage;
  assign alloc_payload = '{id: tmem_ldst_payload.id, store: tmem_ldst_payload.store};
  assign alloc_valid = tmem_ldst_valid && issue_stage == RF_EMPTY;
  assign tmem_ldst_ready = alloc_ready && issue_stage == RF_EMPTY;
  assign slot_ready = issue_stage == RF_SLOT;
  assign issue_valid = issue_stage == RF_ISSUE;
  always_ff @(posedge clk) begin
    if (!rst_n) issue_stage <= RF_EMPTY;
    else begin
      if (alloc_valid && alloc_ready) begin
        issue_payload.cmd <= tmem_ldst_payload;
        issue_stage <= RF_SLOT;
      end
      if (slot_valid && slot_ready) begin
        issue_payload.slot <= slot_payload.slot;
        issue_stage <= RF_ISSUE;
      end
      if (issue_valid && issue_ready) issue_stage <= RF_EMPTY;
    end
  end

  logic pin_req_valid, pin_req_ready, pin_rsp_valid, pin_rsp_ready, unpin_valid, unpin_ready;
  tmem_pin_req_t pin_req_payload, rf_pin_req_payload;
  tmem_pin_rsp_t pin_rsp_payload;
  tmem_unpin_t unpin_payload, rf_unpin_payload;
  logic
      rf_pin_req_valid,
      rf_pin_req_ready,
      rf_pin_rsp_valid,
      rf_pin_rsp_ready,
      rf_unpin_valid,
      rf_unpin_ready;
  logic pin_pending, pin_owner;
  logic [1:0] cursor, held, held_owner, selected, active, accepted;
  wire [1:0] mma_request = {mma_unpin_valid, mma_pin_req_valid};
  wire [1:0] rf_request = {rf_unpin_valid, rf_pin_req_valid};
  wire [1:0] available = {1'b1, !pin_pending || (pin_rsp_valid && pin_rsp_ready)};
  wire [1:0] grant_ready = {unpin_ready, pin_req_ready};
  for (genvar i = 0; i < 2; i++) begin : arbitration
    assign selected[i] = held[i] ? held_owner[i] : rf_request[i] && (!mma_request[i] || cursor[i]);
    assign active[i] = available[i] &&
        (selected[i] ? rf_request[i] : mma_request[i]);
    assign accepted[i] = active[i] && grant_ready[i];
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        cursor[i] <= 0;
        held[i] <= 0;
      end else begin
        held[i] <= active[i] && !grant_ready[i];
        if (active[i]) held_owner[i] <= selected[i];
        if (accepted[i]) cursor[i] <= !selected[i];
      end
    end
  end
  assign pin_req_payload = selected[0] ? rf_pin_req_payload : mma_pin_req_payload;
  assign unpin_payload = selected[1] ? rf_unpin_payload : mma_unpin_payload;
  assign pin_req_valid = active[0];
  assign unpin_valid = active[1];
  assign mma_pin_req_ready = accepted[0] && !selected[0];
  assign rf_pin_req_ready = accepted[0] && selected[0];
  assign mma_unpin_ready = accepted[1] && !selected[1];
  assign rf_unpin_ready = accepted[1] && selected[1];
  assign mma_pin_rsp_valid = pin_rsp_valid && pin_pending && !pin_owner;
  assign mma_pin_rsp_payload = pin_rsp_payload;
  assign rf_pin_rsp_valid = pin_rsp_valid && pin_pending && pin_owner;
  assign pin_rsp_ready = pin_pending && (pin_owner ? rf_pin_rsp_ready : mma_pin_rsp_ready);
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pin_pending <= 0;
    end else begin
      if (pin_rsp_valid && pin_rsp_ready) pin_pending <= 0;
      if (pin_req_valid && pin_req_ready) begin
        pin_pending <= 1;
        pin_owner <= selected[0];
      end
    end
  end

`ifndef SYNTHESIS
  async_id_t pin_id;
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (slot_valid) assert (issue_stage == RF_SLOT && slot_payload.id == issue_payload.cmd.id);
      if (pin_req_valid)
        assert (selected[0] ? pin_req_payload.user inside {3, 4} : pin_req_payload.user <= 2);
      if (unpin_valid)
        assert (selected[1] ? unpin_payload.user inside {3, 4} : unpin_payload.user <= 2);
      if (pin_req_valid && pin_req_ready) pin_id <= pin_req_payload.id;
      if (pin_rsp_valid) assert (pin_pending && pin_rsp_payload.id == pin_id);
    end
  end
`endif
  blackwell_tmem_manager manager (
    .clk,
    .rst_n,
    .stop_i,
    .epoch_i,
    .epoch_end_valid,
    .epoch_end_ready,
    .manage_cmd_valid(tmem_manage_valid),
    .manage_cmd_ready(tmem_manage_ready),
    .manage_cmd_payload(tmem_manage_payload),
    .manage_rsp_valid(tmem_manage_rsp_valid),
    .manage_rsp_ready(tmem_manage_rsp_ready),
    .manage_rsp_payload(tmem_manage_rsp_payload),
    .pin_req_valid,
    .pin_req_ready,
    .pin_req_payload,
    .pin_rsp_valid,
    .pin_rsp_ready,
    .pin_rsp_payload,
    .unpin_valid,
    .unpin_ready,
    .unpin_payload,
    .alloc_credit_o(tmem_alloc_credit),
    .drained_o(mgr_drained),
    .empty_o
  );
  blackwell_tmem_wait_tracker tracker (
    .clk,
    .rst_n,
    .stop_i,
    .epoch_i,
    .alloc_valid,
    .alloc_ready,
    .alloc_payload,
    .slot_valid,
    .slot_ready,
    .slot_payload,
    .complete_valid,
    .complete_ready,
    .complete_payload,
    .wait_cmd_valid(tmem_wait_valid),
    .wait_cmd_ready(tmem_wait_ready),
    .wait_cmd_payload(tmem_wait_payload),
    .wait_done_valid(tmem_wait_done_valid),
    .wait_done_ready(tmem_wait_done_ready),
    .wait_done_payload(tmem_wait_done_payload),
    .drained_o(tracker_drained)
  );
  logic [5:0][127:0] rd_req_valid, rd_req_ready, rd_rsp_valid, rd_rsp_ready;
  logic [5:0][127:0] wr_req_valid, wr_req_ready, wr_ack_valid, wr_ack_ready;
  tmem_rd_req_t rd_req_payload[6][128];
  tmem_rd_rsp_t rd_rsp_payload[6][128];
  tmem_wr_req_t wr_req_payload[6][128];
  tmem_wr_ack_t wr_ack_payload[6][128];
  assign rd_req_valid[4:0] = tc_rd_req_valid;
  assign tc_rd_req_ready = rd_req_ready[4:0];
  assign tc_rd_rsp_valid = rd_rsp_valid[4:0];
  assign rd_rsp_ready[4:0] = tc_rd_rsp_ready;
  assign wr_req_valid[4:0] = tc_wr_req_valid;
  assign tc_wr_req_ready = wr_req_ready[4:0];
  assign tc_wr_ack_valid = wr_ack_valid[4:0];
  assign wr_ack_ready[4:0] = tc_wr_ack_ready;
  for (genvar c = 0; c < 5; c++) begin
    assign rd_req_payload[c] = tc_rd_req_payload[c];
    assign tc_rd_rsp_payload[c] = rd_rsp_payload[c];
    assign wr_req_payload[c] = tc_wr_req_payload[c];
    assign tc_wr_ack_payload[c] = wr_ack_payload[c];
  end
  blackwell_tmem_ldst_engine engine (
    .clk,
    .rst_n,
    .stop_i,
    .issue_valid,
    .issue_ready,
    .issue_payload,
    .rf_store_valid,
    .rf_store_ready,
    .rf_store_payload,
    .rf_load_valid,
    .rf_load_ready,
    .rf_load_payload,
    .rd_req_valid(rd_req_valid[5]),
    .rd_req_ready(rd_req_ready[5]),
    .rd_req_payload(rd_req_payload[5]),
    .rd_rsp_valid(rd_rsp_valid[5]),
    .rd_rsp_ready(rd_rsp_ready[5]),
    .rd_rsp_payload(rd_rsp_payload[5]),
    .wr_req_valid(wr_req_valid[5]),
    .wr_req_ready(wr_req_ready[5]),
    .wr_req_payload(wr_req_payload[5]),
    .wr_ack_valid(wr_ack_valid[5]),
    .wr_ack_ready(wr_ack_ready[5]),
    .wr_ack_payload(wr_ack_payload[5]),
    .pin_req_valid(rf_pin_req_valid),
    .pin_req_ready(rf_pin_req_ready),
    .pin_req_payload(rf_pin_req_payload),
    .pin_rsp_valid(rf_pin_rsp_valid),
    .pin_rsp_ready(rf_pin_rsp_ready),
    .pin_rsp_payload,
    .unpin_valid(rf_unpin_valid),
    .unpin_ready(rf_unpin_ready),
    .unpin_payload(rf_unpin_payload),
    .done_valid(tmem_ldst_done_valid),
    .done_ready(tmem_ldst_done_ready),
    .done_payload(tmem_ldst_done_payload),
    .track_done_valid(complete_valid),
    .track_done_ready(complete_ready),
    .track_done_payload(complete_payload),
    .drained_o(engine_drained)
  );
  blackwell_tmem_fabric fabric (
    .clk,
    .rst_n,
    .epoch_i,
    .live_i,
    .rd_req_valid,
    .rd_req_ready,
    .rd_req_payload,
    .rd_rsp_valid,
    .rd_rsp_ready,
    .rd_rsp_payload,
    .wr_req_valid,
    .wr_req_ready,
    .wr_req_payload,
    .wr_ack_valid,
    .wr_ack_ready,
    .wr_ack_payload,
    .drained_o(fabric_drained)
  );
  assign drained_o = mgr_drained && tracker_drained && engine_drained && fabric_drained &&
      issue_stage == RF_EMPTY && !pin_pending && held == 0;
endmodule
