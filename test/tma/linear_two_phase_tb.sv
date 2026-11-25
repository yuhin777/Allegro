module linear_two_phase_tb;
  import blackwell_async_pkg::*;
  import blackwell_smem_pkg::*;
  import blackwell_mbarrier_pkg::*;
  import blackwell_tma_pkg::*;
  logic clk, rst_n, stop;
  logic [15:0] epoch;
  mma_live_t live[3];
  logic drained, fault;
  logic tma_cmd_valid, tma_rsp_ready, bar_cmd_valid, bar_rsp_ready, tc_req_valid, tc_rsp_ready;
  logic tma_cmd_ready, tma_rsp_valid, bar_cmd_ready, bar_rsp_valid, tc_req_ready, tc_rsp_valid;
  tma_cmd_t tma_cmd_payload;
  bar_cmd_t bar_cmd_payload;
  tc_bar_req_t tc_req_payload;
  tma_rsp_t tma_rsp_payload;
  bar_rsp_t bar_rsp_payload;
  op_done_t tc_rsp_payload;
  logic gmem_req_ready, gmem_rsp_valid;
  logic gmem_req_valid, gmem_rsp_ready;
  gmem_req_t gmem_req_payload;
  gmem_rsp_t gmem_rsp_payload;
  logic [2:0] order_req_ready, order_rsp_valid;
  logic [2:0] order_req_valid, order_rsp_ready;
  order_req_t order_req_payload[3];
  order_rsp_t order_rsp_payload[3];
  logic [31:0] commit_candidate_addr;
  logic commit_blocked;
  logic [31:0] commit_busy_addr;
  logic commit_addr_busy;
  logic flush_req_valid, flush_rsp_ready;
  logic flush_req_ready, flush_rsp_valid;
  status_t flush_rsp_payload;
  logic [4:0][7:0] tc_smem_req_valid, tc_smem_rsp_ready;
  logic [4:0][7:0] tc_smem_req_ready, tc_smem_rsp_valid;
  smem_rd_req_t tc_smem_req_payload[5][8];
  smem_rd_rsp_t tc_smem_rsp_payload[5][8];
  logic [7:0] smem_rd_valid, smem_wr_valid, smem_rd_rsp_ready, smem_wr_ack_ready;
  logic [7:0] smem_rd_ready, smem_wr_ready, smem_rd_rsp_valid, smem_wr_ack_valid;
  smem_rd_req_t smem_rd_payload[8];
  smem_wr_req_t smem_wr_payload[8];
  smem_rd_rsp_t smem_rd_rsp_payload[8];
  smem_wr_ack_t smem_wr_ack_payload[8];
  logic [31:0] read_line_number;
  for (genvar g = 0; g < 8; g++)
    assign smem_rd_payload[g] = '{
            tag: '{
                id: '{epoch: 16'd1, issuer: 10'd0, seq: 32'd500},
                client: 4'd12,
                token: 16'(8 * read_line_number + g)
            },
            addr: 32'(read_line_number * 128 + 16 * g),
            byte_mask: '1
        };
  blackwell_smem_subsystem dut (.*);
  initial clk = 0;
  always #1 clk = !clk;
  int cycle, sequence_number, done_count, arrivals, flips, reads_issued, acks;
  logic [7:0] phase_results;
  logic halt_i = 0;
  function automatic async_id_t new_id(input int n);
    return '{epoch: 16'd1, issuer: '0, seq: 32'(n)};
  endfunction
  assign gmem_req_ready = !gmem_rsp_valid || gmem_rsp_ready;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      gmem_rsp_valid <= 0;
      cycle <= 0;
      reads_issued <= 0;
    end else begin
      cycle <= cycle + 1;
      if (gmem_rsp_valid && gmem_rsp_ready) gmem_rsp_valid <= 0;
      if (gmem_req_valid && gmem_req_ready) begin
        if (gmem_req_payload.id.cls != 0 || gmem_req_payload.op != 0 ||
            gmem_req_payload.byte_mask != '1)
          $fatal(1, "Unexpected GMEM request");
        gmem_rsp_valid <= 1;
        gmem_rsp_payload.id <= gmem_req_payload.id;
        gmem_rsp_payload.status <= OK;
        for (int w = 0; w < 32; w++)
        gmem_rsp_payload.data[w*32+:32] <= 32'(gmem_req_payload.addr >> 2) + 32'(w) + 1;
        reads_issued <= reads_issued + 1;
      end
    end
  end
  for (genvar s = 0; s < 3; s++) begin
    assign order_req_ready[s] = !order_rsp_valid[s] || order_rsp_ready[s];
    always_ff @(posedge clk) begin
      if (!rst_n) order_rsp_valid[s] <= 0;
      else begin
        if (order_rsp_valid[s] && order_rsp_ready[s]) order_rsp_valid[s] <= 0;
        if (order_req_valid[s] && order_req_ready[s]) begin
          // In this single-clock model GMEM read samples initialized data.
          // LSU observations issue only after acquire; writes commit in the SRAM macro.
          order_rsp_valid[s] <= 1;
          order_rsp_payload[s] <= '{id: order_req_payload[s].id, status: OK};
          if (s == 2 && flips <= arrivals) $fatal(1, "acquire before phase flip");
        end
      end
    end
  end
  for (genvar g = 0; g < 8; g++) begin
    always @(posedge clk)
      if (rst_n) begin
        if (dut.fabric.groups[g].capture && dut.fabric.groups[g].rd_bad)
          $fatal(
              1,
              "invalid read g=%0d client=%0d addr=%h tag=%h",
              g,
              dut.fabric.groups[g].reader,
              dut.fabric.rd_req_payload[dut.fabric.groups[g].reader][g].addr,
              dut.fabric.groups[g].new_dest.tag
          );
        if (dut.fabric.groups[g].write_fire && dut.fabric.groups[g].wr_bad)
          $fatal(
              1,
              "invalid write g=%0d client=%0d addr=%h tag=%h",
              g,
              dut.fabric.groups[g].writer,
              dut.fabric.wr_req_payload[dut.fabric.groups[g].writer][g].addr,
              dut.fabric.wr_req_payload[dut.fabric.groups[g].writer][g].tag
          );
      end
  end
  logic last_phase;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      done_count <= 0;
      flips <= 0;
      arrivals <= 0;
      acks <= 0;
      last_phase <= 0;
    end else begin
      if (fault)
        $fatal(
            1,
            "fault at %0d local=%b tma=%b%b%b%b%b%b",
            cycle,
            dut.local_fault,
            dut.tma.unit_fault,
            dut.tma.setup_fault,
            dut.tma.walk_fault,
            dut.tma.track_fault,
            dut.tma.data_fault,
            dut.tma.cache_fault
        );
      if (tma_rsp_valid && tma_rsp_ready) begin
        if (tma_rsp_payload.done.status != OK) $fatal(1, "TMA rejected command");
        if (tma_rsp_payload.logical_bytes == 4096) done_count <= done_count + 1;
        else if (tma_rsp_payload.logical_bytes != 0) $fatal(1, "wrong byte count");
      end
      if (dut.change_valid && dut.change_payload.initialized &&
          dut.change_payload.phase != last_phase) begin
        if (acks < (flips + 1) * 1024) $fatal(1, "phase changed before final write ACK");
        flips <= flips + 1;
        last_phase <= dut.change_payload.phase;
      end
      if (bar_rsp_valid && bar_rsp_ready && bar_rsp_payload.completed) arrivals <= arrivals + 1;
      acks <= acks + $countones(dut.wr_ack_valid[8] & dut.wr_ack_ready[8]);
      if (cycle > 18000)
        $fatal(
            1,
            "timeout cmd=%d copies=%d barrier=%d reads=%d ACK=%d",
            sequence_number,
            done_count,
            flips,
            reads_issued,
            acks
        );
    end
  end
  task automatic barrier_cmd(input bar_op_t operation, input int phase_no, output bit predicate);
    async_id_t id;
    @(negedge clk);
    sequence_number++;
    id = new_id(sequence_number);
    bar_cmd_payload = '0;
    bar_cmd_payload.id = id;
    bar_cmd_payload.addr = 16384;
    bar_cmd_payload.op = operation;
    if (operation == BAR_INIT) bar_cmd_payload.count = 1;
    if (operation == BAR_EXPECT) bar_cmd_payload.bytes = 16384;
    if (operation == BAR_TRY) bar_cmd_payload.parity = 1'(phase_no);
    bar_cmd_valid = 1;
    do @(posedge clk); while (!bar_cmd_ready);
    @(negedge clk);
    bar_cmd_valid = 0;
    do @(posedge clk); while (!bar_rsp_valid);
    if (bar_rsp_payload.status != OK || bar_rsp_payload.id != id)
      $fatal(1, "barrier response mismatch");
    predicate = bar_rsp_payload.completed;
  endtask
  task automatic issue_tma(input tma_opcode_t operation, input int phase_no, copy);
    @(negedge clk);
    sequence_number++;
    tma_cmd_payload = '0;
    tma_cmd_payload.id = new_id(sequence_number);
    tma_cmd_payload.opcode = operation;
    if (operation == LOAD_LINEAR) begin
      tma_cmd_payload.global_addr = 64'(phase_no * 16384 + copy * 4096);
      tma_cmd_payload.smem_addr = copy * 4096;
      tma_cmd_payload.bytes = 4096;
      tma_cmd_payload.barrier_addr = 16384;
    end
    tma_cmd_valid = 1;
    do @(posedge clk); while (!tma_cmd_ready);
    @(negedge clk);
    tma_cmd_valid = 0;
  endtask
  task automatic checksum(input int phase_no);
    logic [63:0] sum, expected_sum;
    sum = 0;
    expected_sum = 0;
    for (int line_no = 0; line_no < 128; line_no++) begin
      @(negedge clk);
      read_line_number = 32'(line_no);
      smem_rd_valid = '1;
      do @(posedge clk); while (smem_rd_ready != '1);
      @(negedge clk);
      smem_rd_valid = 0;
      do @(posedge clk); while (smem_rd_rsp_valid != '1);
      for (int g = 0; g < 8; g++) begin
        if (smem_rd_rsp_payload[g].tag.token != 16'(8 * line_no + g))
          $fatal(1, "LSU return identity");
        for (int w = 0; w < 4; w++) begin
          logic [31:0] expected;
          expected = 32'(phase_no * 4096 + line_no * 32 + g * 4 + w + 1);
          if (smem_rd_rsp_payload[g].data[32*w+:32] != expected)
            $fatal(1, "wrong word phase=%d line=%d group=%d", phase_no, line_no, g);
          sum += 64'(smem_rd_rsp_payload[g].data[32*w+:32]);
          expected_sum += 64'(expected);
        end
      end
    end
    if (sum != expected_sum) $fatal(1, "wrong checksum");
    $display("phase=%0d checksum=%0d", phase_no, sum);
  endtask
  initial begin
    bit predicate;
    rst_n = 0;
    epoch = 0;
    stop = 0;
    commit_addr_busy = 0;
    tma_rsp_ready = 1;
    bar_rsp_ready = 1;
    tc_rsp_ready = 1;
    flush_rsp_ready = 1;
    smem_rd_rsp_ready = '1;
    repeat (3) @(negedge clk);
    rst_n = 1;
    epoch = 1;
    barrier_cmd(BAR_INIT, 0, predicate);
    issue_tma(PROXY_FENCE, 0, 0);
    do @(posedge clk); while (!tma_rsp_valid);
    for (int p = 0; p < 2; p++) begin
      barrier_cmd(BAR_EXPECT, p, predicate);
      for (int c = 0; c < 4; c++) issue_tma(LOAD_LINEAR, p, c);
      do barrier_cmd(BAR_TRY, p, predicate); while (!predicate);
      checksum(p);
    end
    barrier_cmd(BAR_INVAL, 0, predicate);
    wait (drained);
    @(negedge clk);
    if (flips != 2 || done_count != 8 || reads_issued != 256 || acks != 2048)
      $fatal(1, "missing transaction");
    $display("PASS linear_bulk_two_phase cycles=%0d reads=%0d ACKs=%0d", cycle, reads_issued, acks);
    $finish;
  end
endmodule
