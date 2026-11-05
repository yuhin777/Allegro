// Implements frozen A1: doc/specs/blackwell_async_subsystem_top.md
module blackwell_async_subsystem_top
  import blackwell_async_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic mma_cmd_vld_i,
  input blackwell_async_pkg::mma_cmd_a1_t mma_cmd_i,
  input logic mma_done_rdy_i,
  input logic tc_commit_vld_i,
  input blackwell_async_pkg::tc_commit_a1_t tc_commit_i,
  input logic tc_event_rdy_i,
  input logic ctx_vld_i,
  input logic [CTX_ID_W-1:0] ctx_id_i,
  input logic [EPOCH_W-1:0] ctx_epoch_i,
  input logic [ASYNC_TAG_W-1:0] ctx_tag_i,
  input logic ctx_create_i,
  input logic alloc_vld_i,
  input logic [CTX_ID_W-1:0] alloc_ctx_i,
  input logic [EPOCH_W-1:0] alloc_epoch_i,
  input logic [ASYNC_TAG_W-1:0] alloc_tag_i,
  input logic [TMEM_COLUMNS_COUNT_W-1:0] alloc_columns_i,
  input logic free_vld_i,
  input logic [CTX_ID_W-1:0] free_ctx_i,
  input logic [EPOCH_W-1:0] free_epoch_i,
  input logic [ASYNC_TAG_W-1:0] free_tag_i,
  input logic [TMEM_COLUMN_INDEX_W-1:0] free_base_i,
  input logic [TMEM_COLUMNS_COUNT_W-1:0] free_columns_i,
  input logic relinquish_vld_i,
  input logic [CTX_ID_W-1:0] relinquish_ctx_i,
  input logic [EPOCH_W-1:0] relinquish_epoch_i,
  input logic [ASYNC_TAG_W-1:0] relinquish_tag_i,
  input logic ctrl_rsp_rdy_i,
  input logic rf_cmd_vld_i,
  input logic rf_cmd_store_i,
  input logic [CTX_ID_W-1:0] rf_cmd_ctx_i,
  input logic [EPOCH_W-1:0] rf_cmd_epoch_i,
  input logic [WARP_ID_W-1:0] rf_cmd_warp_i,
  input logic [3-1:0] rf_cmd_shape_i,
  input logic [RF_REPEAT_W-1:0] rf_cmd_repeat_i,
  input logic rf_cmd_pack16_i,
  input logic [TMEM_HALF_OFFSET_W-1:0] rf_cmd_half_offset_i,
  input logic [ASYNC_TAG_W-1:0] rf_cmd_tag_i,
  input logic [TMEM_ADDR_W-1:0] rf_cmd_base_addr_i,
  input logic rf_src_vld_i,
  input logic [RF_BEAT_W-1:0] rf_src_data_i,
  input logic rf_src_last_i,
  input logic rf_dst_rdy_i,
  input logic rf_done_rdy_i,
  input logic rf_wait_vld_i,
  input logic [CTX_ID_W-1:0] rf_wait_ctx_i,
  input logic [EPOCH_W-1:0] rf_wait_epoch_i,
  input logic [WARP_ID_W-1:0] rf_wait_warp_i,
  input logic rf_wait_store_i,
  input logic [ASYNC_TAG_W-1:0] rf_wait_tag_i,
  input logic rf_wait_rsp_rdy_i,
  input logic tma_cmd_vld_i,
  input tma_mbarrier_pkg::tma_cmd_t tma_cmd_i,
  input logic tma_rsp_rdy_i,
  input logic bar_cmd_vld_i,
  input tma_mbarrier_pkg::bar_cmd_t bar_cmd_i,
  input logic bar_rsp_rdy_i,
  input logic tma_order_req_rdy_i,
  input logic tma_order_rsp_vld_i,
  input tma_mbarrier_pkg::bw_order_rsp_t tma_order_rsp_i,
  input logic bar_order_req_rdy_i,
  input logic bar_order_rsp_vld_i,
  input tma_mbarrier_pkg::bw_order_rsp_t bar_order_rsp_i,
  input logic gmem_req_rdy_i,
  input logic gmem_rsp_vld_i,
  input logic [GMEM_DATA_W-1:0] gmem_rsp_data_i,
  input logic [MEM_STATUS_W-1:0] gmem_rsp_status_i,
  input logic [GMEM_ID_DEFAULT_W-1:0] gmem_rsp_id_i,
  input logic smem_req_rdy_i,
  input logic smem_rsp_vld_i,
  input logic [SMEM_DATA_W-1:0] smem_rsp_data_i,
  input logic [MEM_STATUS_W-1:0] smem_rsp_status_i,
  input logic [SUBSYSTEM_SMEM_ID_DEFAULT_W-1:0] smem_rsp_id_i,
  input logic mma_smem_req_rdy_i,
  input logic mma_smem_rsp_vld_i,
  input logic [SMEM_DATA_W-1:0] mma_smem_rsp_data_i,
  input logic [TENSOR_SMEM_ID_W-1:0] mma_smem_rsp_id_i,
  input logic [MEM_STATUS_W-1:0] mma_smem_rsp_status_i,
  input logic cp_cmd_vld_i,
  input blackwell_async_pkg::cp_cmd_a1_t cp_cmd_i,
  input logic shift_cmd_vld_i,
  input blackwell_async_pkg::shift_cmd_a1_t shift_cmd_i,
  input logic cp_done_rdy_i,
  input logic shift_done_rdy_i,
  input logic async_req_vld_i,
  input tma_mbarrier_pkg::bw_async_req_t async_req_i,
  input logic async_cpl_req_vld_i,
  input tma_mbarrier_pkg::bw_async_req_t async_cpl_req_i,
  input logic async_rsp_rdy_i,
  input logic report_req_vld_i,
  input tma_mbarrier_pkg::bar_report_req_t report_req_i,
  input logic report_rsp_rdy_i,
  input logic stop_i,
  output logic mma_cmd_rdy_o,
  output logic mma_done_vld_o,
  output blackwell_async_pkg::async_event_a1_t mma_done_o,
  output logic tc_commit_rdy_o,
  output logic tc_event_vld_o,
  output blackwell_async_pkg::async_event_a1_t tc_event_o,
  output logic tc_protocol_error_o,
  output logic ctx_rdy_o,
  output logic alloc_rdy_o,
  output logic free_rdy_o,
  output logic relinquish_rdy_o,
  output logic ctrl_rsp_vld_o,
  output logic [ASYNC_TAG_W-1:0] ctrl_rsp_tag_o,
  output logic [STATUS_W-1:0] ctrl_rsp_status_o,
  output logic [TMEM_COLUMN_INDEX_W-1:0] ctrl_rsp_base_o,
  output logic rf_cmd_rdy_o,
  output logic rf_src_rdy_o,
  output logic rf_dst_vld_o,
  output logic [RF_BEAT_W-1:0] rf_dst_data_o,
  output logic [RF_INDEX_W-1:0] rf_dst_index_o,
  output logic rf_dst_last_o,
  output logic rf_done_vld_o,
  output logic [ASYNC_TAG_W-1:0] rf_done_tag_o,
  output logic rf_done_store_o,
  output logic [STATUS_W-1:0] rf_done_status_o,
  output logic rf_wait_rdy_o,
  output logic rf_wait_protocol_error_o,
  output logic rf_wait_rsp_vld_o,
  output logic [CTX_ID_W-1:0] rf_wait_rsp_ctx_o,
  output logic [EPOCH_W-1:0] rf_wait_rsp_epoch_o,
  output logic [WARP_ID_W-1:0] rf_wait_rsp_warp_o,
  output logic rf_wait_rsp_store_o,
  output logic [ASYNC_TAG_W-1:0] rf_wait_rsp_tag_o,
  output logic [STATUS_W-1:0] rf_wait_rsp_status_o,
  output logic tma_cmd_rdy_o,
  output logic tma_rsp_vld_o,
  output tma_mbarrier_pkg::tma_rsp_t tma_rsp_o,
  output logic bar_cmd_rdy_o,
  output logic bar_rsp_vld_o,
  output tma_mbarrier_pkg::bar_rsp_t bar_rsp_o,
  output logic tma_order_req_vld_o,
  output tma_mbarrier_pkg::bw_order_req_t tma_order_req_o,
  output logic tma_order_rsp_rdy_o,
  output logic bar_order_req_vld_o,
  output tma_mbarrier_pkg::bw_order_req_t bar_order_req_o,
  output logic bar_order_rsp_rdy_o,
  output logic gmem_req_vld_o,
  output logic [GMEM_ADDR_W-1:0] gmem_req_addr_o,
  output logic [GMEM_DATA_W-1:0] gmem_req_data_o,
  output logic [GMEM_MASK_W-1:0] gmem_req_byte_mask_o,
  output logic [GMEM_ID_DEFAULT_W-1:0] gmem_req_id_o,
  output logic gmem_req_write_o,
  output tma_mbarrier_pkg::bw_mem_attr_t gmem_req_attr_o,
  output logic gmem_rsp_rdy_o,
  output logic smem_req_vld_o,
  output logic [SMEM_BYTE_ADDR_W-1:0] smem_req_addr_o,
  output logic [SMEM_DATA_W-1:0] smem_req_data_o,
  output logic [SMEM_MASK_W-1:0] smem_req_byte_mask_o,
  output logic [SUBSYSTEM_SMEM_ID_DEFAULT_W-1:0] smem_req_id_o,
  output logic smem_req_write_o,
  output tma_mbarrier_pkg::bw_mem_attr_t smem_req_attr_o,
  output logic smem_rsp_rdy_o,
  output logic mma_smem_req_vld_o,
  output logic [SMEM_BYTE_ADDR_W-1:0] mma_smem_req_addr_o,
  output logic [TENSOR_SMEM_ID_W-1:0] mma_smem_req_id_o,
  output logic [SMEM_MASK_W-1:0] mma_smem_req_byte_mask_o,
  output logic mma_smem_rsp_rdy_o,
  output logic cp_cmd_rdy_o,
  output logic shift_cmd_rdy_o,
  output logic cp_done_vld_o,
  output blackwell_async_pkg::async_event_a1_t cp_done_o,
  output logic shift_done_vld_o,
  output blackwell_async_pkg::async_event_a1_t shift_done_o,
  output logic async_req_rdy_o,
  output logic async_cpl_req_rdy_o,
  output logic async_rsp_vld_o,
  output tma_mbarrier_pkg::bw_async_rsp_t async_rsp_o,
  output logic report_req_rdy_o,
  output logic report_rsp_vld_o,
  output tma_mbarrier_pkg::bar_rsp_t report_rsp_o,
  output logic idle_o,
  output logic drained_o
);

  logic rf_dispatch;
  logic shift_dispatch;
  logic shift_complete_rdy_i;
  logic mma_owner;
  logic bank_rd_vld;
  logic [CTX_ID_W-1:0] bank_rd_ctx;
  logic [EPOCH_W-1:0] bank_rd_epoch;
  logic [TMEM_LANE_MASK_W-1:0] bank_rd_lane_mask;
  logic [TMEM_COLUMN_BUS_W-1:0] bank_rd_column;
  logic [ASYNC_TAG_W-1:0] bank_rd_tag;
  logic bank_rd_rsp_rdy;
  logic bank_wr_vld;
  logic [CTX_ID_W-1:0] bank_wr_ctx;
  logic [EPOCH_W-1:0] bank_wr_epoch;
  logic [TMEM_COLUMN_BUS_W-1:0] bank_wr_column;
  logic [TMEM_DATA_W-1:0] bank_wr_data;
  logic [TMEM_BYTE_MASK_W-1:0] bank_wr_byte_mask;
  logic [ASYNC_TAG_W-1:0] bank_wr_tag;
  logic bank_wr_rsp_rdy;
  logic cp_dispatch;
  logic cp_complete_rdy_i;
  logic cp_smem_req_rdy;
  logic cp_smem_rsp_vld;
  logic [SMEM_DATA_W-1:0] cp_smem_rsp_data;
  logic [TENSOR_SMEM_ID_W-1:0] cp_smem_rsp_id;
  logic [MEM_STATUS_W-1:0] cp_smem_rsp_status;
  logic dispatch_stop;
  logic management_enable;
  logic rf_ready;
  logic shift_ready;
  logic shift_complete_vld_o;
  blackwell_async_pkg::async_event_a1_t shift_complete_o;
  logic bank_idle;
  logic bank_rd_rdy;
  logic bank_rd_rsp_vld;
  logic [TMEM_DATA_W-1:0] bank_rd_rsp_data;
  logic [STATUS_W-1:0] bank_rd_rsp_status;
  logic bank_wr_rdy;
  logic bank_wr_rsp_vld;
  logic [STATUS_W-1:0] bank_wr_rsp_status;
  logic cp_ready;
  logic cp_complete_vld_o;
  blackwell_async_pkg::async_event_a1_t cp_complete_o;
  logic cp_smem_req_vld;
  logic [SMEM_BYTE_ADDR_W-1:0] cp_smem_req_addr;
  logic [SMEM_MASK_W-1:0] cp_smem_req_byte_mask;
  logic [TENSOR_SMEM_ID_W-1:0] cp_smem_req_id;
  logic cp_smem_rsp_rdy;
  logic rf_idle;
  logic rf_drained;
  logic mma_dispatch;
  logic mma_complete_rdy;
  logic tensor_smem_req_rdy;
  logic tensor_smem_rsp_vld;
  logic [SMEM_DATA_W-1:0] tensor_smem_rsp_data;
  logic [TENSOR_SMEM_ID_W-1:0] tensor_smem_rsp_id;
  logic [MEM_STATUS_W-1:0] tensor_smem_rsp_status;
  logic mma_ready;
  logic mma_complete_vld;
  blackwell_async_pkg::async_event_a1_t mma_complete;
  logic tensor_smem_req_vld;
  logic [SMEM_BYTE_ADDR_W-1:0] tensor_smem_req_addr;
  logic [TENSOR_SMEM_ID_W-1:0] tensor_smem_req_id;
  logic [SMEM_MASK_W-1:0] tensor_smem_req_byte_mask;
  logic tensor_smem_rsp_rdy;
  logic mma_idle;
  logic tc_register_vld;
  blackwell_async_pkg::async_key_a1_t tc_register;
  logic tc_complete_vld;
  blackwell_async_pkg::async_event_a1_t tc_complete;
  logic tc_bar_rdy;
  logic tc_bar_rsp_vld;
  tma_mbarrier_pkg::bar_rsp_t tc_bar_rsp;
  logic tc_register_rdy;
  logic tc_complete_rdy;
  logic tc_bar_vld;
  tma_mbarrier_pkg::bar_cmd_t tc_bar;
  logic tc_bar_rsp_rdy;
  logic tracker_protocol_error;
  logic tc_idle;
  logic tc_drained;
  logic tma_bar_idle;
  logic tma_bar_drained;

  typedef enum logic [2:0] {NoOwner, MmaOwner, RfOwner, CpOwner, ShiftOwner} owner_t;
  owner_t owner_q, owner_d;
  logic [1:0] rr_q, rr_d;
  logic [3:0] candidate;
  integer selection;
  logic management_pending;
  logic mma_done_vld_q, mma_done_vld_d;
  async_event_a1_t mma_done_q, mma_done_d;
  logic tensor_protocol_error_q, tensor_protocol_error_d;

  assign mma_owner = owner_q == MmaOwner;
  // Pending allocation never blocks free: all management channels stay connected.
  assign management_pending = ctx_vld_i || alloc_vld_i || free_vld_i ||
      relinquish_vld_i || ctrl_rsp_vld_o;
  assign dispatch_stop = stop_i || management_pending;
  assign management_enable = drained_o;
  assign idle_o = mma_idle && rf_idle && tc_idle && tma_bar_idle;
  assign drained_o = mma_idle && rf_drained && tc_drained && tma_bar_drained &&
      !mma_done_vld_q && owner_q == NoOwner;
  assign mma_done_vld_o = mma_done_vld_q;
  assign mma_done_o = mma_done_q;
  assign tc_protocol_error_o = tracker_protocol_error || tensor_protocol_error_q;

  // Each candidate's ordinary notification slot and executor are reserved here.
  // With command-level mutual exclusion the preceding TC data op has retired
  // before another data command can be considered; register_rdy still gates fire.
  always_comb begin
    int offset;
    offset = 0;
    candidate = '0;
    if (!dispatch_stop && owner_q == NoOwner && bank_idle) begin
      candidate[0] = mma_cmd_vld_i && mma_ready && !mma_done_vld_q;
      candidate[1] = rf_cmd_vld_i && rf_ready;
      candidate[2] = cp_cmd_vld_i && cp_ready;
      candidate[3] = shift_cmd_vld_i && shift_ready;
    end
    selection = -1;
    for (offset = 0; offset < 4; offset++) begin
      if (candidate[(int'(rr_q)+offset)%4] && selection < 0)
        selection = (int'(rr_q)+offset)%4;
    end
    tc_register = '0;
    case (selection)
      0: tc_register = {mma_cmd_i.ctx,mma_cmd_i.id};
      2: tc_register = {cp_cmd_i.ctx,cp_cmd_i.id};
      3: tc_register = {shift_cmd_i.ctx,shift_cmd_i.id};
      default: tc_register = '0;
    endcase
  end
  always_comb begin
    mma_cmd_rdy_o = selection == 0 && tc_register_rdy;
    rf_cmd_rdy_o = selection == 1;
    cp_cmd_rdy_o = selection == 2 && tc_register_rdy;
    shift_cmd_rdy_o = selection == 3 && tc_register_rdy;
    mma_dispatch = mma_cmd_vld_i && mma_cmd_rdy_o;
    rf_dispatch = rf_cmd_vld_i && rf_cmd_rdy_o;
    cp_dispatch = cp_cmd_vld_i && cp_cmd_rdy_o;
    shift_dispatch = shift_cmd_vld_i && shift_cmd_rdy_o;
    tc_register_vld = mma_dispatch || cp_dispatch || shift_dispatch;

    tc_complete_vld = 1'b0;
    tc_complete = '0;
    mma_complete_rdy = 1'b0;
    cp_complete_rdy_i = 1'b0;
    shift_complete_rdy_i = 1'b0;
    case (owner_q)
      MmaOwner: begin
        tc_complete_vld = mma_complete_vld && !mma_done_vld_q;
        tc_complete = mma_complete;
        mma_complete_rdy = tc_complete_rdy && !mma_done_vld_q;
      end
      CpOwner: begin
        tc_complete_vld = cp_complete_vld_o;
        tc_complete = cp_complete_o;
        cp_complete_rdy_i = tc_complete_rdy;
      end
      ShiftOwner: begin
        tc_complete_vld = shift_complete_vld_o;
        tc_complete = shift_complete_o;
        shift_complete_rdy_i = tc_complete_rdy;
      end
      default: ;
    endcase

    mma_smem_req_vld_o = 1'b0;
    mma_smem_req_addr_o = '0;
    mma_smem_req_byte_mask_o = '0;
    mma_smem_req_id_o = '0;
    tensor_smem_req_rdy = 1'b0;
    cp_smem_req_rdy = 1'b0;
    tensor_smem_rsp_vld = 1'b0;
    cp_smem_rsp_vld = 1'b0;
    mma_smem_rsp_rdy_o = 1'b1;
    if (owner_q == MmaOwner) begin
      mma_smem_req_vld_o = tensor_smem_req_vld;
      mma_smem_req_addr_o = tensor_smem_req_addr;
      mma_smem_req_byte_mask_o = tensor_smem_req_byte_mask;
      mma_smem_req_id_o = tensor_smem_req_id;
      tensor_smem_req_rdy = mma_smem_req_rdy_i;
      tensor_smem_rsp_vld = mma_smem_rsp_vld_i;
      mma_smem_rsp_rdy_o = tensor_smem_rsp_rdy;
    end else if (owner_q == CpOwner) begin
      mma_smem_req_vld_o = cp_smem_req_vld;
      mma_smem_req_addr_o = cp_smem_req_addr;
      mma_smem_req_byte_mask_o = cp_smem_req_byte_mask;
      mma_smem_req_id_o = cp_smem_req_id;
      cp_smem_req_rdy = mma_smem_req_rdy_i;
      cp_smem_rsp_vld = mma_smem_rsp_vld_i;
      mma_smem_rsp_rdy_o = cp_smem_rsp_rdy;
    end
  end
  assign tensor_smem_rsp_data = mma_smem_rsp_data_i;
  assign tensor_smem_rsp_id = mma_smem_rsp_id_i;
  assign tensor_smem_rsp_status = mma_smem_rsp_status_i;
  assign cp_smem_rsp_data = mma_smem_rsp_data_i;
  assign cp_smem_rsp_id = mma_smem_rsp_id_i;
  assign cp_smem_rsp_status = mma_smem_rsp_status_i;

  always_comb begin
    owner_d = owner_q;
    rr_d = rr_q;
    mma_done_vld_d = mma_done_vld_q;
    mma_done_d = mma_done_q;
    tensor_protocol_error_d = mma_smem_rsp_vld_i && mma_smem_rsp_rdy_o &&
        owner_q != MmaOwner && owner_q != CpOwner;
    if (mma_done_vld_q && mma_done_rdy_i) mma_done_vld_d = 1'b0;
    if (owner_q == RfOwner && bank_idle) owner_d = NoOwner;
    if (tc_complete_vld && tc_complete_rdy) begin
      if (owner_q == MmaOwner) begin
        mma_done_vld_d = 1'b1;
        mma_done_d = mma_complete;
      end
      owner_d = NoOwner;
    end
    if (mma_dispatch || rf_dispatch || cp_dispatch || shift_dispatch) begin
      case (selection)
        0: owner_d = MmaOwner;
        1: owner_d = RfOwner;
        2: owner_d = CpOwner;
        3: owner_d = ShiftOwner;
        default: ;
      endcase
      rr_d = 2'(selection+1);
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      owner_q <= NoOwner;
      rr_q <= '0;
      mma_done_vld_q <= 1'b0;
      mma_done_q <= '0;
      tensor_protocol_error_q <= 1'b0;
    end else begin
      owner_q <= owner_d;
      rr_q <= rr_d;
      mma_done_vld_q <= mma_done_vld_d;
      mma_done_q <= mma_done_d;
      tensor_protocol_error_q <= tensor_protocol_error_d;
    end
  end
`ifndef SYNTHESIS
  assert property (@(posedge clk) disable iff (!rst_n)
      $onehot0({mma_dispatch,rf_dispatch,cp_dispatch,shift_dispatch}));
  assert property (@(posedge clk) disable iff (!rst_n)
      tc_register_vld |-> tc_register_rdy);
  assert property (@(posedge clk) disable iff (!rst_n)
      mma_done_vld_o && !mma_done_rdy_i |=> mma_done_vld_o && $stable(mma_done_o));
  assert property (@(posedge clk) disable iff (!rst_n)
      mma_smem_req_vld_o && !mma_smem_req_rdy_i |=>
      mma_smem_req_vld_o && $stable({mma_smem_req_addr_o,mma_smem_req_id_o,mma_smem_req_byte_mask_o}));

`endif
  blackwell_tmem_rf_subsystem u_rf (
    .clk(clk),
    .rst_n(rst_n),
    .ctx_vld_i(ctx_vld_i),
    .ctx_id_i(ctx_id_i),
    .ctx_epoch_i(ctx_epoch_i),
    .ctx_tag_i(ctx_tag_i),
    .ctx_create_i(ctx_create_i),
    .alloc_vld_i(alloc_vld_i),
    .alloc_ctx_i(alloc_ctx_i),
    .alloc_epoch_i(alloc_epoch_i),
    .alloc_tag_i(alloc_tag_i),
    .alloc_columns_i(alloc_columns_i),
    .free_vld_i(free_vld_i),
    .free_ctx_i(free_ctx_i),
    .free_epoch_i(free_epoch_i),
    .free_tag_i(free_tag_i),
    .free_base_i(free_base_i),
    .free_columns_i(free_columns_i),
    .relinquish_vld_i(relinquish_vld_i),
    .relinquish_ctx_i(relinquish_ctx_i),
    .relinquish_epoch_i(relinquish_epoch_i),
    .relinquish_tag_i(relinquish_tag_i),
    .ctrl_rsp_rdy_i(ctrl_rsp_rdy_i),
    .cmd_vld_i(rf_dispatch),
    .cmd_store_i(rf_cmd_store_i),
    .cmd_ctx_i(rf_cmd_ctx_i),
    .cmd_epoch_i(rf_cmd_epoch_i),
    .cmd_warp_i(rf_cmd_warp_i),
    .cmd_shape_i(rf_cmd_shape_i),
    .cmd_repeat_i(rf_cmd_repeat_i),
    .cmd_pack16_i(rf_cmd_pack16_i),
    .cmd_half_offset_i(rf_cmd_half_offset_i),
    .cmd_tag_i(rf_cmd_tag_i),
    .cmd_base_addr_i(rf_cmd_base_addr_i),
    .rf_src_vld_i(rf_src_vld_i),
    .rf_src_data_i(rf_src_data_i),
    .rf_src_last_i(rf_src_last_i),
    .rf_dst_rdy_i(rf_dst_rdy_i),
    .done_rdy_i(rf_done_rdy_i),
    .shift_cmd_vld_i(shift_dispatch),
    .shift_cmd_i(shift_cmd_i),
    .shift_complete_rdy_i(shift_complete_rdy_i),
    .shift_done_rdy_i(shift_done_rdy_i),
    .wait_vld_i(rf_wait_vld_i),
    .wait_ctx_i(rf_wait_ctx_i),
    .wait_epoch_i(rf_wait_epoch_i),
    .wait_warp_i(rf_wait_warp_i),
    .wait_store_i(rf_wait_store_i),
    .wait_tag_i(rf_wait_tag_i),
    .wait_rsp_rdy_i(rf_wait_rsp_rdy_i),
    .mma_active_i(mma_owner),
    .mma_rd_vld_i(bank_rd_vld),
    .mma_rd_ctx_i(bank_rd_ctx),
    .mma_rd_epoch_i(bank_rd_epoch),
    .mma_rd_lane_mask_i(bank_rd_lane_mask),
    .mma_rd_column_i(bank_rd_column),
    .mma_rd_tag_i(bank_rd_tag),
    .mma_rd_rsp_rdy_i(bank_rd_rsp_rdy),
    .mma_wr_vld_i(bank_wr_vld),
    .mma_wr_ctx_i(bank_wr_ctx),
    .mma_wr_epoch_i(bank_wr_epoch),
    .mma_wr_column_i(bank_wr_column),
    .mma_wr_data_i(bank_wr_data),
    .mma_wr_byte_mask_i(bank_wr_byte_mask),
    .mma_wr_tag_i(bank_wr_tag),
    .mma_wr_rsp_rdy_i(bank_wr_rsp_rdy),
    .cp_cmd_vld_i(cp_dispatch),
    .cp_cmd_i(cp_cmd_i),
    .cp_complete_rdy_i(cp_complete_rdy_i),
    .cp_done_rdy_i(cp_done_rdy_i),
    .cp_smem_req_rdy_i(cp_smem_req_rdy),
    .cp_smem_rsp_vld_i(cp_smem_rsp_vld),
    .cp_smem_rsp_data_i(cp_smem_rsp_data),
    .cp_smem_rsp_id_i(cp_smem_rsp_id),
    .cp_smem_rsp_status_i(cp_smem_rsp_status),
    .stop_i(dispatch_stop),
    .management_enable_i(management_enable),
    .ctx_rdy_o(ctx_rdy_o),
    .alloc_rdy_o(alloc_rdy_o),
    .free_rdy_o(free_rdy_o),
    .relinquish_rdy_o(relinquish_rdy_o),
    .ctrl_rsp_vld_o(ctrl_rsp_vld_o),
    .ctrl_rsp_tag_o(ctrl_rsp_tag_o),
    .ctrl_rsp_status_o(ctrl_rsp_status_o),
    .ctrl_rsp_base_o(ctrl_rsp_base_o),
    .cmd_rdy_o(rf_ready),
    .rf_src_rdy_o(rf_src_rdy_o),
    .rf_dst_vld_o(rf_dst_vld_o),
    .rf_dst_data_o(rf_dst_data_o),
    .rf_dst_index_o(rf_dst_index_o),
    .rf_dst_last_o(rf_dst_last_o),
    .done_vld_o(rf_done_vld_o),
    .done_tag_o(rf_done_tag_o),
    .done_store_o(rf_done_store_o),
    .done_status_o(rf_done_status_o),
    .shift_cmd_rdy_o(shift_ready),
    .shift_complete_vld_o(shift_complete_vld_o),
    .shift_complete_o(shift_complete_o),
    .shift_done_vld_o(shift_done_vld_o),
    .shift_done_o(shift_done_o),
    .wait_rdy_o(rf_wait_rdy_o),
    .wait_protocol_error_o(rf_wait_protocol_error_o),
    .wait_rsp_vld_o(rf_wait_rsp_vld_o),
    .wait_rsp_ctx_o(rf_wait_rsp_ctx_o),
    .wait_rsp_epoch_o(rf_wait_rsp_epoch_o),
    .wait_rsp_warp_o(rf_wait_rsp_warp_o),
    .wait_rsp_store_o(rf_wait_rsp_store_o),
    .wait_rsp_tag_o(rf_wait_rsp_tag_o),
    .wait_rsp_status_o(rf_wait_rsp_status_o),
    .mma_idle_o(bank_idle),
    .mma_rd_rdy_o(bank_rd_rdy),
    .mma_rd_rsp_vld_o(bank_rd_rsp_vld),
    .mma_rd_rsp_data_o(bank_rd_rsp_data),
    .mma_rd_rsp_status_o(bank_rd_rsp_status),
    .mma_wr_rdy_o(bank_wr_rdy),
    .mma_wr_rsp_vld_o(bank_wr_rsp_vld),
    .mma_wr_rsp_status_o(bank_wr_rsp_status),
    .cp_cmd_rdy_o(cp_ready),
    .cp_complete_vld_o(cp_complete_vld_o),
    .cp_complete_o(cp_complete_o),
    .cp_done_vld_o(cp_done_vld_o),
    .cp_done_o(cp_done_o),
    .cp_smem_req_vld_o(cp_smem_req_vld),
    .cp_smem_req_addr_o(cp_smem_req_addr),
    .cp_smem_req_byte_mask_o(cp_smem_req_byte_mask),
    .cp_smem_req_id_o(cp_smem_req_id),
    .cp_smem_rsp_rdy_o(cp_smem_rsp_rdy),
    .idle_o(rf_idle),
    .drained_o(rf_drained)
  );
  blackwell_tc_mma_engine u_mma (
    .clk(clk),
    .rst_n(rst_n),
    .cmd_vld_i(mma_dispatch),
    .cmd_i(mma_cmd_i),
    .complete_rdy_i(mma_complete_rdy),
    .smem_req_rdy_i(tensor_smem_req_rdy),
    .smem_rsp_vld_i(tensor_smem_rsp_vld),
    .smem_rsp_data_i(tensor_smem_rsp_data),
    .smem_rsp_id_i(tensor_smem_rsp_id),
    .smem_rsp_status_i(tensor_smem_rsp_status),
    .tmem_rd_rdy_i(bank_rd_rdy),
    .tmem_rd_rsp_vld_i(bank_rd_rsp_vld),
    .tmem_rd_rsp_data_i(bank_rd_rsp_data),
    .tmem_rd_rsp_status_i(bank_rd_rsp_status),
    .tmem_wr_rdy_i(bank_wr_rdy),
    .tmem_wr_rsp_vld_i(bank_wr_rsp_vld),
    .tmem_wr_rsp_status_i(bank_wr_rsp_status),
    .cmd_rdy_o(mma_ready),
    .complete_vld_o(mma_complete_vld),
    .complete_o(mma_complete),
    .smem_req_vld_o(tensor_smem_req_vld),
    .smem_req_addr_o(tensor_smem_req_addr),
    .smem_req_id_o(tensor_smem_req_id),
    .smem_req_byte_mask_o(tensor_smem_req_byte_mask),
    .smem_rsp_rdy_o(tensor_smem_rsp_rdy),
    .tmem_rd_vld_o(bank_rd_vld),
    .tmem_rd_ctx_o(bank_rd_ctx),
    .tmem_rd_epoch_o(bank_rd_epoch),
    .tmem_rd_lane_mask_o(bank_rd_lane_mask),
    .tmem_rd_column_o(bank_rd_column),
    .tmem_rd_tag_o(bank_rd_tag),
    .tmem_rd_rsp_rdy_o(bank_rd_rsp_rdy),
    .tmem_wr_vld_o(bank_wr_vld),
    .tmem_wr_ctx_o(bank_wr_ctx),
    .tmem_wr_epoch_o(bank_wr_epoch),
    .tmem_wr_column_o(bank_wr_column),
    .tmem_wr_data_o(bank_wr_data),
    .tmem_wr_byte_mask_o(bank_wr_byte_mask),
    .tmem_wr_tag_o(bank_wr_tag),
    .tmem_wr_rsp_rdy_o(bank_wr_rsp_rdy),
    .idle_o(mma_idle)
  );
  blackwell_tc_async_completion u_tc (
    .clk(clk),
    .rst_n(rst_n),
    .register_vld_i(tc_register_vld),
    .register_i(tc_register),
    .complete_vld_i(tc_complete_vld),
    .complete_i(tc_complete),
    .commit_vld_i(tc_commit_vld_i),
    .commit_i(tc_commit_i),
    .bar_rdy_i(tc_bar_rdy),
    .bar_rsp_vld_i(tc_bar_rsp_vld),
    .bar_rsp_i(tc_bar_rsp),
    .event_rdy_i(tc_event_rdy_i),
    .stop_i(dispatch_stop),
    .register_rdy_o(tc_register_rdy),
    .complete_rdy_o(tc_complete_rdy),
    .commit_rdy_o(tc_commit_rdy_o),
    .bar_vld_o(tc_bar_vld),
    .bar_o(tc_bar),
    .bar_rsp_rdy_o(tc_bar_rsp_rdy),
    .event_vld_o(tc_event_vld_o),
    .event_o(tc_event_o),
    .protocol_error_o(tracker_protocol_error),
    .idle_o(tc_idle),
    .drained_o(tc_drained)
  );
  blackwell_tma_mbarrier_subsystem u_tma_bar (
    .clk(clk),
    .rst_n(rst_n),
    .tma_cmd_vld_i(tma_cmd_vld_i),
    .tma_cmd_i(tma_cmd_i),
    .tma_rsp_rdy_i(tma_rsp_rdy_i),
    .gmem_req_rdy_i(gmem_req_rdy_i),
    .smem_req_rdy_i(smem_req_rdy_i),
    .tma_order_req_rdy_i(tma_order_req_rdy_i),
    .tma_order_rsp_vld_i(tma_order_rsp_vld_i),
    .tma_order_rsp_i(tma_order_rsp_i),
    .tc_arrive_vld_i(tc_bar_vld),
    .tc_arrive_i(tc_bar),
    .tc_arrive_rsp_rdy_i(tc_bar_rsp_rdy),
    .bar_cmd_vld_i(bar_cmd_vld_i),
    .bar_cmd_i(bar_cmd_i),
    .bar_rsp_rdy_i(bar_rsp_rdy_i),
    .async_cpl_req_vld_i(async_cpl_req_vld_i),
    .async_cpl_req_i(async_cpl_req_i),
    .async_req_vld_i(async_req_vld_i),
    .async_req_i(async_req_i),
    .async_rsp_rdy_i(async_rsp_rdy_i),
    .report_req_vld_i(report_req_vld_i),
    .report_req_i(report_req_i),
    .report_rsp_rdy_i(report_rsp_rdy_i),
    .bar_order_req_rdy_i(bar_order_req_rdy_i),
    .bar_order_rsp_vld_i(bar_order_rsp_vld_i),
    .bar_order_rsp_i(bar_order_rsp_i),
    .gmem_rsp_vld_i(gmem_rsp_vld_i),
    .gmem_rsp_data_i(gmem_rsp_data_i),
    .gmem_rsp_status_i(gmem_rsp_status_i),
    .gmem_rsp_id_i(gmem_rsp_id_i),
    .smem_rsp_vld_i(smem_rsp_vld_i),
    .smem_rsp_data_i(smem_rsp_data_i),
    .smem_rsp_status_i(smem_rsp_status_i),
    .smem_rsp_id_i(smem_rsp_id_i),
    .stop_i(dispatch_stop),
    .tma_cmd_rdy_o(tma_cmd_rdy_o),
    .tma_rsp_vld_o(tma_rsp_vld_o),
    .tma_rsp_o(tma_rsp_o),
    .gmem_req_vld_o(gmem_req_vld_o),
    .gmem_req_attr_o(gmem_req_attr_o),
    .gmem_req_addr_o(gmem_req_addr_o),
    .gmem_req_data_o(gmem_req_data_o),
    .gmem_req_byte_mask_o(gmem_req_byte_mask_o),
    .gmem_req_id_o(gmem_req_id_o),
    .gmem_req_write_o(gmem_req_write_o),
    .smem_req_vld_o(smem_req_vld_o),
    .smem_req_attr_o(smem_req_attr_o),
    .smem_req_addr_o(smem_req_addr_o),
    .smem_req_data_o(smem_req_data_o),
    .smem_req_byte_mask_o(smem_req_byte_mask_o),
    .smem_req_id_o(smem_req_id_o),
    .smem_req_write_o(smem_req_write_o),
    .tma_order_req_vld_o(tma_order_req_vld_o),
    .tma_order_req_o(tma_order_req_o),
    .tma_order_rsp_rdy_o(tma_order_rsp_rdy_o),
    .tc_arrive_rdy_o(tc_bar_rdy),
    .tc_arrive_rsp_vld_o(tc_bar_rsp_vld),
    .tc_arrive_rsp_o(tc_bar_rsp),
    .bar_cmd_rdy_o(bar_cmd_rdy_o),
    .bar_rsp_vld_o(bar_rsp_vld_o),
    .bar_rsp_o(bar_rsp_o),
    .async_cpl_req_rdy_o(async_cpl_req_rdy_o),
    .async_req_rdy_o(async_req_rdy_o),
    .async_rsp_vld_o(async_rsp_vld_o),
    .async_rsp_o(async_rsp_o),
    .report_req_rdy_o(report_req_rdy_o),
    .report_rsp_vld_o(report_rsp_vld_o),
    .report_rsp_o(report_rsp_o),
    .bar_order_req_vld_o(bar_order_req_vld_o),
    .bar_order_req_o(bar_order_req_o),
    .bar_order_rsp_rdy_o(bar_order_rsp_rdy_o),
    .gmem_rsp_rdy_o(gmem_rsp_rdy_o),
    .smem_rsp_rdy_o(smem_rsp_rdy_o),
    .idle_o(tma_bar_idle),
    .drained_o(tma_bar_drained)
  );
endmodule
