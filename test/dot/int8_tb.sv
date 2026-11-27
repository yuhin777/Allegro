module int8_tb;
  import blackwell_dot_pkg::*;
  bit clk;
  always #5 clk = ~clk;
  logic rst_n, req_valid, req_ready, rsp_valid, rsp_ready;
  int_req_t req_payload;
  logic [32:0] rsp_payload;
  blackwell_int8_dot dut (.*);

  assert property (@(posedge clk) disable iff (!rst_n)
      rsp_valid && !rsp_ready |=> rsp_valid && $stable(
      rsp_payload
  ));

  task automatic check(input logic [31:0] c, input int a, b, lanes, input bit sat,
                       input logic [31:0] result, input bit overflow);
    req_payload = '0;
    req_payload.c = c;
    req_payload.saturate = sat;
    for (int k = 0; k < lanes; k++) begin
      req_payload.a[k] = 9'(a);
      req_payload.b[k] = 9'(b);
    end
    req_valid = 1;
    rsp_ready = 0;
    @(posedge clk);
    if (!req_ready) $fatal(1, "INT8 input stalled after drain");
    @(negedge clk);
    req_valid = 0;
    req_payload = '0;
    repeat (2) @(negedge clk);
    repeat (3) begin
      if (!rsp_valid || rsp_payload !== {result, overflow})
        $fatal(
            1,
            "INT8 c=%h a=%0d b=%0d lanes=%0d sat=%b got=%h expected=%h",
            c,
            a,
            b,
            lanes,
            sat,
            rsp_payload,
            {
              result, overflow
            }
        );
      @(negedge clk);
    end
    rsp_ready = 1;
    @(negedge clk);
    if (rsp_valid) $fatal(1, "duplicate INT8 response");
  endtask

  initial begin
    @(negedge clk);
    rst_n = 1;
    for (int s = 0; s < 2; s++) begin
      check(32'h7fffffff, 0, 1, 1, 1'(s), 32'h7fffffff, 0);
      check(32'h7fffffff, 1, 1, 1, 1'(s), s == 1 ? 32'h7fffffff : 32'h80000000, 1);
      check(32'h80000000, 0, 1, 1, 1'(s), 32'h80000000, 0);
      check(32'h80000000, -1, 1, 1, 1'(s), s == 1 ? 32'h80000000 : 32'h7fffffff, 1);
    end
    check(0, 255, 255, 32, 0, 32'd2080800, 0);
    check(0, -128, 255, 32, 0, -32'sd1044480, 0);
    check(0, 255, -128, 32, 0, -32'sd1044480, 0);
    check(0, -128, -128, 32, 0, 32'd524288, 0);
    $display("PASS INT8 signed bounds, wrap, saturation and stalled overflow flag");
    $finish;
  end
endmodule
