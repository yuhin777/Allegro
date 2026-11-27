module blackwell_tc_b_loader
  import blackwell_async_pkg::*;
  import blackwell_tc_pkg::*;
  import blackwell_smem_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic [15:0] epoch_i,
  input mma_live_t [2:0] live_i,
  input logic load_valid,
  output logic load_ready,
  input b_load_t load_payload,
  output logic result_valid,
  input logic result_ready,
  output op_done_t result_payload,
  output logic [3:0] data_valid,
  input logic [3:0] data_ready,
  output b_data_t data_payload,
  output logic [7:0] sm_rd_req_valid,
  input logic [7:0] sm_rd_req_ready,
  output smem_rd_req_t sm_rd_req_payload[8],
  input logic [7:0] sm_rd_rsp_valid,
  output logic [7:0] sm_rd_rsp_ready,
  input smem_rd_rsp_t sm_rd_rsp_payload[8],
  output logic drained_o
);
  b_load_t stream[2];
  logic [1:0] active, result_pending;
  logic [1:0][5:0] next_block;
  logic oldest_stream;
  logic [1:0] occupied, owner;
  logic [1:0][4:0] block_idx;
  logic oldest_slot;
  logic [1:0][15:0][15:0] required, sent, received;
  logic [1:0][15:0][15:0][31:0] address;
  logic [1:0][15:0][15:0][15:0] mask;
  logic [1:0][15:0][127:0] used, buffer_data;
  logic [1:0][15:0][127:0][3:0] bit_part;
  logic [1:0][15:0][127:0][6:0] bit_offset;
  logic [1:0][3:0] delivered;
  logic [1:0] finished, can_assign;
  logic [1:0][15:0][2:0] rr;
  typedef struct packed {
    logic slot;
    logic [3:0] piece, part;
  } pick_t;
  pick_t [7:0] selected, held;
  logic [7:0] locked;
  logic allocate, slot, source, deliver_last, new_stream;
  logic [7:0] rsp_slot;
  logic [7:0][3:0] rsp_piece, rsp_part;
  for (genvar s = 0; s < 2; s++) begin : slot_map
    for (genvar p = 0; p < 16; p++) begin : piece
      wire [7:0] logical_row = {block_idx[s], 3'd0} + 8'(p / 2);
      b_load_t src;
      assign src = stream[owner[s]];
      logic [15:0] generic_required;
      logic [15:0][31:0] generic_address;
      logic [15:0][15:0] generic_mask;
      blackwell_tc_piece_map map (
        .src,
        .row_idx(logical_row),
        .half(1'(p % 2)),
        .required(generic_required),
        .address(generic_address),
        .byte_mask(generic_mask),
        .used(used[s][p]),
        .part(bit_part[s][p]),
        .source_offset(bit_offset[s][p])
      );
      always_comb begin
        required[s][p] = generic_required;
        address[s][p] = generic_address;
        mask[s][p] = generic_mask;
        if (src.kind == 0) begin
          required[s][p] = 1;
          mask[s][p][0] = '1;
          address[s][p][0] = src.transpose ?
              32'(matrix_byte(src.desc, 1, int'(block_idx[s]) * 16, 8 * (p % 2) + p / 2)) :
              32'(matrix_byte(src.desc, 0, int'(logical_row), 16 * (p % 2)));
        end
      end
    end
  end
  always_comb begin
    for (int i = 0; i < 2; i++) begin
      can_assign[i] = active[i] && next_block[i] < (6'd8 << stream[i].n_code);
      finished[i] = occupied[i] && received[i] == required[i];
    end
    source = can_assign[oldest_stream] ? oldest_stream : !oldest_stream;
    data_valid = finished[oldest_slot] ? ~delivered[oldest_slot] : 0;
    data_payload.id = stream[owner[oldest_slot]].id;
    data_payload.block_idx = block_idx[oldest_slot];
    data_payload.data = buffer_data[oldest_slot];
    if (stream[owner[oldest_slot]].kind == 0 && stream[owner[oldest_slot]].transpose)
      for (int c = 0; c < 8; c++)
      for (int k = 0; k < 16; k++)
      data_payload.data[256*c+16*k+:16] = buffer_data[oldest_slot][2*(k%8)+k/8][16*c+:16];
    deliver_last = (|data_valid) && ((delivered[oldest_slot] | (data_valid & data_ready)) == 4'hf);
    allocate = (|can_assign) && (occupied != 3 || deliver_last);
    slot = !occupied[0] ? 0 : (!occupied[1] ? 1 : oldest_slot);
    new_stream = active[0];
    load_ready = active != 3;
    result_valid = result_pending[oldest_stream];
    result_payload.id = stream[oldest_stream].id;
    drained_o = active == 0;
  end
  function automatic logic [3:0] first_set(logic [15:0] bits);
    logic [15:0] onehot;
    onehot = bits & -bits;
    return {|(onehot & 16'hff00), |(onehot & 16'hf0f0), |(onehot & 16'hcccc), |(onehot & 16'haaaa)};
  endfunction
  for (genvar g = 0; g < 8; g++) begin : request
    logic [1:0][15:0] eligible_piece;
    logic [1:0][15:0][3:0] first_part;
    for (genvar s = 0; s < 2; s++) begin : g_slot_priority
      for (
          genvar priority_index = 0; priority_index < 16; priority_index++
      ) begin : g_piece_priority
        // Issue every low half before its corresponding high half.
        localparam int P = 2 * (priority_index % 8) + priority_index / 8;
        logic [15:0] candidates;
        for (genvar a = 0; a < 16; a++)
          assign candidates[a] =
              required[s][P][a] && !sent[s][P][a] && address[s][P][a][6:4] == 3'(g);
        assign eligible_piece[s][priority_index] = occupied[s] && (|candidates);
        assign first_part[s][priority_index] = first_set(candidates);
      end
    end
    always_comb begin
      logic s;
      logic [3:0] priority_index;
      s = (|eligible_piece[oldest_slot]) ? oldest_slot : !oldest_slot;
      priority_index = first_set(eligible_piece[s]);
      selected[g]=locked[g] ? held[g] :
                {s,priority_index[2:0],priority_index[3],first_part[s][priority_index]};
      sm_rd_req_valid[g] = locked[g] || (|eligible_piece);
      sm_rd_req_payload[g].addr = address[selected[g].slot][selected[g].piece][selected[g].part];
      sm_rd_req_payload[g].byte_mask = mask[selected[g].slot][selected[g].piece][selected[g].part];
      sm_rd_req_payload[g].tag = '{
          stream[owner[selected[g].slot]].id,
          4'd6,
          {3'd0, block_idx[selected[g].slot], selected[g].piece, selected[g].part}
      };
    end
    always_comb begin
      rsp_piece[g] = sm_rd_rsp_payload[g].tag.token[7:4];
      rsp_part[g] = sm_rd_rsp_payload[g].tag.token[3:0];
      rsp_slot[g] = occupied[1] && stream[owner[1]].id == sm_rd_rsp_payload[g].tag.id &&
          block_idx[1] == sm_rd_rsp_payload[g].tag.token[12:8];
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if (rst_n && sm_rd_rsp_valid[g]) begin
      assert (occupied[rsp_slot[g]] &&
              stream[owner[rsp_slot[g]]].id == sm_rd_rsp_payload[g].tag.id &&
              block_idx[rsp_slot[g]] == sm_rd_rsp_payload[g].tag.token[12:8] &&
              sm_rd_rsp_payload[g].tag.client == 6 && sm_rd_rsp_payload[g].tag.token[15:13] == 0 &&
              sent[rsp_slot[g]][rsp_piece[g]][rsp_part[g]] &&
              !received[rsp_slot[g]][rsp_piece[g]][rsp_part[g]] &&
              address[rsp_slot[g]][rsp_piece[g]][rsp_part[g]][6:4] == 3'(g))
        else $fatal(1, "TC_B_RETURN: return must match an outstanding source atom");
    end
`endif
    always_comb begin
      sm_rd_rsp_ready[g] = 1;
      for (int k = 0; k < 8; k++)
      if (sm_rd_rsp_valid[k] && rsp_slot[k] == rsp_slot[g] &&
          rsp_piece[k] == rsp_piece[g] &&
          (3'(k) - rr[rsp_slot[g]][rsp_piece[g]]) < (3'(g) - rr[rsp_slot[g]][rsp_piece[g]]))
        sm_rd_rsp_ready[g] = 0;
    end
  end
  // One 128-bit write port per physical assembly row. Returning groups are
  // arbitrated before the bit patch so eight different rows can update on
  // an edge without a variable write into a 4096-bit concatenation.
  for (genvar s = 0; s < 2; s++) begin : g_slot_write
    for (genvar p = 0; p < 16; p++) begin : g_row_write
      logic [  7:0] grants;
      logic [127:0] incoming;
      logic [  3:0] incoming_part;
      always_comb begin
        incoming = 0;
        incoming_part = 0;
        for (int g = 0; g < 8; g++) begin
          grants[g]=sm_rd_rsp_valid[g] && sm_rd_rsp_ready[g] &&
                              rsp_slot[g] == 1'(s) && rsp_piece[g] == 4'(p);
          incoming |= sm_rd_rsp_payload[g].data & {128{grants[g]}};
          incoming_part |= rsp_part[g] & {4{grants[g]}};
        end
      end
      always_ff @(posedge clk) begin
        if (rst_n && (|grants)) begin
          if (stream[owner[s]].kind == 0) buffer_data[s][p] <= incoming;
          else
            for (int k = 0; k < 128; k++) begin
              if (bit_part[s][p][k] == incoming_part)
                buffer_data[s][p][k] <= used[s][p][k] && incoming[bit_offset[s][p][k]];
            end
        end
      end
    end
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      active <= 0;
      occupied <= 0;
      oldest_slot <= 0;
      oldest_stream <= 0;
      locked <= 0;
      result_pending <= 0;
      rr <= '0;
    end else begin
      if (load_valid && load_ready) begin
`ifndef SYNTHESIS
        assert (load_payload.id.epoch == epoch_i && load_payload.n_code < 3 &&
                !(active[0] && load_payload.id == stream[0].id) &&
                !(active[1] && load_payload.id == stream[1].id) &&
                ((live_i[0].valid && live_i[0].id == load_payload.id) ||
                 (live_i[1].valid && live_i[1].id == load_payload.id) ||
                 (live_i[2].valid && live_i[2].id == load_payload.id)));
`endif
        active[new_stream] <= 1;
        stream[new_stream] <= load_payload;
        next_block[new_stream] <= 0;
        if (active == 0 || (result_valid && result_ready)) oldest_stream <= new_stream;
      end
      if (result_valid && result_ready) begin
        active[oldest_stream] <= 0;
        result_pending[oldest_stream] <= 0;
        oldest_stream <= !oldest_stream;
      end
      if (|data_valid) delivered[oldest_slot] <= delivered[oldest_slot] | (data_valid & data_ready);
      if (deliver_last) begin
        if (6'(block_idx[oldest_slot]) + 1 == (6'd8 << stream[owner[oldest_slot]].n_code))
          result_pending[owner[oldest_slot]] <= 1;
        occupied[oldest_slot] <= 0;
        oldest_slot <= !oldest_slot;
      end
      for (int g = 0; g < 8; g++) begin
        held[g] <= selected[g];
        locked[g] <= sm_rd_req_valid[g] && !sm_rd_req_ready[g];
        if (sm_rd_req_valid[g] && sm_rd_req_ready[g])
          sent[selected[g].slot][selected[g].piece][selected[g].part] <= 1;
        if (sm_rd_rsp_valid[g] && sm_rd_rsp_ready[g]) begin
          received[rsp_slot[g]][rsp_piece[g]][rsp_part[g]] <= 1;
          rr[rsp_slot[g]][rsp_piece[g]] <= 3'(g + 1);
        end
      end
      if (allocate) begin
        if (occupied == 0 || (deliver_last && !occupied[!oldest_slot])) oldest_slot <= slot;
        next_block[source] <= next_block[source] + 1'b1;
        owner[slot] <= source;
        block_idx[slot] <= next_block[source][4:0];
        occupied[slot] <= 1;
        sent[slot] <= 0;
        received[slot] <= 0;
        delivered[slot] <= 0;
      end
    end
  end
endmodule
