module array_tb;
`ifdef TEST_INDEPENDENT_FP_TREES
  localparam bit SHARE_FP_DOT_ADDER_TREE = 0;
`else
  localparam bit SHARE_FP_DOT_ADDER_TREE = 1;
`endif
  import blackwell_dot_pkg::*;
  import blackwell_tc_pkg::*;
  bit clk;
  always #5 clk = ~clk;
  logic rst_n, operand_valid, operand_ready, result_valid, result_ready, empty_o;
  mma_cmd_t cmd_i;
  operand_t operand_payload;
  result_t  result_payload;
  blackwell_tc_dot_array #(.SHARE_FP_DOT_ADDER_TREE(SHARE_FP_DOT_ADDER_TREE)) dut (.*);
  assert property (@(posedge clk) disable iff (!rst_n)
      result_valid && !result_ready |=> result_valid && $stable(
      result_payload
  ));
  initial begin : storage_contract
    if ($bits(
            wide_req_t
        ) != 740 || $bits(
            low_req_t
        ) != 818 || $bits(
            fp4_req_t
        ) != 784 || $bits(
            int_req_t
        ) != 609)
      $fatal(1, "decoded broadcast payload width");
    if ($bits(operand_t) != 6732 || $bits(result_t) != 2124) $fatal(1, "microtile payload width");

  end

  typedef struct packed {
    logic [2:0] kind;
    logic [3:0] ta, tb, shift;
    logic na, nb, sat, ue4, asymmetric;
    logic [1:0] n_code;
    logic ws;
    logic [255:0] a, b;
    logic [31:0] c, sa, sb, expected;
  } sample_t;
  sample_t samples[$];
  int accepted_at[$];
  int sent, received, cycle;
  bit [31:0] rng = 32'h8582fd35;
  initial begin
    sample_t entry;
    int fd, fields;
    int kind, ta, tb, shift, na, nb, sat, ue4, asym, ncode, ws;
    logic [255:0] raw_a, raw_b;
    logic [31:0] raw_c, sa, sb, reference;
    logic [31:0] expected;
    fd = $fopen("vectors.txt", "r");
    if (fd == 0) $fatal(1, "open vectors.txt");
    do begin
      fields = $fscanf(
          fd,
          "%d %d %d %d %d %d %d %d %d %d %d %h %h %h %h %h %h",
          kind,
          ta,
          tb,
          shift,
          na,
          nb,
          sat,
          ue4,
          asym,
          ncode,
          ws,
          raw_a,
          raw_b,
          raw_c,
          sa,
          sb,
          reference
      );
      entry = {
        3'(kind),
        4'(ta),
        4'(tb),
        4'(shift),
        1'(na),
        1'(nb),
        1'(sat),
        1'(ue4),
        1'(asym),
        2'(ncode),
        1'(ws),
        raw_a,
        raw_b,
        raw_c,
        sa,
        sb,
        reference
      };
      if (fields == 17) samples.push_back(entry);
      else if (fields > 0) $fatal(1, "malformed vector");
    end while (fields == 17);
    $fclose(fd);
    if (samples.size() == 0) $fatal(1, "empty vectors");
    rst_n = 0;
    operand_valid = 0;
    result_ready = 0;
    @(negedge clk);
    rst_n = 1;
    while (received < samples.size()) begin
      rng = {rng[30:0], rng[31] ^ rng[21] ^ rng[1] ^ rng[0]};
      // First three arrivals deliberately invert natural finish order.
      result_ready = (cycle >= 12) && (rng[2] || rng[5]);
      if (sent >= samples.size() - 100) result_ready = 1;
      operand_valid = sent < samples.size() && (sent < samples.size() - 4 || received == sent);
      if (sent == samples.size() - 100 && received != sent) operand_valid = 0;
      cmd_i = '0;
      operand_payload = '0;
      if (operand_valid) begin
        entry = samples[sent];
        cmd_i.kind = entry.kind;
        cmd_i.a_type = entry.ta;
        cmd_i.b_type = entry.tb;
        cmd_i.int_sat = entry.sat;
        cmd_i.scale_type = entry.ue4;
        cmd_i.scale_input_d = entry.shift;
        cmd_i.input_d = 1;
        cmd_i.n_code = entry.n_code;
        cmd_i.ws = entry.ws;
        cmd_i.negate_a = entry.na;
        cmd_i.negate_b = entry.nb;
        operand_payload.tag = 76'(sent);
        for (int g = 0; g < 8; g++) begin
          operand_payload.a[g] = entry.asymmetric ? 256'(g) + 256'd1 : entry.a;
          operand_payload.b[g] = entry.asymmetric ? 256'(g) + 256'd9 : entry.b;
          operand_payload.sa[g] = entry.sa;
          operand_payload.sb[g] = entry.sb;
        end
        for (int n = 0; n < 64; n++)
        operand_payload.c[n] = entry.asymmetric ? 100 * (n / 8) + n % 8 : entry.c;
      end
      @(posedge clk);
      if(sent>=samples.size()-100 && sent<samples.size()-4 && operand_valid && !operand_ready)
        $fatal(1, "mixed floating point stream lost II=1 at %0d", sent);
      if (operand_valid && operand_ready) begin
        accepted_at.push_back(cycle);
        sent++;
      end
      if (result_valid && result_ready) begin
        if (result_payload.tag !== 76'(received)) $fatal(1, "tag mismatch at %0d", received);
        entry = samples[received];
        if (cycle - accepted_at[received] <
            (entry.kind == 3 ? 3 : ((entry.kind == 2 || entry.kind == 4) ? 6 : 5)))
          $fatal(1, "premature result at %0d", received);
        if (received >= samples.size() - 4 && cycle - accepted_at[received] !=
            (entry.kind == 3 ? 3 : ((entry.kind == 2 || entry.kind == 4) ? 6 : 5)))
          $fatal(1, "incorrect unstalled native latency at %0d", received);
        for (int n = 0; n < 64; n++) begin
          expected = entry.asymmetric ? (n / 8 + 1) * (n % 8 + 9) + 100 * (n / 8) + n % 8 :
              entry.expected;
          if (result_payload.cells[n] !== expected)
            $fatal(
                1,
                "sample %0d kind %0d cell %0d got %h expected %h",
                received,
                entry.kind,
                n,
                result_payload.cells[n],
                expected
            );
        end
        received++;
      end
      if (++cycle > samples.size() * 20 + 100) $fatal(1, "timeout");
      @(negedge clk);
    end
    if (!empty_o || sent != received) $fatal(1, "drain failed");
    result_ready = 0;
    // Block retirement and fill both floating-point tails, the common/front
    // slots and the two other families before applying synchronous reset.
    for (int slot = 0; slot < (SHARE_FP_DOT_ADDER_TREE ? 16 : 19); slot++) begin
      if (SHARE_FP_DOT_ADDER_TREE && slot < 8)
        cmd_i.kind = (slot < 2 || slot == 4 || slot == 6) ? 0 : 2;
      else if (!SHARE_FP_DOT_ADDER_TREE && slot < 11) cmd_i.kind = slot < 5 ? 0 : 2;
      else cmd_i.kind = slot < (SHARE_FP_DOT_ADDER_TREE ? 13 : 16) ? 5 : 3;
      operand_valid = 1;
      @(posedge clk);
      if (!operand_ready) $fatal(1, "premature backpressure at blocked slot %0d", slot);
      @(negedge clk);
    end
    @(posedge clk);
    if (operand_ready) $fatal(1, "array accepted beyond its order capacity");
    @(negedge clk);
    operand_valid = 0;
    rst_n = 0;
    #1;
    if (empty_o) $fatal(1, "asynchronous reset changed order state");
    @(negedge clk);
    if (!empty_o || result_valid) $fatal(1, "reset failed to flush in-flight families");
    rst_n = 1;
    result_ready = 1;
    repeat (8) begin
      @(negedge clk);
      if (!empty_o || result_valid) $fatal(1, "stale result after reset");
    end
    $display("PASS %0d tagged microtiles / %0d cells and synchronous in-flight reset", received,
             64 * received);
    $finish;
  end
endmodule
