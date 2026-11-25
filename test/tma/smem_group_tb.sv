module smem_group_tb;
  import blackwell_async_pkg::*;
  import blackwell_smem_pkg::*;
  logic clk = 0, rst_n = 0, halt_i = 0;
  logic [15:0] epoch_i = 0;
  mma_live_t live[3];
  logic [15:0][7:0]
      rd_req_valid,
      wr_req_valid,
      rd_rsp_ready,
      wr_ack_ready,
      rd_req_ready,
      wr_req_ready,
      rd_rsp_valid,
      wr_ack_valid;
  smem_rd_req_t rd_req_payload[16][8];
  smem_wr_req_t wr_req_payload[16][8];
  smem_rd_rsp_t rd_rsp_payload[16][8];
  smem_wr_ack_t wr_ack_payload[16][8];
  logic drained_o, fault_o;
  async_id_t id = '{epoch: 16'd1, issuer: 10'd3, seq: 32'd9};
  logic [15:0] lsu_token, lsu_mask;
  logic [15:0] wtoken, wmask;
  logic [127:0] wdata;
  localparam logic [127:0] PATTERN = 128'hffee_ddcc_bbaa_9988_7766_5544_3322_1100;
  for (genvar c = 0; c < 16; c++)
  for (genvar g = 0; g < 8; g++) begin
    assign rd_req_payload[c][g] = '{
            tag: '{id: id, client: 4'(c), token: (c < 2 ? 16'h2000 + 16'(c) : lsu_token)},
            addr: 32'd0,
            byte_mask: (c == 0 ? 16'h00ff : c == 1 ? 16'hff00 : lsu_mask)
        };
    assign wr_req_payload[c][g] = '{
            tag: '{id: id, client: 4'(c), token: wtoken},
            addr: 32'd0,
            byte_mask: wmask,
            data: wdata
        };
  end
  assign live[0] = '{valid: 1, rec: 0, id: id};
  assign live[1] = '0;
  assign live[2] = '0;
  blackwell_smem_fabric dut (.*);
  always #1 clk = !clk;
  task automatic request_read(input int client, input int token, input logic [15:0] mask);
    @(negedge clk);
    lsu_token = 16'(token);
    lsu_mask = mask;
    rd_req_valid[client][0] = 1;
    do @(posedge clk); while (!rd_req_ready[client][0]);
    @(negedge clk);
    rd_req_valid[client][0] = 0;
  endtask
  initial begin
    #400;
    $fatal(1, "group progress timeout");
  end
  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1;
    epoch_i = 1;
    wr_ack_ready = '1;
    rd_rsp_ready = '1;
    wr_req_valid[12][0] = 1;
    wdata = PATTERN;
    wmask = '1;
    wtoken = 1;
    @(posedge clk);
    if (!wr_req_ready[12][0]) $fatal;
    @(negedge clk);
    wr_req_valid = 0;
    @(posedge clk);
    if (!wr_ack_valid[12][0] || wr_ack_payload[12][0].tag.token != 1) $fatal;
    @(negedge clk);
    rd_req_valid[0][0] = 1;
    rd_req_valid[1][0] = 1;
    rd_rsp_ready[1][0] = 0;
    @(posedge clk);
    if (!rd_req_ready[0][0] || !rd_req_ready[1][0]) $fatal(1, "broadcast capture");
    @(negedge clk);
    rd_req_valid = 0;
    repeat (2) begin
      @(posedge clk);
      if (rd_rsp_valid[0][0] || rd_rsp_valid[1][0]) $fatal(1, "early return");
    end
    @(posedge clk);
    if (!rd_rsp_valid[0][0] || !rd_rsp_valid[1][0] || rd_rsp_payload[0][0].data !=
        {64'b0, PATTERN[63:0]} || rd_rsp_payload[1][0].data != {PATTERN[127:64], 64'b0} ||
        rd_rsp_payload[1][0].tag.token != 16'h2001)
      $fatal(
          1,
          "broadcast payload v=%b,%b ret0=%h ret1=%h tok=%h",
          rd_rsp_valid[0][0],
          rd_rsp_valid[1][0],
          rd_rsp_payload[0][0].data,
          rd_rsp_payload[1][0].data,
          rd_rsp_payload[1][0].tag.token
      );
    for (int i = 2; i <= 4; i++) request_read(12, i, '1);
    // The held multicast counts as one credit. Two later samples and a
    // registered request fill the pipeline before the stalled receiver retires.
    rd_req_valid[12][0] = 1;
    lsu_token = 5;
    repeat (3) begin
      @(posedge clk);
      if (rd_req_ready[12][0] || rd_rsp_valid[0][0] || !rd_rsp_valid[1][0])
        $fatal(1, "group credit or repeated delivery");
    end
    @(negedge clk);
    rd_rsp_ready[1][0] = 1;
    @(posedge clk);
    if (!rd_req_ready[12][0]) $fatal(1, "credit not reused");
    @(negedge clk);
    rd_req_valid = 0;
    for (int i = 2; i <= 5; i++) begin
      @(posedge clk);
      if (!rd_rsp_valid[12][0] || rd_rsp_payload[12][0].tag.token != 16'(i) ||
          rd_rsp_payload[12][0].data != PATTERN)
        $fatal(1, "return order");
    end
    // Different bytes within a subword still conflict. First collision grants
    // the old read. The waiting byte write commits one edge later.
    request_read(12, 6, 16'h0002);
    wr_req_valid[12][0] = 1;
    wmask = 16'h0001;
    wdata = 128'hff;
    wtoken = 7;
    @(posedge clk);
    if (wr_req_ready[12][0]) $fatal(1, "conflicting subword");
    @(posedge clk);
    if (!wr_req_ready[12][0]) $fatal(1, "waiting write");
    @(negedge clk);
    wr_req_valid = 0;
    @(posedge clk);
    if (!rd_rsp_valid[12][0] || rd_rsp_payload[12][0].data != 128'h1100)
      $fatal(1, "read byte mask");
    request_read(12, 8, '1);
    do @(posedge clk); while (!rd_rsp_valid[12][0]);
    if (rd_rsp_payload[12][0].data != {PATTERN[127:8], 8'hff} || fault_o)
      $fatal(1, "masked write damaged neighbor");
    @(negedge clk);
    if (!drained_o) $fatal(1, "remaining credits");
    $display("PASS shared SMEM multicast, credits, conflict and masked writes");
    $finish;
  end
endmodule
