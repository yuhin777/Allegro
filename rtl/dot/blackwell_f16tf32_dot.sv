module blackwell_f16tf32_dot
  import blackwell_dot_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic req_valid,
  output logic req_ready,
  input logic [$bits(wide_req_t)-1:0] req_payload,
  output logic rsp_valid,
  input logic rsp_ready,
  output logic [31:0] rsp_payload
);
  wide_req_t req;
  assign req = req_payload;
  logic [5:0] valid, ready;
  typedef struct packed {
    logic sign;
    logic [21:0] sig;
    logic signed [8:0] e;
    logic zero;
  } product_t;
  typedef struct packed {
    logic sign;
    logic [23:0] sig;
    logic signed [8:0] e;
    logic zero;
  } c_t;
  typedef struct packed {
    logic [1:0] special;
    product_t [15:0] prod;
    logic signed [8:0] emax;
    c_t c;
  } products_t;
  typedef struct packed {
    logic [1:0] special;
    logic [16:0][32:0] terms;
    logic signed [8:0] emax;
  } aligned_t;
  typedef struct packed {
    logic [1:0] special;
    logic signed [32:0] sum;
    logic signed [8:0] emax;
  } sum_t;
  products_t d0, q0, q1;
  aligned_t d2, q2;
  sum_t d3, q3;
  logic [31:0] d4;
  accum_t c;
  logic [16:0][8:0] exps;
  logic [16:0] nonzero;
  logic [2:0] classes;
  always_comb begin
    c = accum_decode(req.c, req.shift);
    d0.c = {c.sign, c.sig, c.e, c.cls != FINITE};
    classes = flags(c.cls, c.sign);
    nonzero[16] = c.cls == FINITE;
    exps[16] = c.e;
    for (int k = 0; k < 16; k++) begin
      d0.prod[k].sign = req.a[k].sign ^ req.b[k].sign;
      d0.prod[k].sig = req.a[k].sig * req.b[k].sig;
      d0.prod[k].e = 9'($signed(req.a[k].e)) + 9'($signed(req.b[k].e));
      nonzero[k] = req.a[k].cls == FINITE && req.b[k].cls == FINITE;
      d0.prod[k].zero = !nonzero[k];
      exps[k] = d0.prod[k].e;
      classes |= product_flags(req.a[k].cls, req.b[k].cls, d0.prod[k].sign);
    end
    d0.special = special_code(classes);
  end
  blackwell_dot_emax_tree #(
    .TERM_N(17),
    .EXP_W(9),
    .DEFAULT_EXP(9'sh100)
  ) emax (
    .term_vld_i(nonzero),
    .term_exp_flat_i(exps),
    .emax_o(d0.emax),
    .emax_vld_o()
  );
  for (genvar k = 0; k < 16; k++) begin : g_align
    blackwell_dot_align_fixed_rz #(
      .MAG_W(32),
      .EXP_W(9)
    ) align_product (
      .term_valid(valid[2] && !q1.prod[k].zero),
      .term_sign(q1.prod[k].sign),
      .term_mag({5'b0, q1.prod[k].sig, 5'b0}),
      .term_exp(q1.prod[k].e),
      .emax(q1.emax),
      .term(d2.terms[k])
    );
  end
  blackwell_dot_align_fixed_rz #(
    .MAG_W(32),
    .EXP_W(9)
  ) align_c (
    .term_valid(valid[2] && !q1.c.zero),
    .term_sign(q1.c.sign),
    .term_mag({6'b0, q1.c.sig, 2'b0}),
    .term_exp(q1.c.e),
    .emax(q1.emax),
    .term(d2.terms[16])
  );
  assign d2.special = q1.special, d2.emax = q1.emax;
  blackwell_dot_signed_reduce_tree #(
    .TERM_N(17),
    .TERM_W(33)
  ) reduce_terms (
    .term_flat_i(q2.terms),
    .sum_o(d3.sum)
  );
  assign d3.special = q2.special, d3.emax = q2.emax;
  blackwell_dot_fp32_pack pack_result (
    .sum(q3.sum),
    .base_exp(10'($signed(q3.emax)) - 10'sd25),
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
    .WIDTH($bits(q0))
  ) stage1 (
    .clk,
    .rst_n,
    .in_valid(valid[1]),
    .in_ready(ready[1]),
    .in_payload(q0),
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
    if ($bits(q0) != 574 || $bits(q1) != 574 || $bits(q2) != 572 || $bits(q3) != 44)
      $fatal(1, "f16tf32 pipeline storage width");
`endif
endmodule
