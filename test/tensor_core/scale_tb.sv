module scale_tb;
  import blackwell_async_pkg::*;
  import blackwell_tc_pkg::*;
  import blackwell_tmem_pkg::*;
  bit clk;
  always #5 clk = !clk;
  logic rst_n, halt_i, start_valid, start_ready, release_valid, release_ready, drained_o, fault_o;
  logic [15:0] epoch_i = 1;
  mma_live_t [2:0] live_i;
  prepare_t start_payload;
  async_id_t release_payload;
  logic [127:0] rd_req_valid, rd_req_ready, rd_rsp_valid, rd_rsp_ready;
  tmem_rd_req_t rd_req_payload[128];
  tmem_rd_rsp_t rd_rsp_payload[128];
  // Queries change between clock edges. Preserve asynchronous stimulus in
  // the timed coroutine model so each combinational view is sampled.
  logic [3:0][71:0] query  /* verilator public_flat_rw */;
  logic [3:0][256:0] view;
  logic [2:0] ready, quiescent;
  blackwell_tc_scale_b_snapshot dut (.*);
  tmem_rd_req_t saved[128];
  logic [127:0] outstanding;
  function automatic logic [7:0] pattern(int lane, cell_addr, byte_idx);
    return 8'(lane * 7 + cell_addr * 13 + byte_idx * 23);
  endfunction
  int cycle;
  for (genvar l = 0; l < 128; l++) begin
    always_comb begin
      rd_req_ready[l] = cycle % 5 != 2 && (!outstanding[l] || cycle % 3 != 1);
      rd_rsp_valid[l] = outstanding[l] && cycle % 3 != 1;
      rd_rsp_payload[l].tag = saved[l].tag;
      rd_rsp_payload[l].status = OK;
      for (int b = 0; b < 16; b++)
      rd_rsp_payload[l].data[b*8+:8] = pattern(l, 4 * int'(saved[l].word) + b / 4, b % 4);
    end
    always_ff @(posedge clk) begin
      if (!rst_n) outstanding[l] <= 0;
      else begin
        if (rd_rsp_valid[l] && rd_rsp_ready[l]) outstanding[l] <= 0;
        if (rd_req_valid[l] && rd_req_ready[l]) begin
          if (outstanding[l] && !rd_rsp_valid[l]) $fatal(1, "test reply queue overflow");
          outstanding[l] <= 1;
          saved[l] <= rd_req_payload[l];
        end
      end
    end
  end
  always_ff @(posedge clk) begin
    cycle <= cycle + 1;
    if (fault_o || cycle > 20000)
      $fatal(1, "scale snapshot cycle=%0d cmd=%0d fault=%b ready=%b start_ready=%b",
             cycle, start_payload.cmd.id.seq, fault_o, ready, start_ready);
  end
  initial begin
    repeat (2) @(negedge clk);
    rst_n = 1;
    for (int v = 0; v < 3; v++)
    for (int sid = 0; sid < 4; sid += (1 << v)) begin
      for (int b = 0; b < 2; b++) begin
        start_payload = '0;
        start_payload.bank = 1'(b);
        start_payload.rec = 2'(b);
        start_payload.cmd.id = '{16'd1, 10'(b), 32'(10 * v + sid)};
        start_payload.cmd.n_code = 2;
        start_payload.cmd.scale_b = 32'(37 + 4 * b);
        start_payload.cmd.scale_vec = 2'(v + 1);
        start_payload.cmd.scale_b_id = 2'(sid);
        live_i[b] = '{1'b1, 2'(b), start_payload.cmd.id};
        start_valid = 1;
        do @(posedge clk); while (!start_ready);
        @(negedge clk);
        start_valid = 0;
      end
      while (ready != 3) @(negedge clk);
      for (int block_idx = 0; block_idx < 32; block_idx++)
      for (int b = 0; b < 2; b++) begin
        for (int q = 0; q < 4; q++)
        query[q] = {live_i[b].id, 6'((block_idx + q) % 32), 8'(8 * ((block_idx + q) % 32))};
        #1;
        for (int q = 0; q < 4; q++)
        for (int j = 0; j < 8; j++)
        for (int g = 0; g < 4; g++) begin
          int n;
          n = 8 * ((block_idx + q) % 32) + j;
          if (!view[q][256] || view[q][j*32+g*8+:8] != (g < (1 << v) ? pattern(
                  n % 32, 37 + 4 * b + n / 32, sid + g
              ) : 8'd0))
            $fatal(
                1,
                "bad snapshot v=%0d sid=%0d bank=%0d n=%0d g=%0d valid=%b got=%h expected=%h",
                v,
                sid,
                b,
                n,
                g,
                view[q][256],
                view[q][j*32+g*8+:8],
                g < (1 << v) ? pattern(
                    n % 32, 37 + 4 * b + n / 32, sid + g
                ) : 8'd0
            );
        end
      end
      @(negedge clk);
      for (int b = 0; b < 2; b++) begin
        release_payload = live_i[b].id;
        release_valid = 1;
        @(posedge clk);
        if (!release_ready) $fatal;
        @(negedge clk);
        release_valid = 0;
      end
      if (!drained_o) $fatal;
    end
    $display("PASS scale B snapshot both contexts, N256, all legal scale IDs and vector widths");
    $finish;
  end
endmodule
