// One combinational decoder per row/column. The family gates also isolate the
// decoded scale wires when an unrelated family is active.
module blackwell_tc_dot_decode
  import blackwell_dot_pkg::*;
(
  input logic [3:0] selected,
  input logic [3:0] dtype,
  input logic negate,
  input logic mx,
  input logic ue4m3,
  input logic [255:0] raw,
  input logic [31:0] scales,
  output wide_t [15:0] wide_data,
  output low_t [31:0] low_data,
  output nibble_t [63:0] fp4_data,
  output logic [31:0][8:0] int_data,
  output mx_t low_scale,
  output factor_t [3:0] fp4_scale
);
  for (genvar k = 0; k < 16; k++) begin : g_wide
    logic [31:0] elem;
    if (k < 8) assign elem = dtype == 2 ? raw[32*k+:32] : {16'b0, raw[16*k+:16]};
    else assign elem = {16'b0, raw[16*k+:16]};
    assign wide_data[k] = selected[0] && (dtype != 2 || k < 8) ? wide_decode(
        elem, dtype, negate
    ) : '0;
  end
  for (genvar k = 0; k < 32; k++) begin : g_byte
    wire [7:0] elem = raw[8*k+:8];
    assign low_data[k] = selected[1] ? low_decode(elem, dtype, negate) : '0;
    assign int_data[k] = selected[3] ? {dtype == 8 && elem[7], elem} : '0;
  end
  for (genvar k = 0; k < 64; k++) begin : g_nibble
    assign fp4_data[k] = selected[2] ? nibble_decode(raw[4*k+:4], negate) : '0;
  end
  assign low_scale = selected[1] && mx ? mx_decode(scales[7:0]) : '0;
  for (genvar h = 0; h < 4; h++) begin : g_scale
    assign fp4_scale[h] = selected[2] ? factor_decode(
        ue4m3 ? scales[8*h+:8] : scales[8*(h/2)+:8], ue4m3
    ) : '0;
  end
endmodule

module blackwell_tc_dot_array
  import blackwell_dot_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input blackwell_tc_pkg::mma_cmd_t cmd_i,
  input logic operand_valid,
  output logic operand_ready,
  input operand_t operand_payload,
  output logic result_valid,
  input logic result_ready,
  output result_t result_payload,
  output logic empty_o
);
  logic [1:0] family, head;
  logic [3:0] selected, issue, retire, family_ready, family_valid;
  logic fifo_ready, fifo_valid;
  logic [3:0][63:0][31:0] cells;
  logic [3:0][75:0] tags;
  logic [3:0][63:0] lane_ready, lane_valid;
  always_comb begin
    case (cmd_i.kind)
      0, 1: family = 0;
      2, 4: family = 1;
      5, 6: family = 2;
      default: family = 3;
    endcase
  end
  assign selected = operand_valid ? (4'b1 << family) : '0;
  assign operand_ready = fifo_ready && family_ready[family];
  assign issue = selected & {4{fifo_ready}};
  assign result_valid = fifo_valid && family_valid[head];
  assign retire = fifo_valid && result_ready ? (4'b1 << head) : '0;
  assign result_payload = {tags[head], cells[head]};
  assign empty_o = !fifo_valid;
  blackwell_fifo #(
    .WIDTH(2),
    .DEPTH(19)
  ) order (
    .clk,
    .rst_n,
    .in_valid(operand_valid && family_ready[family]),
    .in_ready(fifo_ready),
    .in_payload(family),
    .out_valid(fifo_valid),
    .out_ready(result_ready && family_valid[head]),
    .out_payload(head),
    .occupancy()
  );

  wide_t [15:0] aw[8], bw[8];
  low_t [31:0] al[8], bl[8];
  nibble_t [63:0] af[8], bf[8];
  logic [31:0][8:0] ai[8], bi[8];
  mx_t am[8], bm[8];
  factor_t [3:0] asf[8], bsf[8];
  for (genvar g = 0; g < 8; g++) begin : g_decode
    blackwell_tc_dot_decode decode_a (
      .selected,
      .dtype(cmd_i.a_type),
      .negate(cmd_i.negate_a),
      .mx(cmd_i.kind == 4),
      .ue4m3(cmd_i.scale_type),
      .raw(operand_payload.a[g]),
      .scales(operand_payload.sa[g]),
      .wide_data(aw[g]),
      .low_data(al[g]),
      .fp4_data(af[g]),
      .int_data(ai[g]),
      .low_scale(am[g]),
      .fp4_scale(asf[g])
    );
    blackwell_tc_dot_decode decode_b (
      .selected,
      .dtype(cmd_i.b_type),
      .negate(cmd_i.negate_b),
      .mx(cmd_i.kind == 4),
      .ue4m3(cmd_i.scale_type),
      .raw(operand_payload.b[g]),
      .scales(operand_payload.sb[g]),
      .wide_data(bw[g]),
      .low_data(bl[g]),
      .fp4_data(bf[g]),
      .int_data(bi[g]),
      .low_scale(bm[g]),
      .fp4_scale(bsf[g])
    );
  end
  // Within each family every lane and the tag pipeline start empty, receive
  // identical input valid/retire signals, and have identical stage count.
  for (genvar f = 0; f < 4; f++) begin : g_tags
    localparam int P = (f == 1 ? 6 : (f == 3 ? 3 : 5));
    logic [P:0] valid, ready;
    logic [75:0] tag[0:P];
    assign valid[0] = issue[f], ready[P] = retire[f], tag[0] = operand_payload.tag;
    assign tags[f] = tag[P], family_ready[f] = ready[0], family_valid[f] = valid[P];
    for (genvar s = 0; s < P; s++) begin : g_stage
      blackwell_pipeline_reg #(
        .WIDTH(76)
      ) tag_stage (
        .clk,
        .rst_n,
        .in_valid(valid[s]),
        .in_ready(ready[s]),
        .in_payload(tag[s]),
        .out_valid(valid[s+1]),
        .out_ready(ready[s+1]),
        .out_payload(tag[s+1])
      );
    end
`ifndef SYNTHESIS
    assert property (@(posedge clk) disable iff (!rst_n) lane_ready[f] == {64{ready[0]}});
    assert property (@(posedge clk) disable iff (!rst_n) lane_valid[f] == {64{valid[P]}});
`endif
  end
  for (genvar n = 0; n < 64; n++) begin : g_cell
    localparam int R = n / 8, C = n % 8;
    wide_req_t wr;
    low_req_t  lr;
    fp4_req_t  fr;
    int_req_t  ir;
    assign wr = {aw[R], bw[C], operand_payload.c[n], cmd_i.scale_input_d};
    assign lr = {al[R], bl[C], operand_payload.c[n], am[R], bm[C]};
    assign fr = {af[R], bf[C], operand_payload.c[n], asf[R], bsf[C]};
    assign ir = {ai[R], bi[C], operand_payload.c[n], cmd_i.int_sat};
    blackwell_f16tf32_dot wide_lane (
      .clk,
      .rst_n,
      .req_valid(issue[0]),
      .req_ready(lane_ready[0][n]),
      .req_payload(wr),
      .rsp_ready(retire[0]),
      .rsp_valid(lane_valid[0][n]),
      .rsp_payload(cells[0][n])
    );
    blackwell_f4f6f8_dot low_lane (
      .clk,
      .rst_n,
      .req_valid(issue[1]),
      .req_ready(lane_ready[1][n]),
      .req_payload(lr),
      .rsp_ready(retire[1]),
      .rsp_valid(lane_valid[1][n]),
      .rsp_payload(cells[1][n])
    );
    blackwell_fp4_dot fp4_lane (
      .clk,
      .rst_n,
      .req_valid(issue[2]),
      .req_ready(lane_ready[2][n]),
      .req_payload(fr),
      .rsp_ready(retire[2]),
      .rsp_valid(lane_valid[2][n]),
      .rsp_payload(cells[2][n])
    );
    logic overflow;
    blackwell_int8_dot int_lane (
      .clk,
      .rst_n,
      .req_valid(issue[3]),
      .req_ready(lane_ready[3][n]),
      .req_payload(ir),
      .rsp_ready(retire[3]),
      .rsp_valid(lane_valid[3][n]),
      .rsp_payload({cells[3][n], overflow})
    );
  end
endmodule
