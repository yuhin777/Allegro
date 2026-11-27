module blackwell_dot_fp32_pack #(
  parameter int SUM_W = 33,
  EXP_W = 10,
  parameter bit CANONICAL_ZERO = 1
) (
  input logic signed [SUM_W-1:0] sum,
  input logic signed [EXP_W-1:0] base_exp,
  input logic special_valid,
  input logic [31:0] special_result,
  output logic [31:0] result
);
  logic signed [SUM_W:0] extended;
  logic [SUM_W:0] magnitude;
  logic [23:0] sig24;
  localparam int IndexSignedWidth = $clog2(SUM_W) + 1;
  localparam int ExponentWidth = 1 + (EXP_W > IndexSignedWidth ? EXP_W : IndexSignedWidth);
  typedef logic signed [ExponentWidth-1:0] exponent_t;
  int highest;
  exponent_t exponent;
  always_comb begin
    extended = (SUM_W + 1)'(sum);
    magnitude = $unsigned(extended < 0 ? -extended : extended);
    highest = 0;
    for (int i = 0; i < SUM_W; i++) if (magnitude[i]) highest = i;
    exponent = exponent_t'(base_exp) + exponent_t'(highest);
    sig24 = highest >= 23 ? 24'(magnitude >> (highest - 23)) : 24'(magnitude << (23 - highest));
    if (special_valid) result = special_result;
    else if (sum == 0) result = 0;
    else if (exponent > 127) result = {sum[SUM_W-1], 8'hff, 23'b0};
    else if (exponent >= -126) result = {sum[SUM_W-1], 8'(int'(exponent) + 127), sig24[22:0]};
    else if (exponent >= -149) result = {sum[SUM_W-1], 8'b0, 23'(sig24 >> (-126 - int'(exponent)))};
    else result = {sum[SUM_W-1] && !CANONICAL_ZERO, 31'b0};
  end
endmodule
