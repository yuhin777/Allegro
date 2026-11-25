module blackwell_tma_request_generator
  import blackwell_tma_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic halt_i,
  input logic head_valid,
  input tma_context_ref_t head_payload,
  input tma_context_t ctx[2],
  output logic walk_start_valid,
  output logic slot_release_valid,
  output tma_context_ref_t walk_start_payload,
  output tma_context_ref_t slot_release_payload,
  input logic segment_ready,
  input logic generated_ready,
  output logic segment_valid,
  output logic generated_valid,
  output tma_segment_t segment_payload,
  output ticket_t generated_payload,
  output logic drained,
  output logic fault
);
  logic walking;
  tma_context_ref_t saved, ref_sel;
  tma_context_t current_ctx;
  logic [3:0][8:0] position;
  logic [63:0] ordinal, row, ord, row_no, next_row;
  logic [3:0][8:0] pos, next_pos;
  tma_segment_t chosen, stage[3];
  logic [2:0] valid, empty, space;
  logic zero_length, accept;
  function automatic logic [63:0] smaller(input logic [63:0] a, b);
    return a < b ? a : b;
  endfunction
  always_comb begin
    logic [63:0] n, remaining, byte_in_row, inner, rows, x, a;
    logic signed [34:0] coord[4];
    logic carry, oob, inner_oob, outer_oob;
    carry = 0;
    ref_sel = walking ? saved : head_payload;
    current_ctx = ctx[ref_sel.context_slot];
    ord = walking ? ordinal : '0;
    row_no = walking ? row : '0;
    pos = walking ? position : '0;
    remaining = current_ctx.total_bytes - ord;
    zero_length = remaining == 0;
    n = smaller(remaining, 128);
    inner = 64'(current_ctx.inner_bytes);
    byte_in_row = 64'(pos[0]) << 1;
    rows = 64'(current_ctx.map.box[1]) * 64'(current_ctx.map.box[2]) * 64'(current_ctx.map.box[3]);
    x = 64'(current_ctx.cmd.smem_addr);
    a = current_ctx.cmd.global_addr + ord;
    for (int i = 0; i < 4; i++)
    coord[i] = 35'($signed(current_ctx.cmd.coord[i])) + $signed({26'b0, pos[i]});
    oob = 0;
    outer_oob = 0;
    inner_oob = 0;
    if (current_ctx.cmd.opcode == LOAD_LINEAR) x += ord;
    else begin
      x += (((byte_in_row >> 7) * rows + row_no) << 7) + (byte_in_row & 127);
      n = smaller(n, inner - byte_in_row);
      n = smaller(n, 128 - (byte_in_row & 127));
      for (int d = 1; d < 4; d++)
      outer_oob |= coord[d] < 0 || coord[d] >= $signed({2'b0, current_ctx.map.dim[d]});
      inner_oob = coord[0] < 0 || coord[0] >= $signed({2'b0, current_ctx.map.dim[0]});
      oob = outer_oob || inner_oob;
      if (!outer_oob && coord[0] < 0) n = smaller(n, (-64'($signed(coord[0]))) << 1);
      if (!oob) begin
        n = smaller(n, (64'(current_ctx.map.dim[0]) - 64'(coord[0])) << 1);
        a = current_ctx.map.base_addr + (64'(coord[0]) << 1);
        for (int i = 1; i < 4; i++) a += 64'(coord[i]) * 64'(current_ctx.map.stride[i-1]);
      end else a = 0;
    end
    n = smaller(n, 128 - (x & 127));
    if (!oob) n = smaller(n, 128 - (a & 127));
    chosen = '{
        ticket: ref_sel.ticket,
        ordinal: ord,
        gmem_line: {a[63:7], 7'b0},
        goff: a[6:0],
        smem_sector: {x[31:7], 7'b0},
        soff: x[6:0],
        xor_group: current_ctx.cmd.opcode == LOAD_LINEAR ? 3'd0 : x[9:7],
        logical_bytes: n[7:0],
        store: current_ctx.cmd.opcode == STORE_TENSOR,
        oob: oob,
        last: n == remaining
    };
    next_pos = pos;
    next_row = row_no;
    next_pos[0] += 9'(n >> 1);
    if (next_pos[0] == current_ctx.map.box[0]) begin
      next_pos[0] = 0;
      next_row += 1;
      carry = 1;
      for (int d = 1; d < 4; d++)
      if (carry) begin
        next_pos[d] = pos[d] + 9'd1;
        carry = next_pos[d] == current_ctx.map.box[d];
        if (carry) next_pos[d] = 0;
      end
    end
    segment_payload = stage[2];
    generated_payload = stage[2].ticket;
    segment_valid = valid[2] && !empty[2];
    generated_valid = valid[2] && empty[2];
    space[2] = !valid[2] || (empty[2] ? generated_ready : segment_ready);
    space[1] = !valid[1] || space[2];
    space[0] = !valid[0] || space[1];
    accept = rst_n && !fault && (walking || head_valid) && space[0];
    walk_start_valid = accept && !walking;
    slot_release_valid = accept && chosen.last;
    walk_start_payload = ref_sel;
    slot_release_payload = ref_sel;
    drained = !walking && valid == 0;
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid <= 0;
      walking <= 0;
      fault <= 0;
    end else if (!halt_i) begin
      for (int i = 1; i < 3; i++)
      if (space[i]) begin
        valid[i] <= valid[i-1];
        stage[i] <= stage[i-1];
        empty[i] <= empty[i-1];
      end
      if (space[0]) begin
        valid[0] <= accept;
        if (accept) begin
          stage[0] <= chosen;
          empty[0] <= zero_length;
        end
      end
      if (accept) begin
        saved <= ref_sel;
        walking <= !chosen.last;
        row <= next_row;
        position <= next_pos;
        ordinal <= ord + 64'(chosen.logical_bytes);
        if (current_ctx.ticket != ref_sel.ticket || (!zero_length && chosen.logical_bytes == 0))
          fault <= 1;
      end
    end
  end
endmodule
