module blackwell_pipeline_reg #(
  parameter int WIDTH = 1
) (
  input logic clk,
  input logic rst_n,
  input logic in_valid,
  output logic in_ready,
  input logic [WIDTH-1:0] in_payload,
  output logic out_valid,
  input logic out_ready,
  output logic [WIDTH-1:0] out_payload
);
  assign in_ready = !out_valid || out_ready;
  always_ff @(posedge clk) begin
    if (!rst_n) out_valid <= 1'b0;
    else if (in_ready) begin
      out_valid <= in_valid;
      if (in_valid) out_payload <= in_payload;
    end
  end
endmodule
