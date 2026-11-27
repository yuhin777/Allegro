module blackwell_wide_dot_front
  import blackwell_dot_pkg::*;
(
  input wide_req_t req,
  output wide_products_t d0,
  input wide_products_t q0,
  output wide_shifts_t d1
);
  accum_t c;
  // Below every finite wide product exponent (minimum -252).
  localparam logic signed [8:0] EMPTY_EXP = 9'sh100;
  logic [15:0][8:0] exps;
  logic [15:0] eligible;
  logic [2:0] classes;
  always_comb begin
    c = accum_decode(req.c, req.shift);
    d0.c = {c.sign, c.sig, c.cls == FINITE ? c.e : EMPTY_EXP};
    classes = flags(c.cls, c.sign);
    for (int k = 0; k < 16; k++) begin
      d0.prod[k].sign = req.a[k].sign ^ req.b[k].sign;
      d0.prod[k].sig = req.a[k].sig * req.b[k].sig;
      d0.prod[k].e = 9'($signed(req.a[k].e)) + 9'($signed(req.b[k].e));
      eligible[k] = req.a[k].cls == FINITE && req.b[k].cls == FINITE;
      exps[k] = d0.prod[k].e;
      classes |= product_flags(req.a[k].cls, req.b[k].cls, d0.prod[k].sign);
    end
    d0.special = special_code(classes);
  end
  for (genvar g = 0; g < 4; g++) begin : g_group_max
    blackwell_dot_emax_tree #(
      .TERM_N(4),
      .EXP_W(9),
      .DEFAULT_EXP(EMPTY_EXP)
    ) group_max (
      .term_vld_i(eligible[4*g+:4]),
      .term_exp_flat_i(exps[4*g+:4]),
      .emax_o(d0.group_max[g]),
      .emax_vld_o()
    );
  end

  logic signed [8:0] global_emax;
  blackwell_dot_emax_tree #(
    .TERM_N(5),
    .EXP_W (9)
  ) global_max (
    .term_vld_i('1),
    .term_exp_flat_i({q0.c.e, q0.group_max}),
    .emax_o(global_emax),
    .emax_vld_o()
  );

  assign d1.emax = global_emax;
  assign d1.special = q0.special;
  assign d1.c_sign = q0.c.sign;
  assign d1.c_sig = q0.c.sig;
  assign d1.c_shift = alignment_shift(10'(global_emax), 10'($signed(q0.c.e)));
  for (genvar k = 0; k < 16; k++) begin : g_shift
    assign d1.prod_sign[k] = q0.prod[k].sign;
    assign d1.prod_sig[k] = q0.prod[k].sig;
    assign d1.prod_shift[k] = alignment_shift(10'(global_emax), 10'($signed(q0.prod[k].e)));
  end

endmodule

module blackwell_low_dot_front
  import blackwell_dot_pkg::*;
(
  input low_req_t req,
  output low_products_t d0,
  input low_products_t q0,
  output low_shifts_t d1
);
  accum_t c;
  logic [31:0][8:0] exponents;
  logic [31:0] eligible;
  logic [2:0] classes;
  logic signed [8:0] scale;
  always_comb begin
    c = accum_decode(req.c, 0);
    scale = 9'($signed(req.sa.e)) + 9'($signed(req.sb.e));
    d0.scale = scale;
    d0.c_exp = 10'($signed(c.e)) - 10'(scale);
    d0.c_sign = c.sign;
    d0.c_sig = c.sig;
    d0.c_valid = c.cls == FINITE;
    classes = flags(c.cls, c.sign) | {req.sa.nan || req.sb.nan, 2'b0};
    for (int k = 0; k < 32; k++) begin
      d0.prod[k].sig = req.a[k].sig * req.b[k].sig;
      d0.prod[k].sign = req.a[k].sign ^ req.b[k].sign;
      d0.prod[k].e = 6'($signed(req.a[k].e)) + 6'($signed(req.b[k].e));
      exponents[k] = 9'($signed(d0.prod[k].e));
      eligible[k] = req.a[k].cls == FINITE && req.b[k].cls == FINITE;
      classes |= product_flags(req.a[k].cls, req.b[k].cls, d0.prod[k].sign);
    end
    d0.special = special_code(classes);
  end
  logic [4:0][9:0] candidates;
  for (genvar g = 0; g < 4; g++) begin : g_group
    blackwell_dot_emax_tree #(
      .TERM_N(8),
      .EXP_W (9)
    ) group_max (
      .term_vld_i(eligible[8*g+:8]),
      .term_exp_flat_i(exponents[8*g+:8]),
      .emax_o(d0.group_max[g]),
      .emax_vld_o(d0.group_valid[g])
    );
    assign candidates[g] = 10'($signed(q0.group_max[g]));
  end
  assign candidates[4] = q0.c_exp;
  logic signed [9:0] emax;
  blackwell_dot_emax_tree #(
    .TERM_N(5),
    .EXP_W (10)
  ) global_max (
    .term_vld_i({q0.c_valid, q0.group_valid}),
    .term_exp_flat_i(candidates),
    .emax_o(emax),
    .emax_vld_o()
  );
  assign d1.special = q0.special;
  assign d1.base = emax + 10'($signed(q0.scale)) - 10'sd25;
  assign d1.c_sign = q0.c_sign;
  assign d1.c_sig = q0.c_sig;
  assign d1.c_shift = alignment_shift(emax, q0.c_exp);
  for (genvar k = 0; k < 32; k++) begin : g_shift
    assign d1.prod_sig[k] = q0.prod[k].sig;
    assign d1.prod_sign[k] = q0.prod[k].sign;
    assign d1.prod_shift[k] = alignment_shift(emax, 10'($signed(q0.prod[k].e)));
  end
endmodule
