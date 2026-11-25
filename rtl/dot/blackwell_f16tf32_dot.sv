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
  logic [6:0] advance;
  logic [3:0] low_mode;
  logic spill_write, spill_valid;
  blackwell_fp_dot_control #(
    .HAS_WIDE(1),
    .HAS_LOW (0)
  ) control (
    .allow_spill(1'b0),
    .clk,
    .rst_n,
    .req_valid,
    .req_ready,
    .req_low(1'b0),
    .wide_ready(rsp_ready),
    .low_ready(1'b0),
    .wide_valid(rsp_valid),
    .low_valid(),
    .advance,
    .low_mode,
    .spill_write,
    .spill_valid
  );
  blackwell_fp_dot_lane #(
    .HAS_WIDE(1),
    .HAS_LOW (0)
  ) lane (
    .clk,
    .advance,
    .low_mode,
    .spill_write,
    .spill_valid,
    .req_low(1'b0),
    .wide_req(req_payload),
    .low_req('0),
    .wide_result(rsp_payload),
    .low_result()
  );
endmodule
