// Validate operand installation against physical 1R1W TMEM, independently
// computing each expected bit from its logical matrix coordinate.
module tmem_a_tb;
  import blackwell_async_pkg::*;
  import blackwell_tc_pkg::*;
  import blackwell_tmem_pkg::*;
  import blackwell_smem_pkg::*;
  localparam int CORE = 1;
  logic clk = 0, rst_n = 0, bind_i, active_i, permit_a = 1, permit_scale = 1;
  always #5 clk = !clk;
  mma_cmd_t cmd;
  wire [7:0] sm_valid, sm_ret_ready;
  logic [7:0] sm_ready = '0, sm_ret_valid = '0;
  smem_rd_req_t sm_req[8];
  smem_rd_rsp_t sm_ret[8];
  logic [127:0] tm_valid, tm_ready, tm_ret_valid, tm_ret_ready;
  tmem_rd_req_t tm_req[128];
  tmem_rd_rsp_t tm_ret[128];
  logic [3:0] a_ready;
  logic scale_ready;
  logic [31:0][255:0] rows;
  logic [31:0][ 31:0] scales;
  blackwell_tc_a_context #(.CORE(CORE)) source (.*);

  function automatic logic [7:0] physical_byte(int lane, word_num, byte_num);
    return 8'((lane * 137 + word_num * 103 + byte_num * 51) ^ ((lane + 13) * (word_num + 7)) ^
              (byte_num * lane));
  endfunction
  logic fill, uniform_service, inject_wrong_lane;
  logic saw_cross_partition_conflict;
  tmem_rd_rsp_t wrong_lane_payload;
  logic [6:0] fill_word;
  int cycle;
  always_ff @(posedge clk) cycle <= cycle + 1;
  for (genvar p = 0; p < 4; p++) begin : part
    tmem_rd_req_t rq [32];
    tmem_rd_rsp_t rs [32];
    tmem_wr_req_t wq [32];
    tmem_wr_ack_t ack[32];
    logic [31:0] read_valid, read_ready, ret_valid, ret_ready, write_ready, ack_valid;
    for (genvar b = 0; b < 32; b++) begin : bank
      localparam int L = 32 * p + b;
      // Independent grant stalls exercise held atom identity, including an
      // unaligned piece spanning two words. Return backpressure is real.
      wire service = uniform_service || (cycle + L) % 5 != 0;
      assign read_valid[b] = tm_valid[L] && service;
      assign tm_ready[L] = read_ready[b] && service;
      assign rq[b] = tm_req[L];
      if (L == 127) begin
        assign tm_ret_valid[L] = ret_valid[b] || inject_wrong_lane;
        assign tm_ret[L] = inject_wrong_lane ? wrong_lane_payload : rs[b];
      end else begin
        assign tm_ret_valid[L] = ret_valid[b];
        assign tm_ret[L] = rs[b];
      end
      assign ret_ready[b] = tm_ret_ready[L];
      assign wq[b].tag = '{
              id: '{epoch: 16'd2, issuer: 10'd0, seq: 32'd1},
              client: 4'd5,
              token: {2'b0, fill_word, 7'(L)}
          };
      assign wq[b].lane = 7'(L);
      assign wq[b].word = fill_word;
      assign wq[b].byte_mask = '1;
      for (genvar i = 0; i < 16; i++)
        assign wq[b].data[8*i+:8] = physical_byte(L, int'(fill_word), i);
    end
    blackwell_tmem_partition #(
      .PARTITION_ID(p)
    ) ram (
      .clk,
      .rst_n,
      .rd_req_valid(read_valid),
      .rd_req_ready(read_ready),
      .rd_req_payload(rq),
      .rd_rsp_valid(ret_valid),
      .rd_rsp_ready(ret_ready),
      .rd_rsp_payload(rs),
      .wr_req_valid({32{fill}}),
      .wr_req_ready(write_ready),
      .wr_req_payload(wq),
      .wr_ack_valid(ack_valid),
      .wr_ack_ready('1),
      .wr_ack_payload(ack),
      .read_credit_o(),
      .write_credit_o(),
      .drained_o()
    );
    always @(posedge clk) if (fill && !(&write_ready)) $fatal(1, "initialization lost a frame");
  end

  // Compare each legal return with the first physical lane for its destination.
  always @(posedge clk) begin
    bit [4095:0] prior;
    prior = '0;
    if (rst_n && !inject_wrong_lane)
      for (int l = 0; l < 128; l++) begin
        logic [11:0] key;
        key = tm_ret[l].tag.token[15:4];
        if (tm_ret_valid[l]) begin
          if (tm_ret_ready[l] != !prior[key]) $fatal(1, "bad return grant, lane %0d", l);
          prior[key] = 1;
          if (l >= 15 && l / 32 != (l - 15) / 32 && tm_ret_valid[l-15] &&
              tm_ret[l-15].tag.token[15:4] == key)
            saw_cross_partition_conflict = 1;
        end
      end
  end

  function automatic int container_width();
    case (cmd.kind)
      0: return 16;
      1: return 32;
      5, 6: return 4;
      default: return 8;
    endcase
  endfunction
  // Independent logical address for a destination row and bit position.
  function automatic int source_lane(int row, int bit_idx);
    return int'(cmd.a_ref[31:16]) +
        (cmd.transpose_a ? bit_idx / container_width() : CORE * 32 + row);
  endfunction
  function automatic int source_bit(int row, int bit_idx);
    int width_bits;
    width_bits = container_width();
    return int'(cmd.a_ref[15:0]) * 32 +
        (cmd.transpose_a ? (CORE * 32 + row) * width_bits + bit_idx % width_bits : bit_idx) +
        (cmd.kind < 5 && cmd.a_type == 7 ? 2 : 0);
  endfunction
  function automatic bit meaningful(int bit_idx);
    if (cmd.kind < 5 && cmd.a_type == 7) return bit_idx % 8 < 4;
    if (cmd.a_type == 5 || cmd.a_type == 6) return bit_idx % 8 < 6;
    return 1;
  endfunction
  logic [63:0][15:0] seen;
  logic [31:0] scale_seen;
  for (genvar l = 0; l < 128; l++) begin
    always @(posedge clk)
      if (tm_valid[l] && tm_ready[l]) begin
        int p, a;
        logic [15:0] expected_mask;
        if (tm_req[l].tag.id != cmd.id || tm_req[l].lane != 7'(l) ||
            tm_req[l].tag.client != 4'(CORE))
          $fatal;
        if (tm_req[l].tag.token[15:13] == 1) begin
          p = int'(tm_req[l].tag.token[9:4]);
          a = int'(tm_req[l].tag.token[3:0]);
          expected_mask = 0;
          for (int b = 128 * (p % 2); b < 128 * (1 + p % 2); b++)
          if (meaningful(
                  b
              ) && source_lane(
                  p / 2, b
              ) == l && source_bit(
                  p / 2, b
              ) / 128 == int'(tm_req[l].word))
            expected_mask[(source_bit(p/2, b)%128)/8] = 1;
          if (expected_mask == 0 || expected_mask != tm_req[l].byte_mask || seen[p][a])
            $fatal(
                1,
                "wrong/duplicate A atom seq=%0d piece=%0d part=%0d lane=%0d mask=%h expected=%h",
                cmd.id.seq,
                p,
                a,
                l,
                tm_req[l].byte_mask,
                expected_mask
            );
          seen[p][a] = 1;
        end else begin
          int col;
          col = int'(cmd.scale_a[15:0]) + CORE;
          expected_mask = 0;
          for (int g = 0; g < (1 << (cmd.scale_vec - 1)); g++)
          expected_mask[(col%4)*4+int'(cmd.scale_a_id)+g] = 1;
          if (l >= 32 || tm_req[l].tag.token != {3'd3, 5'b0, 4'(l / 2), 4'(l % 2)} || tm_req[
              l].word != 7'(col / 4) || tm_req[l].byte_mask != expected_mask || scale_seen[l%32])
            $fatal;
          scale_seen[l%32] = 1;
        end
      end
  end
  task automatic exercise(input int kind, dtype, column, lane0, seqnum, vec = 0, scale_id = 0,
                          input bit transpose = 0);
    cmd = '0;
    cmd.id = '{epoch: 16'd2, issuer: 10'd0, seq: 32'(seqnum)};
    cmd.kind = 3'(kind);
    cmd.a_type = 4'(dtype);
    cmd.a_from_tmem = 1;
    cmd.transpose_a = transpose;
    cmd.a_ref = {32'b0, 16'(lane0), 16'(column)};
    cmd.scale_a = vec == 0 ? 0 : 405;
    cmd.scale_a_id = 2'(scale_id);
    cmd.scale_vec = 2'(vec);
    cmd.scale_type = vec == 3;
    seen = '0;
    scale_seen = '0;
    bind_i = 1;
    active_i = 1;
    @(negedge clk);
    bind_i = 0;
    while (a_ready != '1 || !scale_ready) begin
      @(negedge clk);
      if (sm_valid != 0)
        $fatal(1, "bad context seq=%0d", seqnum);
    end
    for (int row = 0; row < 32; row++) begin
      for (int b = 0; b < 256; b++) begin
        int lane, offset;
        logic [7:0] from_memory;
        logic expected;
        lane = source_lane(row, b);
        offset = source_bit(row, b);
        from_memory = physical_byte(lane, offset / 128, (offset % 128) / 8);
        expected = meaningful(b) && from_memory[offset%8];
        if (rows[row][b] !== expected) $fatal(1, "seq=%0d row=%0d bit=%0d", seqnum, row, b);
      end
      if (vec != 0) begin
        int col, byte_num;
        logic [7:0] expected;
        col = int'(cmd.scale_a[15:0]) + CORE;
        for (int g = 0; g < 4; g++) begin
          byte_num = 4 * (col % 4) + scale_id + g;
          expected = g < (1 << (vec - 1)) ? physical_byte(row, col / 4, byte_num) : 0;
          if (scales[row][8*g+:8] != expected) $fatal(1, "wrong scale row %0d byte %0d", row, g);
        end
      end
    end
    active_i = 0;
    @(negedge clk);
  endtask
  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1;
    fill = 1;
    for (int w = 0; w < 128; w++) begin
      fill_word = 7'(w);
      @(negedge clk);
    end
    fill = 0;
    repeat (3) @(negedge clk);
    exercise(0, 0, 0, 0, 2);
    exercise(0, 0, 3, 0, 3);
    exercise(0, 1, 3, 28, 4, 0, 0, 1);
    exercise(1, 2, 2, 30, 5, 0, 0, 1);
    exercise(2, 7, 3, 0, 6);
    exercise(4, 6, 1, 0, 7, 1, 3);
    exercise(4, 5, 1, 12, 8, 1, 2, 1);
    exercise(5, 7, 3, 0, 9, 2, 2);
    exercise(6, 7, 1, 0, 10, 3, 0);
    uniform_service = 1;
    exercise(2, 3, 4, 95, 11, 0, 0, 1);
    if (!saw_cross_partition_conflict) $fatal;

    if ($test$plusargs("wrong_lane")) begin
      // Duplicate a genuine outstanding response on a distant, incorrect lane.
      cmd.transpose_a = 0;
      cmd.a_ref = 0;
      cmd.id.seq++;
      seen = '0;
      active_i = 1;
      bind_i = 1;
      @(negedge clk);
      bind_i = 0;
      while (!tm_ret_valid[32*CORE]) @(negedge clk);
      wrong_lane_payload = tm_ret[32*CORE];
      inject_wrong_lane = 1;
      do @(posedge clk); while (!tm_ret_ready[127]);
      @(negedge clk);
      $fatal(1, "expected wrong-lane assertion");
    end
    $display("PASS TMEM A FP16/BF16/TF32, E2M1 extraction, FP6, native FP4 and 1X/2X/4X scale A");
    $finish;
  end
  initial begin
    repeat (20000) @(posedge clk);
    $fatal(1, "timeout at command %0d", cmd.id.seq);
  end
endmodule
