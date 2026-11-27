module mma_engine_tb;
  import blackwell_async_pkg::*;
  import blackwell_tmem_pkg::*;
  import blackwell_tc_pkg::*;
  bit clk;
  always #5 clk = ~clk;
  logic rst_n, halt_i, stop_i, idle_o, drained_o, fault_o;
  logic [15:0] epoch_i = 1;
  logic
      cmd_valid,
      cmd_ready,
      done_valid,
      done_ready,
      pin_req_valid,
      pin_req_ready,
      pin_rsp_valid,
      pin_rsp_ready;
  logic
      unpin_valid,
      unpin_ready,
      start_valid,
      start_ready,
      release_valid,
      release_ready,
      load_valid,
      load_ready;
  logic result_valid, result_ready, first_valid, launch;
  mma_cmd_t cmd_payload;
  op_done_t done_payload, pin_rsp_payload, result_payload, local_done_payload[4];
  tmem_pin_req_t pin_req_payload, unpin_payload;
  logic [3:0]
      prepare_valid,
      prepare_ready,
      b_select_valid,
      b_select_ready,
      local_done_valid,
      local_done_ready,
      first_ready;
  prepare_t prepare_payload[4], start_payload;
  b_select_t b_select_payload[4];
  async_id_t first_id, release_payload;
  logic [3:0][2:0] input_free, writes_done;
  logic [2:0] snapshot_ready, quiescent;
  logic [2:0][3:0] older_writes_clear;
  mma_live_t [2:0] live_o;
  b_load_t load_payload;
  // Drive the scheduler independently to stagger per-core completion and selection.
  blackwell_tc_mma_control dut (.*);

  localparam int CASES = 21;
  int loads[CASES], reports[CASES], launch_tick[CASES], selections[CASES], grants[CASES];
  bit [3:0] local_sent[CASES];
  bit release_first;
  int cycles;
  bit [1:0] spec_size[CASES], spec_name[CASES], spec_op[CASES];
  bit [1:0] expected_base[CASES];
  bit expected_hit[CASES];
  int descriptor_offset[CASES];

  always @(posedge clk) begin
    if (rst_n) begin
      cycles++;
      pin_rsp_valid <= pin_req_valid && pin_req_ready;
      pin_rsp_payload <= {pin_req_payload.id, OK};
      result_valid <= 0;
      if (load_valid && load_ready) loads[load_payload.id.seq]++;
      for (int r = 0; r < 3; r++)
      if (live_o[r].valid) begin
        int i;
        i = int'(live_o[r].id.seq);
        if (loads[i] > 0 && selections[i] == 4 && grants[i] == 0 && !result_valid) begin
          // Each mock install settles once. Latch a single response per cycle.
          result_payload <= {live_o[r].id, OK};
          result_valid <= 1;
          grants[i]++;
          break;
        end
      end
      if (launch) begin
        int i;
        i = int'(first_id.seq);
        if (launch_tick[i] != 0 || (i != 0 && launch_tick[i-1] == 0))
          $fatal(1, "launch order %d", i);
        launch_tick[i] = cycles;
      end
      for (int c = 0; c < 4; c++) begin
        if (b_select_valid[c] && b_select_ready[c]) begin
          int i;
          i = int'(b_select_payload[c].id.seq);
          selections[i]++;
          if (b_select_payload[c].reuse !== expected_hit[i] ||
              b_select_payload[c].base_part !== expected_base[i])
            $fatal(
                1,
                "select ID %d got hit/base %b/%d want %b/%d",
                i,
                b_select_payload[c].reuse,
                b_select_payload[c].base_part,
                expected_hit[i],
                expected_base[i]
            );
        end
        if (local_done_valid[c] && local_done_ready[c])
          local_sent[local_done_payload[c].id.seq][c] = 1;
      end
      if (done_valid && done_ready) begin
        int i;
        i = int'(done_payload.id.seq);
        reports[i]++;
        if (reports[i] != 1 || done_payload.status != OK) $fatal(1, "duplicate/error done");
      end
      if (fault_o) $fatal(1, "unexpected fault at cycle %0d", cycles);
      if (cycles > 2500) $fatal(1, "scheduler timeout");
    end
  end

  always @(negedge clk) begin
    if (rst_n) begin
      prepare_ready = 4'b1111;
      b_select_ready = (cycles % 7 == 0) ? 4'b0110 : 4'b1111;
      done_ready = cycles % 4 != 0;
      unpin_ready = cycles % 5 != 0;
      first_ready = '1;
      local_done_valid = 0;
      input_free = 0;
      writes_done = 0;
      for (int c = 0; c < 4; c++) begin
        local_done_payload[c] = '0;
        for (int age = 0; age < 3; age++) begin
          if (live_o[age].valid) begin
            int i, r;
            i = int'(live_o[age].id.seq);
            r = int'(live_o[age].rec);
            input_free[c][r] = launch_tick[i] != 0 && cycles >= launch_tick[i] + 2;
            writes_done[c][r] = launch_tick[i] != 0 && cycles >= launch_tick[i] + 4 &&
                (i != 0 || release_first);
            if (writes_done[c][r] && !local_sent[i][c] && !local_done_valid[c]) begin
              local_done_valid[c] = 1;
              local_done_payload[c] = {live_o[age].id, OK};
            end
          end
        end
      end
    end
  end
  task automatic send_cmd(int i);
    @(negedge clk);
    cmd_payload = '0;
    cmd_payload.id.epoch = epoch_i;
    cmd_payload.id.seq = 32'(i);
    cmd_payload.b_desc = (64'd1 << 46) | (64'd16 << 32) | (64'd8 << 16) | 64'(descriptor_offset[i]);
    cmd_payload.a_ref = (64'd1 << 46) | (64'd16 << 32) | (64'd8 << 16);
    cmd_payload.ws = 1;
    cmd_payload.collector_buffer = spec_name[i];
    cmd_payload.collector_op = spec_op[i];
    cmd_payload.n_code = spec_size[i];
    cmd_valid = 1;
    do @(posedge clk); while (!cmd_ready);
    @(negedge clk);
    cmd_valid = 0;
  endtask
  task automatic config_case(int i, name, op, size, base_idx, hit, desc);
    spec_name[i] = 2'(name);
    spec_op[i] = 2'(op);
    spec_size[i] = 2'(size);
    expected_base[i] = 2'(base_idx);
    expected_hit[i] = 1'(hit);
    descriptor_offset[i] = desc;
  endtask
  // Check that the endpoint range proof agrees with exhaustive legal
  // coordinate expansion, including strides smaller than a stripe.
  task automatic check_descriptor_boundary;
    mma_cmd_t c;
    b_load_t src;
    int modes[5];
    int widths[5];
    int k_extent[5];
    int checked;
    modes = '{0, 1, 2, 4, 6};
    widths = '{0, 2, 3, 6, 7};
    k_extent = '{16, 8, 32, 32, 32};
    checked = 0;
    for (int f = 0; f < 5; f++)
      for (int mi = 0; mi < 5; mi++)
        for (int tr = 0; tr < 2; tr++)
          for (int sz = 0; sz < 3; sz++)
            for (int offset = 0; offset < 3; offset++) begin
              logic expected;
              int   mode;
              mode = modes[mi];
              if (tr != 0 && (f >= 3 || ((f == 1) != (mode == 1)))) continue;
              c = '0;
              c.kind = f == 0 ? 0 : (f == 1 ? 1 : 2);
              c.b_type = 4'(widths[f]);
              c.transpose_b = 1'(tr);
              c.n_code = 2'(sz);
              c.b_desc[63:61] = 3'(mode);
              c.b_desc[48:46] = 1;
              c.b_desc[51:49] = mode == 0 ? 0 : 1;
              c.b_desc[13:0] = 14'((233472 - 16 * (1 + offset * 70)) / 16);
              c.b_desc[29:16] = 14'(offset);
              c.b_desc[45:32] = 14'(2 - offset);
              src = {c.id, c.b_desc, c.b_type, c.kind, c.transpose_b, c.n_code};
              expected = 1;
              for (int row = 0; row < (64 << sz); row++)
              for (int k = 0; k < k_extent[f]; k++) begin
                if (source_bit(
                        src, row, k, 0
                    ) >= (64'd233472 << 3) || source_bit(
                        src, row, k, element_bits(src.dtype) - 1
                    ) >= (64'd233472 << 3))
                  expected = 0;
              end
              if (dut.desc_ok(c, 1) != expected)
                $fatal(1, "descriptor range mismatch dtype %d mode %d", f, mode);
              checked++;
            end
    $display("PASS %0d descriptor boundary comparisons", checked);
  endtask
  initial begin
    check_descriptor_boundary();
    config_case(0, 0, 1, 0, 0, 0, 0);
    config_case(1, 0, 2, 0, 0, 1, 0);
    config_case(2, 0, 3, 0, 0, 1, 0);
    config_case(3, 0, 1, 0, 0, 0, 0);
    config_case(4, 1, 1, 0, 1, 0, 1);
    config_case(5, 2, 1, 0, 2, 0, 2);
    config_case(6, 3, 1, 0, 3, 0, 3);
    config_case(7, 0, 2, 0, 0, 1, 0);
    config_case(8, 2, 2, 0, 2, 1, 2);
    // Replace name 0 (part 0) with N128. LRU name 1 frees adjacent part 1.
    config_case(9, 0, 1, 1, 0, 0, 10);
    config_case(10, 0, 2, 1, 0, 1, 10);
    config_case(11, 3, 1, 1, 2, 0, 14);
    config_case(12, 1, 1, 2, 0, 0, 15);
    config_case(13, 1, 3, 2, 0, 1, 15);
    config_case(14, 1, 2, 2, 0, 0, 15);
    config_case(15, 2, 1, 0, 0, 0, 20);
    config_case(16, 1, 1, 0, 1, 0, 21);
    config_case(17, 0, 1, 0, 2, 0, 22);
    config_case(18, 3, 1, 0, 3, 0, 23);
    // A younger prospective hit on the newest N64 version must wait for
    // the older N256 miss to evict all four, then reload under its own ID.
    config_case(19, 2, 1, 2, 0, 0, 24);
    config_case(20, 3, 2, 0, 0, 0, 23);
    rst_n = 0;
    halt_i = 0;
    stop_i = 0;
    cmd_valid = 0;
    done_ready = 0;
    pin_req_ready = 1;
    pin_rsp_valid = 0;
    unpin_ready = 1;
    start_ready = 1;
    release_ready = 1;
    load_ready = 1;
    result_valid = 0;
    local_done_valid = 0;
    prepare_ready = 0;
    b_select_ready = 0;
    first_ready = 0;
    input_free = 0;
    writes_done = 0;
    quiescent = 0;
    snapshot_ready = 0;
    repeat (2) @(negedge clk);
    rst_n = 1;
    for (int i = 0; i < 3; i++) send_cmd(i);
    wait (reports[1] != 0 && reports[2] != 0);
    @(negedge clk);
    if (reports[0] != 0 || cmd_ready || dut.count_q != 3)
      $fatal(1, "head failed to retain younger slots");
    release_first = 1;
    wait (drained_o);
    for (int i = 3; i < CASES; i++) begin
      send_cmd(i);
      if (i != 19) wait (reports[i] != 0);
    end
    @(negedge clk);
    for (int i = 0; i < CASES; i++)
    if (loads[i] != int'(!expected_hit[i]) || reports[i] != 1)
      $fatal(1, "incorrect fetch/notification count for %0d", i);
    $display("PASS %0d scheduler commands, read ownership, LRU, independent completion", CASES);
    $finish;
  end
endmodule
