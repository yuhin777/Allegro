module base_tb;
  bit clk;
  always #5 clk = !clk;
  logic rst_n;
  logic [2:0] in_valid, in_ready, out_valid, out_ready;
  logic [2:0][7:0] in_payload, out_payload;
  logic [1:0][1:0] fifo_occupancy;
  logic [1:0] read_enable, write_enable;
  logic [1:0][1:0] read_addr, write_addr, write_byte_mask;
  logic [1:0][15:0] write_data, read_q;
  blackwell_pipeline_reg #(
    .WIDTH(8)
  ) stage (
    .clk,
    .rst_n,
    .in_valid(in_valid[0]),
    .in_payload(in_payload[0]),
    .out_ready(out_ready[0]),
    .in_ready(in_ready[0]),
    .out_valid(out_valid[0]),
    .out_payload(out_payload[0])
  );
  for (genvar i = 0; i < 2; i++) begin : fifo
    localparam int DEPTH = 1 + i * 2;
    wire [$clog2(DEPTH+1)-1:0] occupancy;
    assign fifo_occupancy[i] = 2'(occupancy);
    blackwell_fifo #(
      .WIDTH(8),
      .DEPTH(DEPTH)
    ) q (
      .clk,
      .rst_n,
      .in_valid(in_valid[i+1]),
      .in_payload(in_payload[i+1]),
      .out_ready(out_ready[i+1]),
      .occupancy,
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
  // At most three accepted bytes can be live in any one reference queue.
  byte unsigned expected[3][3];
  int head[3], tail_idx[3];
  byte unsigned next_payload[3];
  int cycle;

  task automatic queue_cycle(input bit [2:0] offer, input bit [2:0] ready);
    bit [2:0] accepted;
    out_ready = ready;
    for (int i = 0; i < 3; i++) begin
      if (!in_valid[i] && offer[i]) begin
        in_valid[i] = 1'b1;
        in_payload[i] = next_payload[i];
        next_payload[i]++;
      end
    end
    #1;
    accepted = in_valid & in_ready;
    for (int i = 0; i < 3; i++) begin
      int count, capacity;
      count = tail_idx[i] - head[i];
      capacity = i == 2 ? 3 : 1;
      if (i > 0) begin
        if (fifo_occupancy[i-1] !== 2'(count))
          $fatal(1, "cycle=%0d queue=%0d occupancy=%0d expected=%0d",
                 cycle, i, fifo_occupancy[i-1], count);
      end
      if (out_valid[i] !== (count != 0) ||
          in_ready[i] !== (count < capacity || out_ready[i]))
        $fatal(1, "cycle=%0d queue=%0d count=%0d out_valid=%b in_ready=%b out_ready=%b",
               cycle, i, count, out_valid[i], in_ready[i], out_ready[i]);
      if (count != 0) begin
        if (out_payload[i] !== expected[i][head[i] % 3])
          $fatal(1, "cycle=%0d queue=%0d expected=%0d actual=%0d",
                 cycle, i, expected[i][head[i] % 3], out_payload[i]);
        if (out_ready[i]) head[i]++;
      end
      if (accepted[i]) begin
        expected[i][tail_idx[i] % 3] = in_payload[i];
        tail_idx[i]++;
      end
    end
    tick();
    // A blocked offer retains valid and payload into the next cycle.
    in_valid &= ~accepted;
    cycle++;
  endtask

  initial begin
    cycle = 0;
    rst_n = 0;
    in_valid = '0;
    out_ready = '0;
    read_enable = '0;
    write_enable = '0;
    foreach (next_payload[i]) begin
      head[i] = 0;
      tail_idx[i] = 0;
      next_payload[i] = 8'(64 * i);
    end
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
    // Fill all three queues, keep a new offer blocked, then replace the
    // old head on consecutive full pop/push edges through a depth-three wrap.
    repeat (5) queue_cycle('1, '0);
    repeat (4) queue_cycle('1, '1);
    repeat (200) queue_cycle(3'($urandom), 3'($urandom));

    // End with a pending offer on every input. Four ready edges transfer
    // the blocked offer and drain even the depth-three FIFO.
    repeat (4) queue_cycle('1, '0);
    repeat (4) queue_cycle('0, '1);
    queue_cycle('0, '1);
    foreach (next_payload[i]) begin
      if (in_valid[i] || tail_idx[i] != head[i])
        $fatal(1, "queue=%0d failed to drain", i);
    end
    $display("PASS base FIFO, elastic stage, masked SRAM and retained Q");
    $finish;
  end
endmodule
