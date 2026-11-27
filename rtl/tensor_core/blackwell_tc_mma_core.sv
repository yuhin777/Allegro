module blackwell_tc_mma_core
  import blackwell_async_pkg::*;
  import blackwell_tc_pkg::*;
  import blackwell_smem_pkg::*;
  import blackwell_tmem_pkg::*;
  import blackwell_dot_pkg::operand_t;
  import blackwell_dot_pkg::result_t;
#(
  parameter int CORE = 0,
  parameter bit SHARE_FP_DOT_ADDER_TREE = 1
) (
  input logic clk,
  input logic rst_n,
  input logic [15:0] epoch_i,
  input mma_live_t [2:0] live_i,
  input logic [2:0][3:0] older_writes_clear,
  input logic prepare_valid,
  output logic prepare_ready,
  input prepare_t prepare_payload,
  input logic b_select_valid,
  output logic b_select_ready,
  input b_select_t b_select_payload,
  input logic first_id_valid,
  input async_id_t first_id,
  input logic launch,
  output logic first_ready,
  output logic [2:0] input_free,
  output logic [2:0] writes_done,
  output logic local_done_valid,
  input logic local_done_ready,
  output op_done_t local_done_payload,
  input logic data_valid,
  output logic data_ready,
  input b_data_t data_payload,
  output logic [7:0] sm_rd_req_valid,
  input logic [7:0] sm_rd_req_ready,
  output smem_rd_req_t sm_rd_req_payload[8],
  input logic [7:0] sm_rd_rsp_valid,
  output logic [7:0] sm_rd_rsp_ready,
  input smem_rd_rsp_t sm_rd_rsp_payload[8],
  output logic [127:0] tm_rd_req_valid,
  input logic [127:0] tm_rd_req_ready,
  output tmem_rd_req_t tm_rd_req_payload[128],
  input logic [127:0] tm_rd_rsp_valid,
  output logic [127:0] tm_rd_rsp_ready,
  input tmem_rd_rsp_t tm_rd_rsp_payload[128],
  output logic [127:0] tm_wr_req_valid,
  input logic [127:0] tm_wr_req_ready,
  output tmem_wr_req_t tm_wr_req_payload[128],
  input logic [127:0] tm_wr_ack_valid,
  output logic [127:0] tm_wr_ack_ready,
  input tmem_wr_ack_t tm_wr_ack_payload[128],
  output logic [71:0] sb_query,
  input logic [256:0] sb_view,
  output logic drained_o,
  output logic idle_o
);
  mma_cmd_t command[3];
  logic [2:0] bound, selected, bank, reported;
  logic [2:0][1:0] base_part;
  logic [2:0][5:0] installed, consumed, reserved_c, blocks;
  logic [2:0][1:0] row_cursor;
  logic [2:0][31:0] closed;
  logic [2:0][31:0][2:0][31:0] pending;
  logic [2:0][2:0] inflight;
  logic [31:0][2047:0] bmem;
  logic [1:0] context_active, context_bind, scale_ready;
  logic [1:0][1:0] context_rec;
  logic [1:0][3:0] a_ready;
  logic [1:0][31:0][255:0] rows;
  logic [1:0][31:0][31:0] scales;
  logic [1:0][7:0] as_valid, as_ready, as_ret, as_accept;
  logic [1:0][127:0] at_valid, at_ready, at_ret, at_accept;
  smem_rd_req_t as_req[2][  8];
  tmem_rd_req_t at_req[2][128];
  logic [7:0] sm_hold, sm_source;
  logic [127:0] tm_hold;
  logic [127:0][1:0] tm_source, tm_pick;
  logic [7:0] sm_pick;
  logic [1:0] current, bind_rec, deliver_rec, select_rec, done_rec, held_done;
  logic current_valid, deliver_match, select_match, done_lock;
  logic [1:0] c_active, d_active;
  logic [1:0][1:0] c_rec, d_rec;
  logic [1:0][4:0] c_block, d_block;
  logic [1:0][31:0][2:0] c_sent, c_recv, d_sent;
  logic [1:0][31:0][7:0][31:0] cbuf, dbuf;
  logic [1:0][3:0] d_rows;
  logic [1:0] c_reserve;
  logic [1:0][1:0] next_c_rec;
  logic [1:0][4:0] next_c_block;
  logic [31:0] cr_valid, cr_slot, w_slot;
  logic [31:0][1:0] cr_slice, w_slice;
  tmem_rd_req_t cr_req[32];
  logic [31:0] cr_lock, cr_held_slot, w_lock, w_held_slot;
  logic [31:0][1:0] cr_held_slice, w_held_slice;
  logic [1:0] d_finished;
  logic [1:0][31:0][2:0] d_next_sent;
  operand_t operand_payload;
  result_t result_payload;
  logic operand_valid, operand_ready, result_valid, result_ready, empty_o, op_load;
  logic [1:0] op_rec, result_rec;
  tile_tag_t result_tag;
  wire tile_tag_t operand_tag = operand_payload.tag;
  logic result_match, b_can_load, oldest_bank;
  wire mma_cmd_t dot_command = command[op_rec];
  blackwell_tc_dot_array #(
    .SHARE_FP_DOT_ADDER_TREE(SHARE_FP_DOT_ADDER_TREE)
  ) dot (
    .clk,
    .rst_n,
    .cmd_i(dot_command),
    .*
  );
  assign result_tag = result_payload.tag;
  assign idle_o = drained_o;
  assign drained_o = !(|bound) && !operand_valid && empty_o;
  always_comb begin
    bind_rec = prepare_payload.rec;
    prepare_ready = (!context_active[prepare_payload.bank] || input_free[context_rec[prepare_payload.bank]]);
    for (int b = 0; b < 2; b++)
    context_bind[b] = prepare_valid && prepare_ready && prepare_payload.bank == 1'(b);
    current_valid = 0;
    current = 0;
    deliver_match = 0;
    deliver_rec = 0;
    select_match = 0;
    select_rec = 0;
    done_rec = held_done;
    local_done_valid = done_lock;
    result_match = 0;
    result_rec = 0;
    oldest_bank = 0;
    for (int i = 2; i >= 0; i--) begin
      logic [1:0] r;
      r = live_i[i].rec;
      if (live_i[i].valid && bound[r] && live_i[i].id == command[r].id) begin
        if (consumed[r] < blocks[r]) begin
          current = r;
          current_valid = 1;
          oldest_bank = bank[r];
        end
        if (live_i[i].id == data_payload.id) begin
          deliver_match = 1;
          deliver_rec = r;
        end
        if (live_i[i].id == b_select_payload.id) begin
          select_match = 1;
          select_rec = r;
        end
        if (live_i[i].id == result_tag.id) begin
          result_match = 1;
          result_rec = r;
        end
        if (!done_lock && input_free[r] && writes_done[r] && inflight[r] == 0 &&
            !reported[r]) begin
          done_rec = r;
          local_done_valid = 1;
        end
      end
    end
    local_done_payload.id = command[done_rec].id;
    b_select_ready = select_match && !selected[select_rec];
    data_ready = deliver_match && selected[deliver_rec] &&
        installed[deliver_rec] == 6'(data_payload.block_idx);
    for (int i = 0; i < 3; i++) begin
      logic [1:0] r;
      int physical, old_start;
      r = live_i[i].rec;
      physical = 8 * int'(base_part[deliver_rec]) + int'(data_payload.block_idx);
      old_start = 8 * int'(base_part[r]);
      if (live_i[i].valid && r == deliver_rec) break;
      if (live_i[i].valid && bound[r] && selected[r] && physical >= old_start + int'(consumed[r]) &&
          physical < old_start + int'(blocks[r]))
        data_ready = 0;
    end
  end
  for (genvar b = 0; b < 2; b++) begin : a_context
    wire [1:0] r = context_bind[b] ? bind_rec : context_rec[b];
    blackwell_tc_a_context #(
      .CORE(CORE)
    ) ctx (
      .clk,
      .rst_n,
      .bind_i(context_bind[b]),
      .active_i(context_bind[b] || (context_active[b] && !input_free[r])),
      .permit_a(older_writes_clear[r][0]),
      .permit_scale(older_writes_clear[r][1]),
      .cmd(context_bind[b] ? prepare_payload.cmd : command[r]),
      .sm_valid(as_valid[b]),
      .sm_ready(as_ready[b]),
      .sm_req(as_req[b]),
      .sm_ret_valid(as_ret[b]),
      .sm_ret_ready(as_accept[b]),
      .sm_ret(sm_rd_rsp_payload),
      .tm_valid(at_valid[b]),
      .tm_ready(at_ready[b]),
      .tm_req(at_req[b]),
      .tm_ret_valid(at_ret[b]),
      .tm_ret_ready(at_accept[b]),
      .tm_ret(tm_rd_rsp_payload),
      .a_ready(a_ready[b]),
      .scale_ready(scale_ready[b]),
      .rows(rows[b]),
      .scales(scales[b])
    );
  end
  for (genvar g = 0; g < 8; g++) begin : sm_route
    for (genvar b = 0; b < 2; b++)
      assign as_ret[b][g] = sm_rd_rsp_valid[g] && context_active[b] &&
          command[context_rec[b]].id == sm_rd_rsp_payload[g].tag.id;
    assign sm_pick[g] = sm_hold[g] ?
        sm_source[g] : (as_valid[oldest_bank][g] ? oldest_bank : !oldest_bank);
    assign sm_rd_req_valid[g] = as_valid[sm_pick[g]][g];
    assign sm_rd_req_payload[g] = as_req[sm_pick[g]][g];
    assign sm_rd_rsp_ready[g] = (!as_ret[0][g] || as_accept[0][g]) &&
        (!as_ret[1][g] || as_accept[1][g]);
    for (genvar b = 0; b < 2; b++)
      assign as_ready[b][g] = sm_pick[g] == 1'(b) && sm_rd_req_ready[g];
  end
  function automatic logic block_allowed(input logic [1:0] r, input logic [4:0] j);
    logic allow_access;
    allow_access = older_writes_clear[r][3];
    for (int i = 0; i < 3; i++) begin
      logic [1:0] old;
      old = live_i[i].rec;
      if (live_i[i].valid && old == r) break;
      if (live_i[i].valid && bound[old] && command[old].d_tmem == command[r].d_tmem &&
          6'(j) < blocks[old] && (!closed[old][j] || (|pending[old][j])))
        allow_access = 0;
    end
    return allow_access;
  endfunction
  function automatic logic [2:0] word_need(mma_cmd_t cmd);
    return cmd.d_tmem[1:0] == 0 ? 3'b011 : 3'b111;
  endfunction
  function automatic logic [15:0] cell_mask(input logic [1:0] offset, slice_idx);
    logic [15:0] mask;
    for (int b = 0; b < 16; b++)
    mask[b] = (4 * int'(slice_idx) + b / 4 >= int'(offset) &&
               4 * int'(slice_idx) + b / 4 < int'(offset) + 8);
    return mask;
  endfunction
  always_comb begin
    logic all_a, complete_c, overlap;
    logic [1:0] r;
    logic s;
    r = current;
    s = consumed[r][0];
    complete_c = c_active[s] && c_rec[s] == r && c_block[s] == consumed[r][4:0];
    for (int l = 0; l < 32; l++)
    complete_c &= !command[r].input_d || (c_recv[s][l] & word_need(
        command[r]
    )) == word_need(
        command[r]
    );
    overlap = command[r].a_from_tmem &&
        32'(command[r].a_ref[15:0]) < command[r].d_tmem + (32'd64 << command[r].n_code) &&
        command[r].d_tmem < 32'(command[r].a_ref[15:0]) + tmem_a_columns(command[r]);
    all_a = overlap ? (&a_ready[bank[r]]) : a_ready[bank[r]][row_cursor[r]];
    b_can_load = current_valid && selected[r] && installed[r] > consumed[r] && all_a &&
        scale_ready[bank[r]] && (command[r].kind < 4 || sb_view[256]) && complete_c &&
        (!operand_valid || operand_ready);
  end
  assign first_ready = b_can_load && consumed[current] == 0 && row_cursor[current] == 0 &&
      first_id_valid && first_id == command[current].id;
  assign op_load = b_can_load &&
      ((consumed[current] != 0 || row_cursor[current] != 0) || (first_ready && launch));
  always_comb begin
    for (int k = 0; k < 3; k++) begin
      input_free[k] = bound[k] && consumed[k] == blocks[k];
      writes_done[k] = bound[k] && pending[k] == 0;
      for (int j = 0; j < 32; j++) if (j < int'(blocks[k]) && !closed[k][j]) writes_done[k] = 0;
    end
  end
  assign sb_query = {command[current].id, consumed[current], consumed[current][4:0], 3'd0};
  // Rebind the retiring C slot with the next block of the same parity.
  // The new owner can request its first word on the old slot's last load.
  always_comb begin
    logic [2:0][5:0] cursor;
    cursor = reserved_c;
    c_reserve = '0;
    next_c_rec = '0;
    next_c_block = '0;
    for (int pass = 0; pass < 2; pass++) begin
      logic found;
      found = 0;
      for (int i = 0; i < 3; i++) begin
        logic [1:0] r;
        logic s;
        r = live_i[i].rec;
        s = cursor[r][0];
        if (!found && live_i[i].valid && bound[r] && cursor[r] < blocks[r]) begin
          found = 1;
          if (!c_reserve[s] && (!c_active[s] || (op_load && consumed[current][0] == s &&
                                                            row_cursor[current] == 3))) begin
            c_reserve[s] = 1;
            next_c_rec[s] = r;
            next_c_block[s] = cursor[r][4:0];
            cursor[r] = cursor[r] + 6'd1;
          end
        end
      end
    end
  end
  for (genvar l = 0; l < 32; l++) begin : cd_route
    localparam int LANE = 32 * CORE + l;
    always_comb begin
      logic [1:0] r;
      logic [4:0] j;
      logic [2:0] missing;
      cr_valid[l] = cr_lock[l];
      cr_slot[l] = cr_held_slot[l];
      cr_slice[l] = cr_held_slice[l];
      for (int age = 0; age < 3; age++)
      for (int pass = 0; pass < 2; pass++) begin
        logic s;
        s = consumed[live_i[age].rec][0] ^ 1'(pass);
        r = c_reserve[s] ? next_c_rec[s] : c_rec[s];
        j = c_reserve[s] ? next_c_block[s] : c_block[s];
        missing = word_need(command[r]) & ~(c_reserve[s] ? 3'b0 : c_sent[s][l]);
        for (int w = 0; w < 3; w++)
        if (!cr_valid[l] && live_i[age].valid && r == live_i[age].rec &&
            command[r].input_d && (c_active[s] || c_reserve[s]) && missing[w] && block_allowed(
                r, j
            )) begin
          cr_valid[l] = 1;
          cr_slot[l] = s;
          cr_slice[l] = 2'(w);
        end
      end
      r = c_reserve[cr_slot[l]] ? next_c_rec[cr_slot[l]] : c_rec[cr_slot[l]];
      j = c_reserve[cr_slot[l]] ? next_c_block[cr_slot[l]] : c_block[cr_slot[l]];
      cr_req[l].tag = '{
          command[r].id,
          4'(CORE),
          {3'd2, j, 4'(l / 2), 4'(3 * (l % 2) + int'(cr_slice[l]))}
      };
      cr_req[l].lane = 7'(LANE);
      cr_req[l].word = command[r].d_tmem[8:2] + 7'(2 * int'(j) + int'(cr_slice[l]));
      cr_req[l].byte_mask = cell_mask(command[r].d_tmem[1:0], cr_slice[l]);
    end
    always_comb begin
      logic [1:0] r;
      logic [4:0] j;
      int n;
      w_slot[l] = w_held_slot[l];
      w_slice[l] = w_held_slice[l];
      tm_wr_req_valid[LANE] = w_lock[l];
      for (int age = 0; age < 3; age++)
      for (int s = 0; s < 2; s++)
      for (int w = 0; w < 3; w++)
      if (!tm_wr_req_valid[LANE] && d_active[s] && (&d_rows[s]) && live_i[age].valid &&
          d_rec[s] == live_i[age].rec && !command[d_rec[s]].disable_lane_mask[LANE] &&
          block_allowed(
              d_rec[s], d_block[s]
          ) && cell_mask(
              command[d_rec[s]].d_tmem[1:0], 2'(w)
          ) != 0 && !d_sent[s][l][w]) begin
        tm_wr_req_valid[LANE] = 1;
        w_slot[l] = 1'(s);
        w_slice[l] = 2'(w);
      end
      r = d_rec[w_slot[l]];
      j = d_block[w_slot[l]];
      tm_wr_req_payload[LANE].tag = '{command[r].id, 4'(CORE), {3'd0, j, 1'b0, w_slice[l], 5'(l)}};
      tm_wr_req_payload[LANE].lane = 7'(LANE);
      tm_wr_req_payload[LANE].word = command[r].d_tmem[8:2] + 7'(2 * int'(j) + int'(w_slice[l]));
      tm_wr_req_payload[LANE].byte_mask = cell_mask(command[r].d_tmem[1:0], w_slice[l]);
      tm_wr_req_payload[LANE].data = 0;
      for (int k = 0; k < 4; k++) begin
        n = 4 * int'(w_slice[l]) + k - int'(command[r].d_tmem[1:0]);
        if (n >= 0 && n < 8) tm_wr_req_payload[LANE].data[32*k+:32] = dbuf[w_slot[l]][l][n];
      end
    end
  end
  for (genvar l = 0; l < 128; l++) begin : tm_route
    localparam int R = l % 32;
    if (l / 32 != CORE) begin
      assign tm_wr_req_valid[l] = 0;
      assign tm_wr_req_payload[l] = '0;
    end
    for (genvar b = 0; b < 2; b++)
      assign at_ret[b][l] = tm_rd_rsp_valid[l] && tm_rd_rsp_payload[l].tag.token[15:13] != 2 &&
          context_active[b] && command[context_rec[b]].id == tm_rd_rsp_payload[l].tag.id;
    logic [1:0] scale_req;
    for (genvar b = 0; b < 2; b++)
      assign scale_req[b] = at_valid[b][l] && at_req[b][l].tag.token[15:13] == 3'd3;
    always_comb begin
      if (tm_hold[l]) tm_pick[l] = tm_source[l];
      else if (l / 32 == CORE && cr_valid[R]) tm_pick[l] = 2'd2;
      else if (scale_req[0] != scale_req[1]) tm_pick[l] = 2'(scale_req[1]);
      else tm_pick[l] = at_valid[oldest_bank][l] ? 2'(oldest_bank) : 2'(!oldest_bank);
    end
    assign tm_rd_req_valid[l] = tm_pick[l] == 2 ? cr_valid[R] : at_valid[tm_pick[l][0]][l];
    assign tm_rd_req_payload[l] = tm_pick[l] == 2 ? cr_req[R] : at_req[tm_pick[l][0]][l];
    assign tm_rd_rsp_ready[l] = (!at_ret[0][l] || at_accept[0][l]) &&
        (!at_ret[1][l] || at_accept[1][l]);
    assign tm_wr_ack_ready[l] = 1;
    for (genvar b = 0; b < 2; b++)
      assign at_ready[b][l] = tm_pick[l] == 2'(b) && tm_rd_req_ready[l];
  end
  always_comb begin
    d_next_sent = d_sent;
    for (int l = 0; l < 32; l++)
    if (tm_wr_req_valid[32*CORE+l] && tm_wr_req_ready[32*CORE+l])
      d_next_sent[w_slot[l]][l][w_slice[l]] = 1;
    for (int s = 0; s < 2; s++) begin
      d_finished[s] = d_active[s] && (&d_rows[s]);
      for (int l = 0; l < 32; l++)
      if (!command[d_rec[s]].disable_lane_mask[32*CORE+l])
        d_finished[s] &= (d_next_sent[s][l] & word_need(
            command[d_rec[s]]
        )) == word_need(
            command[d_rec[s]]
        );
    end
    result_ready = (!d_active[result_tag.block_idx[0]] ||
         (d_rec[result_tag.block_idx[0]] == result_rec && d_block[result_tag.block_idx[0]] ==
          result_tag.block_idx[4:0] && !d_rows[result_tag.block_idx[0]][result_tag.row_idx]));
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      bound <= 0;
      context_active <= 0;
      selected <= 0;
      reported <= 0;
      c_active <= 0;
      d_active <= 0;
      operand_valid <= 0;
      done_lock <= 0;
      sm_hold <= 0;
      tm_hold <= 0;
      cr_lock <= 0;
      w_lock <= 0;
      inflight <= 0;
      closed <= 0;
      pending <= 0;
      consumed <= 0;
      reserved_c <= 0;
    end else begin
      for (int r = 0; r < 3; r++) begin
        logic alive;
        alive = 0;
        for (int i = 0; i < 3; i++)
        alive |= live_i[i].valid && live_i[i].rec == 2'(r) && live_i[i].id == command[r].id;
        if (!alive) bound[r] <= 0;
        case ({
          op_load && current == 2'(r),
          result_valid && result_ready && result_match && result_rec == 2'(r)
        })
          2'b10:   inflight[r] <= inflight[r] + 1'b1;
          2'b01:   inflight[r] <= inflight[r] - 1'b1;
          default: ;
        endcase
        reserved_c[r] <= reserved_c[r] + 6'(c_reserve[0] && next_c_rec[0] == 2'(r)) +
            6'(c_reserve[1] && next_c_rec[1] == 2'(r));
      end
      if (prepare_ready && prepare_valid) begin
`ifndef SYNTHESIS
        assert (bind_rec < 3 && prepare_payload.cmd.id.epoch == epoch_i);
`endif
        command[bind_rec] <= prepare_payload.cmd;
        bound[bind_rec] <= 1;
        selected[bind_rec] <= 0;
        reported[bind_rec] <= 0;
        bank[bind_rec] <= prepare_payload.bank;
        consumed[bind_rec] <= 0;
        reserved_c[bind_rec] <= 0;
        row_cursor[bind_rec] <= 0;
        installed[bind_rec] <= 0;
        blocks[bind_rec] <= 6'd8 << prepare_payload.cmd.n_code;
        closed[bind_rec] <= 0;
        pending[bind_rec] <= 0;
        inflight[bind_rec] <= 0;
      end
      for (int b = 0; b < 2; b++) begin
        if (input_free[context_rec[b]]) context_active[b] <= 0;
        if (context_bind[b]) begin
          context_active[b] <= 1;
          context_rec[b] <= bind_rec;
        end
      end
      if (b_select_valid && b_select_ready) begin
        base_part[select_rec] <= b_select_payload.base_part;
        selected[select_rec] <= 1;
        installed[select_rec] <= b_select_payload.reuse ? blocks[select_rec] : 0;
      end
      if (data_valid && data_ready) begin
        bmem[5'({base_part[deliver_rec], 3'b0}+data_payload.block_idx)] <= data_payload.data;
        installed[deliver_rec] <= installed[deliver_rec] + 1'b1;
      end
      if (operand_ready) operand_valid <= 0;
      if (op_load) begin
        op_rec <= current;
        operand_valid <= 1;
        operand_payload.tag <= {
          command[current].id,
          2'(CORE),
          consumed[current],
          row_cursor[current],
          {3'b0, consumed[current][5:1]}
        };
        operand_payload.a <= rows[bank[current]][8*int'(row_cursor[current])+:8];
        if (row_cursor[current] == 0)
          operand_payload.b <= bmem[5'({base_part[current], 3'b0}+consumed[current][4:0])];
        operand_payload.c <= command[current].input_d ?
            cbuf[consumed[current][0]][8*int'(row_cursor[current])+:8] : '0;
        operand_payload.sa <= command[current].kind >= 4 ?
            scales[bank[current]][8*int'(row_cursor[current])+:8] : '0;
        operand_payload.sb <= command[current].kind >= 4 ? sb_view[255:0] : '0;
        row_cursor[current] <= row_cursor[current] + 1'b1;
        if (row_cursor[current] == 3) begin
          consumed[current] <= consumed[current] + 1'b1;
          c_active[consumed[current][0]] <= 0;
        end
      end
      for (int s = 0; s < 2; s++) begin
        if (c_reserve[s]) begin
          c_active[s] <= 1;
          c_rec[s] <= next_c_rec[s];
          c_block[s] <= next_c_block[s];
          c_sent[s] <= 0;
          c_recv[s] <= 0;
        end
        if (d_finished[s]) begin
          d_active[s] <= 0;
          closed[d_rec[s]][d_block[s]] <= 1;
        end
      end
      if (result_valid && result_ready) begin
        logic s;
        s = result_tag.block_idx[0];
`ifndef SYNTHESIS
        assert (result_match && result_tag.core == 2'(CORE) && result_tag.generation ==
                {3'b0, result_tag.block_idx[5:1]} && result_tag.block_idx < blocks[result_rec]);
`endif
        if (!d_active[s]) begin
          d_active[s] <= 1;
          d_rec[s] <= result_rec;
          d_block[s] <= result_tag.block_idx[4:0];
          d_rows[s] <= 0;
          d_sent[s] <= 0;
        end
        d_rows[s][result_tag.row_idx] <= 1;
        dbuf[s][8*int'(result_tag.row_idx)+:8] <= result_payload.cells;
        if (result_tag.row_idx == 3 &&
            (&command[result_rec].disable_lane_mask[32*CORE+:32])) begin
          d_active[s] <= 0;
          closed[result_rec][result_tag.block_idx[4:0]] <= 1;
        end
      end
      for (int g = 0; g < 8; g++) begin
        sm_source[g] <= sm_pick[g];
        sm_hold[g] <= sm_rd_req_valid[g] && !sm_rd_req_ready[g];
`ifndef SYNTHESIS
        if (sm_rd_rsp_valid[g]) assert (as_ret[0][g] ^ as_ret[1][g]);
`endif
      end
      for (int l = 0; l < 128; l++) begin
        tm_source[l] <= tm_pick[l];
        tm_hold[l] <= tm_rd_req_valid[l] && !tm_rd_req_ready[l];
`ifndef SYNTHESIS
        if (tm_rd_rsp_valid[l] && tm_rd_rsp_payload[l].tag.token[15:13] != 2)
          assert (at_ret[0][l] ^ at_ret[1][l]);
`endif
        if (tm_rd_rsp_valid[l] && tm_rd_rsp_payload[l].tag.token[15:13] == 2) begin
          logic [4:0] j;
          logic s;
          int w, n;
          j = tm_rd_rsp_payload[l].tag.token[12:8];
          s = j[0];
          w = int'(tm_rd_rsp_payload[l].tag.token[3:0]) - 3 * (l % 2);
`ifndef SYNTHESIS
          assert (l / 32 == CORE && c_active[s] && c_block[s] == j &&
                  command[c_rec[s]].id == tm_rd_rsp_payload[l].tag.id &&
                  tm_rd_rsp_payload[l].tag.client == 4'(CORE) &&
                  tm_rd_rsp_payload[l].tag.token[7:4] == 4'((l % 32) / 2) &&
                  w >= 0 && w < 3 && c_sent[s][l%32][w] && !c_recv[s][l%32][w]);
`endif
          c_recv[s][l%32][w] <= 1;
          for (int k = 0; k < 4; k++) begin
            n = 4 * w + k - int'(command[c_rec[s]].d_tmem[1:0]);
            if (n >= 0 && n < 8) cbuf[s][l%32][n] <= tm_rd_rsp_payload[l].data[32*k+:32];
          end
        end
        if (tm_wr_ack_valid[l]) begin
          logic [2:0] owner_match;
          logic [4:0] j;
          logic [2:0] w;
          j = tm_wr_ack_payload[l].tag.token[12:8];
          w = tm_wr_ack_payload[l].tag.token[7:5];
          for (int r = 0; r < 3; r++) begin
            owner_match[r] = bound[r] && command[r].id == tm_wr_ack_payload[l].tag.id;
            if (owner_match[r]) begin
`ifndef SYNTHESIS
              assert (pending[r][j][w][l%32]);
`endif
              pending[r][j][w][l%32] <= 0;
            end
          end
`ifndef SYNTHESIS
          assert ($onehot(owner_match) && tm_wr_ack_payload[l].tag.client == 4'(CORE) &&
                  l / 32 == CORE && w < 3 && tm_wr_ack_payload[l].tag.token[15:13] == 0 &&
                  tm_wr_ack_payload[l].tag.token[4:0] == 5'(l));
`endif
        end
      end
      for (int l = 0; l < 32; l++) begin
        int lane;
        lane = 32 * CORE + l;
        cr_lock[l] <= cr_valid[l] && !(tm_pick[lane] == 2 && tm_rd_req_ready[lane]);
        cr_held_slot[l] <= cr_slot[l];
        cr_held_slice[l] <= cr_slice[l];
        if (cr_valid[l] && tm_pick[lane] == 2 && tm_rd_req_ready[lane])
          c_sent[cr_slot[l]][l][cr_slice[l]] <= 1;
        w_lock[l] <= tm_wr_req_valid[lane] && !tm_wr_req_ready[lane];
        w_held_slot[l] <= w_slot[l];
        w_held_slice[l] <= w_slice[l];
        if (tm_wr_req_valid[lane] && tm_wr_req_ready[lane]) begin
          d_sent[w_slot[l]][l][w_slice[l]] <= 1;
          pending[d_rec[w_slot[l]]][d_block[w_slot[l]]][w_slice[l]][l] <= 1;
        end
      end
      done_lock <= local_done_valid && !local_done_ready;
      held_done <= done_rec;
      if (local_done_valid && local_done_ready) reported[done_rec] <= 1;
    end
  end
endmodule
