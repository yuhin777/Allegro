module blackwell_fp4_dot
  import blackwell_dot_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic req_valid,
  output logic req_ready,
  input logic [$bits(fp4_req_t)-1:0] req_payload,
  output logic rsp_valid,
  input logic rsp_ready,
  output logic [31:0] rsp_payload
);
  fp4_req_t req;
  assign req = req_payload;
  logic [5:0] valid, ready;
  typedef struct packed {
    logic sign;
    logic [23:0] sig;
    logic signed [9:0] e;
  } c_t;
  typedef struct packed {
    logic [1:0] special;
    logic [3:0][12:0] sigma;
    logic [3:0][7:0] scale;
    logic [3:0][9:0] exp;
    c_t c;
  } grouped_t;
  typedef struct packed {
    logic sign;
    logic [18:0] mag;
    logic signed [9:0] e;
  } gamma_t;
  typedef struct packed {
    logic [1:0] special;
    gamma_t [3:0] gamma;
    c_t c;
    logic signed [9:0] emax;
  } gamma_stage_t;
  typedef struct packed {
    logic [1:0] special;
    logic [3:0][46:0] gamma;
    logic signed [36:0] c;
    logic signed [9:0] base;
  } aligned_t;
  typedef struct packed {
    logic [1:0] special;
    logic signed [48:0] sum;
    logic signed [9:0] base;
  } sum_t;
  grouped_t d0, q0;
  gamma_stage_t d1, q1;
  aligned_t d2, q2;
  sum_t d3, q3;
  logic [31:0] d4;
  logic [3:0] nan_scale;
  accum_t c;
  assign c = accum_decode(req.c, 0);
  assign d0.c = {c.sign, c.sig, 10'($signed(c.e)) - 10'sd6};
  assign d0.special = special_code(flags(c.cls, c.sign) | {|nan_scale, 2'b0});
  logic [4:0][9:0] exps;
  logic [4:0] eligible;
  for (genvar h = 0; h < 4; h++) begin : g_group
    logic [15:0][8:0] products;
    for (genvar l = 0; l < 16; l++) begin : g_product
      localparam int K = 16 * h + l;
      logic [7:0] mag;
      assign mag = req.a[K].q * req.b[K].q;
      assign products[l] = (req.a[K].sign ^ req.b[K].sign) ? -9'(mag) : 9'(mag);
    end
    blackwell_dot_signed_reduce_tree #(
      .TERM_N(16),
      .TERM_W(9),
      .SUM_W(13),
      .CARRY_SAVE(1'b1)
    ) group_sum (
      .term_flat_i(products),
      .sum_o(d0.sigma[h])
    );
    assign nan_scale[h] = req.sa[h].nan || req.sb[h].nan;
    assign d0.scale[h] = req.sa[h].sig * req.sb[h].sig;
    assign d0.exp[h] = 10'($signed(req.sa[h].e)) + 10'($signed(req.sb[h].e));
    logic [12:0] abs_sigma;
    assign abs_sigma = q0.sigma[h][12] ? -q0.sigma[h] : q0.sigma[h];
    assign d1.gamma[h].sign = q0.sigma[h][12],
        d1.gamma[h].mag = abs_sigma * q0.scale[h],
        d1.gamma[h].e = q0.exp[h];
    assign exps[h] = d1.gamma[h].e;
    assign eligible[h] = (|q0.sigma[h]) && (|q0.scale[h]);
    // 16 * 12^2 * 15^2 < 2^19, so the scaled group magnitude fits in 19 bits.
    blackwell_dot_align_fixed_rz #(
      .MAG_W(46),
      .EXP_W(10)
    ) align_gamma (
      .term_valid(valid[2] && (|q1.gamma[h].mag)),
      .term_sign(q1.gamma[h].sign),
      .term_mag({q1.gamma[h].mag, 27'b0}),
      .term_exp(q1.gamma[h].e),
      .emax(q1.emax),
      .term(d2.gamma[h])
    );
  end
  assign d1.special = q0.special, d1.c = q0.c;
  assign exps[4] = q0.c.e;
  assign eligible[4] = |q0.c.sig;
  blackwell_dot_emax_tree #(
    .TERM_N(5),
    .EXP_W (10)
  ) select_emax (
    .term_vld_i(eligible),
    .term_exp_flat_i(exps),
    .emax_o(d1.emax),
    .emax_vld_o()
  );
  blackwell_dot_align_fixed_rz #(
    .MAG_W(36),
    .EXP_W(10)
  ) align_c (
    .term_valid(valid[2] && (|q1.c.sig)),
    .term_sign(q1.c.sign),
    .term_mag({q1.c.sig, 12'b0}),
    .term_exp(q1.c.e),
    .emax(q1.emax),
    .term(d2.c)
  );
  assign d2.special = q1.special, d2.base = q1.emax - 10'sd29;
  blackwell_dot_signed_reduce_tree #(
    .TERM_N(5),
    .TERM_W(47),
    .SUM_W (49)
  ) reduce_sum (
    .term_flat_i({47'($signed(q2.c)), q2.gamma}),
    .sum_o(d3.sum)
  );
  assign d3.special = q2.special, d3.base = q2.base;
  blackwell_dot_fp32_pack #(
    .SUM_W(49),
    .CANONICAL_ZERO(1'b0)
  ) pack_result (
    .sum(q3.sum),
    .base_exp(q3.base),
    .special_valid(|q3.special),
    .special_result(special_value(q3.special)),
    .result(d4)
  );
  assign valid[0] = req_valid, req_ready = ready[0], rsp_valid = valid[5], ready[5] = rsp_ready;
  blackwell_pipeline_reg #(
    .WIDTH($bits(d0))
  ) stage0 (
    .clk,
    .rst_n,
    .in_valid(valid[0]),
    .in_ready(ready[0]),
    .in_payload(d0),
    .out_valid(valid[1]),
    .out_ready(ready[1]),
    .out_payload(q0)
  );
  blackwell_pipeline_reg #(
    .WIDTH($bits(d1))
  ) stage1 (
    .clk,
    .rst_n,
    .in_valid(valid[1]),
    .in_ready(ready[1]),
    .in_payload(d1),
    .out_valid(valid[2]),
    .out_ready(ready[2]),
    .out_payload(q1)
  );
  blackwell_pipeline_reg #(
    .WIDTH($bits(d2))
  ) stage2 (
    .clk,
    .rst_n,
    .in_valid(valid[2]),
    .in_ready(ready[2]),
    .in_payload(d2),
    .out_valid(valid[3]),
    .out_ready(ready[3]),
    .out_payload(q2)
  );
  blackwell_pipeline_reg #(
    .WIDTH($bits(d3))
  ) stage3 (
    .clk,
    .rst_n,
    .in_valid(valid[3]),
    .in_ready(ready[3]),
    .in_payload(d3),
    .out_valid(valid[4]),
    .out_ready(ready[4]),
    .out_payload(q3)
  );
  blackwell_pipeline_reg #(
    .WIDTH($bits(d4))
  ) stage4 (
    .clk,
    .rst_n,
    .in_valid(valid[4]),
    .in_ready(ready[4]),
    .in_payload(d4),
    .out_valid(valid[5]),
    .out_ready(ready[5]),
    .out_payload(rsp_payload)
  );
`ifndef SYNTHESIS
  initial
    if ($bits(
            q0
        ) != 161 || $bits(
            q1
        ) != 167 || $bits(
            q2
        ) != 237 || $bits(
            q3
        ) != 61 || $bits(
            d4
        ) != 32)
      $fatal(1, "fp4 pipeline storage width");
`endif
endmodule
