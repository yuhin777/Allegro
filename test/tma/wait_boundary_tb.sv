module wait_boundary_tb;
  import blackwell_async_pkg::*;
  import blackwell_mbarrier_pkg::*;
  logic clk = 0, rst_n = 0, stop = 0;
  logic [15:0] epoch = 1;
  logic
      wait_cmd_valid,
      wait_cmd_ready,
      wait_rsp_valid,
      wait_rsp_ready,
      probe_req_valid,
      probe_req_ready,
      probe_rsp_valid,
      probe_rsp_ready,
      acquire_req_valid,
      acquire_req_ready,
      acquire_rsp_valid,
      acquire_rsp_ready;
  bar_cmd_t wait_cmd_payload;
  bar_rsp_t wait_rsp_payload;
  bar_service_req_t probe_req_payload;
  bar_service_rsp_t probe_rsp_payload;
  order_req_t acquire_req_payload;
  op_done_t acquire_rsp_payload;
  logic change_valid, addr_busy, drained;
  bar_change_t change_payload;
  logic [31:0] busy_addr = 128;
  blackwell_mbarrier_wait dut (
    .ingress_id('0),
    .ingress_id_busy(),
    .*
  );
  always #1 clk = !clk;
  task automatic check(input int seq_no, hint, flip_at);
    async_id_t id;
    id = '{epoch: epoch, issuer: 10'd9, seq: 32'(seq_no)};
    @(negedge clk);
    wait_cmd_payload = '0;
    wait_cmd_payload.id = id;
    wait_cmd_payload.op = BAR_TRY;
    wait_cmd_payload.addr = 128;
    wait_cmd_payload.time_hint = 32'(hint);
    wait_cmd_valid = 1;
    @(posedge clk);
    if (!wait_cmd_ready) $fatal(1, "unavailable wait entry");
    @(negedge clk);
    wait_cmd_valid = 0;
    probe_req_ready = 1;
    @(posedge clk);
    if (!probe_req_valid) $fatal(1, "probe missing");
    probe_rsp_payload = '{
        route: 2'd1,
        slot: probe_req_payload.slot,
        rsp: '{id: id, completed: 0},
        phase: 0,
        initialized: 1
    };
    @(negedge clk);
    probe_req_ready = 0;
    probe_rsp_valid = 1;
    @(posedge clk);
    if (!probe_rsp_ready) $fatal(1, "probe return stalled");
    @(negedge clk);
    probe_rsp_valid = 0;
    for (int i = 1; i <= flip_at; i++) begin
      change_valid = i == flip_at;
      change_payload = '{addr: 32'd128, phase: 1, initialized: 1};
      @(posedge clk);
      if (i <= 64 && (wait_rsp_valid || acquire_req_valid)) $fatal(1, "resolved before deadline");
      @(negedge clk);
    end
    change_valid = 0;
    if (flip_at == 64) begin
      repeat (3) begin
        @(posedge clk);
        if (!acquire_req_valid || acquire_req_payload.id != id || wait_rsp_valid)
          $fatal(1, "acquire stability");
        @(negedge clk);
      end
      acquire_req_ready = 1;
      @(negedge clk);
      acquire_req_ready = 0;
      acquire_rsp_payload = '{id: id};
      acquire_rsp_valid = 1;
      @(negedge clk);
      acquire_rsp_valid = 0;
    end
    repeat (2) begin
      @(posedge clk);
      if (!wait_rsp_valid || wait_rsp_payload.id != id || wait_rsp_payload.completed !=
          (flip_at == 64) || !addr_busy)
        $fatal(1, "wrong parity at boundary");
      @(negedge clk);
    end
    wait_rsp_ready = 1;
    @(negedge clk);
    wait_rsp_ready = 0;
    if (!drained || addr_busy) $fatal(1, "wait slot retained");
  endtask
  // An already queued wait must allocate during drain. A phase match before
  // dispatch may complete its acquire, but the initial QUERY still owns a return.
  task automatic early_match_during_drain;
    async_id_t key;
    bar_service_req_t held;
    key = '{epoch: epoch, issuer: 10'd9, seq: 32'd4};
    @(negedge clk);
    stop = 1;
    wait_cmd_payload = '0;
    wait_cmd_payload.op = BAR_TRY;
    wait_cmd_payload.id = key;
    wait_cmd_payload.addr = busy_addr;
    wait_cmd_valid = 1;
    @(posedge clk);
    if (!wait_cmd_ready) $fatal(1, "queued wait blocked during drain");
    @(negedge clk);
    wait_cmd_valid = 0;
    held = probe_req_payload;
    change_valid = 1;
    change_payload = '{addr: busy_addr, phase: 1, initialized: 1};
    @(posedge clk);
    if (!probe_req_valid || held.route != 1 || held.cmd.op != BAR_QUERY || held.cmd.id != key)
      $fatal(1, "missing initial QUERY");
    @(negedge clk);
    change_valid = 0;
    acquire_req_ready = 1;
    @(posedge clk);
    if (!acquire_req_valid || acquire_req_payload.id != key) $fatal;
    @(negedge clk);
    acquire_req_ready = 0;
    acquire_rsp_valid = 1;
    acquire_rsp_payload.id = key;
    @(negedge clk);
    acquire_rsp_valid = 0;
    repeat (3) begin
      @(posedge clk);
      if (!probe_req_valid || probe_req_payload != held || wait_rsp_valid) $fatal;
      @(negedge clk);
    end
    probe_req_ready = 1;
    @(negedge clk);
    probe_req_ready = 0;
    if (probe_req_valid || wait_rsp_valid) $fatal;
    probe_rsp_valid = 1;
    probe_rsp_payload = '{route: held.route, slot: held.slot, rsp: '{id: key, completed: 0},
                          phase: 0, initialized: 1};
    @(negedge clk);
    probe_rsp_valid = 0;
    wait_rsp_ready = 1;
    @(posedge clk);
    if (!wait_rsp_valid || wait_rsp_payload.id != key || !wait_rsp_payload.completed) $fatal;
    @(negedge clk);
    wait_rsp_ready = 0;
    if (!drained || addr_busy) $fatal;
  endtask
  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1;
    check(0, 0, 64);
    check(1, 0, 65);
    check(2, 641, 64);
    check(3, 641, 65);
    early_match_during_drain();
    $display("PASS early match with stalled drain QUERY, ARMED deadline and following edge for hints 0 and 641");
    $finish;
  end
endmodule
