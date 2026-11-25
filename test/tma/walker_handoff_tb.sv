module walker_handoff_tb;
  import blackwell_tma_pkg::*;
  bit clk;
  always #1 clk = !clk;
  logic rst_n, head_valid, segment_ready, generated_ready;
  logic walk_start_valid, slot_release_valid, segment_valid, generated_valid, fault, drained;
  tma_context_ref_t head_payload, walk_start_payload, slot_release_payload;
  tma_context_t ctx[2];
  tma_segment_t segment_payload;
  ticket_t generated_payload, ticket;

  // Reuse slot zero on every S0 acceptance while the tracker holds the first
  // segment. Every stage must retain the ticket and bases from its own edge.
  always_comb begin
    ctx[0] = '0;
    ctx[0].ticket = ticket;
    ctx[0].cmd.opcode = LOAD_LINEAR;
    ctx[0].cmd.global_addr = 64'h1234_5678_9abc_0000 + (64'(ticket) << 4);
    ctx[0].cmd.smem_addr = 32'h3000 + (32'(ticket) << 4);
    ctx[0].total_bytes = ticket == 2 ? 0 : 16;
    ctx[1] = '0;
    head_payload = '{ticket: ticket, context_slot: 1'b0};
  end
  blackwell_tma_request_generator dut (
    .halt_i(1'b0),
    .*
  );

  task automatic check_segment(input ticket_t id);
    tma_segment_t expected;
    expected = '0;
    expected.ticket = id;
    expected.gmem_line = 64'h1234_5678_9abc_0000;
    expected.smem_sector = 32'h3000;
    expected.goff = 7'(id) << 4;
    expected.soff = 7'(id) << 4;
    expected.logical_bytes = 16;
    expected.last = 1;
    if (!segment_valid || generated_valid || segment_payload !== expected)
      $fatal(1, "segment for ticket %0d changed after release", id);
  endtask

  initial begin
    rst_n = 0;
    head_valid = 0;
    segment_ready = 0;
    generated_ready = 0;
    @(negedge clk);
    rst_n = 1;
    head_valid = 1;
    for (int i = 1; i <= 3; i++) begin
      ticket = ticket_t'(i);
      @(posedge clk);
      if (!walk_start_valid || !slot_release_valid || walk_start_payload != head_payload ||
          slot_release_payload != head_payload)
        $fatal(1, "handoff bubble at ticket %0d", i);
      @(negedge clk);
    end
    ticket = 4;
    head_valid = 0;
    repeat (4) begin
      @(posedge clk);
      check_segment(1);
    end
    @(negedge clk);
    segment_ready = 1;
    @(negedge clk);
    repeat (4) begin
      @(posedge clk);
      if (!generated_valid || generated_payload != 2 || segment_valid)
        $fatal(1, "stalled close-only token changed");
    end
    @(negedge clk);
    generated_ready = 1;
    @(negedge clk);
    check_segment(3);
    @(negedge clk);
    if (!drained || fault) $fatal(1, "walker failed to drain");
    $display("PASS consecutive slot releases and stalled segment / close-only handoffs");
    $finish;
  end
endmodule
