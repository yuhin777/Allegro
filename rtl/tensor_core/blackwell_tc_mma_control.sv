// Ancillary issue ports can choose different records. A presented choice is
// held independently until its consumer accepts it, including during halt.
module blackwell_tc_record_select (
  input logic clk,
  input logic rst_n,
  input logic halt,
  input blackwell_async_pkg::mma_live_t [2:0] live,
  input logic [2:0] eligible,
  output logic valid,
  output logic [1:0] rec,
  input logic ready
);
  logic locked;
  logic [1:0] saved;
  always_comb begin
    valid = locked;
    rec = locked ? saved : 0;
    for (int age = 2; age >= 0; age--) begin
      if (!halt && !locked && live[age].valid && eligible[live[age].rec]) begin
        valid = 1;
        rec = live[age].rec;
      end
    end
  end
  always_ff @(posedge clk) begin
    if (!rst_n) locked <= 0;
    else begin
      locked <= valid && !ready;
      if (valid && !ready) saved <= rec;
    end
  end
endmodule

module blackwell_tc_mma_control
  import blackwell_async_pkg::*;
  import blackwell_tc_pkg::*;
  import blackwell_tmem_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic halt_i,
  input logic stop_i,
  input logic [15:0] epoch_i,
  output logic idle_o,
  output logic drained_o,
  output logic fault_o,
  input logic cmd_valid,
  output logic cmd_ready,
  input mma_cmd_t cmd_payload,
  output logic done_valid,
  input logic done_ready,
  output op_done_t done_payload,
  output logic pin_req_valid,
  input logic pin_req_ready,
  output tmem_pin_req_t pin_req_payload,
  input logic pin_rsp_valid,
  output logic pin_rsp_ready,
  input op_done_t pin_rsp_payload,
  output logic unpin_valid,
  input logic unpin_ready,
  output tmem_unpin_t unpin_payload,
  output logic [3:0] prepare_valid,
  input logic [3:0] prepare_ready,
  output prepare_t prepare_payload[4],
  output logic [3:0] b_select_valid,
  input logic [3:0] b_select_ready,
  output b_select_t b_select_payload[4],
  output logic first_valid,
  output async_id_t first_id,
  output logic launch,
  input logic [3:0] first_ready,
  input logic [3:0][2:0] input_free,
  input logic [3:0][2:0] writes_done,
  input logic [3:0] local_done_valid,
  output logic [3:0] local_done_ready,
  input op_done_t local_done_payload[4],
  output mma_live_t [2:0] live_o,
  output logic [2:0][3:0] older_writes_clear,
  output logic start_valid,
  input logic start_ready,
  output prepare_t start_payload,
  output logic release_valid,
  input logic release_ready,
  output async_id_t release_payload,
  input logic [2:0] snapshot_ready,
  input logic [2:0] quiescent,
  output logic load_valid,
  input logic load_ready,
  output b_load_t load_payload,
  input logic result_valid,
  output logic result_ready,
  input op_done_t result_payload
);
  typedef struct packed {
    mma_cmd_t cmd;
    logic valid, checked, pin_sent, pinned, bank_bound, bank;
    logic classified, hit, load_sent, installed, assigned, launched;
    logic [1:0] base_part;
    logic snap_started, sources_done, terminal, reported;
    logic [3:0] prepared, selected, finished;
  } record_t;
  record_t rec_q[3], rec_d[3];
  typedef struct packed {
    logic valid;
    logic [89:0] key;
    logic [1:0] base_part, n_code;
    async_id_t owner;
    logic [1:0] rank;
  } resident_t;
  resident_t resident_q[4], resident_d[4];
  logic [15:0] previous_epoch;
  logic [2:0][1:0] order_q, order_d;
  logic [1:0] count_q, count_d;
  logic halt, fault_d;
  assign halt = halt_i || fault_o;
  assign idle_o = count_q == 0;
  assign drained_o = idle_o;

  function automatic int k_size(logic [2:0] kind);
    case (kind)
      0: return 16;
      1: return 8;
      5, 6: return 64;
      default: return 32;
    endcase
  endfunction
  function automatic logic [89:0] key(mma_cmd_t c);
    return {c.id.epoch, c.b_desc, c.b_type, c.kind, c.transpose_b, c.n_code};
  endfunction
  function automatic logic [3:0] partitions(logic [1:0] base, n_code);
    case (n_code)
      0: return 4'b0001 << base;
      1: return 4'b0011 << base;
      default: return 4'b1111;
    endcase
  endfunction
  function automatic logic desc_ok(mma_cmd_t c, logic side_b);
    b_load_t src;
    logic [63:0] d, last_bit;
    int rows, bits_per_element, period, start, phase;
    src.id = c.id;
    src.desc = side_b ? c.b_desc : c.a_ref;
    src.dtype = side_b ? c.b_type : c.a_type;
    src.kind = c.kind;
    src.transpose = side_b ? c.transpose_b : c.transpose_a;
    src.n_code = c.n_code;
    d = src.desc;
    bits_per_element = element_bits(src.dtype);
    if (d[15:14] != 0 || d[31:30] != 0 || d[48:46] != 1 || d[60:52] != 0) return 0;
    case (d[63:61])
      0: begin
        if (d[51:49] != 0) return 0;
        period = 1;
      end
      1, 4: period = 512;
      2: period = 1024;
      6: period = 256;
      default: return 0;
    endcase
    start = int'(d[13:0]) * 16;
    phase = int'(d[51:49]) * 128;
    if (start < phase && phase < ((phase - start + period - 1) / period) * period) return 0;
    if (src.transpose && (bits_per_element < 8 || ((bits_per_element == 32) != (d[63:61] == 1))))
      return 0;
    rows = side_b ? (64 << c.n_code) : 128;
    // Legal dimensions contain whole swizzle stripes or a single partial
    // stripe. All index coefficients are nonnegative. The last coordinate
    // maximizes the unswizzled address, and XOR never crosses a 4 KiB page.
    last_bit = source_bit(src, rows - 1, k_size(c.kind) - 1, bits_per_element - 1);
    return (last_bit >> 3) < 64'd233472;
  endfunction
  function automatic logic cmd_ok(mma_cmd_t c);
    int n, acols, lanes;
    n = 64 << c.n_code;
    if (c.n_code == 3 || c.id.epoch != epoch_i) return 0;
    case (c.kind)
      0: if (c.a_type > 1 || c.b_type > 1) return 0;
      1: if (c.a_type != 2 || c.b_type != 2) return 0;
      2, 4: if (c.a_type < 3 || c.a_type > 7 || c.b_type < 3 || c.b_type > 7) return 0;
      3:
      if (!(c.a_type inside {8, 9}) || !(c.b_type inside {8, 9}) || c.negate_a || c.negate_b)
        return 0;
      5, 6: if (c.a_type != 7 || c.b_type != 7 || c.transpose_a || c.transpose_b) return 0;
      default: return 0;
    endcase
    if ((c.int_sat && c.kind != 3) || (c.scale_input_d != 0 && (c.ws || c.kind > 1)) ||
        (c.collector_buffer != 0 && !c.ws) || ((c.ws || c.kind >= 4) && c.disable_lane_mask != 0))
      return 0;
    if (c.kind < 4) begin
      if ({c.scale_type, c.scale_vec, c.scale_a_id, c.scale_b_id, c.scale_a, c.scale_b} != 0)
        return 0;
    end else begin
      if (c.ws || c.scale_a > 508 || c.scale_b[31:16] != 0 || int'(c.scale_b[15:0]) > 512 - n / 32)
        return 0;
      case (c.kind)
        4: if (c.scale_type || c.scale_vec != 1) return 0;
        5, 6:
        if (c.scale_type ? (c.kind != 6 || c.scale_vec != 3 || c.scale_a_id != 0 || c.scale_b_id !=
                            0) : (c.scale_vec != 2 || c.scale_a_id[0] || c.scale_b_id[0]))
          return 0;
        default: return 0;
      endcase
    end
    if (c.d_tmem > 512 - n || !desc_ok(c, 1)) return 0;
    if (c.a_from_tmem) begin
      acols = tmem_a_columns(c);
      lanes = c.transpose_a ? k_size(c.kind) : 128;
      if (c.a_ref[63:32] != 0 || int'(c.a_ref[31:16]) > 128 - lanes ||
          int'(c.a_ref[15:0]) > 512 - acols)
        return 0;
    end else if (!desc_ok(c, 0)) return 0;
    return 1;
  endfunction
  function automatic logic overlaps(int a, aw, b, bw);
    return a < b + bw && b < a + aw;
  endfunction
  for (genvar a = 0; a < 3; a++) begin : g_live
    assign live_o[a] = {int'(count_q) > a, order_q[a], rec_q[order_q[a]].cmd.id};
  end
  always_comb begin
    older_writes_clear = '1;
    for (int a = 0; a < 3; a++) begin
      for (int b = 0; b < a; b++) begin
        mma_cmd_t young, old;
        int old_w, old_base, awidth;
        logic writes_clear;
        young = rec_q[order_q[a]].cmd;
        old = rec_q[order_q[b]].cmd;
        old_w = 64 << old.n_code;
        old_base = int'(old.d_tmem);
        awidth = tmem_a_columns(young);
        writes_clear = 1;
        for (int c = 0; c < 4; c++)
        writes_clear &= writes_done[c][order_q[b]] || rec_q[order_q[b]].finished[c];
        if (live_o[a].valid && !writes_clear && !(&old.disable_lane_mask)) begin
          if (young.a_from_tmem && overlaps(old_base, old_w, int'(young.a_ref[15:0]), awidth))
            older_writes_clear[order_q[a]][0] = 0;
          if (young.kind >= 4 && overlaps(old_base, old_w, int'(young.scale_a), 4))
            older_writes_clear[order_q[a]][1] = 0;
          if (young.kind >= 4 && overlaps(
                  old_base, old_w, int'(young.scale_b), (64 << young.n_code) / 32
              ))
            older_writes_clear[order_q[a]][2] = 0;
          if (old_base != int'(young.d_tmem) && overlaps(
                  old_base, old_w, int'(young.d_tmem), 64 << young.n_code
              ))
            older_writes_clear[order_q[a]][3] = 0;
        end
      end
    end
  end
  logic [2:0]
      pin_candidates,
      unpin_candidates,
      done_candidates,
      snap_candidates,
      release_candidates,
      load_candidates;
  logic [2:0] source_free, freeing;
  logic [1:0] pin_rec, unpin_rec, done_rec, snap_rec, release_rec, load_rec;
  logic [1:0] bank_rec, lookup_rec, assign_rec, first_rec;
  logic bank_offer, bank_number, lookup_valid, assign_valid;
  logic [1:0] occupied_banks;
  logic [3:0][2:0] prep_candidates, sel_candidates;
  logic [3:0][1:0] prep_rec, sel_rec;

  for (genvar i = 0; i < 3; i++) begin : g_eligible
    assign source_free[i] = rec_q[i].bank_bound && rec_q[i].launched && input_free[0][i] &&
        input_free[1][i] && input_free[2][i] && input_free[3][i];
    assign release_candidates[i] = source_free[i] && rec_q[i].snap_started && quiescent[i];
    assign freeing[i] = rec_q[i].bank_bound &&
        (rec_q[i].cmd.kind < 4 ?
         source_free[i] : (release_valid && release_ready && release_rec == i));
    assign pin_candidates[i] = rec_q[i].checked && !rec_q[i].pin_sent;
    assign unpin_candidates[i] = rec_q[i].pinned && (&rec_q[i].finished) &&
        (rec_q[i].sources_done || freeing[i]) && (rec_q[i].installed || rec_q[i].hit);
    assign done_candidates[i] = rec_q[i].terminal && !rec_q[i].reported;
    assign snap_candidates[i] = rec_q[i].bank_bound && rec_q[i].cmd.kind >= 4 &&
        !rec_q[i].snap_started && older_writes_clear[i][2];
    assign load_candidates[i] = rec_q[i].classified && !rec_q[i].hit && !rec_q[i].load_sent;
  end
  blackwell_tc_record_select pin_pick (
    .clk,
    .rst_n,
    .halt,
    .live(live_o),
    .eligible(pin_candidates),
    .valid(pin_req_valid),
    .rec(pin_rec),
    .ready(pin_req_ready)
  );
  blackwell_tc_record_select unpin_pick (
    .clk,
    .rst_n,
    .halt,
    .live(live_o),
    .eligible(unpin_candidates),
    .valid(unpin_valid),
    .rec(unpin_rec),
    .ready(unpin_ready)
  );
  blackwell_tc_record_select done_pick (
    .clk,
    .rst_n,
    .halt,
    .live(live_o),
    .eligible(done_candidates),
    .valid(done_valid),
    .rec(done_rec),
    .ready(done_ready)
  );
  blackwell_tc_record_select snapshot_pick (
    .clk,
    .rst_n,
    .halt,
    .live(live_o),
    .eligible(snap_candidates),
    .valid(start_valid),
    .rec(snap_rec),
    .ready(start_ready)
  );
  blackwell_tc_record_select release_pick (
    .clk,
    .rst_n,
    .halt,
    .live(live_o),
    .eligible(release_candidates),
    .valid(release_valid),
    .rec(release_rec),
    .ready(release_ready)
  );
  blackwell_tc_record_select load_pick (
    .clk,
    .rst_n,
    .halt,
    .live(live_o),
    .eligible(load_candidates),
    .valid(load_valid),
    .rec(load_rec),
    .ready(load_ready)
  );
  assign pin_req_payload = {rec_q[pin_rec].cmd.id, 1'b0, pin_rec};
  assign unpin_payload = {rec_q[unpin_rec].cmd.id, 1'b0, unpin_rec};
  assign done_payload = {rec_q[done_rec].cmd.id, OK};
  assign start_payload = {snap_rec, rec_q[snap_rec].bank, rec_q[snap_rec].cmd};
  assign release_payload = rec_q[release_rec].cmd.id;
  assign load_payload = {
    rec_q[load_rec].cmd.id,
    rec_q[load_rec].cmd.b_desc,
    rec_q[load_rec].cmd.b_type,
    rec_q[load_rec].cmd.kind,
    rec_q[load_rec].cmd.transpose_b,
    rec_q[load_rec].cmd.n_code
  };
  assign pin_rsp_ready = !halt, result_ready = !halt, local_done_ready = {4{!halt}};

  always_comb begin
    occupied_banks = 0;
    for (int r = 0; r < 3; r++)
    if (rec_q[r].valid && rec_q[r].bank_bound && !freeing[r]) occupied_banks[rec_q[r].bank] = 1;
    bank_offer = 0;
    bank_rec = 0;
    bank_number = occupied_banks[0];
    lookup_valid = 0;
    lookup_rec = 0;
    assign_valid = 0;
    assign_rec = 0;
    first_valid = 0;
    first_rec = 0;
    for (int a = 2; a >= 0; a--) begin
      if (live_o[a].valid) begin
        if (!rec_q[order_q[a]].bank_bound && !rec_q[order_q[a]].sources_done) begin
          bank_rec = order_q[a];
          bank_offer = rec_q[order_q[a]].pinned && !(&occupied_banks) && !halt;
        end
        if (!rec_q[order_q[a]].classified) begin
          lookup_rec = order_q[a];
          lookup_valid = rec_q[order_q[a]].pinned && !halt;
        end
        if (!rec_q[order_q[a]].assigned) begin
          assign_rec = order_q[a];
          assign_valid = rec_q[order_q[a]].classified && !halt;
        end
        if (!rec_q[order_q[a]].launched) begin
          first_valid = !halt;
          first_rec = order_q[a];
        end
      end
    end
    first_id = rec_q[first_rec].cmd.id;
  end
  assign launch = first_valid && rec_q[first_rec].pinned && (&rec_q[first_rec].prepared) &&
      (&rec_q[first_rec].selected) &&
      (rec_q[first_rec].cmd.kind < 4 || snapshot_ready[first_rec]) && (&first_ready);

  for (genvar c = 0; c < 4; c++) begin : g_core
    for (genvar r = 0; r < 3; r++) begin : g_offer
      assign prep_candidates[c][r] = !rec_q[r].prepared[c] &&
          (rec_q[r].bank_bound || (bank_offer && bank_rec == r));
      assign sel_candidates[c][r] = rec_q[r].assigned && !rec_q[r].selected[c];
    end
    blackwell_tc_record_select prep_pick (
      .clk,
      .rst_n,
      .halt,
      .live(live_o),
      .eligible(prep_candidates[c]),
      .valid(prepare_valid[c]),
      .rec(prep_rec[c]),
      .ready(prepare_ready[c])
    );
    blackwell_tc_record_select select_pick (
      .clk,
      .rst_n,
      .halt,
      .live(live_o),
      .eligible(sel_candidates[c]),
      .valid(b_select_valid[c]),
      .rec(sel_rec[c]),
      .ready(b_select_ready[c])
    );
    assign prepare_payload[c] = {
      prep_rec[c],
      rec_q[prep_rec[c]].bank_bound ? rec_q[prep_rec[c]].bank : bank_number,
      rec_q[prep_rec[c]].cmd
    };
    assign b_select_payload[c] = {
      rec_q[sel_rec[c]].cmd.id,
      rec_q[sel_rec[c]].base_part,
      rec_q[sel_rec[c]].cmd.n_code,
      rec_q[sel_rec[c]].hit
    };
  end

  // Classify in program order. Until an older same-name operation has bound
  // its version, no later operation can decide whether that version hits.
  logic lookup_wait, hit;
  logic [1:0] lookup_name, assign_name;
  logic [3:0] busy_parts, protected_names;
  logic run_found, evict_found, assign_wait;
  logic [1:0] run_base, victim;
  always_comb begin
    lookup_wait = 0;
    lookup_name = rec_q[lookup_rec].cmd.collector_buffer;
    hit = rec_q[lookup_rec].cmd.ws && rec_q[lookup_rec].cmd.collector_op[1] &&
        resident_q[lookup_name].valid && resident_q[lookup_name].key == key(rec_q[lookup_rec].cmd);
    for (int r = 0; r < 3; r++) begin
      // An older miss may need to evict this exact version before it
      // can reserve a contiguous run. Only bind the prospective hit
      // after all earlier allocation decisions have taken effect.
      if (hit && rec_q[r].valid && rec_q[r].classified && !rec_q[r].assigned) lookup_wait = 1;
      if (r != int'(lookup_rec) && rec_q[r].valid && rec_q[r].classified && rec_q[r].cmd.ws &&
          rec_q[r].cmd.collector_buffer == lookup_name && rec_q[lookup_rec].cmd.ws &&
          (!rec_q[r].assigned || (!rec_q[r].installed && !rec_q[r].hit) ||
           (rec_q[r].hit && !rec_q[r].launched)))
        lookup_wait = 1;
    end
    assign_name = rec_q[assign_rec].cmd.collector_buffer;
    busy_parts = 0;
    protected_names = 0;
    for (int r = 0; r < 3; r++) begin
      if (rec_q[r].valid && rec_q[r].assigned && !rec_q[r].launched && rec_q[r].hit)
        protected_names[rec_q[r].cmd.collector_buffer] = 1;
      if (rec_q[r].valid && rec_q[r].assigned &&
          ((!rec_q[r].hit && !rec_q[r].installed) || (rec_q[r].hit && !rec_q[r].launched)))
        busy_parts |= partitions(rec_q[r].base_part, rec_q[r].cmd.n_code);
    end
    // A hit awaiting assignment keeps the resident version it matched.
    for (int r = 0; r < 3; r++)
    if (rec_q[r].valid && rec_q[r].hit && !rec_q[r].launched)
      protected_names[rec_q[r].cmd.collector_buffer] = 1;
    for (int n = 0; n < 4; n++)
    if (resident_q[n].valid)
      busy_parts |= partitions(resident_q[n].base_part, resident_q[n].n_code);
    run_found = 0;
    run_base = 0;
    for (int base = 3; base >= 0; base--) begin
      if (base + (1 << rec_q[assign_rec].cmd.n_code) <= 4 && (busy_parts & partitions(
              2'(base), rec_q[assign_rec].cmd.n_code
          )) == 0) begin
        run_found = 1;
        run_base = 2'(base);
      end
    end
    victim = 0;
    evict_found = 0;
    for (int n = 0; n < 4; n++) begin
      if (resident_q[n].valid && !protected_names[n] &&
          (!evict_found || resident_q[n].rank > resident_q[victim].rank)) begin
        evict_found = 1;
        victim = 2'(n);
      end
    end
    assign_wait = rec_q[assign_rec].cmd.ws && protected_names[assign_name] &&
        !rec_q[assign_rec].hit;
  end
  task automatic make_mru(inout resident_t ways[4], input logic [1:0] name, input logic is_new);
    logic [1:0] old_rank;
    old_rank = ways[name].rank;
    for (int n = 0; n < 4; n++)
      if (n != int'(name) && ways[n].valid && (is_new || ways[n].rank < old_rank) &&
          ways[n].rank != 3)
        ways[n].rank = ways[n].rank + 1'b1;
    ways[name].rank = 0;
  endtask
  // Removing a named version also closes the gap in the LRU stack.
  task automatic drop_name(inout resident_t ways[4], input logic [1:0] name);
    if (ways[name].valid) begin
      for (int n = 0; n < 4; n++)
      if (ways[n].valid && ways[n].rank > ways[name].rank) ways[n].rank = ways[n].rank - 1'b1;
      ways[name].valid = 0;
    end
  endtask
  logic [1:0] free_rec;
  logic reclaim;
  always_comb begin
    free_rec = 0;
    for (int r = 2; r >= 0; r--) if (!rec_q[r].valid) free_rec = 2'(r);
  end
  assign cmd_ready = !stop_i && !halt && count_q < 3;
  assign reclaim = count_q != 0 &&
      (rec_q[order_q[0]].reported || (done_valid && done_ready && done_rec == order_q[0]));
  always_comb begin
    logic pin_matched, result_matched, duplicate;
    logic [3:0] local_matched;
    logic [1:0] publish_name;
    pin_matched = 0;
    result_matched = 0;
    duplicate = 0;
    local_matched = 0;
    publish_name = 0;
    rec_d = rec_q;
    resident_d = resident_q;
    order_d = order_q;
    count_d = count_q;
    fault_d = fault_o;
    if (!halt) begin
      for (int r = 0; r < 3; r++) begin
        if (rec_q[r].valid && !rec_q[r].checked) begin
          if (cmd_ok(rec_q[r].cmd)) rec_d[r].checked = 1;
          else fault_d = 1;
        end
      end
    end
    if (pin_req_valid && pin_req_ready) rec_d[pin_rec].pin_sent = 1;
    if (pin_rsp_valid && pin_rsp_ready) begin
      for (int r = 0; r < 3; r++) begin
        if (rec_q[r].valid && rec_q[r].cmd.id == pin_rsp_payload.id && rec_q[r].pin_sent &&
            !rec_q[r].pinned && !rec_q[r].terminal && pin_rsp_payload.status == OK) begin
          rec_d[r].pinned = 1;
          pin_matched = 1;
        end
      end
      if (!pin_matched) fault_d = 1;
    end
    if (bank_offer) begin
      rec_d[bank_rec].bank_bound = 1;
      rec_d[bank_rec].bank = bank_number;
    end
    for (int r = 0; r < 3; r++)
    if (freeing[r]) begin
      rec_d[r].bank_bound = 0;
      rec_d[r].sources_done = 1;
    end
    if (start_valid && start_ready) rec_d[snap_rec].snap_started = 1;
    if (load_valid && load_ready) rec_d[load_rec].load_sent = 1;
    if (assign_valid && !assign_wait) begin
      if (rec_q[assign_rec].hit) begin
        if (resident_q[assign_name].valid && resident_q[assign_name].key == key(
                rec_q[assign_rec].cmd
            )) begin
          rec_d[assign_rec].assigned = 1;
          rec_d[assign_rec].base_part = resident_q[assign_name].base_part;
          resident_d[assign_name].owner = rec_q[assign_rec].cmd.id;
          make_mru(resident_d, assign_name, 0);
          if (rec_q[assign_rec].cmd.collector_op == 3) drop_name(resident_d, assign_name);
        end else rec_d[assign_rec].hit = 0;
      end else if (rec_q[assign_rec].cmd.ws && resident_q[assign_name].valid)
        drop_name(resident_d, assign_name);
      else if (run_found) begin
        rec_d[assign_rec].assigned = 1;
        rec_d[assign_rec].base_part = run_base;
      end else if (evict_found) drop_name(resident_d, victim);
    end
    if (lookup_valid && !lookup_wait) begin
      rec_d[lookup_rec].classified = 1;
      rec_d[lookup_rec].hit = hit && resident_d[lookup_name].valid;
    end
    if (result_valid && result_ready) begin
      for (int r = 0; r < 3; r++) begin
        if (rec_q[r].valid && rec_q[r].cmd.id == result_payload.id && rec_q[r].load_sent &&
            rec_q[r].assigned && (&rec_q[r].selected) && !rec_q[r].installed &&
            result_payload.status == OK) begin
          publish_name = rec_q[r].cmd.collector_buffer;
          result_matched = 1;
          rec_d[r].installed = 1;
          if (rec_q[r].cmd.ws && rec_q[r].cmd.collector_op inside {2'd1, 2'd2}) begin
            drop_name(resident_d, publish_name);
            make_mru(resident_d, publish_name, 1);
            resident_d[publish_name].valid = 1;
            resident_d[publish_name].key = key(rec_q[r].cmd);
            resident_d[publish_name].base_part = rec_q[r].base_part;
            resident_d[publish_name].n_code = rec_q[r].cmd.n_code;
            resident_d[publish_name].owner = rec_q[r].cmd.id;
          end
        end
      end
      if (!result_matched) fault_d = 1;
    end
    for (int c = 0; c < 4; c++) begin
      if (prepare_valid[c] && prepare_ready[c]) rec_d[prep_rec[c]].prepared[c] = 1;
      if (b_select_valid[c] && b_select_ready[c]) rec_d[sel_rec[c]].selected[c] = 1;
      if (local_done_valid[c] && local_done_ready[c]) begin
        for (int r = 0; r < 3; r++)
        if (rec_q[r].valid && rec_q[r].cmd.id == local_done_payload[c].id && rec_q[r].launched &&
            !rec_q[r].finished[c] && writes_done[c][r] && local_done_payload[c].status == OK) begin
          local_matched[c] = 1;
          rec_d[r].finished[c] = 1;
        end
        if (!local_matched[c]) fault_d = 1;
      end
    end
    if (launch) rec_d[first_rec].launched = 1;
    if (unpin_valid && unpin_ready) begin
      rec_d[unpin_rec].pinned = 0;
      rec_d[unpin_rec].terminal = 1;
    end
    if (done_valid && done_ready) rec_d[done_rec].reported = 1;
    if (reclaim) begin
      rec_d[order_q[0]].valid = 0;
      order_d = {2'd0, order_q[2], order_q[1]};
      count_d = count_q - 1'b1;
    end
    if (cmd_valid && cmd_ready) begin
      for (int r = 0; r < 3; r++) duplicate |= rec_q[r].valid && rec_q[r].cmd.id == cmd_payload.id;
      if (duplicate) fault_d = 1;
      else begin
        rec_d[free_rec] = '0;
        rec_d[free_rec].cmd = cmd_payload;
        rec_d[free_rec].valid = 1;
        order_d[count_d] = free_rec;
        count_d = count_d + 1'b1;
      end
    end
    if (previous_epoch != epoch_i) for (int n = 0; n < 4; n++) resident_d[n].valid = 0;
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      count_q <= 0;
      order_q <= 0;
      fault_o <= 0;
      previous_epoch <= 0;
      for (int r = 0; r < 3; r++) rec_q[r] <= '0;
      for (int n = 0; n < 4; n++) resident_q[n] <= '0;
    end else begin
      count_q <= count_d;
      order_q <= order_d;
      fault_o <= fault_d;
      previous_epoch <= epoch_i;
      rec_q <= rec_d;
      resident_q <= resident_d;
    end
  end
endmodule
