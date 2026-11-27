module blackwell_smem_fabric
  import blackwell_async_pkg::*;
  import blackwell_smem_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic [15:0] epoch_i,
  input mma_live_t live[3],
  input logic [15:0][7:0] rd_req_valid,
  input logic [15:0][7:0] wr_req_valid,
  input logic [15:0][7:0] rd_rsp_ready,
  input logic [15:0][7:0] wr_ack_ready,
  output logic [15:0][7:0] rd_req_ready,
  output logic [15:0][7:0] wr_req_ready,
  output logic [15:0][7:0] rd_rsp_valid,
  output logic [15:0][7:0] wr_ack_valid,
  input smem_rd_req_t rd_req_payload[16][8],
  input smem_wr_req_t wr_req_payload[16][8],
  output smem_rd_rsp_t rd_rsp_payload[16][8],
  output smem_wr_ack_t wr_ack_payload[16][8],
  output logic drained_o
);
  logic [31:0] read_enable, write_enable;
  logic [31:0][10:0] read_addr, write_addr;
  logic [31:0][31:0] read_q, write_data;
  logic [31:0][3:0] write_byte_mask;
  blackwell_banked_sram #(
    .BANKS (32),
    .DEPTH (1824),
    .WORD_W(32)
  ) ram (
    .*
  );
  logic [1:0] phase;
  logic [7:0] busy;
  assign drained_o = !(|busy);
  always_ff @(posedge clk)
    if (!rst_n) phase <= '0;
    else phase <= phase + 2'd1;

  for (genvar g = 0; g < 8; g++) begin : groups
    // Only the four A clients can multicast. External/B reads use the
    // primary destination. Each additional A receiver retains its own token.
    typedef struct packed {
      mem_tag_t tag;
      logic [15:0] mask;
      logic [3:0] extra;
      logic [3:0][15:0] tokens, masks;
    } destinations_t;
    typedef struct packed {
      destinations_t dest;
      logic [127:0]  data;
    } frame_t;
    destinations_t rdest, qdest, new_dest;
    logic [31:0] raddr;
    logic [15:0] rmask, new_mask;
    logic rvalid, qvalid, rp, wp, ap, aw;
    logic [1:0] ret_count, ack_count;
    frame_t returns[2];
    smem_wr_ack_t acks[2];
    logic [15:0] delivered, target_mask, handshakes;
    logic pop, ack_pop, q_move, grant, write_fire, capture;
    logic ext_turn, conflict_write, conflict;
    logic [3:0] rd_cursor, wr_cursor, reader, writer;
    logic [15:0] selected;
    logic rfound, wfound;
    logic [127:0] qdata;
    function automatic logic [1:0] age(input async_id_t id);
      for (int i = 0; i < 3; i++) if (live[i].valid && live[i].id == id) return 2'(i);
      return 2'd3;
    endfunction

    always_comb begin
      logic a_found, ext_found, prefer_b;
      logic [3:0] a_sel, ext_sel, c;
      logic [12:0] a_key, key;
      a_found = 0;
      a_sel = 0;
      a_key = '1;
      for (int i = 0; i < 4; i++) begin
        key = {
          age(rd_req_payload[i][g].tag.id),
          rd_req_payload[i][g].tag.token[12:8],
          2'(i),
          rd_req_payload[i][g].tag.token[7:4]
        };
        if (rd_req_valid[i][g] && (!a_found || key < a_key)) begin
          a_found = 1;
          a_key = key;
          a_sel = 4'(i);
        end
      end
      ext_found = 0;
      ext_sel = 0;
      writer = 0;
      wfound = 0;
      for (int n = 0; n < 16; n++) begin
        c = rd_cursor + 4'(n);
        if (!ext_found && c >= 4 && c != 6 && rd_req_valid[c][g]) begin
          ext_found = 1;
          ext_sel = c;
        end
        c = wr_cursor + 4'(n);
        if (!wfound && wr_req_valid[c][g]) begin
          wfound = 1;
          writer = c;
        end
      end
      // The request selected at g-1 grants at g in the unstalled case.
      prefer_b = (phase == 1 || phase == 2);
      if (ext_found && (ext_turn || !(a_found || rd_req_valid[6][g]))) reader = ext_sel;
      else if (rd_req_valid[6][g] && (prefer_b || !a_found)) reader = 6;
      else reader = a_sel;
      rfound = ext_found || a_found || rd_req_valid[6][g];
      selected = '0;
      new_dest = '0;
      new_dest.tag = rd_req_payload[reader][g].tag;
      new_dest.mask = rd_req_payload[reader][g].byte_mask;
      new_mask = new_dest.mask;
      selected[reader] = rfound;
      for (int i = 0; i < 4; i++) begin
        if (reader < 4 && reader != 4'(i) && rd_req_valid[i][g] && rd_req_payload[i][g].tag.id ==
            new_dest.tag.id && rd_req_payload[i][g].addr == rd_req_payload[reader][g].addr &&
            rd_req_payload[i][g].tag.token[15:8] == new_dest.tag.token[15:8]) begin
          selected[i] = 1;
          new_dest.extra[i] = 1;
          new_dest.tokens[i] = rd_req_payload[i][g].tag.token;
          new_dest.masks[i] = rd_req_payload[i][g].byte_mask;
          new_mask |= rd_req_payload[i][g].byte_mask;
        end
      end
    end
    always_comb begin
      target_mask = 16'(1) << returns[rp].dest.tag.client;
      target_mask[3:0] |= returns[rp].dest.extra;

      for (int i = 0; i < 16; i++) begin
        logic [15:0] mask;
        rd_rsp_valid[i][g] = ret_count != 0 && target_mask[i] && !delivered[i];
        rd_rsp_payload[i][g] = '0;
        rd_rsp_payload[i][g].tag = returns[rp].dest.tag;
        mask = returns[rp].dest.mask;
        if (i < 4 && returns[rp].dest.extra[i%4]) begin
          rd_rsp_payload[i][g].tag.client = 4'(i);
          rd_rsp_payload[i][g].tag.token = returns[rp].dest.tokens[i%4];
          mask = returns[rp].dest.masks[i%4];
        end
        for (int b = 0; b < 16; b++)
        if (mask[b]) rd_rsp_payload[i][g].data[b*8+:8] = returns[rp].data[b*8+:8];

        wr_ack_valid[i][g] = ack_count != 0 && acks[ap].tag.client == 4'(i);
        wr_ack_payload[i][g] = acks[ap];
      end
    end
    always_comb begin
      for (int i = 0; i < 16; i++) handshakes[i] = rd_rsp_valid[i][g] && rd_rsp_ready[i][g];
      pop = ret_count != 0 && ((delivered | handshakes) & target_mask) == target_mask;
      ack_pop = ack_count != 0 && wr_ack_ready[acks[ap].tag.client][g];
      q_move = qvalid && (ret_count < 2 || pop);
    end
    always_comb begin
      logic r_possible, w_possible;
      smem_wr_req_t w;
      w = wr_req_payload[writer][g];
      r_possible = rvalid && (!qvalid || q_move);
      w_possible = wfound && (ack_count < 2 || ack_pop);
      conflict = 0;
      for (int s = 0; s < 4; s++)
      conflict |= r_possible && w_possible && raddr[31:7] == w.addr[31:7] && (|rmask[4*s+:4]) &&
          (|w.byte_mask[4*s+:4]);
      grant = r_possible && (!conflict || !conflict_write);
      write_fire = w_possible && (!conflict || conflict_write);
      for (int i = 0; i < 16; i++) begin
        rd_req_ready[i][g] = rst_n && (!rvalid || grant) && selected[i];
        wr_req_ready[i][g] = rst_n && write_fire && writer == 4'(i);
      end
      capture = rfound && (!rvalid || grant) && rst_n;
      for (int s = 0; s < 4; s++) begin
        read_enable[4*g+s] = rst_n && grant && (|rmask[4*s+:4]);
        read_addr[4*g+s] = raddr[17:7];
        qdata[32*s+:32] = read_q[4*g+s];
        write_enable[4*g+s] = rst_n && write_fire && (|w.byte_mask[4*s+:4]);
        write_addr[4*g+s] = w.addr[17:7];
        write_byte_mask[4*g+s] = w.byte_mask[4*s+:4];
        write_data[4*g+s] = w.data[32*s+:32];
      end
    end
    assign busy[g] = rvalid || qvalid || ret_count != 0 || ack_count != 0;
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        rvalid <= 0;
        qvalid <= 0;
        rp <= 0;
        wp <= 0;
        ap <= 0;
        aw <= 0;
        ret_count <= 0;
        ack_count <= 0;
        delivered <= 0;
        rd_cursor <= 0;
        wr_cursor <= 0;
        ext_turn <= 0;
        conflict_write <= 0;
      end else begin
        if (grant) begin
          qdest <= rdest;
          rvalid <= 0;
        end
        if (capture) begin
          rvalid <= 1;
          rdest <= new_dest;
          raddr <= rd_req_payload[reader][g].addr;
          rmask <= new_mask;
          ext_turn <= reader < 4 || reader == 6;
          if (reader >= 4 && reader != 6) rd_cursor <= reader + 4'd1;
        end
        qvalid <= (qvalid && !q_move) || grant;
        if (q_move) begin
          returns[wp] <= '{dest: qdest, data: qdata};
          wp <= !wp;
        end
        if (pop) rp <= !rp;
        delivered <= pop ? '0 : delivered | handshakes;
        ret_count <= ret_count + 2'(q_move) - 2'(pop);
        if (write_fire) begin
          acks[aw] <= '{tag: wr_req_payload[writer][g].tag};
          aw <= !aw;
          wr_cursor <= writer + 4'd1;
        end
        if (ack_pop) ap <= !ap;
        ack_count <= ack_count + 2'(write_fire) - 2'(ack_pop);
        if (conflict) conflict_write <= !conflict_write;
      end
    end
`ifndef SYNTHESIS
    for (genvar i = 0; i < 16; i++) begin : check_request
      // An accepted broadcast enters each destination's stream independently.
      mem_tag_t read_tags[$], write_tags[$];
      always @(posedge clk) begin
        if (!rst_n) begin
          read_tags.delete();
          write_tags.delete();
        end else begin
          if (rd_rsp_valid[i][g]) begin
            assert (read_tags.size() > 0 && rd_rsp_payload[i][g].tag == read_tags[0]);
            if (rd_rsp_ready[i][g]) void'(read_tags.pop_front());
          end
          if (wr_ack_valid[i][g]) begin
            assert (write_tags.size() > 0 && wr_ack_payload[i][g].tag == write_tags[0]);
            if (wr_ack_ready[i][g]) void'(write_tags.pop_front());
          end
          if (rd_req_valid[i][g] && rd_req_ready[i][g])
            read_tags.push_back(rd_req_payload[i][g].tag);
          if (wr_req_valid[i][g] && wr_req_ready[i][g])
            write_tags.push_back(wr_req_payload[i][g].tag);
        end
      end
      always_ff @(posedge clk) begin
        if (rst_n && rd_req_valid[i][g])
          assert (rd_req_payload[i][g].addr[6:0] == {3'(g), 4'b0} &&
                  rd_req_payload[i][g].addr < 233472 && rd_req_payload[i][g].tag.client == 4'(i) &&
                  rd_req_payload[i][g].tag.id.epoch == epoch_i);
        if (rst_n && wr_req_valid[i][g])
          assert (wr_req_payload[i][g].addr[6:0] == {3'(g), 4'b0} &&
                  wr_req_payload[i][g].addr < 233472 && wr_req_payload[i][g].tag.client == 4'(i) &&
                  wr_req_payload[i][g].tag.id.epoch == epoch_i);
      end
    end
    assert property (@(posedge clk) disable iff (!rst_n) busy[g] |-> $stable(epoch_i));
`endif
  end
endmodule
