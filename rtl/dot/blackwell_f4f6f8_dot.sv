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
  logic [6:0] advance;
  logic [3:0] low_mode;
  logic spill_write, spill_valid;
  blackwell_fp_dot_control #(
    .HAS_WIDE(0),
    .HAS_LOW (1)
  ) control (
    .allow_spill(1'b0),
    .clk,
    .rst_n,
    .req_valid,
    .req_ready,
    .req_low(1'b1),
    .wide_ready(1'b0),
    .low_ready(rsp_ready),
    .low_valid(rsp_valid),
    .wide_valid(),
    .advance,
    .low_mode,
    .spill_write,
    .spill_valid
  );
  blackwell_fp_dot_lane #(
    .HAS_WIDE(0),
    .HAS_LOW (1)
  ) lane (
    .clk,
    .advance,
    .low_mode,
    .spill_write,
    .spill_valid,
    .req_low(1'b1),
    .low_req(req_payload),
    .wide_req('0),
    .low_result(rsp_payload),
    .wide_result()
  );
endmodule
