// All three independent read reservations can be occupied at one bank.
// Check full-credit reuse without using any internal state as the oracle.
module tmem_partition_tb;
  import blackwell_async_pkg::*;
  import blackwell_tmem_pkg::*;
  logic clk = 0, rst_n = 0;
  always #5 clk = !clk;
  logic [31:0] rd_req_valid, rd_req_ready, rd_rsp_valid, rd_rsp_ready;
  logic [31:0] wr_req_valid, wr_req_ready, wr_ack_valid, wr_ack_ready = '1;
  tmem_rd_req_t rd_req_payload[32];
  tmem_rd_rsp_t rd_rsp_payload[32];
  tmem_wr_req_t wr_req_payload[32];
  tmem_wr_ack_t wr_ack_payload[32];
  logic [31:0][1:0] read_credit_o;
  logic [1:0] write_credit_o;
  logic drained_o;
  logic [31:0][6:0] word_sel;
  logic [31:0][15:0] token, mask;
  logic modify;
  logic enable_consumer;
  always_ff @(posedge clk) rd_rsp_ready <= {30'b0, {2{enable_consumer}}};
  blackwell_tmem_partition dut (.*);
  function automatic logic [127:0] full_word(input int b, w);
    logic [127:0] data;
    for (int i = 0; i < 16; i++) data[i*8+:8] = 8'(11 * b + 17 * w + 3 * i);
    return data;
  endfunction
  for (genvar b = 0; b < 32; b++) begin
    assign rd_req_payload[b] = '{
            tag: '{
                id: '{epoch: 16'd7, issuer: 10'd31, seq: 32'd8},
                client: 4'd0,
                token: token[b]
            },
            lane: 7'(b),
            word: word_sel[b],
            byte_mask: mask[b]
        };
    assign wr_req_payload[b] = '{
            tag: '{
                id: '{epoch: 16'd7, issuer: 10'd31, seq: 32'd9},
                client: 4'd0,
                token: token[b]
            },
            lane: 7'(b),
            word: word_sel[b],
            byte_mask: mask[b],
            data: modify ? {16{8'ha5}} : full_word(b, int'(word_sel[b]))
        };
  end
  task automatic expect_bank(input int b, w, tok, input logic [15:0] read_mask, changed = 0);
    logic [127:0] want;
    want = full_word(b, w);
    for (int i = 0; i < 16; i++) begin
      if (changed[i]) want[8*i+:8] = 8'ha5;
      if (!read_mask[i]) want[8*i+:8] = 0;
    end
    if (!rd_rsp_valid[b] || rd_rsp_payload[b].tag.token != 16'(tok) ||
        rd_rsp_payload[b].data !== want)
      $fatal(1, "bank %0d wrong return for token %0d", b, tok);
  endtask
  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1;
    wr_req_valid = 3;
    mask = '1;
    for (int w = 0; w < 5; w++) begin
      word_sel[0] = 7'(w);
      word_sel[1] = 7'(w);
      token[0] = 16'(w);
      token[1] = 16'(64 + w);
      @(posedge clk);
      if (wr_req_ready[1:0] != 3) $fatal;
      @(negedge clk);
    end
    wr_req_valid = 0;
    repeat (2) @(negedge clk);
    rd_req_valid[0] = 1;
    for (int w = 0; w < 3; w++) begin
      word_sel[0] = 7'(w);
      token[0] = 16'(10 + w);
      mask[0] = 16'hffff >> (2 * w);
      @(posedge clk);
      if (!rd_req_ready[0] || read_credit_o[0] != 2'(3 - w)) $fatal;
      @(negedge clk);
    end
    word_sel[0] = 3;
    token[0] = 13;
    mask[0] = 16'h1357;
    rd_req_valid[1] = 1;
    word_sel[1] = 4;
    token[1] = 64;
    mask[1] = 16'hf0f0;
    @(posedge clk);
    if (rd_req_ready[0] || !rd_req_ready[1] || read_credit_o[0] != 0) $fatal;
    @(negedge clk);
    rd_req_valid[1] = 0;
    repeat (3) begin
      @(posedge clk);
      if (rd_req_ready[0]) $fatal;
      expect_bank(0, 0, 10, 16'hffff);
      @(negedge clk);
    end
    expect_bank(1, 4, 64, 16'hf0f0);
    enable_consumer = 1;
    @(negedge clk);
    @(posedge clk);
    if (!rd_req_ready[0] || read_credit_o[0] != 1)
      $fatal(1, "ready %b credit %d", rd_req_ready[0], read_credit_o[0]);
    expect_bank(0, 0, 10, 16'hffff);
    @(negedge clk);
    rd_req_valid = 0;
    for (int w = 1; w < 4; w++) begin
      @(posedge clk);
      expect_bank(0, w, 10 + w, w == 3 ? 16'h1357 : 16'hffff >> (2 * w));
      @(negedge clk);
    end
    // The winning masked write changes only alternate bytes. The withheld
    // read then observes the committed value from the same bank and word.
    rd_req_valid[0] = 1;
    wr_req_valid[0] = 1;
    word_sel[0] = 3;
    mask[0] = 16'h5555;
    token[0] = 99;
    modify = 1;
    @(posedge clk);
    if (rd_req_ready[0] || !wr_req_ready[0]) $fatal;
    @(negedge clk);
    wr_req_valid = 0;
    @(posedge clk);
    if (!rd_req_ready[0]) $fatal;
    @(negedge clk);
    rd_req_valid = 0;
    repeat (2) @(negedge clk);
    @(posedge clk);
    expect_bank(0, 3, 99, 16'h5555, 16'h5555);
    @(negedge clk);
    rd_req_valid[0] = 1;
    mask[0] = '1;
    token[0] = 100;
    @(posedge clk);
    if (!rd_req_ready[0]) $fatal;
    @(negedge clk);
    rd_req_valid = 0;
    repeat (2) @(negedge clk);
    @(posedge clk);
    expect_bank(0, 3, 100, 16'hffff, 16'h5555);
    @(negedge clk);
    if (!drained_o) $fatal;
    $display("PASS TMEM three reservations, same-edge reuse, independent banks, masked conflict");
    $finish;
  end
  initial begin
    repeat (250) @(posedge clk);
    $fatal(1, "timeout");
  end
endmodule
