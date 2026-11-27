// One operand bank. Enumerate physical atoms per 16-byte logical piece;
// the descriptor remains bound until the parent finishes its final op_load.
module blackwell_tc_a_context
  import blackwell_async_pkg::*;
  import blackwell_tc_pkg::*;
  import blackwell_smem_pkg::*;
  import blackwell_tmem_pkg::*;
#(
  parameter int CORE = 0
) (
  input logic clk,
  input logic rst_n,
  input logic bind_i,
  input logic active_i,
  input logic permit_a,
  input logic permit_scale,
  input mma_cmd_t cmd,
  output logic [7:0] sm_valid,
  input logic [7:0] sm_ready,
  output smem_rd_req_t sm_req[8],
  input logic [7:0] sm_ret_valid,
  output logic [7:0] sm_ret_ready,
  input smem_rd_rsp_t sm_ret[8],
  output logic [127:0] tm_valid,
  input logic [127:0] tm_ready,
  output tmem_rd_req_t tm_req[128],
  input logic [127:0] tm_ret_valid,
  output logic [127:0] tm_ret_ready,
  input tmem_rd_rsp_t tm_ret[128],
  output logic [3:0] a_ready,
  output logic scale_ready,
  output logic [31:0][255:0] rows,
  output logic [31:0][31:0] scales
);
  b_load_t src;
  assign src = '{cmd.id, cmd.a_ref, cmd.a_type, cmd.kind, cmd.transpose_a, cmd.n_code};
  logic [63:0][15:0] sent, received, need;
  logic [31:0] sa_sent, sa_received;
  logic [63:0][15:0][31:0] addresses;
  logic [63:0][15:0][15:0] masks;
  logic [63:0][127:0] used;
  logic [63:0][127:0][3:0] parts;
  logic [63:0][127:0][6:0] offsets;
  typedef struct packed {
    logic scale;
    logic [5:0] piece;
    logic [3:0] part;
  } selection_t;
  selection_t [7:0] sp, sh;
  selection_t [127:0] tp, th;
  logic [  7:0] slock;
  logic [127:0] tlock;
  for (genvar p = 0; p < 64; p++) begin : piece
    localparam int ROW = 32 * CORE + p / 2;
    logic [15:0] sm_need;
    logic [15:0][31:0] sm_addr;
    logic [15:0][15:0] sm_mask;
    logic [127:0] sm_used;
    logic [127:0][3:0] sm_part;
    logic [127:0][6:0] sm_offset;
    blackwell_tc_piece_map map (
      .src,
      .row_idx(8'(ROW)),
      .half(1'(p % 2)),
      .required(sm_need),
      .address(sm_addr),
      .byte_mask(sm_mask),
      .used(sm_used),
      .part(sm_part),
      .source_offset(sm_offset)
    );
    always_comb begin
      int width_bits, element, physical_bit, word_idx, lane, k0, part_idx;
      // A nontransposed half row spans at most two adjacent bank words.
      // Transposition maps consecutive elements to consecutive lanes,
      // each touching exactly one word at the same column.
      width_bits = tmem_a_element_bits(cmd.kind);
      need[p] = sm_need;
      addresses[p] = sm_addr;
      masks[p] = sm_mask;
      used[p] = sm_used;
      parts[p] = sm_part;
      offsets[p] = sm_offset;
      k0 = 128 * (p % 2) / width_bits;
      element = 0;
      physical_bit = 0;
      word_idx = 0;
      lane = 0;
      part_idx = 0;
      if (cmd.a_from_tmem) begin
        need[p] = 0;
        addresses[p] = 0;
        masks[p] = 0;
        for (int b = 0; b < 128; b++) begin
          element = k0 + b / width_bits;
          lane = int'(cmd.a_ref[31:16]) + (cmd.transpose_a ? element : ROW);
          physical_bit = 32 * int'(cmd.a_ref[15:0]) +
              (cmd.transpose_a ? ROW * width_bits + b % width_bits : 128 * (p % 2) + b);
          if (cmd.kind < 5 && cmd.a_type == 7) physical_bit += 2;
          word_idx = physical_bit / 128;
          if (cmd.transpose_a) part_idx = element - k0;
          else part_idx = word_idx - (int'(cmd.a_ref[15:0]) / 4 + p % 2);
          used[p][b] = cmd.kind >= 5 || b % width_bits < element_bits(cmd.a_type);
          if (used[p][b]) begin
            need[p][part_idx] = 1;
            addresses[p][part_idx] = {16'(lane), 16'(word_idx)};
            masks[p][part_idx][(physical_bit%128)/8] = 1;
          end
          // The source part that installs the low bits also zeroes padding.
          if (!used[p][b]) part_idx = int'(parts[p][b-(b%8)]);
          parts[p][b] = 4'(part_idx);
          offsets[p][b] = 7'(physical_bit);
        end
      end
    end
  end
  // A transposed 16-byte piece spans at most 16 adjacent TMEM lanes.
  // A nontransposed piece uses one lane, and a scale token uses a lane pair.
  localparam int MAX_RETURN_DISTANCE = 15;
  always_comb begin
    a_ready = {4{active_i && !bind_i}};
    for (int p = 0; p < 64; p++) a_ready[p/16] &= (received[p] & need[p]) == need[p];
    scale_ready = cmd.kind < 4 || (!bind_i && (&sa_received));
    sm_valid = slock;
    sp = sh;
    tm_valid = tlock;
    tp = th;
    for (int l = 0; l < 32; l++)
    if (!tm_valid[l] && active_i && cmd.kind >= 4 && permit_scale && (bind_i || !sa_sent[l])) begin
      tm_valid[l] = 1;
      tp[l] = '{1'b1, 6'(l), 4'd0};
    end
    for (int r = 0; r < 4; r++)
    for (int h = 0; h < 2; h++)
    for (int y = 0; y < 8; y++)
    for (int a = 0; a < 16; a++) begin
      int p;
      logic [2:0] g;
      logic [6:0] l;
      p = 16 * r + 2 * y + h;
      g = addresses[p][a][6:4];
      l = addresses[p][a][22:16];
      if (active_i && permit_a && need[p][a] && (bind_i || !sent[p][a])) begin
        if (cmd.a_from_tmem && !tm_valid[l]) begin
          tp[l] = '{1'b0, 6'(p), 4'(a)};
          tm_valid[l] = 1;
        end
        if (!cmd.a_from_tmem && !sm_valid[g]) begin
          sp[g] = '{1'b0, 6'(p), 4'(a)};
          sm_valid[g] = 1;
        end
      end
    end
    for (int g = 0; g < 8; g++) begin
      sm_req[g].tag = '{cmd.id, 4'(CORE), {3'd1, 3'b0, sp[g].piece, sp[g].part}};
      sm_req[g].addr = addresses[sp[g].piece][sp[g].part];
      sm_req[g].byte_mask = masks[sp[g].piece][sp[g].part];
      sm_ret_ready[g] = 1;
      for (int k = 0; k < g; k++)
      if (sm_ret_valid[k] && sm_ret[k].tag.token[9:4] == sm_ret[g].tag.token[9:4])
        sm_ret_ready[g] = 0;
    end
    for (int l = 0; l < 128; l++) begin
      int scale_col;
      scale_col = int'(cmd.scale_a[15:0]) + CORE;
      tm_req[l].tag = '{cmd.id, 4'(CORE), {3'd1, 3'b0, tp[l].piece, tp[l].part}};
      tm_req[l].lane = 7'(l);
      tm_req[l].word = addresses[tp[l].piece][tp[l].part][6:0];
      tm_req[l].byte_mask = masks[tp[l].piece][tp[l].part];
      if (tp[l].scale) begin
        tm_req[l].tag.token = {3'd3, 5'd0, 4'(l / 2), 4'(l % 2)};
        tm_req[l].word = 7'(scale_col / 4);
        tm_req[l].byte_mask = '0;
        for (int g = 0; g < 4; g++)
        if (g < (1 << (cmd.scale_vec - 1)))
          tm_req[l].byte_mask[4*(scale_col%4)+int'(cmd.scale_a_id)+g] = 1;
      end
      tm_ret_ready[l] = 1;
      for (int k = (l > MAX_RETURN_DISTANCE ? l - MAX_RETURN_DISTANCE : 0); k < l; k++)
      if (tm_ret_valid[k] && tm_ret[k].tag.token[15:4] == tm_ret[l].tag.token[15:4])
        tm_ret_ready[l] = 0;
    end
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      slock <= 0;
      tlock <= 0;
    end else begin
      if (bind_i) begin
        sent <= '0;
        received <= '0;
        sa_sent <= '0;
        sa_received <= '0;
      end
      for (int g = 0; g < 8; g++) begin
        slock[g] <= sm_valid[g] && !sm_ready[g];
        sh[g] <= sp[g];
        if (sm_valid[g] && sm_ready[g]) sent[sp[g].piece][sp[g].part] <= 1;
        if (sm_ret_valid[g] && sm_ret_ready[g]) begin
          logic [5:0] p;
          logic [3:0] a;
          p = sm_ret[g].tag.token[9:4];
          a = sm_ret[g].tag.token[3:0];
`ifndef SYNTHESIS
          assert (sm_ret[g].tag.id == cmd.id && sm_ret[g].tag.client == 4'(CORE) &&
                  sm_ret[g].tag.token[15:10] == 6'b001000 && sent[p][a] &&
                  !received[p][a] && addresses[p][a][6:4] == 3'(g));
`endif
          received[p][a] <= 1;
          for (int b = 0; b < 128; b++)
          if (parts[p][b] == a)
            rows[p[5:1]][128*int'(p[0])+b] <= used[p][b] && sm_ret[g].data[offsets[p][b]];
        end
      end
      for (int l = 0; l < 128; l++) begin
        tlock[l] <= tm_valid[l] && !tm_ready[l];
        th[l] <= tp[l];
        if (tm_valid[l] && tm_ready[l]) begin
          if (tp[l].scale) sa_sent[l%32] <= 1;
          else sent[tp[l].piece][tp[l].part] <= 1;
        end
        if (tm_ret_valid[l] && tm_ret_ready[l]) begin
          logic [5:0] p;
          logic [3:0] a;
          p = tm_ret[l].tag.token[9:4];
          a = tm_ret[l].tag.token[3:0];
`ifndef SYNTHESIS
          assert (tm_ret[l].tag.id == cmd.id && tm_ret[l].tag.client == 4'(CORE));
`endif
          if (tm_ret[l].tag.token[15:13] == 3) begin
`ifndef SYNTHESIS
            assert (l < 32 && sa_sent[l%32] && !sa_received[l%32] &&
                    tm_ret[l].tag.token == {3'd3, 5'd0, 4'(l / 2), 4'(l % 2)});
`endif
            sa_received[l%32] <= 1;
            for (int g = 0; g < 4; g++)
            scales[l%32][g*8+:8] <= g < (1 << (cmd.scale_vec - 1)) ? tm_ret[l].data[
                8*(4*((int'(cmd.scale_a[1:0])+CORE)%4)+int'(cmd.scale_a_id)+g)+:8] : 0;
          end else begin
`ifndef SYNTHESIS
            assert (tm_ret[l].tag.token[15:10] == 6'b001000 && sent[p][a] && !received[p][a] &&
                    addresses[p][a][31:16] == 16'(l))
              else $fatal(1, "TC_A_TMEM_RETURN: return must match the requested lane and atom");
`endif
            received[p][a] <= 1;
            for (int b = 0; b < 128; b++)
            if (parts[p][b] == a)
              rows[p[5:1]][128*int'(p[0])+b] <= used[p][b] && tm_ret[l].data[offsets[p][b]];
          end
        end
      end
    end
  end
endmodule
