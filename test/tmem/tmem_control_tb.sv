module tmem_control_tb;
  import blackwell_async_pkg::*;
  import blackwell_tmem_pkg::*;
  logic clk = 0, rst_n = 0, stop_i = 0;
  always #5 clk = !clk;
  logic [15:0] epoch_i;
  logic
      epoch_end_valid,
      epoch_end_ready,
      manage_cmd_valid,
      manage_cmd_ready,
      manage_rsp_valid,
      manage_rsp_ready;
  tmem_manage_cmd_t manage_cmd_payload;
  tmem_manage_rsp_t manage_rsp_payload;
  logic pin_req_valid, pin_req_ready, pin_rsp_valid, pin_rsp_ready, unpin_valid, unpin_ready;
  tmem_pin_req_t pin_req_payload, unpin_payload;
  tmem_pin_rsp_t pin_rsp_payload;
  logic alloc_credit_o, empty_o, mgr_drained;
  logic alloc_valid, alloc_ready, slot_valid, slot_ready, complete_valid, complete_ready;
  logic wait_cmd_valid, wait_cmd_ready, wait_done_valid, wait_done_ready, wait_drained;
  rf_track_alloc_t alloc_payload;
  rf_track_slot_t slot_payload;
  rf_track_done_t complete_payload;
  tmem_wait_cmd_t wait_cmd_payload;
  op_done_t wait_done_payload;
  blackwell_tmem_manager manager (
    .drained_o(mgr_drained),
    .*
  );
  blackwell_tmem_wait_tracker tracker (
    .drained_o(wait_drained),
    .*
  );
  function automatic async_id_t id(input int seqnum, warp = 0);
    return '{epoch: epoch_i, issuer: 10'(warp * 32), seq: 32'(seqnum)};
  endfunction
  int manage_seq;
  task automatic management(input logic [1:0] op);
    manage_seq++;
    manage_cmd_valid = 1;
    manage_cmd_payload = '{id: id(manage_seq), op: op, base: 0, columns: op == 2 ? 10'd0 : 10'd512};
    do @(posedge clk); while (!manage_cmd_ready);
    @(negedge clk);
    manage_cmd_valid = 0;
    if (!manage_rsp_valid || manage_rsp_payload.id != manage_cmd_payload.id || manage_rsp_payload.base != 0)
      $fatal;
  endtask
  task automatic register_op(input async_id_t key, input bit is_store, output logic [4:0] slot);
    alloc_payload = '{id: key, store: is_store};
    alloc_valid = 1;
    do @(posedge clk); while (!alloc_ready);
    @(negedge clk);
    alloc_valid = 0;
    if (!slot_valid || slot_payload.id != key) $fatal;
    slot = slot_payload.slot;
    @(negedge clk);
  endtask
  task automatic complete_op(input async_id_t key, input logic [4:0] slot);
    complete_payload = '{slot: slot, id: key};
    complete_valid = 1;
    do @(posedge clk); while (!complete_ready);
    @(negedge clk);
    complete_valid = 0;
  endtask
  logic [4:0] op_slot[4];
  initial begin
    repeat (2) @(negedge clk);
    rst_n = 1;
    epoch_i = 1;
    @(negedge clk);
    if (!alloc_credit_o || !empty_o) $fatal;
    manage_rsp_ready = 0;
    management(0);
    if (alloc_credit_o || empty_o) $fatal;
    for (int u = 0; u < 5; u++) begin
      pin_req_valid = 1;
      pin_req_payload = '{id: id(u + 10), user: 3'(u)};
      pin_rsp_ready = 1;
      do @(posedge clk); while (!pin_req_ready);
      @(negedge clk);
      pin_req_valid = 0;
      if (!pin_rsp_valid || pin_rsp_payload.id != id(u + 10))
        $fatal;
    end
    pin_rsp_ready = 0;
    if ($test$plusargs("dealloc_pinned")) begin
      manage_rsp_ready = 1;
      management(1);
      $fatal(1, "Expected deallocation lifetime assertion");
    end
    for (int u = 4; u >= 0; u--) begin
      unpin_valid = 1;
      unpin_payload = '{id: id(u + 10), user: 3'(u)};
      do @(posedge clk); while (!unpin_ready);
      @(negedge clk);
    end
    unpin_valid = 0;
    if (!pin_rsp_valid || !manage_rsp_valid) $fatal;
    pin_rsp_ready = 1;
    manage_rsp_ready = 1;
    management(1);
    if (!alloc_credit_o) $fatal;
    management(0);
    management(2);
    management(1);
    if (alloc_credit_o) $fatal;
    @(negedge clk);
    epoch_end_valid = 1;
    do @(posedge clk); while (!epoch_end_ready);
    @(negedge clk);
    epoch_end_valid = 0;
    epoch_i = 2;
    @(negedge clk);
    if (!alloc_credit_o) $fatal;

    slot_ready = 1;
    register_op(id(1), 1, op_slot[0]);
    register_op(id(1, 4), 1, op_slot[1]);  // same physical partition, different warp
    register_op(id(2), 0, op_slot[2]);
    // One old store finishes and a new one registers on the cutoff edge.
    alloc_valid = 1;
    alloc_payload = '{id: id(4), store: 1};
    complete_valid = 1;
    complete_payload = '{slot: op_slot[0], id: id(1)};
    wait_cmd_valid = 1;
    wait_cmd_payload.id = id(3);
    @(posedge clk);
    if (!alloc_ready || !complete_ready || !wait_cmd_ready) $fatal;
    @(negedge clk);
    alloc_valid = 0;
    complete_valid = 0;
    wait_cmd_valid = 0;
    if (!wait_done_valid || wait_done_payload.id != id(3) || !slot_valid) $fatal;
    op_slot[3] = slot_payload.slot;
    repeat (3) @(negedge clk);
    wait_done_ready = 1;
    @(negedge clk);
    wait_done_ready = 0;
    wait_cmd_valid = 1;
    wait_cmd_payload.id = id(5);
    @(negedge clk);
    wait_cmd_valid = 0;
    if (wait_done_valid) $fatal;
    complete_op(id(2), op_slot[2]);
    complete_op(id(1, 4), op_slot[1]);
    if (wait_done_valid) $fatal;
    stop_i = 1;
    complete_op(id(4), op_slot[3]);
    if (!wait_done_valid || wait_done_payload.id != id(5)) $fatal;
    wait_done_ready = 1;
    @(negedge clk);
    if (!wait_drained) $fatal;
    stop_i = 0;
    for (int i = 0; i < 64; i++) begin
      register_op(id(6 + i), 1, op_slot[0]);
      complete_op(id(6 + i), op_slot[0]);
    end
    wait_cmd_valid = 1;
    wait_cmd_payload.id = id(70);
    @(negedge clk);
    if (!wait_done_valid) $fatal;
    $display(
        "PASS TMEM allocation, five independent pins, held responses, wait snapshots and 64 reuses");
    $finish;
  end
  initial begin
    repeat (2000) @(posedge clk);
    $fatal(1, "timeout");
  end
endmodule
