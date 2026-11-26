// Drive RF store/load against one physical 32-bank partition. Timing below is
// counted at the receiving edge, and every lane has distinct data.
module tmem_rf_tb;
  import blackwell_async_pkg::*;
  import blackwell_tmem_pkg::*;
  logic clk = 0, rst_n = 0, halt_i = 0, stop_i = 0;
  always #5 clk = !clk;
  int cycle;
  always @(posedge clk) cycle <= cycle + 1;
  logic issue_valid, issue_ready;
  ldst_issue_t issue_payload;
  logic rf_store_valid, rf_store_ready, rf_load_valid, rf_load_ready;
  rf_beat_t rf_store_payload, rf_load_payload;
  logic [127:0] rd_req_valid, rd_req_ready, rd_rsp_valid, rd_rsp_ready;
  logic [127:0] wr_req_valid, wr_req_ready, wr_ack_valid, wr_ack_ready;
  tmem_rd_req_t rd_req_payload[128];
  tmem_rd_rsp_t rd_rsp_payload[128];
  tmem_wr_req_t wr_req_payload[128];
  tmem_wr_ack_t wr_ack_payload[128];
  logic pin_req_valid, pin_req_ready = 1, pin_rsp_valid, pin_rsp_ready;
  tmem_pin_req_t pin_req_payload;
  tmem_pin_rsp_t pin_rsp_payload;
  logic unpin_valid, unpin_ready = 1, done_valid, done_ready, track_done_valid, track_done_ready;
  tmem_unpin_t unpin_payload;
  op_done_t done_payload;
  rf_track_done_t track_done_payload;
  logic fault_o, drained_o;
  localparam int BASE_LANE = 64;
  logic [31:0] read_ready, write_ready, return_valid, ack_valid;
  tmem_rd_req_t read_data[32];
  tmem_rd_rsp_t return_data[32];
  tmem_wr_req_t write_data[32];
  tmem_wr_ack_t ack_data[32];
  logic part_fault, part_drained, inject_final_error, allow_fault;
  blackwell_tmem_ldst_engine dut (.*);
  blackwell_tmem_partition #(
    .PARTITION_ID(BASE_LANE / 32)
  ) part (
    .clk,
    .rst_n,
    .halt_i,
    .rd_req_valid(rd_req_valid[BASE_LANE+:32]),
    .rd_req_ready(read_ready),
    .rd_req_payload(read_data),
    .rd_rsp_valid(return_valid),
    .rd_rsp_ready(rd_rsp_ready[BASE_LANE+:32]),
    .rd_rsp_payload(return_data),
    .wr_req_valid(wr_req_valid[BASE_LANE+:32]),
    .wr_req_ready(write_ready),
    .wr_req_payload(write_data),
    .wr_ack_valid(ack_valid),
    .wr_ack_ready(wr_ack_ready[BASE_LANE+:32]),
    .wr_ack_payload(ack_data),
    .read_credit_o(),
    .write_credit_o(),
    .drained_o(part_drained),
    .fault_o(part_fault)
  );
  for (genvar t = 0; t < 128; t++) begin
    if (t >= BASE_LANE && t < BASE_LANE + 32) begin
      localparam int B = t - BASE_LANE;
      assign read_data[B] = rd_req_payload[t];
      assign write_data[B] = wr_req_payload[t];
      assign rd_req_ready[t] = read_ready[B];
      assign wr_req_ready[t] = write_ready[B];
      assign rd_rsp_valid[t] = return_valid[B];
      assign wr_ack_valid[t] = ack_valid[B];
      assign rd_rsp_payload[t] = return_data[B];
      assign wr_ack_payload[t].tag = ack_data[B].tag;
      assign wr_ack_payload[t].status = B == 0 && inject_final_error &&
          ack_data[B].tag.token[14:8] == 15 ? MEMORY : ack_data[B].status;
    end else begin
      assign rd_req_ready[t] = 0;
      assign wr_req_ready[t] = 0;
      assign rd_rsp_valid[t] = 0;
      assign wr_ack_valid[t] = 0;
      assign rd_rsp_payload[t] = tmem_rd_rsp_t'('0);
      assign wr_ack_payload[t] = tmem_wr_ack_t'('0);
    end
  end
  always_ff @(posedge clk) begin
    if (!rst_n) pin_rsp_valid <= 0;
    else begin
      if (pin_rsp_valid && pin_rsp_ready) pin_rsp_valid <= 0;
      if (pin_req_valid && pin_req_ready) begin
        pin_rsp_valid <= 1;
        pin_rsp_payload <= '{id: pin_req_payload.id, status: OK};
      end
      if ((fault_o && !allow_fault) || part_fault)
        $fatal(1, "unexpected fault at cycle %0d", cycle);
    end
  end
  int first_read, last_read, nread, last_ack;
  always @(posedge clk) begin
    if (rd_req_ready[BASE_LANE] && rd_req_valid[BASE_LANE]) begin
      if (nread == 0) first_read = cycle;
      nread++;
      last_read = cycle;
      if (rd_req_valid[BASE_LANE+:32] != '1) $fatal;
    end
    if (ack_valid[0] && wr_ack_ready[BASE_LANE]) last_ack = cycle;
  end
  function automatic logic [31:0] value(input int lane, column);
    return 32'h37ac9 + lane * 32'h1f5a + column * 32'h3613;
  endfunction
  task automatic issue(input bit store, x32, input int base, seqnum);
    @(negedge clk);
    issue_payload = '{
        cmd: '{
            id: '{epoch: 16'd7, issuer: 10'd64, seq: 32'(seqnum)},
            store: store,
            x32: x32,
            base: {16'(BASE_LANE), 16'(base)}
        },
        slot: 5'(seqnum)
    };
    issue_valid = 1;
    do @(posedge clk); while (!issue_ready);
    @(negedge clk);
    issue_valid = 0;
  endtask
  task automatic finish_cmd(input int seqnum);
    while (!done_valid) @(negedge clk);
    repeat (2) begin
      if (!done_valid || done_payload.id.seq != seqnum || track_done_valid) $fatal;
      @(negedge clk);
    end
    done_ready = 1;
    @(negedge clk);
    done_ready = 0;
    if (!track_done_valid || track_done_payload.slot != 5'(seqnum)) $fatal;
    @(negedge clk);
    track_done_ready = 1;
    @(negedge clk);
    track_done_ready = 0;
    if (!drained_o || !part_drained) $fatal;
  endtask
  task automatic store16(input int base, seqnum);
    int first_rf;
    issue(1, 0, base, seqnum);
    for (int j = 0; j < 16; j++) begin
      rf_store_valid = 1;
      rf_store_payload.id = issue_payload.cmd.id;
      rf_store_payload.index = 7'(j);
      rf_store_payload.last = j == 15;
      for (int t = 0; t < 32; t++) rf_store_payload.data[t*32+:32] = value(t, base + j);
      do @(posedge clk); while (!rf_store_ready);
      if (j == 0) first_rf = cycle;
      @(negedge clk);
    end
    rf_store_valid = 0;
    finish_cmd(seqnum);
    if (last_ack != first_rf + 18)
      $fatal(1, "ST tail got %0d expected %0d", last_ack, first_rf + 18);
  endtask
  task automatic load_regs(input bit x32, stall, input int base, seqnum);
    int count;
    rf_beat_t held;
    count = x32 ? 32 : 16;
    nread = 0;
    issue(0, x32, base, seqnum);
    for (int j = 0; j < count; j++) begin
      if (stall && j == 3 - base % 4) begin
        rf_load_ready = 0;
        while (!rf_load_valid) @(negedge clk);
        held = rf_load_payload;
        repeat (7) begin
          @(negedge clk);
          if (!rf_load_valid || rf_load_payload != held) $fatal(1, "stalled RF changed");
        end
      end
      rf_load_ready = 1;
      do @(posedge clk); while (!rf_load_valid);
      if (rf_load_payload.index != 7'(j) || rf_load_payload.last != (j == count - 1) ||
          rf_load_payload.id != issue_payload.cmd.id)
        $fatal;
      for (int t = 0; t < 32; t++)
      if (rf_load_payload.data[t*32+:32] != value(t, base + j))
        $fatal(1, "load lane %0d col %0d", t, base + j);
      if (!stall && cycle != first_read + j + 4)
        $fatal(1, "RF beat %0d at %0d expected %0d", j, cycle, first_read + j + 4);
      @(negedge clk);
    end
    rf_load_ready = 0;
    if (nread != (base + count - 1) / 4 - base / 4 + 1) $fatal;
    finish_cmd(seqnum);
  endtask
  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1;
    store16(464, 1);
    store16(480, 2);
    store16(496, 3);
    load_regs(1, 0, 480, 4);
    for (int offset = 0; offset < 4; offset++) begin
      load_regs(0, 0, 468 + offset, 5 + offset);
      load_regs(1, 1, 468 + offset, 9 + offset);
    end
    allow_fault = 1;
    issue(0, 1, 65535, 15);
    @(negedge clk);
    if (!fault_o || pin_req_valid || (|rd_req_valid)) $fatal(1, "range precheck");
    rst_n = 0;
    @(negedge clk);
    rst_n = 1;
    inject_final_error = 1;
    issue(1, 0, 0, 20);
    for (int j = 0; j < 16; j++) begin
      rf_store_valid = 1;
      rf_store_payload = '{id: issue_payload.cmd.id, index: 7'(j), last: j == 15, data: '1};
      do @(posedge clk); while (!rf_store_ready);
      @(negedge clk);
    end
    rf_store_valid = 0;
    repeat (6) begin
      @(negedge clk);
      if (unpin_valid || done_valid || track_done_valid)
        $fatal(1, "failed ACK settled the dependency");
    end
    if (!fault_o || drained_o) $fatal;
    $display(
        "PASS TMEM RF masked writes, ACK and RF edges, unaligned handoff, range and late MEMORY");
    $finish;
  end
  initial begin
    repeat (4000) @(posedge clk);
    $fatal(1, "timeout");
  end
endmodule
