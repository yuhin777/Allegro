module blackwell_int8_dot
  import blackwell_dot_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic req_valid,
  output logic req_ready,
  input logic [$bits(int_req_t)-1:0] req_payload,
  output logic rsp_valid,
  input logic rsp_ready,
  output logic [32:0] rsp_payload
);
  int_req_t req;
  assign req = req_payload;
  typedef struct packed {
    logic [15:0][17:0] pairs;
    logic [31:0] c;
    logic sat;
  } pairs_t;
  typedef struct packed {
    logic signed [21:0] psum;
    logic signed [31:0] c;
    logic sat;
  } partial_t;
  pairs_t d0, q0;
  partial_t d1, q1;
  logic [32:0] d2;
  // S8/U8 decode bounds each product to [-32640, 65025].
  for (genvar p = 0; p < 16; p++) begin : g_pair
    logic signed [16:0] product[2];
    for (genvar i = 0; i < 2; i++) begin : g_product
      localparam int K = 2 * p + i;
      assign product[i] = $signed(req.a[K]) * $signed(req.b[K]);
    end
    assign d0.pairs[p] = 18'(product[0]) + 18'(product[1]);
  end
  assign d0.c = req.c, d0.sat = req.saturate;
  blackwell_dot_signed_reduce_tree #(
    .TERM_N(16),
    .TERM_W(18),
    .SUM_W (22)
  ) reduce_terms (
    .term_flat_i(q0.pairs),
    .sum_o(d1.psum)
  );
  assign d1.c = q0.c, d1.sat = q0.sat;
  logic signed [32:0] total;
  logic overflow;
  assign total = 33'($signed(q1.psum)) + 33'($signed(q1.c));
  assign overflow = total[32] ^ total[31];
  assign d2 = {
    q1.sat && overflow ? (total[32] ? 32'h80000000 : 32'h7fffffff) : total[31:0], overflow
  };
  logic [3:0] valid, ready;
  assign valid[0] = req_valid, req_ready = ready[0], rsp_valid = valid[3], ready[3] = rsp_ready;
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
    .out_payload(rsp_payload)
  );
`ifndef SYNTHESIS
  initial
    if ($bits(q0) != 321 || $bits(q1) != 55 || $bits(d2) != 33)
      $fatal(1, "int8 pipeline storage width");
`endif
endmodule
