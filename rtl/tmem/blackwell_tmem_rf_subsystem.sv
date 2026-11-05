// Implements frozen A1: doc/specs/blackwell_tmem_rf_subsystem.md
module blackwell_tmem_rf_subsystem
  import blackwell_async_pkg::*;
#(
  parameter int unsigned CONTEXTS = 32,
  parameter int unsigned TAG_W = ASYNC_TAG_W
) (
  input logic clk,
  input logic rst_n,
  input logic ctx_vld_i,
  input logic [CTX_ID_W-1:0] ctx_id_i,
  input logic [EPOCH_W-1:0] ctx_epoch_i,
  input logic [TAG_W-1:0] ctx_tag_i,
  input logic ctx_create_i,
  input logic alloc_vld_i,
  input logic [CTX_ID_W-1:0] alloc_ctx_i,
  input logic [EPOCH_W-1:0] alloc_epoch_i,
  input logic [TAG_W-1:0] alloc_tag_i,
  input logic [TMEM_COLUMNS_COUNT_W-1:0] alloc_columns_i,
  input logic free_vld_i,
  input logic [CTX_ID_W-1:0] free_ctx_i,
  input logic [EPOCH_W-1:0] free_epoch_i,
  input logic [TAG_W-1:0] free_tag_i,
  input logic [TMEM_COLUMN_INDEX_W-1:0] free_base_i,
  input logic [TMEM_COLUMNS_COUNT_W-1:0] free_columns_i,
  input logic relinquish_vld_i,
  input logic [CTX_ID_W-1:0] relinquish_ctx_i,
  input logic [EPOCH_W-1:0] relinquish_epoch_i,
  input logic [TAG_W-1:0] relinquish_tag_i,
  input logic ctrl_rsp_rdy_i,
  input logic cmd_vld_i,
  input logic cmd_store_i,
  input logic [CTX_ID_W-1:0] cmd_ctx_i,
  input logic [EPOCH_W-1:0] cmd_epoch_i,
  input logic [WARP_ID_W-1:0] cmd_warp_i,
  input logic [3-1:0] cmd_shape_i,
  input logic [RF_REPEAT_W-1:0] cmd_repeat_i,
  input logic cmd_pack16_i,
  input logic [TMEM_HALF_OFFSET_W-1:0] cmd_half_offset_i,
  input logic [TAG_W-1:0] cmd_tag_i,
  input logic [TMEM_ADDR_W-1:0] cmd_base_addr_i,
  input logic rf_src_vld_i,
  input logic [RF_BEAT_W-1:0] rf_src_data_i,
  input logic rf_src_last_i,
  input logic rf_dst_rdy_i,
  input logic done_rdy_i,
  input logic shift_cmd_vld_i,
  input blackwell_async_pkg::shift_cmd_a1_t shift_cmd_i,
  input logic shift_complete_rdy_i,
  input logic shift_done_rdy_i,
  input logic wait_vld_i,
  input logic [CTX_ID_W-1:0] wait_ctx_i,
  input logic [EPOCH_W-1:0] wait_epoch_i,
  input logic [WARP_ID_W-1:0] wait_warp_i,
  input logic wait_store_i,
  input logic [TAG_W-1:0] wait_tag_i,
  input logic wait_rsp_rdy_i,
  input logic mma_active_i,
  input logic mma_rd_vld_i,
  input logic [CTX_ID_W-1:0] mma_rd_ctx_i,
  input logic [EPOCH_W-1:0] mma_rd_epoch_i,
  input logic [TMEM_LANE_MASK_W-1:0] mma_rd_lane_mask_i,
  input logic [TMEM_COLUMN_BUS_W-1:0] mma_rd_column_i,
  input logic [TAG_W-1:0] mma_rd_tag_i,
  input logic mma_rd_rsp_rdy_i,
  input logic mma_wr_vld_i,
  input logic [CTX_ID_W-1:0] mma_wr_ctx_i,
  input logic [EPOCH_W-1:0] mma_wr_epoch_i,
  input logic [TMEM_COLUMN_BUS_W-1:0] mma_wr_column_i,
  input logic [TMEM_DATA_W-1:0] mma_wr_data_i,
  input logic [TMEM_BYTE_MASK_W-1:0] mma_wr_byte_mask_i,
  input logic [TAG_W-1:0] mma_wr_tag_i,
  input logic mma_wr_rsp_rdy_i,
  input logic cp_cmd_vld_i,
  input blackwell_async_pkg::cp_cmd_a1_t cp_cmd_i,
  input logic cp_complete_rdy_i,
  input logic cp_done_rdy_i,
  input logic cp_smem_req_rdy_i,
  input logic cp_smem_rsp_vld_i,
  input logic [SMEM_DATA_W-1:0] cp_smem_rsp_data_i,
  input logic [TENSOR_SMEM_ID_W-1:0] cp_smem_rsp_id_i,
  input logic [MEM_STATUS_W-1:0] cp_smem_rsp_status_i,
  input logic stop_i,
  input logic management_enable_i,
  output logic ctx_rdy_o,
  output logic alloc_rdy_o,
  output logic free_rdy_o,
  output logic relinquish_rdy_o,
  output logic ctrl_rsp_vld_o,
  output logic [TAG_W-1:0] ctrl_rsp_tag_o,
  output logic [STATUS_W-1:0] ctrl_rsp_status_o,
  output logic [TMEM_COLUMN_INDEX_W-1:0] ctrl_rsp_base_o,
  output logic cmd_rdy_o,
  output logic rf_src_rdy_o,
  output logic rf_dst_vld_o,
  output logic [RF_BEAT_W-1:0] rf_dst_data_o,
  output logic [RF_INDEX_W-1:0] rf_dst_index_o,
  output logic rf_dst_last_o,
  output logic done_vld_o,
  output logic [TAG_W-1:0] done_tag_o,
  output logic done_store_o,
  output logic [STATUS_W-1:0] done_status_o,
  output logic shift_cmd_rdy_o,
  output logic shift_complete_vld_o,
  output blackwell_async_pkg::async_event_a1_t shift_complete_o,
  output logic shift_done_vld_o,
  output blackwell_async_pkg::async_event_a1_t shift_done_o,
  output logic wait_rdy_o,
  output logic wait_protocol_error_o,
  output logic wait_rsp_vld_o,
  output logic [CTX_ID_W-1:0] wait_rsp_ctx_o,
  output logic [EPOCH_W-1:0] wait_rsp_epoch_o,
  output logic [WARP_ID_W-1:0] wait_rsp_warp_o,
  output logic wait_rsp_store_o,
  output logic [TAG_W-1:0] wait_rsp_tag_o,
  output logic [STATUS_W-1:0] wait_rsp_status_o,
  output logic mma_idle_o,
  output logic mma_rd_rdy_o,
  output logic mma_rd_rsp_vld_o,
  output logic [TMEM_DATA_W-1:0] mma_rd_rsp_data_o,
  output logic [STATUS_W-1:0] mma_rd_rsp_status_o,
  output logic mma_wr_rdy_o,
  output logic mma_wr_rsp_vld_o,
  output logic [STATUS_W-1:0] mma_wr_rsp_status_o,
  output logic cp_cmd_rdy_o,
  output logic cp_complete_vld_o,
  output blackwell_async_pkg::async_event_a1_t cp_complete_o,
  output logic cp_done_vld_o,
  output blackwell_async_pkg::async_event_a1_t cp_done_o,
  output logic cp_smem_req_vld_o,
  output logic [SMEM_BYTE_ADDR_W-1:0] cp_smem_req_addr_o,
  output logic [SMEM_MASK_W-1:0] cp_smem_req_byte_mask_o,
  output logic [TENSOR_SMEM_ID_W-1:0] cp_smem_req_id_o,
  output logic cp_smem_rsp_rdy_o,
  output logic idle_o,
  output logic drained_o
);

  localparam logic [STATUS_W-1:0] OK = ASYNC_OK, BAD_ADDR = 8'd5, BAD_SHAPE = 8'd10;
  typedef enum logic [3:0] {
    IDLE, GATHER, PROBE_REQ, PROBE_RSP, READ_REQ, READ_RSP,
    WRITE_REQ, WRITE_RSP, OUTPUT_RF, DONE
  } state_t;
  state_t state_q, state_d;
  typedef enum logic [1:0] {NoOwner, RfOwner, CpOwner, ShiftOwner} owner_t;
  owner_t owner_q, owner_d;
  logic [CTX_ID_W-1:0] ctx_q, ctx_d;
  logic [EPOCH_W-1:0] epoch_q, epoch_d;
  logic [WARP_ID_W-1:0] warp_q, warp_d;
  logic [2:0] shape_q, shape_d;
  logic [RF_REPEAT_W-1:0] repeat_q, repeat_d;
  logic [7:0] reg_q, reg_d, out_q, out_d;
  logic [8:0] count_q, count_d;
  logic [TMEM_ADDR_W-1:0] base_q, base_d;
  logic [TMEM_HALF_OFFSET_W-1:0] half_offset_q, half_offset_d;
  logic pack_q, pack_d, store_q, store_d, second_q, second_d;
  logic [RF_THREADS-1:0] pending_q, pending_d, issued_q, issued_d;
  logic [TAG_W-1:0] tag_q, tag_d;
  logic [STATUS_W-1:0] status_q, status_d;
  logic [SEQ_W-1:0] next_seq_q, next_seq_d, seq_q, seq_d;
  logic [RF_BEAT_W-1:0] rf_vector_q, rf_vector_d;
  logic done_vld_q, done_vld_d, done_store_q, done_store_d;
  logic [TAG_W-1:0] done_tag_q, done_tag_d;
  logic [STATUS_W-1:0] done_status_q, done_status_d;
  logic cp_done_vld_q, cp_done_vld_d, shift_done_vld_q, shift_done_vld_d;
  async_event_a1_t cp_done_q, cp_done_d, shift_done_q, shift_done_d;
  logic ctx_pending_q, ctx_pending_d, ctx_create_q, ctx_create_d;
  logic [CTX_ID_W-1:0] ctx_route_q, ctx_route_d;
  logic tracker_op_rdy, tracker_finish_rdy, tracker_idle, tracker_drained;
  logic bank_idle, bank_drained, cp_idle, shift_idle;
  logic cp_engine_rdy, shift_engine_rdy, available, management_window;
  logic bank_ctx_rdy, bank_alloc_rdy, bank_free_rdy, bank_relinquish_rdy;
  logic bank_rd_rdy, bank_wr_rdy, bank_rd_rsp, bank_wr_rsp;
  logic [TMEM_DATA_W-1:0] bank_rd_data;
  logic [TAG_W-1:0] bank_rd_tag, bank_wr_tag;
  logic [STATUS_W-1:0] bank_rd_status, bank_wr_status, rf_read_status, rf_write_status;
  assign rf_read_status = bank_rd_tag == tag_q ? bank_rd_status : ASYNC_BAD_COMPLETION;
  assign rf_write_status = bank_wr_tag == tag_q ? bank_wr_status : ASYNC_BAD_COMPLETION;
  logic tracker_op_vld, tracker_finish_vld;
  logic [RF_THREADS-1:0] map_valid, group_selected;
  logic [RF_THREADS*TMEM_ADDR_W-1:0] map_cell0, map_cell1;
  logic group_valid;
  logic [TMEM_LANE_MASK_W-1:0] rf_rd_mask;
  logic [TMEM_COLUMN_BUS_W-1:0] rf_rd_column, rf_wr_column;
  logic [TMEM_DATA_W-1:0] rf_wr_data;
  logic [TMEM_BYTE_MASK_W-1:0] rf_wr_mask;
  wire [RF_THREADS-1:0] pending_after_rsp = pending_q & ~issued_q;
  logic rf_rd_vld, rf_wr_vld, rf_rd_rsp_rdy, rf_wr_rsp_rdy;
  logic rf_cmd_fire, cp_cmd_fire, shift_cmd_fire;
  assign available = owner_q == NoOwner && !mma_active_i && bank_idle;
  assign management_window = available && management_enable_i && tracker_drained &&
      cp_idle && shift_idle && !done_vld_q && !cp_done_vld_q && !shift_done_vld_q;
  assign cmd_rdy_o = available && !stop_i && !done_vld_q && tracker_op_rdy && next_seq_q != '1;
  assign cp_cmd_rdy_o = available && !stop_i && !cp_done_vld_q && cp_engine_rdy;
  assign shift_cmd_rdy_o = available && !stop_i && !shift_done_vld_q && shift_engine_rdy;
  assign rf_cmd_fire = cmd_vld_i && cmd_rdy_o;
  assign cp_cmd_fire = cp_cmd_vld_i && cp_cmd_rdy_o;
  assign shift_cmd_fire = shift_cmd_vld_i && shift_cmd_rdy_o;
  assign tracker_op_vld = rf_cmd_fire;
  assign tracker_finish_vld = state_q == DONE;
  assign mma_idle_o = owner_q == NoOwner && bank_idle && cp_idle && shift_idle;
  assign idle_o = owner_q == NoOwner && bank_idle && cp_idle && shift_idle && tracker_idle;
  assign drained_o = idle_o && bank_drained && tracker_drained &&
      !done_vld_q && !cp_done_vld_q && !shift_done_vld_q;
  assign rf_src_rdy_o = state_q == GATHER;
  assign rf_dst_vld_o = state_q == OUTPUT_RF;
  assign rf_dst_data_o = rf_vector_q;
  assign rf_dst_index_o = RF_INDEX_W'(out_q);
  assign rf_dst_last_o = {1'b0,out_q} + 9'd1 == count_q;
  assign done_vld_o = done_vld_q;
  assign done_tag_o = done_tag_q;
  assign done_store_o = done_store_q;
  assign done_status_o = done_status_q;
  assign cp_done_vld_o = cp_done_vld_q;
  assign cp_done_o = cp_done_q;
  assign shift_done_vld_o = shift_done_vld_q;
  assign shift_done_o = shift_done_q;
  assign ctx_rdy_o = bank_ctx_rdy && management_window;
  assign alloc_rdy_o = bank_alloc_rdy && management_window;
  assign free_rdy_o = bank_free_rdy && management_window;
  assign relinquish_rdy_o = bank_relinquish_rdy && management_window;
  assign rf_rd_vld = group_valid && (state_q == PROBE_REQ || state_q == READ_REQ);
  assign rf_wr_vld = group_valid && state_q == WRITE_REQ;
  assign rf_rd_rsp_rdy = state_q == PROBE_RSP || state_q == READ_RSP;
  assign rf_wr_rsp_rdy = state_q == WRITE_RSP;
  logic cp_rd_rdy;
  logic cp_rd_rsp_vld;
  logic [STATUS_W-1:0] cp_rd_rsp_status;
  logic [TMEM_DATA_W-1:0] cp_rd_rsp_data;
  logic cp_wr_rdy;
  logic cp_wr_rsp_vld;
  logic [STATUS_W-1:0] cp_wr_rsp_status;
  logic cp_rd_vld;
  logic [CTX_ID_W-1:0] cp_rd_ctx;
  logic [EPOCH_W-1:0] cp_rd_epoch;
  logic [TMEM_COLUMN_BUS_W-1:0] cp_rd_column;
  logic [ASYNC_TAG_W-1:0] cp_rd_tag;
  logic [TMEM_LANE_MASK_W-1:0] cp_rd_lane_mask;
  logic cp_rd_rsp_rdy;
  logic cp_wr_vld;
  logic [CTX_ID_W-1:0] cp_wr_ctx;
  logic [EPOCH_W-1:0] cp_wr_epoch;
  logic [TMEM_COLUMN_BUS_W-1:0] cp_wr_column;
  logic [ASYNC_TAG_W-1:0] cp_wr_tag;
  logic [TMEM_DATA_W-1:0] cp_wr_data;
  logic [TMEM_BYTE_MASK_W-1:0] cp_wr_byte_mask;
  logic cp_wr_rsp_rdy;
  blackwell_tmem_cp_engine u_cp (
    .clk(clk),
    .rst_n(rst_n),
    .cmd_vld_i(cp_cmd_fire),
    .cmd_rdy_o(cp_engine_rdy),
    .cmd_i(cp_cmd_i),
    .complete_rdy_i(cp_complete_rdy_i),
    .complete_vld_o(cp_complete_vld_o),
    .complete_o(cp_complete_o),
    .idle_o(cp_idle),
    .smem_req_rdy_i(cp_smem_req_rdy_i),
    .smem_rsp_vld_i(cp_smem_rsp_vld_i),
    .smem_rsp_data_i(cp_smem_rsp_data_i),
    .smem_rsp_id_i(cp_smem_rsp_id_i),
    .smem_rsp_status_i(cp_smem_rsp_status_i),
    .smem_req_vld_o(cp_smem_req_vld_o),
    .smem_req_addr_o(cp_smem_req_addr_o),
    .smem_req_byte_mask_o(cp_smem_req_byte_mask_o),
    .smem_req_id_o(cp_smem_req_id_o),
    .smem_rsp_rdy_o(cp_smem_rsp_rdy_o),
    .rd_rdy_i(cp_rd_rdy),
    .rd_rsp_vld_i(cp_rd_rsp_vld),
    .rd_rsp_status_i(cp_rd_rsp_status),
    .rd_rsp_data_i(cp_rd_rsp_data),
    .wr_rdy_i(cp_wr_rdy),
    .wr_rsp_vld_i(cp_wr_rsp_vld),
    .wr_rsp_status_i(cp_wr_rsp_status),
    .rd_vld_o(cp_rd_vld),
    .rd_ctx_o(cp_rd_ctx),
    .rd_epoch_o(cp_rd_epoch),
    .rd_column_o(cp_rd_column),
    .rd_tag_o(cp_rd_tag),
    .rd_lane_mask_o(cp_rd_lane_mask),
    .rd_rsp_rdy_o(cp_rd_rsp_rdy),
    .wr_vld_o(cp_wr_vld),
    .wr_ctx_o(cp_wr_ctx),
    .wr_epoch_o(cp_wr_epoch),
    .wr_column_o(cp_wr_column),
    .wr_tag_o(cp_wr_tag),
    .wr_data_o(cp_wr_data),
    .wr_byte_mask_o(cp_wr_byte_mask),
    .wr_rsp_rdy_o(cp_wr_rsp_rdy)
  );
  assign cp_rd_rdy = bank_rd_rdy && owner_q == CpOwner;
  assign cp_rd_rsp_vld = bank_rd_rsp && owner_q == CpOwner;
  assign cp_rd_rsp_status = bank_rd_tag == cp_rd_tag ? bank_rd_status : ASYNC_BAD_COMPLETION;
  assign cp_wr_rdy = bank_wr_rdy && owner_q == CpOwner;
  assign cp_wr_rsp_vld = bank_wr_rsp && owner_q == CpOwner;
  assign cp_wr_rsp_status = bank_wr_tag == cp_wr_tag ? bank_wr_status : ASYNC_BAD_COMPLETION;
  assign cp_rd_rsp_data = bank_rd_data;
  logic shift_rd_rdy;
  logic shift_rd_rsp_vld;
  logic [TMEM_DATA_W-1:0] shift_rd_rsp_data;
  logic [STATUS_W-1:0] shift_rd_rsp_status;
  logic shift_wr_rdy;
  logic shift_wr_rsp_vld;
  logic [STATUS_W-1:0] shift_wr_rsp_status;
  logic shift_rd_vld;
  logic [CTX_ID_W-1:0] shift_rd_ctx;
  logic [EPOCH_W-1:0] shift_rd_epoch;
  logic [TMEM_COLUMN_BUS_W-1:0] shift_rd_column;
  logic [ASYNC_TAG_W-1:0] shift_rd_tag;
  logic [TMEM_LANE_MASK_W-1:0] shift_rd_lane_mask;
  logic shift_rd_rsp_rdy;
  logic shift_wr_vld;
  logic [CTX_ID_W-1:0] shift_wr_ctx;
  logic [EPOCH_W-1:0] shift_wr_epoch;
  logic [TMEM_COLUMN_BUS_W-1:0] shift_wr_column;
  logic [TMEM_DATA_W-1:0] shift_wr_data;
  logic [ASYNC_TAG_W-1:0] shift_wr_tag;
  logic [TMEM_BYTE_MASK_W-1:0] shift_wr_byte_mask;
  logic shift_wr_rsp_rdy;
  blackwell_tmem_shift_engine #(.TAG_W(TAG_W)) u_shift (
    .clk(clk),
    .rst_n(rst_n),
    .cmd_vld_i(shift_cmd_fire),
    .cmd_rdy_o(shift_engine_rdy),
    .cmd_i(shift_cmd_i),
    .complete_rdy_i(shift_complete_rdy_i),
    .complete_vld_o(shift_complete_vld_o),
    .complete_o(shift_complete_o),
    .idle_o(shift_idle),
    .rd_rdy_i(shift_rd_rdy),
    .rd_rsp_vld_i(shift_rd_rsp_vld),
    .rd_rsp_data_i(shift_rd_rsp_data),
    .rd_rsp_status_i(shift_rd_rsp_status),
    .wr_rdy_i(shift_wr_rdy),
    .wr_rsp_vld_i(shift_wr_rsp_vld),
    .wr_rsp_status_i(shift_wr_rsp_status),
    .rd_vld_o(shift_rd_vld),
    .rd_ctx_o(shift_rd_ctx),
    .rd_epoch_o(shift_rd_epoch),
    .rd_column_o(shift_rd_column),
    .rd_tag_o(shift_rd_tag),
    .rd_lane_mask_o(shift_rd_lane_mask),
    .rd_rsp_rdy_o(shift_rd_rsp_rdy),
    .wr_vld_o(shift_wr_vld),
    .wr_ctx_o(shift_wr_ctx),
    .wr_epoch_o(shift_wr_epoch),
    .wr_column_o(shift_wr_column),
    .wr_data_o(shift_wr_data),
    .wr_tag_o(shift_wr_tag),
    .wr_byte_mask_o(shift_wr_byte_mask),
    .wr_rsp_rdy_o(shift_wr_rsp_rdy)
  );
  assign shift_rd_rdy = bank_rd_rdy && owner_q == ShiftOwner;
  assign shift_rd_rsp_vld = bank_rd_rsp && owner_q == ShiftOwner;
  assign shift_rd_rsp_status = bank_rd_tag == shift_rd_tag ? bank_rd_status : ASYNC_BAD_COMPLETION;
  assign shift_wr_rdy = bank_wr_rdy && owner_q == ShiftOwner;
  assign shift_wr_rsp_vld = bank_wr_rsp && owner_q == ShiftOwner;
  assign shift_wr_rsp_status = bank_wr_tag == shift_wr_tag ? bank_wr_status : ASYNC_BAD_COMPLETION;
  assign shift_rd_rsp_data = bank_rd_data;

  blackwell_tmem_wait_tracker #(.TAG_W(TAG_W)) u_wait (
    .clk(clk), .rst_n(rst_n), .op_vld_i(tracker_op_vld), .op_rdy_o(tracker_op_rdy),
    .op_ctx_i(cmd_ctx_i), .op_epoch_i(cmd_epoch_i), .op_warp_i(cmd_warp_i),
    .op_store_i(cmd_store_i), .op_tag_i(cmd_tag_i), .op_seq_i(next_seq_q),
    .finish_vld_i(tracker_finish_vld), .finish_rdy_o(tracker_finish_rdy),
    .finish_ctx_i(ctx_q), .finish_epoch_i(epoch_q), .finish_warp_i(warp_q),
    .finish_store_i(store_q), .finish_tag_i(tag_q), .finish_seq_i(seq_q), .finish_status_i(status_q),
    .wait_vld_i(wait_vld_i && !stop_i), .wait_rdy_o(tracker_wait_rdy),
    .wait_ctx_i(wait_ctx_i), .wait_epoch_i(wait_epoch_i), .wait_warp_i(wait_warp_i),
    .wait_store_i(wait_store_i), .wait_tag_i(wait_tag_i),
    .clear_ctx_vld_i(ctx_pending_q && ctx_create_q && ctrl_rsp_vld_o && ctrl_rsp_rdy_i && ctrl_rsp_status_o == OK),
    .clear_ctx_i(ctx_route_q),
    .rsp_vld_o(wait_rsp_vld_o), .rsp_rdy_i(wait_rsp_rdy_i), .rsp_ctx_o(wait_rsp_ctx_o),
    .rsp_epoch_o(wait_rsp_epoch_o), .rsp_warp_o(wait_rsp_warp_o), .rsp_store_o(wait_rsp_store_o),
    .rsp_tag_o(wait_rsp_tag_o), .rsp_status_o(wait_rsp_status_o),
    .protocol_error_o(wait_protocol_error_o), .idle_o(tracker_idle), .drained_o(tracker_drained)
  );
  logic tracker_wait_rdy;
  assign wait_rdy_o = tracker_wait_rdy && !stop_i;
  for (genvar thread_id = 0; thread_id < RF_THREADS; thread_id++) begin : gen_map
    blackwell_tmem_rf_map u_map (
      .shape_i(shape_q), .warp_i(warp_q), .thread_i(5'(thread_id)), .base_addr_i(base_q),
      .repeat_i(repeat_q), .reg_index_i(RF_INDEX_W'(reg_q)), .pack16_i(pack_q), .half_offset_i(half_offset_q),
      .valid_o(map_valid[thread_id]), .cell0_o(map_cell0[thread_id*TMEM_ADDR_W+:TMEM_ADDR_W]),
      .cell1_o(map_cell1[thread_id*TMEM_ADDR_W+:TMEM_ADDR_W]), .second_cell_o()
    );
  end
  blackwell_tmem_rf_group u_group (
    .pending_i(pending_q), .valid_i(map_valid), .cell0_i(map_cell0), .cell1_i(map_cell1),
    .second_i(second_q), .pack16_i(pack_q), .writing_i(state_q == WRITE_REQ), .rf_data_i(rf_vector_q),
    .all_valid_o(group_valid), .selected_o(group_selected), .rd_lane_mask_o(rf_rd_mask),
    .rd_column_o(rf_rd_column), .wr_column_o(rf_wr_column), .wr_data_o(rf_wr_data), .wr_byte_mask_o(rf_wr_mask)
  );
  blackwell_tmem_bank #(.CONTEXTS(CONTEXTS), .TAG_W(TAG_W)) u_bank (
    .clk(clk),
    .rst_n(rst_n),
    .idle_o(bank_idle),
    .drained_o(bank_drained),
    .ctx_vld_i(ctx_vld_i && management_window),
    .ctx_id_i(ctx_id_i),
    .ctx_epoch_i(ctx_epoch_i),
    .ctx_tag_i(ctx_tag_i),
    .ctx_create_i(ctx_create_i),
    .alloc_vld_i(alloc_vld_i && management_window),
    .alloc_ctx_i(alloc_ctx_i),
    .alloc_epoch_i(alloc_epoch_i),
    .alloc_tag_i(alloc_tag_i),
    .alloc_columns_i(alloc_columns_i),
    .free_vld_i(free_vld_i && management_window),
    .free_ctx_i(free_ctx_i),
    .free_epoch_i(free_epoch_i),
    .free_tag_i(free_tag_i),
    .free_base_i(free_base_i),
    .free_columns_i(free_columns_i),
    .relinquish_vld_i(relinquish_vld_i && management_window),
    .relinquish_ctx_i(relinquish_ctx_i),
    .relinquish_epoch_i(relinquish_epoch_i),
    .relinquish_tag_i(relinquish_tag_i),
    .ctrl_rsp_rdy_i(ctrl_rsp_rdy_i),
    .rd_vld_i(mma_active_i ? mma_rd_vld_i : owner_q == CpOwner ? cp_rd_vld : owner_q == ShiftOwner ? shift_rd_vld : rf_rd_vld),
    .rd_ctx_i(mma_active_i ? mma_rd_ctx_i : owner_q == CpOwner ? cp_rd_ctx : owner_q == ShiftOwner ? shift_rd_ctx : ctx_q),
    .rd_epoch_i(mma_active_i ? mma_rd_epoch_i : owner_q == CpOwner ? cp_rd_epoch : owner_q == ShiftOwner ? shift_rd_epoch : epoch_q),
    .rd_column_i(mma_active_i ? mma_rd_column_i : owner_q == CpOwner ? cp_rd_column : owner_q == ShiftOwner ? shift_rd_column : rf_rd_column),
    .rd_tag_i(mma_active_i ? mma_rd_tag_i : owner_q == CpOwner ? cp_rd_tag : owner_q == ShiftOwner ? shift_rd_tag : tag_q),
    .rd_lane_mask_i(mma_active_i ? mma_rd_lane_mask_i : owner_q == CpOwner ? cp_rd_lane_mask : owner_q == ShiftOwner ? shift_rd_lane_mask : rf_rd_mask),
    .rd_rsp_rdy_i(mma_active_i ? mma_rd_rsp_rdy_i : owner_q == CpOwner ? cp_rd_rsp_rdy : owner_q == ShiftOwner ? shift_rd_rsp_rdy : rf_rd_rsp_rdy),
    .wr_vld_i(mma_active_i ? mma_wr_vld_i : owner_q == CpOwner ? cp_wr_vld : owner_q == ShiftOwner ? shift_wr_vld : rf_wr_vld),
    .wr_ctx_i(mma_active_i ? mma_wr_ctx_i : owner_q == CpOwner ? cp_wr_ctx : owner_q == ShiftOwner ? shift_wr_ctx : ctx_q),
    .wr_epoch_i(mma_active_i ? mma_wr_epoch_i : owner_q == CpOwner ? cp_wr_epoch : owner_q == ShiftOwner ? shift_wr_epoch : epoch_q),
    .wr_column_i(mma_active_i ? mma_wr_column_i : owner_q == CpOwner ? cp_wr_column : owner_q == ShiftOwner ? shift_wr_column : rf_wr_column),
    .wr_data_i(mma_active_i ? mma_wr_data_i : owner_q == CpOwner ? cp_wr_data : owner_q == ShiftOwner ? shift_wr_data : rf_wr_data),
    .wr_tag_i(mma_active_i ? mma_wr_tag_i : owner_q == CpOwner ? cp_wr_tag : owner_q == ShiftOwner ? shift_wr_tag : tag_q),
    .wr_byte_mask_i(mma_active_i ? mma_wr_byte_mask_i : owner_q == CpOwner ? cp_wr_byte_mask : owner_q == ShiftOwner ? shift_wr_byte_mask : rf_wr_mask),
    .wr_rsp_rdy_i(mma_active_i ? mma_wr_rsp_rdy_i : owner_q == CpOwner ? cp_wr_rsp_rdy : owner_q == ShiftOwner ? shift_wr_rsp_rdy : rf_wr_rsp_rdy),
    .ctx_rdy_o(bank_ctx_rdy),
    .alloc_rdy_o(bank_alloc_rdy),
    .free_rdy_o(bank_free_rdy),
    .relinquish_rdy_o(bank_relinquish_rdy),
    .ctrl_rsp_vld_o(ctrl_rsp_vld_o),
    .ctrl_rsp_tag_o(ctrl_rsp_tag_o),
    .ctrl_rsp_status_o(ctrl_rsp_status_o),
    .ctrl_rsp_base_o(ctrl_rsp_base_o),
    .rd_rdy_o(bank_rd_rdy),
    .rd_rsp_vld_o(bank_rd_rsp),
    .rd_rsp_data_o(bank_rd_data),
    .rd_rsp_tag_o(bank_rd_tag),
    .rd_rsp_status_o(bank_rd_status),
    .wr_rdy_o(bank_wr_rdy),
    .wr_rsp_vld_o(bank_wr_rsp),
    .wr_rsp_tag_o(bank_wr_tag),
    .wr_rsp_status_o(bank_wr_status)
  );

  assign mma_rd_rdy_o = bank_rd_rdy && mma_active_i;
  assign mma_wr_rdy_o = bank_wr_rdy && mma_active_i;
  assign mma_rd_rsp_vld_o = bank_rd_rsp && mma_active_i;
  assign mma_wr_rsp_vld_o = bank_wr_rsp && mma_active_i;
  assign mma_rd_rsp_data_o = bank_rd_data;
  assign mma_rd_rsp_status_o = bank_rd_tag == mma_rd_tag_i ? bank_rd_status : ASYNC_BAD_COMPLETION;
  assign mma_wr_rsp_status_o = bank_wr_tag == mma_wr_tag_i ? bank_wr_status : ASYNC_BAD_COMPLETION;
  always_comb begin
    int thread_id;
    thread_id = 0;
    state_d = state_q;
    ctx_d = ctx_q;
    epoch_d = epoch_q;
    warp_d = warp_q;
    shape_d = shape_q;
    repeat_d = repeat_q;
    reg_d = reg_q;
    out_d = out_q;
    count_d = count_q;
    pending_d = pending_q;
    issued_d = issued_q;
    second_d = second_q;
    base_d = base_q;
    half_offset_d = half_offset_q;
    pack_d = pack_q;
    store_d = store_q;
    tag_d = tag_q;
    status_d = status_q;
    owner_d = owner_q;
    next_seq_d = next_seq_q;
    seq_d = seq_q;
    rf_vector_d = rf_vector_q;
    done_vld_d = done_vld_q;
    done_store_d = done_store_q;
    done_tag_d = done_tag_q;
    done_status_d = done_status_q;
    cp_done_vld_d = cp_done_vld_q;
    shift_done_vld_d = shift_done_vld_q;
    cp_done_d = cp_done_q;
    shift_done_d = shift_done_q;
    ctx_pending_d = ctx_pending_q;
    ctx_create_d = ctx_create_q;
    ctx_route_d = ctx_route_q;

    if (done_vld_q && done_rdy_i) done_vld_d = 1'b0;
    if (cp_done_vld_q && cp_done_rdy_i) cp_done_vld_d = 1'b0;
    if (shift_done_vld_q && shift_done_rdy_i) shift_done_vld_d = 1'b0;
    if (rf_cmd_fire) begin
      owner_d = RfOwner;
      seq_d = next_seq_q;
      next_seq_d = next_seq_q + SEQ_W'(1);
      rf_vector_d = '0;
    end
    if (cp_cmd_fire) owner_d = CpOwner;
    if (shift_cmd_fire) owner_d = ShiftOwner;
    if (tracker_finish_vld && tracker_finish_rdy) begin
      owner_d = NoOwner;
      done_vld_d = 1'b1;
      done_tag_d = tag_q;
      done_store_d = store_q;
      done_status_d = status_q;
    end
    if (cp_complete_vld_o && cp_complete_rdy_i) begin
      owner_d = NoOwner;
      cp_done_vld_d = 1'b1;
      cp_done_d = cp_complete_o;
    end
    if (shift_complete_vld_o && shift_complete_rdy_i) begin
      owner_d = NoOwner;
      shift_done_vld_d = 1'b1;
      shift_done_d = shift_complete_o;
    end
    if (ctrl_rsp_vld_o && ctrl_rsp_rdy_i) ctx_pending_d = 1'b0;
    if (ctx_vld_i && ctx_rdy_o) begin
      ctx_pending_d = 1'b1;
      ctx_create_d = ctx_create_i;
      ctx_route_d = ctx_id_i;
    end
    if (state_q == GATHER && rf_src_vld_i && rf_src_rdy_o) rf_vector_d = rf_src_data_i;
    if (state_q == OUTPUT_RF && rf_dst_rdy_i) rf_vector_d = '0;
    if (state_q == READ_RSP && bank_rd_rsp && rf_read_status == OK) begin
      for (thread_id = 0; thread_id < RF_THREADS; thread_id++) begin
        if (issued_q[thread_id]) begin
          if (pack_q) begin
            if (second_q) rf_vector_d[thread_id*32+16+:16] =
                bank_rd_data[map_cell1[thread_id*32+16+:7]*128+map_cell1[thread_id*32+:2]*32+:16];
            else rf_vector_d[thread_id*32+:16] =
                bank_rd_data[map_cell0[thread_id*32+16+:7]*128+map_cell0[thread_id*32+:2]*32+:16];
          end else rf_vector_d[thread_id*32+:32] =
              bank_rd_data[map_cell0[thread_id*32+16+:7]*128+map_cell0[thread_id*32+:2]*32+:32];
        end
      end
    end
            case (state_q)
                IDLE: if (cmd_vld_i && cmd_rdy_o) begin
                    ctx_d=cmd_ctx_i; epoch_d=cmd_epoch_i; warp_d=cmd_warp_i;
                    shape_d=cmd_shape_i; repeat_d=cmd_repeat_i;
                    base_d=cmd_base_addr_i; half_offset_d=cmd_half_offset_i;
                    pack_d=cmd_pack16_i; store_d=cmd_store_i; tag_d=cmd_tag_i;
                    count_d=cmd_shape_i == 3'd2 ? (9'(cmd_repeat_i) << 1) :
                             cmd_shape_i == 3'd3 ? (9'(cmd_repeat_i) << 2) :
                             9'(cmd_repeat_i);
                    reg_d=0; out_d=0; pending_d='1; issued_d='0;
                    second_d=1'b0; status_d=OK;
                    if (cmd_shape_i > 3'd4 || cmd_repeat_i == 0 || cmd_repeat_i > 8'd128 ||
                        (cmd_repeat_i & (cmd_repeat_i-8'd1)) != 0 ||
                        (cmd_shape_i == 3'd2 && cmd_repeat_i > 8'd64) ||
                        (cmd_shape_i == 3'd3 && cmd_repeat_i > 8'd32) ||
                        (cmd_shape_i == 0 ? cmd_base_addr_i[20:16] != 0 : cmd_base_addr_i[19:16] != 0) ||
                        (cmd_shape_i != 4 && cmd_half_offset_i != 0)) begin
                        status_d=BAD_SHAPE; state_d=DONE;
                    end else state_d=PROBE_REQ;
                end
                GATHER: if (rf_src_vld_i && rf_src_rdy_o) begin
                    if (rf_src_last_i != ({1'b0,reg_q}+9'd1 == count_q)) begin
                        status_d=BAD_SHAPE; state_d=DONE;
                    end else state_d=WRITE_REQ;
                end
                PROBE_REQ: if (!group_valid) begin
                    status_d=BAD_ADDR; state_d=DONE;
                end else if (bank_rd_rdy) begin
                    issued_d=group_selected; state_d=PROBE_RSP;
                end
                READ_REQ: if (!group_valid) begin
                    status_d=BAD_ADDR; state_d=DONE;
                end else if (bank_rd_rdy) begin
                    issued_d=group_selected; state_d=READ_RSP;
                end
                WRITE_REQ: if (!group_valid) begin
                    status_d=BAD_ADDR; state_d=DONE;
                end else if (bank_wr_rdy) begin
                    issued_d=group_selected; state_d=WRITE_RSP;
                end
                PROBE_RSP, READ_RSP: if (bank_rd_rsp) begin
                    if (rf_read_status != OK) begin
                        status_d=rf_read_status; state_d=DONE;
                    end else begin
                        if (pending_after_rsp != 0) begin
                            pending_d=pending_after_rsp;
                            state_d=state_q == PROBE_RSP ? PROBE_REQ : READ_REQ;
                        end else begin
                            pending_d='1;
                            if (pack_q && !second_q) begin
                                second_d=1'b1;
                                state_d=state_q == PROBE_RSP ? PROBE_REQ : READ_REQ;
                            end else begin
                                second_d=1'b0;
                                if (state_q == PROBE_RSP) begin
                                    if ({1'b0,reg_q}+9'd1 != count_q) begin
                                        reg_d=reg_q+8'd1;
                                        state_d=PROBE_REQ;
                                    end else begin
                                        reg_d=0;
                                        state_d=store_q ? GATHER : READ_REQ;
                                    end
                                end else begin
                                    out_d=reg_q;
                                    state_d=OUTPUT_RF;
                                end
                            end
                        end
                    end
                end
                WRITE_RSP: if (bank_wr_rsp) begin
                    if (rf_write_status != OK) begin
                        status_d=rf_write_status; state_d=DONE;
                    end else begin
                        if (pending_after_rsp != 0) begin
                            pending_d=pending_after_rsp;
                            state_d=WRITE_REQ;
                        end else begin
                            pending_d='1;
                            if (pack_q && !second_q) begin
                                second_d=1'b1;
                                state_d=WRITE_REQ;
                            end else begin
                                second_d=1'b0;
                                if ({1'b0,reg_q}+9'd1 != count_q) begin
                                    reg_d=reg_q+8'd1;
                                    state_d=GATHER;
                                end else state_d=DONE;
                            end
                        end
                    end
                end
                OUTPUT_RF: if (rf_dst_rdy_i) begin
                    if ({1'b0,out_q}+9'd1 == count_q) state_d=DONE;
                    else begin
                        reg_d=reg_q+8'd1;
                        pending_d='1;
                        second_d=1'b0;
                        state_d=READ_REQ;
                    end
                end
                DONE: if (tracker_finish_vld && tracker_finish_rdy) state_d=IDLE;
                default: begin status_d=ASYNC_BAD_COMPLETION; state_d=DONE; end
            endcase
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= IDLE;
      ctx_q <= '0;
      epoch_q <= '0;
      warp_q <= '0;
      shape_q <= '0;
      repeat_q <= '0;
      reg_q <= '0;
      out_q <= '0;
      count_q <= '0;
      pending_q <= '0;
      issued_q <= '0;
      second_q <= '0;
      base_q <= '0;
      half_offset_q <= '0;
      pack_q <= '0;
      store_q <= '0;
      tag_q <= '0;
      status_q <= '0;
      owner_q <= NoOwner;
      next_seq_q <= '0;
      seq_q <= '0;
      rf_vector_q <= '0;
      done_vld_q <= '0;
      done_store_q <= '0;
      done_tag_q <= '0;
      done_status_q <= '0;
      cp_done_vld_q <= '0;
      shift_done_vld_q <= '0;
      cp_done_q <= '0;
      shift_done_q <= '0;
      ctx_pending_q <= '0;
      ctx_create_q <= '0;
      ctx_route_q <= '0;
    end else begin
      state_q <= state_d;
      ctx_q <= ctx_d;
      epoch_q <= epoch_d;
      warp_q <= warp_d;
      shape_q <= shape_d;
      repeat_q <= repeat_d;
      reg_q <= reg_d;
      out_q <= out_d;
      count_q <= count_d;
      pending_q <= pending_d;
      issued_q <= issued_d;
      second_q <= second_d;
      base_q <= base_d;
      half_offset_q <= half_offset_d;
      pack_q <= pack_d;
      store_q <= store_d;
      tag_q <= tag_d;
      status_q <= status_d;
      owner_q <= owner_d;
      next_seq_q <= next_seq_d;
      seq_q <= seq_d;
      rf_vector_q <= rf_vector_d;
      done_vld_q <= done_vld_d;
      done_store_q <= done_store_d;
      done_tag_q <= done_tag_d;
      done_status_q <= done_status_d;
      cp_done_vld_q <= cp_done_vld_d;
      shift_done_vld_q <= shift_done_vld_d;
      cp_done_q <= cp_done_d;
      shift_done_q <= shift_done_d;
      ctx_pending_q <= ctx_pending_d;
      ctx_create_q <= ctx_create_d;
      ctx_route_q <= ctx_route_d;

    end
  end
  initial if (TAG_W != ASYNC_TAG_W || CONTEXTS < 1 || CONTEXTS > (1 << CTX_ID_W))
      $fatal(1, "RF A1 parameters");
`ifndef SYNTHESIS
  assert property (@(posedge clk) disable iff (!rst_n)
      $onehot0({rf_cmd_fire,cp_cmd_fire,shift_cmd_fire}));
  assert property (@(posedge clk) disable iff (!rst_n)
      !(mma_active_i && owner_q != NoOwner));
  assert property (@(posedge clk) disable iff (!rst_n)
      rf_dst_vld_o && !rf_dst_rdy_i |=> rf_dst_vld_o && $stable({rf_dst_data_o,rf_dst_index_o,rf_dst_last_o}));
  assert property (@(posedge clk) disable iff (!rst_n)
      done_vld_o && !done_rdy_i |=> done_vld_o && $stable({done_tag_o,done_store_o,done_status_o}));

`endif
endmodule
