module tmem_subsystem_tb;
  import blackwell_async_pkg::*;
  import blackwell_tmem_pkg::*;
  logic clk = 0, rst_n = 0, halt_i = 0, stop_i = 0;
  always #5 clk = !clk;
  logic [15:0] epoch_i;
  logic [2:0][60:0] live_i;
  logic epoch_end_valid, epoch_end_ready, tmem_alloc_credit, drained_o, empty_o, fault_o;
  logic tmem_manage_valid, tmem_manage_ready, tmem_manage_rsp_valid, tmem_manage_rsp_ready = 1;
  tmem_manage_cmd_t tmem_manage_payload;
  tmem_manage_rsp_t tmem_manage_rsp_payload;
  logic tmem_ldst_valid, tmem_ldst_ready, tmem_ldst_done_valid, tmem_ldst_done_ready;
  tmem_ldst_cmd_t tmem_ldst_payload;
  op_done_t tmem_ldst_done_payload;
  logic rf_store_valid, rf_store_ready, rf_load_valid, rf_load_ready = 1;
  rf_beat_t rf_store_payload, rf_load_payload;
  logic tmem_wait_valid, tmem_wait_ready, tmem_wait_done_valid, tmem_wait_done_ready;
  tmem_wait_cmd_t tmem_wait_payload;
  op_done_t tmem_wait_done_payload;
  logic
      mma_pin_req_valid,
      mma_pin_req_ready,
      mma_pin_rsp_valid,
      mma_pin_rsp_ready,
      mma_unpin_valid,
      mma_unpin_ready;
  tmem_pin_req_t mma_pin_req_payload, mma_unpin_payload;
  tmem_pin_rsp_t mma_pin_rsp_payload;
  logic [4:0][127:0] tc_rd_req_valid, tc_rd_req_ready, tc_rd_rsp_valid, tc_rd_rsp_ready;
  logic [4:0][127:0] tc_wr_req_valid, tc_wr_req_ready, tc_wr_ack_valid, tc_wr_ack_ready;
  tmem_rd_req_t tc_rd_req_payload[5][128];
  tmem_rd_rsp_t tc_rd_rsp_payload[5][128];
  tmem_wr_req_t tc_wr_req_payload[5][128];
  tmem_wr_ack_t tc_wr_ack_payload[5][128];
  blackwell_tmem_subsystem dut (.*);
  function automatic async_id_t id(input int seqnum);
    return '{epoch: epoch_i, issuer: 10'd0, seq: 32'(seqnum)};
  endfunction
  // Register the consumer's backpressure controls, as an external sink would.
  // This also gives timing simulators an explicit clock-domain boundary.
  logic [4:0][127:0] next_read_ready, next_ack_ready;
  always_ff @(posedge clk) begin
    tc_rd_rsp_ready <= next_read_ready;
    tc_wr_ack_ready <= next_ack_ready;
  end
  int seqnum;
  for (genvar c = 0; c < 5; c++) begin
    for (genvar b = 0; b < 128; b++) begin
      assign tc_rd_req_payload[c][b] = '{
              tag: '{
                  id: id(10 + c),
                  client: 4'(c),
                  token: {(c == 0 ? 3'd2 : 3'd1), 6'(seqnum), 7'(b)}
              },
              lane: 7'(b),
              word: 7'd0,
              byte_mask: '1
          };
      assign tc_wr_req_payload[c][b] = '{
              tag: '{id: id(10 + c), client: 4'(c), token: {9'(seqnum), 7'(b)}},
              lane: 7'(b),
              word: 7'd0,
              byte_mask: '1,
              data: 128'h12345678 + 128'(b)
          };
    end
  end
  initial begin
    repeat (2) @(negedge clk);
    rst_n = 1;
    epoch_i = 5;
    @(negedge clk);
    tmem_manage_valid = 1;
    tmem_manage_payload = '{id: id(1), op: 2'd0, base: 0, columns: 10'd512};
    do @(posedge clk); while (!tmem_manage_ready);
    @(negedge clk);
    tmem_manage_valid = 0;
    if (!tmem_manage_rsp_valid || tmem_manage_rsp_payload.status != OK) $fatal;
    mma_pin_req_valid = 1;
    mma_pin_req_payload = '{id: id(10), user: 0};
    do @(posedge clk); while (!mma_pin_req_ready);
    @(negedge clk);
    mma_pin_req_valid = 0;
    // The RF issue and its cutoff snapshot can progress behind the held MMA pin response.
    tmem_ldst_valid = 1;
    tmem_ldst_payload = '{id: id(2), store: 1, x32: 0, base: 32'd8};
    do @(posedge clk); while (!tmem_ldst_ready);
    @(negedge clk);
    tmem_ldst_valid = 0;
    tmem_wait_valid = 1;
    tmem_wait_payload.id = id(3);
    @(negedge clk);
    tmem_wait_valid = 0;
    repeat (4) @(negedge clk);
    if (!mma_pin_rsp_valid || mma_pin_rsp_payload.id != id(10) || rf_store_ready) $fatal;
    // While this manager result stalls, the independent unpin can be granted.
    mma_unpin_valid = 1;
    mma_unpin_payload = mma_pin_req_payload;
    do @(posedge clk); while (!mma_unpin_ready);
    @(negedge clk);
    mma_unpin_valid = 0;
    mma_pin_rsp_ready = 1;
    for (int j = 0; j < 16; j++) begin
      rf_store_valid = 1;
      rf_store_payload = '{id: id(2), index: 7'(j), last: j == 15, data: {32{32'h515100 + j}}};
      do @(posedge clk); while (!rf_store_ready);
      @(negedge clk);
    end
    rf_store_valid = 0;
    while (!tmem_ldst_done_valid) @(negedge clk);
    repeat (3) begin
      if (tmem_wait_done_valid) $fatal;
      @(negedge clk);
    end
    tmem_ldst_done_ready = 1;
    while (!tmem_wait_done_valid) @(negedge clk);
    if (tmem_wait_done_payload.id != id(3)) $fatal;
    tmem_wait_done_ready = 1;
    // A frame may combine clients at separate banks. The next frame reuses
    // bank zero and its ACK must remain behind its previous write.
    seqnum = 0;
    tc_wr_req_valid[0][0] = 1;
    tc_wr_req_valid[1][1] = 1;
    @(posedge clk);
    if (!tc_wr_req_ready[0][0] || !tc_wr_req_ready[1][1]) $fatal;
    @(negedge clk);
    tc_wr_req_valid = '0;
    seqnum = 1;
    tc_wr_req_valid[0][0] = 1;
    tc_rd_req_valid[0][0] = 1;
    tc_rd_req_valid[1][0] = 1;
    @(posedge clk);
    if (!tc_wr_req_ready[0][0] || tc_rd_req_ready[0][0] || tc_rd_req_ready[1][0]) $fatal;
    @(negedge clk);
    tc_wr_req_valid = '0;
    if (!tc_wr_ack_valid[0][0] || !tc_wr_ack_valid[1][1]) $fatal;
    next_ack_ready[1][1] = 1;
    @(posedge clk);
    if (!tc_rd_req_ready[0][0] || tc_rd_req_ready[1][0]) $fatal;
    @(negedge clk);
    tc_rd_req_valid[0][0] = 0;
    @(posedge clk);
    if (!tc_rd_req_ready[1][0]) $fatal;
    @(negedge clk);
    tc_rd_req_valid = '0;
    repeat (2) @(negedge clk);
    if (!tc_rd_rsp_valid[0][0] || tc_rd_rsp_valid[1][0] ||
        tc_rd_rsp_payload[0][0].data != 128'h12345678 || tc_wr_ack_valid[1][1])
      $fatal;
    if (tc_wr_ack_payload[0][0].tag.token != 0) $fatal;
    next_ack_ready[0][0] = 1;
    next_read_ready[0][0] = 1;
    @(negedge clk);
    @(negedge clk);
    if (!tc_rd_rsp_valid[1][0] || !tc_wr_ack_valid[0][0] ||
        tc_wr_ack_payload[0][0].tag.token != 128)
      $fatal(
          1,
          "second returns rd=%b ack=%b token=%h fault=%b",
          tc_rd_rsp_valid[1][0],
          tc_wr_ack_valid[0][0],
          tc_wr_ack_payload[0][0].tag.token,
          fault_o
      );
    next_read_ready[1][0] = 1;
    @(negedge clk);
    @(negedge clk);
    if (!drained_o || fault_o) $fatal;
    stop_i = 1;
    epoch_end_valid = 1;
    @(posedge clk);
    if (!epoch_end_ready) $fatal;
    @(negedge clk);
    if (!empty_o) $fatal;
    $display(
        "PASS TMEM routing, nonblocking unpin, wait cutoff, partial ACK retirement, C priority and same-word conflict");
    $finish;
  end
  initial begin
    repeat (2000) @(posedge clk);
    $fatal(1, "timeout");
  end
endmodule
