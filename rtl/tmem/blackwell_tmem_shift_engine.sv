// Implements frozen A1: doc/specs/blackwell_tmem_shift_engine.md
module blackwell_tmem_shift_engine
  import blackwell_async_pkg::*;
#(
  parameter int unsigned TAG_W = ASYNC_TAG_W
) (
  input logic clk,
  input logic rst_n,
  input logic cmd_vld_i,
  input blackwell_async_pkg::shift_cmd_a1_t cmd_i,
  input logic complete_rdy_i,
  input logic rd_rdy_i,
  input logic rd_rsp_vld_i,
  input logic [TMEM_DATA_W-1:0] rd_rsp_data_i,
  input logic [STATUS_W-1:0] rd_rsp_status_i,
  input logic wr_rdy_i,
  input logic wr_rsp_vld_i,
  input logic [STATUS_W-1:0] wr_rsp_status_i,
  output logic cmd_rdy_o,
  output logic complete_vld_o,
  output blackwell_async_pkg::async_event_a1_t complete_o,
  output logic rd_vld_o,
  output logic [CTX_ID_W-1:0] rd_ctx_o,
  output logic [EPOCH_W-1:0] rd_epoch_o,
  output logic [TMEM_COLUMN_BUS_W-1:0] rd_column_o,
  output logic [TAG_W-1:0] rd_tag_o,
  output logic [TMEM_LANE_MASK_W-1:0] rd_lane_mask_o,
  output logic rd_rsp_rdy_o,
  output logic wr_vld_o,
  output logic [CTX_ID_W-1:0] wr_ctx_o,
  output logic [EPOCH_W-1:0] wr_epoch_o,
  output logic [TMEM_COLUMN_BUS_W-1:0] wr_column_o,
  output logic [TMEM_DATA_W-1:0] wr_data_o,
  output logic [TAG_W-1:0] wr_tag_o,
  output logic [TMEM_BYTE_MASK_W-1:0] wr_byte_mask_o,
  output logic wr_rsp_rdy_o,
  output logic idle_o
);


  typedef enum logic [2:0] {Idle, ProbeReq, ProbeRsp, ReadReq, ReadRsp, WriteReq, WriteRsp, Complete} state_t;
  state_t state_q, state_d;
  shift_cmd_a1_t cmd_q, cmd_d;
  logic [STATUS_W-1:0] status_q, status_d;
  logic [2:0] column_q, column_d;
  logic [32*TMEM_CELL_W-1:0] old_q, old_d;
  logic [15:0] column, word_column;
  assign column = cmd_q.base_addr[15:0] + {13'd0,column_q};
  assign word_column = {column[15:2],2'b00};
  assign cmd_rdy_o = state_q == Idle;
  assign complete_vld_o = state_q == Complete;
  assign idle_o = state_q == Idle;
  assign complete_o = {cmd_q.ctx,cmd_q.id,3'(CPL_TC),status_q,1'b0};
  assign rd_vld_o = state_q == ProbeReq || state_q == ReadReq;
  assign rd_rsp_rdy_o = state_q == ProbeRsp || state_q == ReadRsp;
  assign wr_vld_o = state_q == WriteReq;
  assign wr_rsp_rdy_o = state_q == WriteRsp;
  assign rd_ctx_o = cmd_q.ctx;
  assign wr_ctx_o = cmd_q.ctx;
  assign rd_epoch_o = cmd_q.id.epoch;
  assign wr_epoch_o = cmd_q.id.epoch;
  assign rd_tag_o = TAG_W'(cmd_q.id.tag);
  assign wr_tag_o = TAG_W'(cmd_q.id.tag);
  assign rd_column_o = {TMEM_LANES{word_column}};
  assign wr_column_o = {TMEM_LANES{word_column}};
  for (genvar bank = 0; bank < TMEM_LANES; bank++) begin : gen_bank
    localparam int unsigned ROW = bank % 32;
    wire selected = cmd_q.base_addr[31:16] == 16'((bank / 32) * 32);
    assign rd_lane_mask_o[bank] = selected;
    if (ROW < 31) begin : gen_moved
      assign wr_data_o[bank*TMEM_WORD_W+:TMEM_WORD_W] = selected ?
          ({96'd0,old_q[(ROW+1)*TMEM_CELL_W+:TMEM_CELL_W]} << {column[1:0],5'd0}) : '0;
      assign wr_byte_mask_o[bank*16+:16] = selected ? (16'h000f << {column[1:0],2'd0}) : '0;
    end else begin : gen_last
      assign wr_data_o[bank*TMEM_WORD_W+:TMEM_WORD_W] = '0;
      assign wr_byte_mask_o[bank*16+:16] = '0;
    end
  end
  always_comb begin
    int row;
    row = 0;
    state_d = state_q;
    cmd_d = cmd_q;
    status_d = status_q;
    column_d = column_q;
    old_d = old_q;
    case (state_q)
      Idle: if (cmd_vld_i && cmd_rdy_o) begin
        cmd_d = cmd_i;
        column_d = '0;
        status_d = ASYNC_OK;
        if (cmd_i.base_addr[31:16] > 16'd96 || cmd_i.base_addr[20:16] != 0 ||
            cmd_i.base_addr[15:0] > 16'd504) begin
          status_d = 8'd5;
          state_d = Complete;
        end else state_d = ProbeReq;
      end
      ProbeReq: if (rd_vld_o && rd_rdy_i) state_d = ProbeRsp;
      ProbeRsp: if (rd_rsp_vld_i && rd_rsp_rdy_o) begin
        if (rd_rsp_status_i != ASYNC_OK) begin
          status_d = rd_rsp_status_i;
          state_d = Complete;
        end else if (column_q == 3'd7) begin
          column_d = '0;
          state_d = ReadReq;
        end else begin
          column_d = column_q + 3'd1;
          state_d = ProbeReq;
        end
      end
      ReadReq: if (rd_vld_o && rd_rdy_i) state_d = ReadRsp;
      ReadRsp: if (rd_rsp_vld_i && rd_rsp_rdy_o) begin
        if (rd_rsp_status_i != ASYNC_OK) begin
          status_d = rd_rsp_status_i;
          state_d = Complete;
        end else begin
          for (row = 0; row < 32; row++) begin
            old_d[row*TMEM_CELL_W+:TMEM_CELL_W] =
                rd_rsp_data_i[(int'(cmd_q.base_addr[31:16])+row)*TMEM_WORD_W+int'(column[1:0])*TMEM_CELL_W+:TMEM_CELL_W];
          end
          state_d = WriteReq;
        end
      end
      WriteReq: if (wr_vld_o && wr_rdy_i) state_d = WriteRsp;
      WriteRsp: if (wr_rsp_vld_i && wr_rsp_rdy_o) begin
        if (wr_rsp_status_i != ASYNC_OK) begin
          status_d = wr_rsp_status_i;
          state_d = Complete;
        end else if (column_q == 3'd7) state_d = Complete;
        else begin
          column_d = column_q + 3'd1;
          state_d = ReadReq;
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
      column_q <= '0;
      old_q <= '0;
    end else begin
      state_q <= state_d;
      cmd_q <= cmd_d;
      status_q <= status_d;
      column_q <= column_d;
      old_q <= old_d;
    end
  end
  initial if (TAG_W != ASYNC_TAG_W) $fatal(1, "SHIFT A1 tag width");
`ifndef SYNTHESIS
  assert property (@(posedge clk) disable iff (!rst_n)
      complete_vld_o && !complete_rdy_i |=> complete_vld_o && $stable(complete_o));
  assert property (@(posedge clk) disable iff (!rst_n)
      rd_vld_o && !rd_rdy_i |=> rd_vld_o && $stable({rd_ctx_o,rd_epoch_o,rd_tag_o,rd_column_o,rd_lane_mask_o}));
  assert property (@(posedge clk) disable iff (!rst_n)
      wr_vld_o && !wr_rdy_i |=> wr_vld_o && $stable({wr_ctx_o,wr_epoch_o,wr_tag_o,wr_column_o,wr_data_o,wr_byte_mask_o}));

`endif
endmodule
