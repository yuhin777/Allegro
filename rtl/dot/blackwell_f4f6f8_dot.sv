module blackwell_f4f6f8_dot
  import blackwell_dot_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic req_valid,
  output logic req_ready,
  input logic [$bits(low_req_t)-1:0] req_payload,
  output logic rsp_valid,
  input logic rsp_ready,
  output logic [31:0] rsp_payload
);
  low_req_t req;
  assign req = req_payload;
  logic [6:0] valid, ready;
  typedef struct packed {
    logic sign;
    logic [7:0] sig;
    logic signed [5:0] e;
    logic zero;
  } prod_t;
  typedef struct packed {
    logic sign;
    logic [26:0] mag;
    logic signed [9:0] e;
    logic zero;
  } c_t;
  typedef struct packed {
    logic special;
    logic [31:0] value;
    prod_t [31:0] prod;
    logic evalid;
    logic signed [9:0] emax;
    c_t c;
    logic signed [9:0] scale;
  } products_t;
  typedef struct packed {
    logic special;
    logic [31:0] value;
    logic [32:0][27:0] terms;
    logic signed [9:0] base;
  } aligned_t;
  typedef struct packed {
    logic special;
    logic [31:0] value;
    logic [4:0][32:0] terms;
    logic signed [9:0] base;
  } partial_t;
  typedef struct packed {
    logic special;
    logic [31:0] value;
    logic signed [32:0] sum;
    logic signed [9:0] base;
  } sum_t;
  products_t d0, q0, d1, q1;
  aligned_t d2, q2;
  partial_t d3, q3;
  sum_t d4, q4;
  logic [31:0] d5;
  logic [31:0] nonzero;
  logic [31:0][9:0] exps;
  logic [2:0] classes;
  accum_t c;
  always_comb begin
    c = accum_decode(req.c, 0);
    d0.c = {c.sign, 1'b0, c.sig, 2'b0, 10'($signed(c.e)), c.cls != FINITE};
    d0.scale = 10'($signed(req.sa.e)) + 10'($signed(req.sb.e));
    classes = flags(c.cls, c.sign) | {req.sa.nan || req.sb.nan, 2'b0};
    for (int k = 0; k < 32; k++) begin
      d0.prod[k].sign = req.a[k].sign ^ req.b[k].sign;
      d0.prod[k].sig = req.a[k].sig * req.b[k].sig;
      d0.prod[k].e = 6'($signed(req.a[k].e)) + 6'($signed(req.b[k].e));
      nonzero[k] = req.a[k].cls == FINITE && req.b[k].cls == FINITE;
      d0.prod[k].zero = !nonzero[k];
      exps[k] = 10'($signed(d0.prod[k].e));
      classes |= product_flags(req.a[k].cls, req.b[k].cls, d0.prod[k].sign);
    end
    d0.special = |classes;
    d0.value = special_value(special_code(classes));
  end
  blackwell_dot_emax_tree #(
    .TERM_N(32),
    .EXP_W (10)
  ) emax_products (
    .term_vld_i(nonzero),
    .term_exp_flat_i(exps),
    .emax_o(d0.emax),
    .emax_vld_o(d0.evalid)
  );
  assign d1.prod = q0.prod, d1.special = q0.special, d1.value = q0.value, d1.scale = q0.scale;
  assign d1.c.sign = q0.c.sign,
      d1.c.mag = q0.c.mag,
      d1.c.zero = q0.c.zero,
      d1.c.e = q0.c.e - q0.scale;
  blackwell_dot_emax_tree #(
    .TERM_N(2),
    .EXP_W (10)
  ) emax_with_c (
    .term_vld_i({!q0.c.zero, q0.evalid}),
    .term_exp_flat_i({d1.c.e, q0.emax}),
    .emax_o(d1.emax),
    .emax_vld_o(d1.evalid)
  );
  for (genvar k = 0; k < 32; k++) begin : g_align
    blackwell_dot_align_fixed_rz #(
      .MAG_W(27),
      .EXP_W(10)
    ) align_product (
      .term_valid(valid[2] && !q1.prod[k].zero),
      .term_sign(q1.prod[k].sign),
      .term_mag({q1.prod[k].sig, 19'b0}),
      .term_exp(10'($signed(q1.prod[k].e))),
      .emax(q1.emax),
      .term(d2.terms[k])
    );
  end
  blackwell_dot_align_fixed_rz #(
    .MAG_W(27),
    .EXP_W(10)
  ) align_c (
    .term_valid(valid[2] && !q1.c.zero),
    .term_sign(q1.c.sign),
    .term_mag(q1.c.mag),
    .term_exp(q1.c.e),
    .emax(q1.emax),
    .term(d2.terms[32])
  );
  assign d2.special = q1.special, d2.value = q1.value, d2.base = q1.emax - 10'sd25 + q1.scale;
  for (genvar h = 0; h < 4; h++) begin : g_partial
    blackwell_dot_signed_reduce_tree #(
      .TERM_N(8),
      .TERM_W(28),
      .SUM_W (33)
    ) reduce_terms (
      .term_flat_i(q2.terms[h*8+:8]),
      .sum_o(d3.terms[h])
    );
  end
  assign d3.terms[4] = 33'($signed(
          q2.terms[32]
      )),
      d3.special = q2.special,
      d3.value = q2.value,
      d3.base = q2.base;
  blackwell_dot_signed_reduce_tree #(
    .TERM_N(5),
    .TERM_W(33)
  ) reduce_sum (
    .term_flat_i(q3.terms),
    .sum_o(d4.sum)
  );
  assign d4.special = q3.special, d4.value = q3.value, d4.base = q3.base;
  blackwell_dot_fp32_pack pack_result (
    .sum(q4.sum),
    .base_exp(q4.base),
    .special_valid(q4.special),
    .special_result(q4.value),
    .result(d5)
  );
  assign valid[0] = req_valid, req_ready = ready[0], rsp_valid = valid[6], ready[6] = rsp_ready;
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
    .out_payload(q4)
  );
  blackwell_pipeline_reg #(
    .WIDTH($bits(d5))
  ) stage5 (
    .clk,
    .rst_n,
    .in_valid(valid[5]),
    .in_ready(ready[5]),
    .in_payload(d5),
    .out_valid(valid[6]),
    .out_ready(ready[6]),
    .out_payload(rsp_payload)
  );
`ifndef SYNTHESIS
  initial
    if ($bits(
            q0
        ) != 605 || $bits(
            q1
        ) != 605 || $bits(
            q2
        ) != 967 || $bits(
            q3
        ) != 208 || $bits(
            q4
        ) != 76)
      $fatal(1, "f4f6f8 pipeline storage width");
`endif
endmodule
