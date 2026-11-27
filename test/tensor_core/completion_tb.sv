module completion_tb;
  import blackwell_async_pkg::*;
  import blackwell_tc_pkg::*;
  bit clk;
  always #5 clk = !clk;
  logic rst_n, stop_i;
  logic [15:0] epoch_i = 1;
  logic
      register_op_valid,
      register_op_ready,
      engine_done_valid,
      engine_done_ready,
      op_done_valid,
      op_done_ready;
  logic
      commit_cmd_valid,
      commit_cmd_ready,
      ready_commit_valid,
      ready_commit_ready,
      commit_retire_valid,
      commit_retire_ready;
  logic [31:0] busy_addr;
  logic addr_busy, drained_o, bridge_drained;
  async_id_t register_op_payload;
  op_done_t engine_done_payload, op_done_payload, tc_bar_rsp_payload, commit_done_payload;
  tc_commit_t commit_cmd_payload, tc_bar_req_payload;
  tc_ready_commit_t  ready_commit_payload;
  tc_commit_retire_t commit_retire_payload;
  logic tc_bar_req_valid, tc_bar_req_ready, tc_bar_rsp_valid, tc_bar_rsp_ready;
  logic commit_done_valid, commit_done_ready;
  blackwell_tc_completion_tracker tracker (.*);
  blackwell_tc_async_completion bridge (
    .drained_o(bridge_drained),
    .*
  );
  function automatic async_id_t id(int issuer, seq);
    return {16'd1, 10'(issuer), 32'(seq)};
  endfunction
  task automatic tick;
    @(posedge clk);
    @(negedge clk);
  endtask
  task automatic check(input bit ok);
    if (!ok) $fatal(1, "handshake mismatch at %0t", $time);
  endtask
  initial begin
    rst_n = 0;
    tick();
    rst_n = 1;
    register_op_valid = 1;
    register_op_payload = id(5, 0);
    #1;
    check(register_op_ready);
    tick();
    register_op_payload = id(6, 0);
    tick();
    register_op_valid = 0;
    commit_cmd_valid = 1;
    commit_cmd_payload = '{id(6, 1), 32'd16};
    tick();
    commit_cmd_valid = 0;
    busy_addr = 16;
    #1;
    check(addr_busy && !ready_commit_valid);
    stop_i = 1;  // Drain the registered commit after new commands are stopped.
    engine_done_valid = 1;
    engine_done_payload.id = id(6, 0);
    tick();
    engine_done_valid = 0;
    check(ready_commit_valid && ready_commit_payload.commit.id == id(6, 1));
    tick();
    check(tc_bar_req_valid && tc_bar_req_payload.id == id(6, 1));
    tc_bar_req_ready = 1;
    tick();
    tc_bar_rsp_valid = 1;
    tc_bar_rsp_payload.id = id(6, 1);
    tick();
    tc_bar_rsp_valid = 0;
    check(commit_done_valid && commit_done_payload.id == id(6, 1));
    repeat (3) begin
      tick();
      check(commit_done_valid && addr_busy);
    end
    commit_done_ready = 1;
    tick();
    check(commit_retire_valid);
    tick();
    check(!addr_busy && op_done_valid && op_done_payload.id == id(6, 0));
    stop_i = 0;
    op_done_ready = 1;
    engine_done_valid = 1;
    engine_done_payload.id = id(5, 0);
    // The new command is excluded; the finishing predecessor is subtracted.
    register_op_valid = 1;
    register_op_payload = id(5, 2);
    commit_cmd_valid = 1;
    commit_cmd_payload = '{id(5, 1), 32'd32};
    tick();
    engine_done_valid = 0;
    register_op_valid = 0;
    commit_cmd_valid = 0;
    check(ready_commit_valid && op_done_valid && op_done_payload.id == id(5, 0));
    tick();
    if ($test$plusargs("duplicate_done")) begin
      engine_done_valid = 1;
      engine_done_payload.id = id(6, 0);
      tick();
      $fatal(1, "expected duplicate-completion assertion");
    end
    if ($test$plusargs("unsolicited_bar_rsp")) begin
      tc_bar_rsp_valid = 1;  // The new commit is still presenting its request.
      tick();
      $fatal(1, "expected unsolicited-response assertion");
    end
    tick();
    tc_bar_rsp_payload.id = id(5, 1);
    tc_bar_rsp_valid = 1;
    tick();
    tc_bar_rsp_valid = 0;
    check(commit_done_valid && commit_done_payload.id == id(5, 1));
    engine_done_valid = 1;
    engine_done_payload.id = id(5, 2);
    tick();
    engine_done_valid = 0;
    check(commit_retire_valid && op_done_valid && op_done_payload.id == id(5, 2));
    tick();
    check(drained_o && bridge_drained);
    $display("PASS completion snapshots, issuer isolation, stop and bridge retirement");
    $finish;
  end
endmodule
