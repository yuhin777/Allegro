// Implements frozen A1: doc/specs/blackwell_tc_completion_tracker.md
module blackwell_tc_completion_tracker
  import blackwell_async_pkg::*;
#(
  parameter int unsigned OPERATIONS = 32,
  parameter int unsigned COMMITS = 8
) (
  input logic clk,
  input logic rst_n,
  input logic register_vld_i,
  input blackwell_async_pkg::async_key_a1_t register_i,
  input logic complete_vld_i,
  input blackwell_async_pkg::async_event_a1_t complete_i,
  input logic commit_vld_i,
  input blackwell_async_pkg::tc_commit_a1_t commit_i,
  input logic arrival_rdy_i,
  output logic register_rdy_o,
  output logic complete_rdy_o,
  output logic commit_rdy_o,
  output logic arrival_vld_o,
  output blackwell_async_pkg::tc_commit_a1_t arrival_o,
  output logic [STATUS_W-1:0] arrival_status_o,
  output logic protocol_error_o,
  output logic idle_o,
  output logic drained_o
);

  localparam int unsigned COMMIT_INDEX_W = (COMMITS > 1) ? $clog2(COMMITS) : 1;
  typedef struct packed {
    async_key_a1_t key;
  } operation_t;
  typedef struct packed {
    tc_commit_a1_t payload;
    logic [OPERATIONS-1:0] pending;
    logic [COMMITS-1:0] predecessors;
    logic [STATUS_W-1:0] status;
  } snapshot_t;
  logic [OPERATIONS-1:0] live_q, live_d;
  logic [COMMITS-1:0] snapshot_live_q, snapshot_live_d;
  operation_t [OPERATIONS-1:0] operations_q, operations_d;
  snapshot_t [COMMITS-1:0] snapshots_q, snapshots_d;
  logic [(1 << ISSUER_ID_W)-1:0][STATUS_W-1:0] fault_q, fault_d;
  logic arrival_vld_q, arrival_vld_d;
  tc_commit_a1_t arrival_q, arrival_d;
  logic [STATUS_W-1:0] arrival_status_q, arrival_status_d;
  logic [COMMIT_INDEX_W-1:0] rr_q, rr_d;
  logic protocol_error_q, protocol_error_d;
  integer free_operation, free_snapshot, matched_operation;
  integer selected_snapshot, scan_index;
  logic duplicate, valid_completion;
  logic [OPERATIONS-1:0] completed_mask;
  logic [COMMITS-1:0] released_snapshot_mask;
  snapshot_t accepted_snapshot;
  logic register_fire, complete_fire, commit_fire;

  assign complete_rdy_o = 1'b1;
  assign arrival_vld_o = arrival_vld_q;
  assign arrival_o = arrival_q;
  assign arrival_status_o = arrival_status_q;
  assign protocol_error_o = protocol_error_q;
  assign idle_o = !(|live_q);
  assign drained_o = idle_o && !(|snapshot_live_q) && !arrival_vld_q;
  assign register_fire = register_vld_i && register_rdy_o;
  assign complete_fire = complete_vld_i && complete_rdy_o;
  assign commit_fire = commit_vld_i && commit_rdy_o;

  always_comb begin
    int op;
    int snap;
    op = 0;
    snap = 0;
    free_operation = -1;
    free_snapshot = -1;
    matched_operation = -1;
    duplicate = 1'b0;
    for (op = 0; op < OPERATIONS; op++) begin
      if (!live_q[op] && free_operation < 0) free_operation = op;
      if (live_q[op] && operations_q[op].key == register_i) duplicate = 1'b1;
      if (live_q[op] && operations_q[op].key.ctx == complete_i.ctx &&
          operations_q[op].key.id == complete_i.\event .id) matched_operation = op;
    end
    for (snap = 0; snap < COMMITS; snap++) begin
      if (!snapshot_live_q[snap] && free_snapshot < 0) free_snapshot = snap;
    end
    register_rdy_o = free_operation >= 0 && !duplicate;
    commit_rdy_o = free_snapshot >= 0;

  end

  assign valid_completion = complete_fire && matched_operation >= 0 &&
      complete_i.\event .domain == CPL_TC;
  for (genvar issuer = 0; issuer < (1 << ISSUER_ID_W); issuer++) begin : g_issuer_fault
    always_comb begin
      fault_d[issuer] = fault_q[issuer];
      if (valid_completion && complete_i.\event .id.issuer == ISSUER_ID_W'(issuer) &&
          complete_i.\event .status != ASYNC_OK && fault_q[issuer] == ASYNC_OK)
        fault_d[issuer] = complete_i.\event .status;
    end
  end
  // Form one immutable candidate record before distributing it to a free
  // slot. No candidate depends on a partially updated record array.
  always_comb begin
    int op;
    int snap;
    op = 0;
    snap = 0;
    completed_mask = '0;
    accepted_snapshot = '0;
    accepted_snapshot.payload = commit_i;
    accepted_snapshot.status = fault_q[commit_i.commit.id.issuer];
    for (op = 0; op < OPERATIONS; op++) begin
      completed_mask[op] = valid_completion && matched_operation == op;
      accepted_snapshot.pending[op] = live_q[op] &&
          operations_q[op].key.ctx == commit_i.ctx &&
          operations_q[op].key.id.issuer == commit_i.commit.id.issuer &&
          operations_q[op].key.id.epoch == commit_i.commit.id.epoch &&
          !completed_mask[op];
    end
    if (valid_completion && complete_i.ctx == commit_i.ctx &&
        complete_i.\event .id.issuer == commit_i.commit.id.issuer &&
        complete_i.\event .id.epoch == commit_i.commit.id.epoch &&
        fault_q[commit_i.commit.id.issuer] == ASYNC_OK)
      accepted_snapshot.status = complete_i.\event .status;
    for (snap = 0; snap < COMMITS; snap++) begin
      accepted_snapshot.predecessors[snap] = snapshot_live_q[snap] &&
          snapshots_q[snap].payload.ctx == commit_i.ctx &&
          snapshots_q[snap].payload.commit.id.epoch == commit_i.commit.id.epoch &&
          snapshots_q[snap].payload.commit.id.issuer == commit_i.commit.id.issuer;
    end
  end

  always_comb begin
    int offset;
    int snap;
    offset = 0;
    snap = 0;
    selected_snapshot = -1;
    scan_index = 0;
    released_snapshot_mask = '0;
    if (!arrival_vld_q || arrival_rdy_i) begin
      for (offset = 0; offset < COMMITS; offset++) begin
        scan_index = (int'(rr_q) + offset) % COMMITS;
        if (selected_snapshot < 0 && snapshot_live_q[scan_index] &&
            !(|(snapshots_q[scan_index].pending & ~completed_mask)) &&
            !(|snapshots_q[scan_index].predecessors))
          selected_snapshot = scan_index;
      end
      for (snap = 0; snap < COMMITS; snap++)
        released_snapshot_mask[snap] = selected_snapshot == snap;
    end
  end

  always_comb begin
    int op;
    int snap;
    op = 0;
    snap = 0;
    live_d = live_q & ~completed_mask;
    snapshot_live_d = snapshot_live_q & ~released_snapshot_mask;
    arrival_vld_d = arrival_vld_q && !arrival_rdy_i;
    arrival_d = arrival_q;
    arrival_status_d = arrival_status_q;
    rr_d = rr_q;
    protocol_error_d = complete_fire && !valid_completion;
    for (op = 0; op < OPERATIONS; op++) begin
      operations_d[op] = operations_q[op];
      if (register_fire && free_operation == op) begin
        live_d[op] = 1'b1;
        operations_d[op].key = register_i;
      end
    end
    for (snap = 0; snap < COMMITS; snap++) begin
      snapshots_d[snap] = snapshots_q[snap];
      snapshots_d[snap].pending = snapshots_q[snap].pending & ~completed_mask;
      snapshots_d[snap].predecessors = snapshots_q[snap].predecessors & ~released_snapshot_mask;
      if (valid_completion && (|(snapshots_q[snap].pending & completed_mask)) &&
          snapshots_q[snap].status == ASYNC_OK)
        snapshots_d[snap].status = complete_i.\event .status;
      if (commit_fire && free_snapshot == snap) begin
        snapshot_live_d[snap] = 1'b1;
        snapshots_d[snap] = accepted_snapshot;
        snapshots_d[snap].predecessors = accepted_snapshot.predecessors & ~released_snapshot_mask;
      end
    end
    if (selected_snapshot >= 0) begin
      arrival_vld_d = 1'b1;
      arrival_d = snapshots_q[selected_snapshot].payload;
      arrival_status_d = snapshots_q[selected_snapshot].status;
      if (valid_completion && (|(snapshots_q[selected_snapshot].pending & completed_mask)) &&
          snapshots_q[selected_snapshot].status == ASYNC_OK)
        arrival_status_d = complete_i.\event .status;
      rr_d = COMMIT_INDEX_W'((selected_snapshot + 1) % COMMITS);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      live_q <= '0;
      snapshot_live_q <= '0;
      arrival_vld_q <= 1'b0;
      arrival_q <= '0;
      arrival_status_q <= ASYNC_OK;
      rr_q <= '0;
      protocol_error_q <= 1'b0;
      operations_q <= '0;
      snapshots_q <= '0;
      fault_q <= '0;
    end else begin
      live_q <= live_d;
      snapshot_live_q <= snapshot_live_d;
      arrival_vld_q <= arrival_vld_d;
      arrival_q <= arrival_d;
      arrival_status_q <= arrival_status_d;
      rr_q <= rr_d;
      protocol_error_q <= protocol_error_d;
      operations_q <= operations_d;
      snapshots_q <= snapshots_d;
      fault_q <= fault_d;
    end
  end
  initial begin
    if (OPERATIONS < 1 || COMMITS < 1) $fatal(1, "TC table capacity");
  end
`ifndef SYNTHESIS
  assert property (@(posedge clk) disable iff (!rst_n)
      arrival_vld_o && !arrival_rdy_i |=> arrival_vld_o && $stable({arrival_o,arrival_status_o}));
  assert property (@(posedge clk) disable iff (!rst_n)
      $onehot0(completed_mask) && $onehot0(released_snapshot_mask));

`endif
endmodule
