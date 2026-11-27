module blackwell_dot_align_fixed_rz #(
  parameter int MAG_W = 32,
  TERM_W = MAG_W + 1,
  EXP_W = 10
) (
  input logic term_valid,
  input logic term_sign,
  input logic [MAG_W-1:0] term_mag,
  input logic signed [EXP_W-1:0] term_exp,
  input logic signed [EXP_W-1:0] emax,
  output logic signed [TERM_W-1:0] term
);
  logic signed [EXP_W:0] distance;
  logic signed [TERM_W-1:0] magnitude;
  always_comb begin
    distance = (EXP_W + 1)'(emax) - (EXP_W + 1)'(term_exp);
    magnitude = $signed({1'b0, term_mag >> $unsigned(distance)});
    term = !term_valid ? '0 : (term_sign ? -magnitude : magnitude);
  end
`ifndef SYNTHESIS
  always_comb
    assert final (!term_valid || $isunknown({term_exp, emax}) || distance >= 0)
    else $error("valid dot exponent exceeds emax");
`endif
endmodule
