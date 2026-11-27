// Check setup's four-edge multiplier contract independently of its partial products.
module setup_product_check (
  input logic clk,
  input logic rst_n,
  input logic issue,
  input logic [4:0] issue_tag,
  input logic [63:0] operand_a,
  input logic [39:0] operand_b,
  input logic returned,
  input logic [4:0] return_tag,
  input logic [75:0] product
);
  typedef struct packed {
    logic valid;
    logic [4:0] tag;
    logic [75:0] value;
  } expected_t;
  expected_t expected[4];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      foreach (expected[i]) expected[i].valid <= 0;
    end else begin
      if (returned !== expected[3].valid ||
          (returned && {return_tag, product} !== {expected[3].tag, expected[3].value}))
        $fatal(
            1,
            "TMA setup multiply return: expected %h, got %h",
            expected[3],
            {
              returned, return_tag, product
            }
        );
      expected[0] <= '{valid: issue, tag: issue_tag, value: 76'(operand_a) * 76'(operand_b)};
      for (int i = 1; i < 4; i++) expected[i] <= expected[i-1];
    end
  end
endmodule

bind blackwell_tma_setup setup_product_check product_check (
  .clk,
  .rst_n,
  .issue(found),
  .issue_tag({chosen, task_id}),
  .operand_a(mul_a),
  .operand_b(mul_b),
  .returned(pipe[3].valid),
  .return_tag({pipe[3].slot, pipe[3].task_id}),
  .product(product_value)
);
