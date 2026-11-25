module blackwell_tma_data_path
  import blackwell_async_pkg::*;
  import blackwell_smem_pkg::*;
  import blackwell_tma_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic halt_i,
  input logic start_valid,
  output logic start_ready,
  input tma_start_t start_payload,
  input tma_tag_t tag_view[64],
  input tma_owner_view_t owner_view[18],
  output logic [19:0] event_valid,
  output tma_xfer_event_t event_payload[20],
  output logic [63:0] data_ref,
  input logic gmem_req_ready,
  input logic gmem_rsp_valid,
  output logic gmem_req_valid,
  output logic gmem_rsp_ready,
  output gmem_req_t gmem_req_payload,
  input gmem_rsp_t gmem_rsp_payload,
  input logic [7:0] smem_req_ready,
  input logic [7:0] smem_rsp_valid,
  output logic [7:0] smem_req_valid,
  output logic [7:0] smem_rsp_ready,
  output smem_atom_req_t smem_req_payload[8],
  input smem_atom_rsp_t smem_rsp_payload[8],
  output logic drained,
  output logic fault
);
  typedef struct packed {
    logic valid, claimed, zero;
    key_t key;
    logic [56:0] line_addr;
    logic [63:0] ordinal;
  } row_t;
  row_t rows[16];
  logic rd_valid, q_valid, out_valid, read_held;
  logic [3:0] rd_slot, q_slot, out_slot, free_slot, pick_rd;
  logic [7:0] pending, submitted;
  logic [7:0][127:0] out_data;
  logic [7:0] read_enable, write_enable;
  logic [7:0][3:0] read_addr, write_addr;
  logic [7:0][15:0] write_byte_mask;
  logic [7:0][127:0] read_q, write_data;
  blackwell_banked_sram #(
    .BANKS (8),
    .DEPTH (16),
    .WORD_W(128)
  ) ram (
    .*
  );
  key_t read_key, return_key, out_key;
  logic [56:0] read_line;
  logic [ 7:0] outstanding_reads;
  logic [ 4:0] free_count;
  logic
      stores_present,
      read_fire,
      write_fire,
      load_reply,
      reply_bad,
      load_write,
      slot_requested,
      choose_start;
  logic room_for_start, reply_alloc;
  logic slot_turn, write_turn, gmem_turn, gmem_locked, gmem_lock_store, gmem_store;
  logic [7:0] smem_turn, smem_lock, smem_lock_store, smem_store, smem_bad, smem_store_return;
  logic [7:0][3:0] store_selected, smem_lock_slot, return_slot;
  ticket_t group_rr[8], rd_store_rr;
  logic [3:0] rd_load_rr;
  logic rd_store_turn, pick_store;
  logic output_retire, out_space, q_space, rd_space, rd_found;
  tma_tag_t out_tag, return_tag;
  logic [7:0] read_rsp_groups;

  always_comb begin
    free_count = 0;
    free_slot = 0;
    data_ref = 0;
    stores_present = 0;
    for (int i = 15; i >= 0; i--) begin
      if (!rows[i].valid) begin
        free_count++;
        free_slot = 4'(i);
      end else begin
        data_ref[rows[i].key.tag] = 1;
        stores_present |= owner_view[tag_view[rows[i].key.tag].ticket].store;
      end
    end
    if (read_held) data_ref[read_key.tag] = 1;
    drained = free_count == 16 && !read_held && !rd_valid && !q_valid && !out_valid;
  end
  assign out_key = rows[out_slot].key;
  assign out_tag = tag_view[out_key.tag];
  assign return_key = {gmem_rsp_payload.id.tag, gmem_rsp_payload.id.phase};
  assign return_tag = tag_view[return_key.tag];
  function automatic logic [7:0] row_byte(input logic [7:0][127:0] data, input logic [6:0] offset,
                                          input logic [2:0] xor_group);
    return data[3'(offset[6:4]^xor_group)][8*offset[3:0]+:8];
  endfunction
  always_comb begin
    logic store_offer;
    store_offer = out_valid && owner_view[out_tag.ticket].store;
    gmem_store = gmem_locked ? gmem_lock_store : store_offer && (!read_held || gmem_turn);
    gmem_req_valid = (store_offer || read_held) && !fault;
    gmem_req_payload = '0;
    gmem_req_payload.op = 3'(gmem_store);
    if (gmem_store) begin
      gmem_req_payload.id = '{cls: 0, tag: out_key.tag, phase: out_key.phase};
      gmem_req_payload.addr = {rows[out_slot].line_addr, 7'b0};
      gmem_req_payload.byte_mask = line_mask(out_tag);
      gmem_req_payload.cache_policy = owner_view[out_tag.ticket].cache_policy;
      for (int k = 0; k < 128; k++) begin
        if (gmem_req_payload.byte_mask[k])
          gmem_req_payload.data[8*k+:8] = row_byte(
            out_data, 7'(k) - out_tag.goff + out_tag.soff, out_tag.xor_group
          );
      end
    end else begin
      gmem_req_payload.id = '{cls: 0, tag: read_key.tag, phase: read_key.phase};
      gmem_req_payload.addr = {read_line, 7'b0};
      gmem_req_payload.byte_mask = line_mask(tag_view[read_key.tag]);
      gmem_req_payload.cache_policy = owner_view[tag_view[read_key.tag].ticket].cache_policy;
    end
  end
  assign read_fire = gmem_req_valid && gmem_req_ready && !gmem_store;
  assign write_fire = gmem_req_valid && gmem_req_ready && gmem_store;

  // A ticket is chosen in cyclic order. The minimum ordinal breaks ties
  // only among rows belonging to that ticket.
  function automatic logic [5:0] ticket_distance(input ticket_t candidate, cursor);
    return candidate >= cursor ? 6'(candidate) - 6'(cursor) : 6'd18 + 6'(candidate) - 6'(cursor);
  endfunction
  always_comb begin
    for (int g = 0; g < 8; g++) begin
      logic found, load_offer;
      logic [5:0] best, distance;
      logic [63:0] best_ordinal;
      key_t key;
      tma_tag_t tag;
      logic [3:0] s;
      found = 0;
      s = 0;
      best = '1;
      best_ordinal = '1;
      for (int i = 0; i < 16; i++) begin
        tag = tag_view[rows[i].key.tag];
        distance = ticket_distance(tag.ticket, group_rr[g]);
        if (rows[i].valid && owner_view[tag.ticket].store && (|group_mask(
                tag, 3'(g)
            )) && !tag.smem_sent[g] && (!found || distance < best ||
                                        (distance == best && rows[i].ordinal < best_ordinal))) begin
          found = 1;
          s = 4'(i);
          best = distance;
          best_ordinal = rows[i].ordinal;
        end
      end
      load_offer = out_valid && !owner_view[out_tag.ticket].store && pending[g];
      smem_store[g] = smem_lock[g] ? smem_lock_store[g] : found && (!load_offer || smem_turn[g]);
      if (smem_lock[g]) s = smem_lock_slot[g];
      store_selected[g] = s;
      smem_req_valid[g] = !fault && (found || load_offer);
      key = smem_store[g] ? rows[s].key : out_key;
      tag = tag_view[key.tag];
      smem_req_payload[g].write = !smem_store[g];
      smem_req_payload[g].tag.id = owner_view[tag.ticket].id;
      smem_req_payload[g].tag.client = 8;
      smem_req_payload[g].tag.token = {6'b0, key.tag, 3'(g), key.phase};
      smem_req_payload[g].addr = {14'b0, tag.sector, 3'(g), 4'b0};
      smem_req_payload[g].byte_mask = group_mask(tag, 3'(g));
      smem_req_payload[g].data = smem_store[g] ? '0 : out_data[g];

    end
  end
  assign submitted = smem_req_valid & smem_req_ready & ~smem_store;
  always_comb begin
    logic [5:0] best, distance;
    logic [63:0] best_ordinal;
    logic store_found, load_found, load_after_cursor;
    logic [3:0] store_slot, first_load, next_load;
    output_retire = out_valid &&
        (owner_view[out_tag.ticket].store ? write_fire : (submitted & pending) == pending);
    out_space = !out_valid || output_retire;
    q_space = !q_valid || out_space;
    rd_space = !rd_valid || q_space;
    store_found = 0;
    store_slot = 0;
    best = '1;
    best_ordinal = '1;
    load_found = 0;
    load_after_cursor = 0;
    first_load = 0;
    next_load = 0;
    for (int i = 15; i >= 0; i--) begin
      tma_tag_t tag;
      tag = tag_view[rows[i].key.tag];
      distance = ticket_distance(tag.ticket, rd_store_rr);
      if (rows[i].valid && !rows[i].claimed && tag.source_done) begin
        if (owner_view[tag.ticket].store) begin
          if (!store_found || distance < best ||
              (distance == best && rows[i].ordinal < best_ordinal)) begin
            store_found = 1;
            store_slot = 4'(i);
            best = distance;
            best_ordinal = rows[i].ordinal;
          end
        end else begin
          // Descending scan retains the lowest ready slot in each range.
          load_found = 1;
          first_load = 4'(i);
          if (4'(i) >= rd_load_rr) begin
            load_after_cursor = 1;
            next_load = 4'(i);
          end
        end
      end
    end
    rd_found = load_found || store_found;
    pick_store = store_found && (!load_found || rd_store_turn);
    pick_rd = pick_store ? store_slot : (load_after_cursor ? next_load : first_load);
    for (int g = 0; g < 8; g++) begin
      read_enable[g] = rst_n && !halt_i && !fault && rd_valid && q_space && !rows[rd_slot].zero;
      read_addr[g] = rd_slot;
    end
  end
  always_comb begin
    logic store_return_competes, start_alloc;
    reply_bad = gmem_rsp_payload.id.cls != 0 || return_tag.state inside {TAG_FREE, RETIRE} ||
        return_tag.phase != return_key.phase || !return_tag.gmem_sent || return_tag.gmem_done ||
        gmem_rsp_payload.status != OK;
    load_reply = gmem_rsp_valid && !reply_bad && !owner_view[return_tag.ticket].store;
    read_rsp_groups = active_groups(return_tag);
    store_return_competes = 0;
    for (int g = 0; g < 8; g++) begin
      logic [15:0] token;
      key_t key;
      tma_tag_t t;
      logic found;
      token = smem_rsp_payload[g].tag.token;
      key = '{tag: token[9:4], phase: token[0]};
      t = tag_view[key.tag];
      found = 0;
      return_slot[g] = 0;
      for (int i = 0; i < 16; i++)
      if (rows[i].valid && rows[i].key == key) begin
        found = 1;
        return_slot[g] = 4'(i);
      end
      smem_store_return[g] = owner_view[t.ticket].store;
      smem_bad[g] = token[15:10] != 0 || token[3:1] != 3'(g) ||
          smem_rsp_payload[g].tag.client != 8 || t.state inside {TAG_FREE, RETIRE} ||
          t.phase != key.phase || !t.smem_sent[g] || t.smem_done[g] ||
          smem_rsp_payload[g].tag.id != owner_view[t.ticket].id ||
          smem_rsp_payload[g].write == smem_store_return[g] || smem_rsp_payload[g].status != OK ||
          (smem_store_return[g] && !found);
      store_return_competes |= read_rsp_groups[g] && smem_rsp_valid[g] && !smem_bad[g] &&
          smem_store_return[g];
    end
    slot_requested = start_payload.segment.store ^ start_payload.segment.oob;
    room_for_start = free_count != 0;
    if (start_payload.segment.store || stores_present)
      room_for_start &= 8'(free_count) > outstanding_reads;
    start_alloc = start_valid && slot_requested && room_for_start;
    reply_alloc = load_reply && free_count != 0 && (!store_return_competes || write_turn);
    choose_start = start_alloc && (!reply_alloc || slot_turn);
    gmem_rsp_ready = rst_n && !fault && (!load_reply || (reply_alloc && !choose_start));
    load_write = load_reply && gmem_rsp_ready;
    for (int g = 0; g < 8; g++) begin
      tma_tag_t t;
      t = tag_view[smem_rsp_payload[g].tag.token[9:4]];
      smem_rsp_ready[g] = rst_n && !fault &&
          (smem_bad[g] || !smem_store_return[g] || !(load_write && read_rsp_groups[g]));
      write_enable[g] = !halt_i && load_write && read_rsp_groups[g];
      write_addr[g] = free_slot;
      write_byte_mask[g] = group_mask(return_tag, 3'(g));
      write_data[g] = 0;
      for (int k = 0; k < 16; k++) begin
        logic [6:0] src;
        src = {(3'(g) ^ return_tag.xor_group), 4'(k)} - return_tag.soff + return_tag.goff;
        write_data[g][8*k+:8] = gmem_rsp_payload.data[8*src+:8];
      end
      if (smem_rsp_valid[g] && smem_rsp_ready[g] && !smem_bad[g] && smem_store_return[g]) begin
        write_enable[g] = !halt_i;
        write_addr[g] = return_slot[g];
        write_byte_mask[g] = group_mask(t, 3'(g));
        write_data[g] = smem_rsp_payload[g].data;
      end
    end
  end
  always_comb begin
    if (slot_requested) start_ready = room_for_start && (!reply_alloc || slot_turn);
    else if (start_payload.segment.store) start_ready = 1;
    else
      start_ready = (!read_held || read_fire) &&
          (!stores_present || 8'(free_count) > outstanding_reads);
    start_ready &= rst_n && !fault;
  end
  always_comb begin
    event_valid = 0;
    for (int i = 0; i < 20; i++) event_payload[i] = '0;
    event_valid[0] = read_fire || write_fire;
    event_payload[0] = '{
        key: {gmem_req_payload.id.tag, gmem_req_payload.id.phase},
        kind: GMEM_REQ,
        grp: 0
    };
    event_valid[1] = gmem_rsp_valid && gmem_rsp_ready && !reply_bad;
    event_payload[1] = '{key: return_key, kind: GMEM_RSP, grp: 0};
    for (int g = 0; g < 8; g++) begin
      event_valid[2+g] = smem_req_valid[g] && smem_req_ready[g];
      event_valid[10+g] = smem_rsp_valid[g] && smem_rsp_ready[g] && !smem_bad[g];
      event_payload[2+g] = '{
          key: {smem_req_payload[g].tag.token[9:4], smem_req_payload[g].tag.token[0]},
          kind: SMEM_REQ,
          grp: 3'(g)
      };
      event_payload[10+g] = '{
          key: {smem_rsp_payload[g].tag.token[9:4], smem_rsp_payload[g].tag.token[0]},
          kind: SMEM_RSP,
          grp: 3'(g)
      };
    end
    event_valid[18] = start_valid && start_ready && start_payload.segment.oob &&
        !start_payload.segment.store;
    event_valid[19] = start_valid && start_ready && start_payload.segment.oob &&
        start_payload.segment.store;
    event_payload[18] = '{key: start_payload.key, kind: LOCAL_ZERO, grp: 0};
    event_payload[19] = '{key: start_payload.key, kind: NO_ACCESS, grp: 0};
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < 16; i++) rows[i].valid <= 0;
      for (int g = 0; g < 8; g++) group_rr[g] <= 0;
      rd_valid <= 0;
      q_valid <= 0;
      out_valid <= 0;
      fault <= 0;
      read_held <= 0;
      rd_load_rr <= 0;
      rd_store_rr <= 0;
      rd_store_turn <= 0;
      outstanding_reads <= 0;
      slot_turn <= 0;
      write_turn <= 0;
      gmem_turn <= 0;
      gmem_locked <= 0;
      smem_turn <= 0;
      smem_lock <= 0;
    end else if (!halt_i && !fault) begin
      logic accept_read;
      accept_read = start_valid && start_ready && !start_payload.segment.store &&
          !start_payload.segment.oob;
      outstanding_reads <= outstanding_reads + 8'(accept_read) - 8'(load_write);
      if (gmem_req_valid) begin
        gmem_locked <= !gmem_req_ready;
        gmem_lock_store <= gmem_store;
        if (gmem_req_ready) gmem_turn <= !gmem_store;
      end
      if (read_fire) read_held <= 0;
      if (accept_read) begin
        read_held <= 1;
        read_key <= start_payload.key;
        read_line <= start_payload.segment.gmem_line[63:7];
      end
      if (start_valid && start_ready && slot_requested) begin
        rows[free_slot] <= '{
            valid: 1,
            claimed: 0,
            zero: start_payload.segment.oob,
            key: start_payload.key,
            line_addr: start_payload.segment.gmem_line[63:7],
            ordinal: start_payload.segment.ordinal
        };
        slot_turn <= 0;
      end
      if (load_write) begin
        rows[free_slot] <= '{
            valid: 1,
            claimed: 0,
            zero: 0,
            key: return_key,
            line_addr: '0,
            ordinal: '0
        };
        slot_turn <= 1;
        write_turn <= 0;
      end
      if (gmem_rsp_valid && gmem_rsp_ready && reply_bad) fault <= 1;
      if (rd_space) begin
        rd_valid <= rd_found;
        rd_slot <= pick_rd;
        if (rd_found) begin
          rows[pick_rd].claimed <= 1;
          rd_store_turn <= !pick_store;
          if (pick_store)
            rd_store_rr <= tag_view[rows[pick_rd].key.tag].ticket == 17 ? 0 :
                tag_view[rows[pick_rd].key.tag].ticket + 5'd1;
          else rd_load_rr <= pick_rd + 4'd1;
        end
      end
      if (q_space) begin
        q_valid <= rd_valid;
        q_slot <= rd_slot;
      end
      if (output_retire) rows[out_slot].valid <= 0;
      if (out_space) begin
        out_valid <= q_valid;
        out_slot <= q_slot;
        pending <= active_groups(tag_view[rows[q_slot].key.tag]);
        out_data <= rows[q_slot].zero ? '0 : read_q;
      end else pending <= pending & ~submitted;
      for (int g = 0; g < 8; g++) begin
        if (smem_req_valid[g]) begin
          smem_lock[g] <= !smem_req_ready[g];
          smem_lock_store[g] <= smem_store[g];
          smem_lock_slot[g] <= store_selected[g];
          if (smem_req_ready[g]) begin
            smem_turn[g] <= !smem_store[g];
            if (smem_store[g])
              group_rr[g] <= tag_view[rows[store_selected[g]].key.tag].ticket == 17 ? 0 :
                  tag_view[rows[store_selected[g]].key.tag].ticket + 5'd1;
          end
        end
        if (smem_rsp_valid[g] && smem_rsp_ready[g]) begin
          if (smem_bad[g]) fault <= 1;
          else if (smem_store_return[g] && read_rsp_groups[g]) write_turn <= 1;
        end
      end
    end
  end
endmodule
