module blackwell_tc_mma_engine
  import blackwell_async_pkg::*;
  import blackwell_tc_pkg::*;
  import blackwell_tmem_pkg::*;
  import blackwell_smem_pkg::*;
#(
  parameter bit SHARE_FP_DOT_ADDER_TREE = 1
) (
  input logic clk,
  input logic rst_n,
  input logic halt_i,
  input logic stop_i,
  input logic [15:0] epoch_i,
  output logic idle_o,
  output logic drained_o,
  output logic fault_o,
  input logic cmd_valid,
  output logic cmd_ready,
  input mma_cmd_t cmd_payload,
  output logic done_valid,
  input logic done_ready,
  output op_done_t done_payload,
  output logic pin_req_valid,
  input logic pin_req_ready,
  output tmem_pin_req_t pin_req_payload,
  input logic pin_rsp_valid,
  output logic pin_rsp_ready,
  input op_done_t pin_rsp_payload,
  output logic unpin_valid,
  input logic unpin_ready,
  output tmem_unpin_t unpin_payload,
  output mma_live_t [2:0] live_o,
  output logic [4:0][7:0] tc_smem_req_valid,
  input logic [4:0][7:0] tc_smem_req_ready,
  output smem_rd_req_t tc_smem_req_payload[5][8],
  input logic [4:0][7:0] tc_smem_rsp_valid,
  output logic [4:0][7:0] tc_smem_rsp_ready,
  input smem_rd_rsp_t tc_smem_rsp_payload[5][8],
  output logic [4:0][127:0] tc_rd_req_valid,
  input logic [4:0][127:0] tc_rd_req_ready,
  output tmem_rd_req_t tc_rd_req_payload[5][128],
  input logic [4:0][127:0] tc_rd_rsp_valid,
  output logic [4:0][127:0] tc_rd_rsp_ready,
  input tmem_rd_rsp_t tc_rd_rsp_payload[5][128],
  output logic [4:0][127:0] tc_wr_req_valid,
  input logic [4:0][127:0] tc_wr_req_ready,
  output tmem_wr_req_t tc_wr_req_payload[5][128],
  input logic [4:0][127:0] tc_wr_ack_valid,
  output logic [4:0][127:0] tc_wr_ack_ready,
  input tmem_wr_ack_t tc_wr_ack_payload[5][128]
);
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
  logic [3:0] data_valid, data_ready;
  b_data_t data_payload;
  logic [3:0][71:0] sb_query;
  logic [3:0][256:0] sb_view;
  logic control_empty, control_fault, loader_drained, loader_fault, snapshot_drained, snapshot_fault;
  logic [3:0] core_drained, core_fault;

  assign drained_o = control_empty && loader_drained && snapshot_drained && (&core_drained);
  assign idle_o = drained_o;
  assign fault_o = control_fault || loader_fault || snapshot_fault || (|core_fault);

  blackwell_tc_mma_control control (
    .idle_o(),
    .drained_o(control_empty),
    .fault_o(control_fault),
    .*
  );
  for (genvar i = 0; i < 4; i++) begin : cores
    blackwell_tc_mma_core #(
      .CORE(i),
      .SHARE_FP_DOT_ADDER_TREE(SHARE_FP_DOT_ADDER_TREE)
    ) core (
      .epoch_i,
      .halt_i,
      .live_i(live_o),
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
    .epoch_i,
    .halt_i,
    .live_i(live_o),
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
    .epoch_i,
    .halt_i,
    .live_i(live_o),
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
endmodule
