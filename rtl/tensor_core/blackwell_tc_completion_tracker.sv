module blackwell_tc_completion_tracker
  import blackwell_async_pkg::*;
  import blackwell_tc_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic halt_i,
  input logic stop_i,
  input logic [15:0] epoch_i,
  input logic register_op_valid,
  output logic register_op_ready,
  input async_id_t register_op_payload,
  input logic engine_done_valid,
  output logic engine_done_ready,
  input op_done_t engine_done_payload,
  output logic op_done_valid,
  input logic op_done_ready,
  output op_done_t op_done_payload,
  input logic commit_cmd_valid,
  output logic commit_cmd_ready,
  input tc_commit_t commit_cmd_payload,
  output logic ready_commit_valid,
  input logic ready_commit_ready,
  output tc_ready_commit_t ready_commit_payload,
  input logic commit_retire_valid,
  output logic commit_retire_ready,
  input tc_commit_retire_t commit_retire_payload,
  input logic [31:0] busy_addr,
  output logic addr_busy,
  output logic drained_o,
  output logic fault_o
);
  async_id_t ops[32];
  tc_commit_t commits[8];
  logic [31:0] live, finished, snapshot, done_match;
  logic [7:0] occupied, sent, eligible;
  logic [31:0] pending[8];
  logic [ 7:0] older  [8];
  logic [4:0] free_op, selected_op, op_cursor, held_op;
  logic [2:0] free_commit, selected_commit, commit_cursor, held_commit;
  logic op_locked, commit_locked, bad_op, bad_commit;
  logic op_found, commit_found, retire_match;
  wire completing = engine_done_valid && engine_done_ready && engine_done_payload.status == OK;
  wire retiring = commit_retire_valid && commit_retire_ready;

  always_comb begin
    bad_op = register_op_payload.epoch != epoch_i || (&register_op_payload.seq);
    bad_commit = commit_cmd_payload.id.epoch != epoch_i || (&commit_cmd_payload.id.seq);
    free_op = 0;
    free_commit = 0;
    for (int i = 31; i >= 0; i--) begin
      if (!live[i]) free_op = 5'(i);
      bad_op |= live[i] && ops[i] == register_op_payload;
      bad_commit |= live[i] && ops[i] == commit_cmd_payload.id;
      done_match[i] = live[i] && !finished[i] && ops[i] == engine_done_payload.id;
      snapshot[i] = live[i] && !finished[i] && ops[i].epoch == commit_cmd_payload.id.epoch &&
          ops[i].issuer == commit_cmd_payload.id.issuer && !(completing && done_match[i]);
    end
    addr_busy = 0;
    for (int j = 7; j >= 0; j--) begin
      if (!occupied[j]) free_commit = 3'(j);
      bad_op |= occupied[j] && commits[j].id == register_op_payload;
      bad_commit |= occupied[j] && commits[j].id == commit_cmd_payload.id;
      addr_busy |= occupied[j] && commits[j].barrier_addr == busy_addr;
      eligible[j] = occupied[j] && !sent[j] && pending[j] == 0;
      for (int k = 0; k < 8; k++)
      if (older[j][k] && occupied[k] && commits[k].id.issuer == commits[j].id.issuer)
        eligible[j] = 0;
    end
  end
  wire collision = commit_cmd_valid && register_op_valid &&
      commit_cmd_payload.id == register_op_payload;
  assign register_op_ready = !halt_i && !stop_i && !(&live) && !bad_op && !collision;
  assign commit_cmd_ready = !halt_i && !stop_i && !(&occupied) && !bad_commit && !collision;
  assign engine_done_ready = !halt_i;
  assign retire_match = occupied[commit_retire_payload.slot] && sent[commit_retire_payload.slot] &&
      commits[commit_retire_payload.slot].id == commit_retire_payload.id;
  assign commit_retire_ready = !halt_i && retire_match;
  assign drained_o = live == 0 && occupied == 0;

  always_comb begin
    selected_op = held_op;
    op_found = op_locked;
    selected_commit = held_commit;
    commit_found = commit_locked;
    for (int i = 0; i < 32; i++)
    if (!op_found && !halt_i && finished[5'(int'(op_cursor)+i)]) begin
      selected_op = 5'(int'(op_cursor) + i);
      op_found = 1;
    end
    for (int j = 0; j < 8; j++)
    if (!commit_found && !halt_i && eligible[3'(int'(commit_cursor)+j)]) begin
      selected_commit = 3'(int'(commit_cursor) + j);
      commit_found = 1;
    end
  end
  assign op_done_valid = op_found;
  assign op_done_payload = '{ops[selected_op], OK};
  assign ready_commit_valid = commit_found;
  assign ready_commit_payload = '{commits[selected_commit], selected_commit};

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      live <= 0;
      finished <= 0;
      occupied <= 0;
      sent <= 0;
      op_locked <= 0;
      commit_locked <= 0;
      op_cursor <= 0;
      commit_cursor <= 0;
      fault_o <= 0;
      for (int j = 0; j < 8; j++) older[j] <= 0;
    end else begin
      if (!halt_i && !stop_i &&
          ((register_op_valid && bad_op) || (commit_cmd_valid && bad_commit) || collision))
        fault_o <= 1;
      if (engine_done_valid && engine_done_ready &&
          ((done_match == 0 || (done_match & (done_match - 1'b1)) != 0) ||
           engine_done_payload.status != OK))
        fault_o <= 1;
      if (commit_retire_valid && !retire_match) fault_o <= 1;
      if (register_op_valid && register_op_ready) begin
        live[free_op] <= 1;
        ops[free_op] <= register_op_payload;
      end
      for (int i = 0; i < 32; i++) if (completing && done_match[i]) finished[i] <= 1;
      op_locked <= op_found && !op_done_ready;
      if (op_found) begin
        held_op <= selected_op;
        if (op_done_ready) begin
          live[selected_op] <= 0;
          finished[selected_op] <= 0;
          op_cursor <= selected_op + 1'b1;
        end
      end
      commit_locked <= commit_found && !ready_commit_ready;
      if (commit_found) begin
        held_commit <= selected_commit;
        if (ready_commit_ready) begin
          sent[selected_commit] <= 1;
          commit_cursor <= selected_commit + 1'b1;
        end
      end
      for (int j = 0; j < 8; j++) begin
        if (completing) pending[j] <= pending[j] & ~done_match;
        if (retiring) older[j][commit_retire_payload.slot] <= 0;
      end
      if (retiring) begin
        occupied[commit_retire_payload.slot] <= 0;
        sent[commit_retire_payload.slot] <= 0;
        older[commit_retire_payload.slot] <= 0;
      end
      if (commit_cmd_valid && commit_cmd_ready) begin
        occupied[free_commit] <= 1;
        pending[free_commit] <= snapshot;
        commits[free_commit] <= commit_cmd_payload;
        older[free_commit] <= occupied & ~(retiring ? (8'b1 << commit_retire_payload.slot) : 8'b0);
      end
    end
  end
endmodule
