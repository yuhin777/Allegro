module blackwell_tma_request_generator
  import blackwell_tma_pkg::*;
(
  input logic clk,
  input logic rst_n,
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
  output logic drained
);
  logic walking;
  tma_context_ref_t saved, ref_sel;
  tma_context_t current_ctx;
  typedef struct packed {
    ticket_t ticket;
    logic [63:0] ordinal;
    logic [7:0] logical_bytes;
    logic linear, store, oob, last;
  } segment_meta_t;

  typedef struct packed {
    segment_meta_t meta;
    logic [63:0] gbase;
    logic [31:0] sbase;
    logic [8:0] row_offset;
  } span_t;

  logic [3:0][8:0] position, pos, next_pos;
  logic [63:0] ordinal, ord;
  // Anchor d holds the GMEM origin of the current slice with positions
  // 0 through d-1 cleared. An outer carry reloads all inner anchors.
  logic [63:0] anchor_q[1:3], anchor[1:3], next_anchor[1:3];
  logic [31:0] srow_q, spanel_q, srow, spanel, next_srow, next_spanel;
  span_t selected, span_q;
  tma_segment_t addressed, address_q, result_q;
  logic [2:0] valid, empty;
  logic space0, space1, space2;
  logic zero_length, accept;

  function automatic logic [7:0] cap_line(input logic [63:0] distance);
    return |distance[63:7] ? 8'd128 : {1'b0, distance[6:0]};
  endfunction

  function automatic logic [7:0] smaller(input logic [7:0] a, b);
    return a < b ? a : b;
  endfunction

  always_comb begin
    logic [7:0] n, bounds[7];
    logic [63:0] remaining;
    logic [ 8:0] byte_in_row;
    logic [6:0] goff, soff;
    logic signed [34:0] coord[4];
    logic carry, outer_oob, linear;
    ref_sel = walking ? saved : head_payload;
    current_ctx = ctx[ref_sel.context_slot];
    linear = current_ctx.cmd.opcode == LOAD_LINEAR;
    ord = walking ? ordinal : '0;
    pos = walking ? position : '0;
    for (int d = 1; d < 4; d++) anchor[d] = walking ? anchor_q[d] : current_ctx.gmem_origin;
    srow = walking ? srow_q : current_ctx.cmd.smem_addr;
    spanel = walking ? spanel_q : current_ctx.cmd.smem_addr;
    remaining = current_ctx.total_bytes - ord;
    zero_length = remaining == 0;
    byte_in_row = pos[0] << 1;

    selected.meta.ticket = ref_sel.ticket;
    selected.meta.ordinal = ord;
    selected.meta.linear = linear;
    selected.meta.store = current_ctx.cmd.opcode == STORE_TENSOR;
    selected.gbase = linear ? current_ctx.cmd.global_addr : anchor[1];
    selected.sbase = linear ? current_ctx.cmd.smem_addr : spanel;
    selected.row_offset = byte_in_row;
    goff = selected.gbase[6:0] + (linear ? ord[6:0] : byte_in_row[6:0]);
    soff = selected.sbase[6:0] + (linear ? ord[6:0] : byte_in_row[6:0]);
    for (int d = 0; d < 4; d++)
    coord[d] = 35'($signed(current_ctx.cmd.coord[d])) + $signed({26'b0, pos[d]});
    outer_oob = 0;
    for (int d = 1; d < 4; d++)
    outer_oob |= coord[d] < 0 || coord[d] >= $signed({2'b0, current_ctx.map.dim[d]});
    selected.meta.oob = !linear &&
        (outer_oob || coord[0] < 0 || coord[0] >= $signed({2'b0, current_ctx.map.dim[0]}));

    // Bound each independent distance before the three-level minimum tree.
    bounds[0] = cap_line(remaining);
    bounds[1] = 8'd128 - {1'b0, soff};
    bounds[2] = selected.meta.oob ? 8'd128 : 8'd128 - {1'b0, goff};
    bounds[3] = linear ? 8'd128 : cap_line(64'(current_ctx.inner_bytes) - 64'(byte_in_row));
    bounds[4] = linear ? 8'd128 : 8'd128 - {1'b0, byte_in_row[6:0]};
    bounds[5] = !linear && !outer_oob && coord[0] < 0 ? cap_line((-64'($signed(coord[0]))) << 1) :
        8'd128;
    bounds[6] = !linear && !selected.meta.oob ?
        cap_line((64'(current_ctx.map.dim[0]) - 64'(coord[0])) << 1) : 8'd128;
    n = smaller(
      smaller(
        smaller(bounds[0], bounds[1]), smaller(bounds[2], bounds[3])
      ),
      smaller(
        smaller(bounds[4], bounds[5]), bounds[6])
    );
    selected.meta.logical_bytes = n;
    selected.meta.last = 64'(n) == remaining;

    next_pos = pos;
    next_srow = srow;
    next_spanel = spanel;
    for (int d = 1; d < 4; d++) next_anchor[d] = anchor[d];
    carry = 0;
    next_pos[0] += {2'b0, n[7:1]};
    if (next_pos[0] == current_ctx.map.box[0]) begin
      next_pos[0] = 0;
      next_srow = srow + 32'd128;
      next_spanel = next_srow;
      carry = 1;
      for (int d = 1; d < 4; d++) begin
        if (carry) begin
          next_pos[d] = pos[d] + 9'd1;
          carry = next_pos[d] == current_ctx.map.box[d];
          if (carry) next_pos[d] = 0;
          else begin
            for (int k = 1; k <= d; k++)
            next_anchor[k] = anchor[d] + 64'(current_ctx.map.stride[d-1]);
          end
        end
      end
    end else if (next_pos[0][8:6] != pos[0][8:6]) begin
      next_spanel = spanel + {current_ctx.row_count, 7'b0};
    end
  end

  // S0 needs only the low seven address bits to find the next boundary.
  // Complete both address additions after S0, using its captured context.
  always_comb begin
    logic [63:0] gaddr;
    logic [31:0] saddr;
    gaddr = span_q.gbase + (span_q.meta.linear ? span_q.meta.ordinal : 64'(span_q.row_offset));
    saddr = span_q.sbase +
        (span_q.meta.linear ? span_q.meta.ordinal[31:0] : 32'(span_q.row_offset[6:0]));
    addressed = '{
        ticket: span_q.meta.ticket,
        ordinal: span_q.meta.ordinal,
        gmem_line: span_q.meta.oob ? '0 : {gaddr[63:7], 7'b0},
        goff: span_q.meta.oob ? '0 : gaddr[6:0],
        smem_sector: {saddr[31:7], 7'b0},
        soff: saddr[6:0],
        xor_group: span_q.meta.linear ? 3'd0 : saddr[9:7],
        logical_bytes: span_q.meta.logical_bytes,
        store: span_q.meta.store,
        oob: span_q.meta.oob,
        last: span_q.meta.last
    };
  end

  assign segment_payload = result_q, generated_payload = result_q.ticket;
  assign segment_valid = valid[2] && !empty[2], generated_valid = valid[2] && empty[2];
  assign space2 = !valid[2] || (empty[2] ? generated_ready : segment_ready);
  assign space1 = !valid[1] || space2, space0 = !valid[0] || space1;
  assign accept = rst_n && (walking || head_valid) && space0;
  assign walk_start_valid = accept && !walking, slot_release_valid = accept && selected.meta.last;
  assign walk_start_payload = ref_sel, slot_release_payload = ref_sel;
  assign drained = !walking && valid == 0;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid <= 0;
      walking <= 0;
    end else begin
      if (space2) begin
        valid[2] <= valid[1];
        empty[2] <= empty[1];
        result_q <= address_q;
      end
      if (space1) begin
        valid[1] <= valid[0];
        empty[1] <= empty[0];
        address_q <= addressed;
      end
      if (space0) begin
        valid[0] <= accept;
        if (accept) begin
          span_q <= selected;
          empty[0] <= zero_length;
        end
      end
      if (accept) begin
        saved <= ref_sel;
        walking <= !selected.meta.last;
        position <= next_pos;
        ordinal <= ord + 64'(selected.meta.logical_bytes);
        for (int d = 1; d < 4; d++) anchor_q[d] <= next_anchor[d];
        srow_q <= next_srow;
        spanel_q <= next_spanel;
      end
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk)
    if (accept) assert (current_ctx.ticket == ref_sel.ticket &&
                        (zero_length || selected.meta.logical_bytes != 0));
`endif
endmodule
