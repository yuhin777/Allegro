module primitive_tb;
  logic signed [32:0] sum;
  logic signed [9:0] base_exp;
  logic special_valid;
  logic [31:0] special_result, canonical, keep_sign;
  blackwell_dot_fp32_pack pack_canonical (
    .sum,
    .base_exp,
    .special_valid,
    .special_result,
    .result(canonical)
  );
  blackwell_dot_fp32_pack #(
    .CANONICAL_ZERO(0)
  ) pack_signed (
    .sum,
    .base_exp,
    .special_valid,
    .special_result,
    .result(keep_sign)
  );

  logic v, signbit;
  logic [4:0] mag;
  logic signed [3:0] exp_i, emax;
  logic signed [5:0] term;
  blackwell_dot_align_fixed_rz #(
    .MAG_W(5),
    .EXP_W(4)
  ) align_dut (
    .term_valid(v),
    .term_sign(signbit),
    .term_mag(mag),
    .term_exp(exp_i),
    .emax,
    .term
  );

  logic [4:0] valid;
  logic [4:0][3:0] exp_values;
  logic max_valid;
  logic signed [3:0] max_exp;
  blackwell_dot_emax_tree #(
    .TERM_N(5),
    .EXP_W(4),
    .DEFAULT_EXP(4'sh8)
  ) max_dut (
    .term_vld_i(valid),
    .term_exp_flat_i(exp_values),
    .emax_vld_o(max_valid),
    .emax_o(max_exp)
  );
  logic [4:0][3:0] ints;
  logic signed [6:0] reduced;
  logic signed [3:0] wrapped;
  logic signed [6:0] one;
  blackwell_dot_signed_reduce_tree #(
    .TERM_N(5),
    .TERM_W(4),
    .SUM_W (7)
  ) sum_dut (
    .term_flat_i(ints),
    .sum_o(reduced)
  );
  blackwell_dot_signed_reduce_tree #(
    .TERM_N(5),
    .TERM_W(4)
  ) wrap_dut (
    .term_flat_i(ints),
    .sum_o(wrapped)
  );
  blackwell_dot_signed_reduce_tree #(
    .TERM_N(1),
    .TERM_W(4),
    .SUM_W (7)
  ) one_dut (
    .term_flat_i(ints[0]),
    .sum_o(one)
  );

  logic signed [6:0] compressed;
  logic signed [3:0] compressed_wrapped;
  blackwell_dot_signed_reduce_tree #(
    .TERM_N(5),
    .TERM_W(4),
    .SUM_W(7),
    .CARRY_SAVE(1)
  ) compressor_dut (
    .term_flat_i(ints),
    .sum_o(compressed)
  );
  blackwell_dot_signed_reduce_tree #(
    .TERM_N(5),
    .TERM_W(4),
    .CARRY_SAVE(1)
  ) compressor_wrap_dut (
    .term_flat_i(ints),
    .sum_o(compressed_wrapped)
  );

  task automatic check_pack(logic signed [32:0] value, int base, logic [31:0] poszero, signedzero);
    sum = value;
    base_exp = 10'(base);
    #1;
    if (canonical !== poszero || keep_sign !== signedzero)
      $fatal(
          1,
          "FP32 magnitude %d base %d got %h/%h wanted %h/%h",
          value,
          base,
          canonical,
          keep_sign,
          poszero,
          signedzero
      );
  endtask
  initial begin
    special_valid = 0;
    special_result = 32'h7fffffff;
    check_pack(3, 0, 32'h40400000, 32'h40400000);
    check_pack(33'sh100000000, 0, 32'hcf800000, 32'hcf800000);
    check_pack(33'd16777219, -24, 32'h3f800001, 32'h3f800001);
    check_pack(1, -126, 32'h00800000, 32'h00800000);
    check_pack(-1, -149, 32'h80000001, 32'h80000001);
    check_pack(-1, -150, 0, 32'h80000000);
    check_pack(1, 127, 32'h7f000000, 32'h7f000000);
    check_pack(-1, 128, 32'hff800000, 32'hff800000);
    check_pack(0, 128, 0, 0);
    special_valid = 1;
    check_pack(1, 0, 32'h7fffffff, 32'h7fffffff);

    v = 1;
    signbit = 1;
    mag = 5;
    exp_i = -7;
    emax = -6;
    #1;
    if (term != -2) $fatal;
    mag = 31;
    emax = -3;
    #1;
    if (term != -1) $fatal;
    emax = -2;
    #1;
    if (term != 0) $fatal;
    emax = -7;
    #1;
    if (term != -31) $fatal;
    v = 0;
    #1;
    if (term != 0) $fatal;

    exp_values = {4'd0, 4'h8, 4'hf, 4'hf, 4'h9};
    valid = 0;
    #1;
    if (max_valid || max_exp != -8) $fatal;
    valid = 5'b01000;
    #1;
    if (!max_valid || max_exp != -8) $fatal;
    valid = 5'b01111;
    #1;
    if (!max_valid || max_exp != -1) $fatal;
    ints = {4'd7, 4'h8, 4'd7, 4'h8, 4'h8};
    #1;
    if (reduced != -10 || wrapped != 6 || one != -8) $fatal;
    for (int pattern = 0; pattern < (1 << $bits(ints)); pattern++) begin
      int expected;
      expected = 0;
      ints = 20'(pattern);
      for (int i = 0; i < 5; i++) expected += int'($signed(ints[i]));
      #1;
      if (compressed !== 7'(expected) || compressed_wrapped !== 4'(expected) ||
          reduced !== compressed || wrapped !== compressed_wrapped)
        $fatal(1, "reduce pattern %h expected %0d", ints, expected);
    end
    $display("PASS exhaustive binary and carry-save reduction for five signed nibbles");
    $display("PASS combinational pack, exponent, signed reduction and RZ alignment boundaries");
    $finish;
  end
endmodule
