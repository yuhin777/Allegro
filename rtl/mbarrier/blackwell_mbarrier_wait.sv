module blackwell_mbarrier_wait
  import blackwell_async_pkg::*;
  import blackwell_mbarrier_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic stop,
  input logic [15:0] epoch,
  input logic wait_cmd_valid,
  input logic wait_rsp_ready,
  input logic probe_req_ready,
  input logic probe_rsp_valid,
  input logic acquire_req_ready,
  input logic acquire_rsp_valid,
  output logic wait_cmd_ready,
  output logic wait_rsp_valid,
  output logic probe_req_valid,
  output logic probe_rsp_ready,
  output logic acquire_req_valid,
  output logic acquire_rsp_ready,
  input bar_cmd_t wait_cmd_payload,
  output bar_rsp_t wait_rsp_payload,
  output bar_service_req_t probe_req_payload,
  input bar_service_rsp_t probe_rsp_payload,
  output order_req_t acquire_req_payload,
  input op_done_t acquire_rsp_payload,
  input logic change_valid,
  input bar_change_t change_payload,
`ifndef SYNTHESIS
  input async_id_t ingress_id,
  output logic ingress_id_busy,
`endif
  input logic [31:0] busy_addr,
  output logic addr_busy,
  output logic drained
);
  typedef enum logic [2:0] {
    FREE,
    PROBE,
    ARMED,
    MATCHED,
    ACQUIRE,
    RESULT
  } state_t;
  state_t state[32];
  async_id_t id[32];
  logic [31:0] addr[32];
  logic [31:0] parity, matched, probe_pending;
  logic [5:0] tick, armed_tick[32];
  logic [4:0] free_slot, probe_slot, acquire_slot, rsp_slot, outstanding_slot;
  logic [4:0] acquire_cursor, rsp_cursor, dispatch_slot, acquire_hold, rsp_hold;
  logic dispatch_valid;
  logic acquire_locked, rsp_locked, outstanding_valid;
  logic free_any, acquire_any, rsp_any;
  always_comb begin
    free_any = 0;
    acquire_any = 0;
    rsp_any = 0;
    addr_busy = 0;
`ifndef SYNTHESIS
    ingress_id_busy = 0;
`endif
    drained = 1;
    free_slot = 0;
    acquire_slot = 0;
    rsp_slot = 0;
    for (int i = 0; i < 32; i++) begin
      logic [4:0] a, r;
      a = acquire_cursor + 5'(i);
      r = rsp_cursor + 5'(i);
      if (!free_any && state[i] == FREE) begin
        free_any = 1;
        free_slot = 5'(i);
      end
      if (!acquire_any && state[a] == MATCHED) begin
        acquire_any = 1;
        acquire_slot = a;
      end
      if (!rsp_any && state[r] == RESULT && !probe_pending[r]) begin
        rsp_any = 1;
        rsp_slot = r;
      end
      if (state[i] != FREE) begin
        drained = 0;
        addr_busy |= addr[i] == busy_addr;
`ifndef SYNTHESIS
        ingress_id_busy |= id[i] == ingress_id;
`endif
      end
    end
    probe_slot = dispatch_slot;
    if (acquire_locked) begin
      acquire_slot = acquire_hold;
      acquire_any = 1;
    end
    if (rsp_locked) begin
      rsp_slot = rsp_hold;
      rsp_any = 1;
    end
    wait_cmd_ready = rst_n && !dispatch_valid && free_any;
    probe_req_valid = dispatch_valid;
    probe_req_payload = '0;
    probe_req_payload.route = 1;
    probe_req_payload.slot = probe_slot;
    probe_req_payload.cmd.id = id[probe_slot];
    probe_req_payload.cmd.op = BAR_QUERY;
    probe_req_payload.cmd.addr = addr[probe_slot];
    acquire_req_valid = acquire_any && !outstanding_valid;
    acquire_req_payload = '0;
    acquire_req_payload.id = id[acquire_slot];
    acquire_req_payload.kind = 1;
    acquire_req_payload.from_proxy = 1;
    wait_rsp_valid = rsp_any;
    wait_rsp_payload = '{id: id[rsp_slot], completed: matched[rsp_slot]};
    probe_rsp_ready = rst_n;
    acquire_rsp_ready = rst_n;
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < 32; i++) state[i] <= FREE;
      tick <= 0;
      probe_pending <= 0;
      matched <= 0;
      dispatch_valid <= 0;
      acquire_locked <= 0;
      rsp_locked <= 0;
      outstanding_valid <= 0;
      acquire_cursor <= 0;
      rsp_cursor <= 0;
    end else begin
      tick <= tick + 6'd1;
      if (wait_cmd_valid && wait_cmd_ready) begin
        state[free_slot] <= PROBE;
        id[free_slot] <= wait_cmd_payload.id;
        addr[free_slot] <= wait_cmd_payload.addr;
        parity[free_slot] <= wait_cmd_payload.parity;
        matched[free_slot] <= 0;
        probe_pending[free_slot] <= 1;
        dispatch_valid <= 1;
        dispatch_slot <= free_slot;
      end
      if (probe_req_valid && probe_req_ready) dispatch_valid <= 0;
      if (acquire_req_valid) begin
        acquire_locked <= !acquire_req_ready;
        acquire_hold <= acquire_slot;
        if (acquire_req_ready) begin
          acquire_cursor <= acquire_slot + 5'd1;
          outstanding_valid <= 1;
          outstanding_slot <= acquire_slot;
          state[acquire_slot] <= ACQUIRE;
        end
      end
      if (acquire_rsp_valid) begin
        state[outstanding_slot] <= RESULT;
        outstanding_valid <= 0;
      end
      if (wait_rsp_valid) begin
        rsp_locked <= !wait_rsp_ready;
        rsp_hold <= rsp_slot;
        if (wait_rsp_ready) begin
          state[rsp_slot] <= FREE;
          rsp_cursor <= rsp_slot + 5'd1;
        end
      end
      if (probe_rsp_valid) begin
        probe_pending[probe_rsp_payload.slot] <= 0;
        if (state[probe_rsp_payload.slot] == PROBE) begin
          if (probe_rsp_payload.phase != parity[probe_rsp_payload.slot]) begin
            matched[probe_rsp_payload.slot] <= 1;
            state[probe_rsp_payload.slot] <= MATCHED;
          end else begin
            state[probe_rsp_payload.slot] <= ARMED;
            armed_tick[probe_rsp_payload.slot] <= tick;
          end
        end
      end
      for (int i = 0; i < 32; i++) begin
        if (state[i] inside {ARMED, PROBE}) begin
          if (change_valid && change_payload.addr == addr[i] &&
              change_payload.phase != parity[i]) begin
            matched[i] <= 1;
            state[i] <= MATCHED;
          end else if (state[i] == ARMED && tick == armed_tick[i]) state[i] <= RESULT;
        end
      end
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (wait_cmd_valid) assert (wait_cmd_payload.id.epoch == epoch && wait_cmd_payload.op == BAR_TRY);
      if (probe_rsp_valid) begin
        assert (probe_rsp_payload.route == 1 && probe_rsp_payload.initialized);
        assert (probe_pending[probe_rsp_payload.slot] &&
                id[probe_rsp_payload.slot] == probe_rsp_payload.rsp.id &&
                !(dispatch_valid && dispatch_slot == probe_rsp_payload.slot));
      end
      if (acquire_rsp_valid) assert (outstanding_valid && acquire_rsp_payload.id == id[outstanding_slot]);
      for (int i = 0; i < 32; i++)
        if (state[i] != FREE && change_valid && change_payload.addr == addr[i])
          assert (change_payload.initialized);
    end
  end
`endif
endmodule
