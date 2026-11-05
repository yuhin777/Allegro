// Implements frozen A1: doc/specs/blackwell_tmem_cp_engine.md
module blackwell_tmem_cp_engine
  import blackwell_async_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic cmd_vld_i,
  input blackwell_async_pkg::cp_cmd_a1_t cmd_i,
  input logic complete_rdy_i,
  input logic smem_req_rdy_i,
  input logic smem_rsp_vld_i,
  input logic [SMEM_DATA_W-1:0] smem_rsp_data_i,
  input logic [TENSOR_SMEM_ID_W-1:0] smem_rsp_id_i,
  input logic [MEM_STATUS_W-1:0] smem_rsp_status_i,
  input logic rd_rdy_i,
  input logic rd_rsp_vld_i,
  input logic [STATUS_W-1:0] rd_rsp_status_i,
  input logic [TMEM_DATA_W-1:0] rd_rsp_data_i,
  input logic wr_rdy_i,
  input logic wr_rsp_vld_i,
  input logic [STATUS_W-1:0] wr_rsp_status_i,
  output logic cmd_rdy_o,
  output logic complete_vld_o,
  output blackwell_async_pkg::async_event_a1_t complete_o,
  output logic smem_req_vld_o,
  output logic [SMEM_BYTE_ADDR_W-1:0] smem_req_addr_o,
  output logic [SMEM_MASK_W-1:0] smem_req_byte_mask_o,
  output logic [TENSOR_SMEM_ID_W-1:0] smem_req_id_o,
  output logic smem_rsp_rdy_o,
  output logic rd_vld_o,
  output logic [CTX_ID_W-1:0] rd_ctx_o,
  output logic [EPOCH_W-1:0] rd_epoch_o,
  output logic [TMEM_COLUMN_BUS_W-1:0] rd_column_o,
  output logic [ASYNC_TAG_W-1:0] rd_tag_o,
  output logic [TMEM_LANE_MASK_W-1:0] rd_lane_mask_o,
  output logic rd_rsp_rdy_o,
  output logic wr_vld_o,
  output logic [CTX_ID_W-1:0] wr_ctx_o,
  output logic [EPOCH_W-1:0] wr_epoch_o,
  output logic [TMEM_COLUMN_BUS_W-1:0] wr_column_o,
  output logic [ASYNC_TAG_W-1:0] wr_tag_o,
  output logic [TMEM_DATA_W-1:0] wr_data_o,
  output logic [TMEM_BYTE_MASK_W-1:0] wr_byte_mask_o,
  output logic wr_rsp_rdy_o,
  output logic idle_o
);

  typedef enum logic [3:0] {
    Idle, CheckSource, ProbeReq, ProbeRsp, SourceReq, SourceRsp, WriteReq, WriteRsp, Complete
  } state_t;
  state_t state_q, state_d;
  cp_cmd_a1_t cmd_q, cmd_d;
  logic [STATUS_W-1:0] status_q, status_d;
  logic [7:0] row_q, row_d;
  logic chunk_q, chunk_d;
  logic [3:0] check_byte_q, check_byte_d;
  logic [SMEM_DATA_W-1:0] source_q, source_d;
  logic [TMEM_WORD_W-1:0] expanded;
  logic [63:0] source_address, check_address;
  logic [7:0] source_rows;
  logic [4:0] source_bytes;
  logic chunks_two, source_last;
  logic [TMEM_COLUMN_FIELD_W-1:0] target_column;
  logic command_legal;

  assign source_rows = cmd_q.shape == 3'd4 ? 8'd4 :
                       cmd_q.shape == 3'd3 ? 8'd32 :
                       cmd_q.shape == 3'd2 ? 8'd64 : 8'd128;
  assign source_bytes = cmd_q.source_format == 2'd1 ? 5'd8 :
                        cmd_q.source_format == 2'd2 ? 5'd12 : 5'd16;
  assign chunks_two = cmd_q.shape == 3'd0 || cmd_q.shape == 3'd4;
  assign source_last = row_q == source_rows - 8'd1 && (!chunks_two || chunk_q);
  assign source_address = matrix_byte_address(cmd_q.smem_desc,32'(row_q),chunk_q ? 32'd16 : 32'd0,1'b0);
  assign check_address = matrix_byte_address(cmd_q.smem_desc,32'(row_q),
      (chunk_q ? 32'd16 : 32'd0) + 32'(check_byte_q),1'b0);
  assign target_column = cmd_q.base_addr[15:0] + (chunk_q ? 16'd4 : 16'd0);
  assign command_legal = cmd_i.shape <= 3'd4 && cmd_i.source_format <= 2'd2 &&
      matrix_descriptor_valid(cmd_i.smem_desc) && cmd_i.smem_desc[63:61] != 3'd1 &&
      cmd_i.base_addr[1:0] == 0 &&
      cmd_i.base_addr[15:0] <= ((cmd_i.shape == 0 || cmd_i.shape == 4) ? 16'd504 : 16'd508) &&
      ((cmd_i.shape == 4) ? cmd_i.base_addr[31:16] < 16'd32 : cmd_i.base_addr[31:16] == 0) &&
      ((cmd_i.shape == 0 || cmd_i.shape == 1 || cmd_i.shape == 4) ? cmd_i.multicast == 0 :
       (cmd_i.shape == 2) ? (cmd_i.multicast == 1 || cmd_i.multicast == 2) : cmd_i.multicast == 3);
  assign cmd_rdy_o = state_q == Idle;
  assign idle_o = state_q == Idle;
  assign complete_vld_o = state_q == Complete;
  assign complete_o = {cmd_q.ctx,cmd_q.id,3'(CPL_TC),status_q,1'b0};
  assign smem_req_vld_o = state_q == SourceReq;
  assign smem_req_addr_o = SMEM_BYTE_ADDR_W'(source_address & ~64'd31);
  assign smem_req_byte_mask_o = ((32'h1 << source_bytes) - 32'd1) << source_address[4:0];
  assign smem_req_id_o = '0;
  assign smem_rsp_rdy_o = state_q == SourceRsp;
  assign rd_vld_o = state_q == ProbeReq;
  assign rd_rsp_rdy_o = state_q == ProbeRsp;
  assign rd_ctx_o = cmd_q.ctx;
  assign rd_epoch_o = cmd_q.id.epoch;
  assign rd_tag_o = cmd_q.id.tag;
  assign rd_column_o = {TMEM_LANES{target_column}};
  assign wr_vld_o = state_q == WriteReq;
  assign wr_rsp_rdy_o = state_q == WriteRsp;
  assign wr_ctx_o = cmd_q.ctx;
  assign wr_epoch_o = cmd_q.id.epoch;
  assign wr_tag_o = cmd_q.id.tag;
  assign wr_column_o = {TMEM_LANES{target_column}};
  always_comb begin
    int element;
    element = 0;
    expanded = source_q[TMEM_WORD_W-1:0];
    for (element = 0; element < 16; element++) begin
      if (cmd_q.source_format == 2'd1) expanded[element*8+:8] = {2'd0,source_q[element*4+:4],2'd0};
      if (cmd_q.source_format == 2'd2) expanded[element*8+:8] = {2'd0,source_q[element*6+:6]};
    end
  end
  for (genvar lane = 0; lane < TMEM_LANES; lane++) begin : gen_destination
    logic [7:0] source_row;
    logic selected;
    always_comb begin
      source_row = 8'(lane);
      selected = 1'b1;
      case (cmd_q.shape)
        3'd2: source_row = cmd_q.multicast == 1 ? 8'(lane % 64) : 8'(32*(lane / 64)+lane % 32);
        3'd3: source_row = 8'(lane % 32);
        3'd4: begin
          source_row = 8'(lane / 32);
          selected = (lane % 32) == int'(cmd_q.base_addr[31:16]);
        end
        default: ;
      endcase
      rd_lane_mask_o[lane] = selected;
      wr_byte_mask_o[lane*16+:16] = (selected && source_row == row_q) ? 16'hffff : '0;
      wr_data_o[lane*TMEM_WORD_W+:TMEM_WORD_W] = expanded;
    end
  end
  always_comb begin
    state_d = state_q;
    cmd_d = cmd_q;
    status_d = status_q;
    row_d = row_q;
    chunk_d = chunk_q;
    check_byte_d = check_byte_q;
    source_d = source_q;
    case (state_q)
      Idle: if (cmd_vld_i && cmd_rdy_o) begin
        cmd_d = cmd_i;
        status_d = command_legal ? ASYNC_OK : 8'd10;
        row_d = '0;
        chunk_d = 1'b0;
        check_byte_d = '0;
        source_d = '0;
        state_d = command_legal ? CheckSource : Complete;
      end
      CheckSource: begin
        // Preflight the entire source before any destination is modified.
        if (check_address >= 64'(SMEM_BYTES)) begin
          status_d = 8'd10;
          state_d = Complete;
        end else if (check_byte_q == 4'(source_bytes - 5'd1)) begin
          check_byte_d = '0;
          if (source_last) begin row_d = '0; chunk_d = 1'b0; state_d = ProbeReq; end
          else if (chunks_two && !chunk_q) chunk_d = 1'b1;
          else begin row_d = row_q + 8'd1; chunk_d = 1'b0; end
        end else check_byte_d = check_byte_q + 4'd1;
      end
      ProbeReq: if (rd_vld_o && rd_rdy_i) state_d = ProbeRsp;
      ProbeRsp: if (rd_rsp_vld_i && rd_rsp_rdy_o) begin
        if (rd_rsp_status_i != ASYNC_OK) begin status_d = rd_rsp_status_i; state_d = Complete; end
        else if (chunks_two && !chunk_q) begin chunk_d = 1'b1; state_d = ProbeReq; end
        else begin chunk_d = 1'b0; state_d = SourceReq; end
      end
      SourceReq: if (smem_req_vld_o && smem_req_rdy_i) state_d = SourceRsp;
      SourceRsp: if (smem_rsp_vld_i && smem_rsp_rdy_o) begin
        if (smem_rsp_id_i != 0) begin
          // Unknown IDs cannot retire the outstanding ID zero.
          status_d = ASYNC_BAD_COMPLETION;
        end else if (status_q != ASYNC_OK || smem_rsp_status_i != 0) begin
          status_d = status_q != ASYNC_OK ? status_q : 8'd16;
          state_d = Complete;
        end else begin
          source_d = smem_rsp_data_i >> {source_address[4:0],3'd0};
          state_d = WriteReq;
        end
      end
      WriteReq: if (wr_vld_o && wr_rdy_i) state_d = WriteRsp;
      WriteRsp: if (wr_rsp_vld_i && wr_rsp_rdy_o) begin
        if (wr_rsp_status_i != ASYNC_OK) begin status_d = wr_rsp_status_i; state_d = Complete; end
        else if (source_last) state_d = Complete;
        else begin
          if (chunks_two && !chunk_q) chunk_d = 1'b1;
          else begin chunk_d = 1'b0; row_d = row_q + 8'd1; end
          state_d = SourceReq;
        end
      end
      Complete: if (complete_vld_o && complete_rdy_i) state_d = Idle;
      default: begin status_d = ASYNC_BAD_COMPLETION; state_d = Complete; end
    endcase
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= Idle;
      cmd_q <= '0;
      status_q <= ASYNC_OK;
      row_q <= '0;
      chunk_q <= 1'b0;
      check_byte_q <= '0;
      source_q <= '0;
    end else begin
      state_q <= state_d;
      cmd_q <= cmd_d;
      status_q <= status_d;
      row_q <= row_d;
      chunk_q <= chunk_d;
      check_byte_q <= check_byte_d;
      source_q <= source_d;
    end
  end
`ifndef SYNTHESIS
  assert property (@(posedge clk) disable iff (!rst_n)
      complete_vld_o && !complete_rdy_i |=> complete_vld_o && $stable(complete_o));
  assert property (@(posedge clk) disable iff (!rst_n)
      smem_req_vld_o && !smem_req_rdy_i |=> smem_req_vld_o && $stable({smem_req_addr_o,smem_req_byte_mask_o,smem_req_id_o}));
  assert property (@(posedge clk) disable iff (!rst_n)
      wr_vld_o && !wr_rdy_i |=> wr_vld_o && $stable({wr_column_o,wr_data_o,wr_byte_mask_o,wr_tag_o}));

`endif
endmodule
