// The FP16-D numeric provider normalizes/rounds the existing dot accumulator.
// This is the explicit numeric dependency; no simulation math is product RTL.
// final_i carries the final K-chunk FDA sum, signed exponent and special state,
// before FP32 packing. Intermediate chunks still use the existing FP32 carry.
// One result cell returns FP16 in [15:0]; the masked TMEM write ignores [31:16].
(* blackbox *) module blackwell_fp16_result_provider #(
  parameter int unsigned DOTS = 256
) (
  input logic clk,
  input logic rst_n,
  input logic in_vld_i,
  output logic in_rdy_o,
  input logic result_fp16_i,
  input logic [DOTS*dot_prod_pkg::DOT_FINAL_W-1:0] final_i,
  output logic out_vld_o,
  input logic out_rdy_i,
  output logic [DOTS*32-1:0] result_o
);
endmodule
