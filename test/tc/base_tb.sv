module base_tb;
  bit clk;
  always #5 clk = !clk;
  logic rst_n, in_valid, out_ready;
  logic [7:0] in_payload;
  logic [2:0] in_ready, out_valid;
  logic [2:0][7:0] out_payload;
  logic [1:0] read_enable, write_enable;
  logic [1:0][1:0] read_addr, write_addr, write_byte_mask;
  logic [1:0][15:0] write_data, read_q;
  blackwell_pipeline_reg #(
    .WIDTH(8)
  ) stage (
    .clk,
    .rst_n,
    .in_valid,
    .in_payload,
    .out_ready,
    .in_ready(in_ready[0]),
    .out_valid(out_valid[0]),
    .out_payload(out_payload[0])
  );
  for (genvar i = 0; i < 2; i++) begin : fifo
    blackwell_fifo #(
      .WIDTH(8),
      .DEPTH(1 + i * 2)
    ) q (
      .clk,
      .rst_n,
      .in_valid,
      .in_payload,
      .out_ready,
      .occupancy(),
      .in_ready(in_ready[i+1]),
      .out_valid(out_valid[i+1]),
      .out_payload(out_payload[i+1])
    );
  end
  blackwell_banked_sram #(
    .BANKS (2),
    .DEPTH (3),
    .WORD_W(16)
  ) ram (
    .*
  );
  task automatic tick;
    @(posedge clk);
    @(negedge clk);
  endtask
  byte unsigned model[3][200];
  int head[3], tail_idx[3];
  initial begin
    rst_n = 0;
    tick();
    rst_n = 1;
    write_enable = 3;
    write_addr = {2'd1, 2'd2};
    write_byte_mask = '1;
    write_data = 32'h1234abcd;
    tick();
    write_enable = 0;
    read_enable = 3;
    read_addr = write_addr;
    tick();
    if (read_q != 32'h1234abcd) $fatal;
    read_enable = 2;
    write_enable = 1;
    write_byte_mask[0] = 1;
    write_data[0] = 16'h0099;
    tick();
    if (read_q != 32'h1234abcd) $fatal;
    write_enable = 0;
    read_enable = 1;
    tick();
    if (read_q != 32'h1234ab99) $fatal;
    read_enable = 0;
    for (int n = 0; n < 200; n++) begin
      in_valid = 1'($urandom);
      out_ready = 1'($urandom);
      in_payload = 8'(n);
      #1;
      for (int i = 0; i < 3; i++) begin
        int capacity;
        capacity = i == 2 ? 3 : 1;
        if (out_valid[i] != ((tail_idx[i] - head[i]) != 0) ||
            in_ready[i] != ((tail_idx[i] - head[i]) < capacity || out_ready))
          $fatal;
        if (out_valid[i] && out_payload[i] != model[i][head[i]])
          $fatal(
              1,
              "cycle=%0d queue=%0d expected=%0d actual=%0d",
              n,
              i,
              model[i][head[i]],
              out_payload[i]
          );
        if (out_valid[i] && out_ready) head[i]++;
        if (in_valid && in_ready[i]) begin
          model[i][tail_idx[i]] = in_payload;
          tail_idx[i]++;
        end
      end
      tick();
    end
    $display("PASS base FIFO, elastic stage, masked SRAM and retained Q");
    $finish;
  end
endmodule
