module blackwell_tma_unit
  import blackwell_async_pkg::*;
  import blackwell_smem_pkg::*;
  import blackwell_mbarrier_pkg::*;
  import blackwell_tma_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic stop,
  input logic [15:0] epoch,
  input logic cmd_valid,
  input logic rsp_ready,
  input logic gmem_req_ready,
  input logic gmem_rsp_valid,
  input logic order_req_ready,
  input logic order_rsp_valid,
  input logic bar_bind_ready,
  input logic bar_bind_rsp_valid,
  input logic producer_done_ready,
  input logic producer_rsp_valid,
  output logic cmd_ready,
  output logic rsp_valid,
  output logic gmem_req_valid,
  output logic gmem_rsp_ready,
  output logic order_req_valid,
  output logic order_rsp_ready,
  output logic bar_bind_valid,
  output logic bar_bind_rsp_ready,
  output logic producer_done_valid,
  output logic producer_rsp_ready,
  input tma_cmd_t cmd_payload,
  output tma_rsp_t rsp_payload,
  output gmem_req_t gmem_req_payload,
  input gmem_rsp_t gmem_rsp_payload,
  output order_req_t order_req_payload,
  input op_done_t order_rsp_payload,
  output bar_bind_t bar_bind_payload,
  input op_done_t bar_bind_rsp_payload,
  input op_done_t producer_rsp_payload,
  output bar_producer_done_t producer_done_payload,
  input logic [7:0] smem_req_ready,
  input logic [7:0] smem_rsp_valid,
  output logic [7:0] smem_req_valid,
  output logic [7:0] smem_rsp_ready,
  output logic [7:0] smem_read_blocked,
  output smem_atom_req_t smem_req_payload[8],
  input smem_atom_rsp_t smem_rsp_payload[8],
  output logic drained
);
  typedef enum logic [3:0] {
    FREE,
    QUEUED,
    DESC,
    SETUP,
    CHECK_DEPS,
    BIND_WAIT,
    PREPARED,
    ARMED_HEAD,
    ISSUED,
    FENCE_WAIT,
    GROUP_WAIT,
    RESULT
  } ticket_state_t;
  ticket_state_t state[20];
  async_id_t id[20];
  tma_opcode_t op[20];
  logic [19:0] source_done, target_done, bound, slot;
  logic [1:0] age[18];
  logic [17:0] wait_pending[20];
  logic [19:0] older[20];
  logic [31:0] barrier[18];
  logic [63:0] policy[18], total[20];
  tma_span_t spans[18];
  tma_owner_view_t owner_view[18];
  logic in_valid, in_ready, out_valid, out_ready;
  tma_issue_t in_payload, out_payload;
  logic [3:0] occupancy;
  blackwell_fifo #(
    .WIDTH($bits(tma_issue_t)),
    .DEPTH(8)
  ) ingress (
    .*
  );
  logic cache_drained, setup_drained, walk_drained, track_drained, data_drained;
  logic available, uses_fifo, is_control;
  ticket_t new_ticket, head_t, rsp_t, rsp_cursor, held_rsp;
  logic rsp_locked, ticket_locked;
  ticket_t held_ticket;
  assign head_t = out_payload.ticket;
  logic
      lookup_valid, lookup_ready, desc_valid, desc_ready, cg_req_valid, cg_req_ready, cg_rsp_ready;
  tma_desc_req_t lookup_payload;
  tma_desc_rsp_t desc_payload;
  tma_gmem_return_t gmem_return;
  assign gmem_return = '{id: gmem_rsp_payload.id, data: gmem_rsp_payload.data};
  gmem_req_t cg_req_payload, dg_req_payload;
  logic dg_req_valid, dg_req_ready, dg_rsp_ready, mem_turn, mem_lock, mem_hold, req_cache;
  blackwell_tma_descriptor_cache cache (
    .clk,
    .rst_n,
    .epoch,
    .lookup_valid,
    .lookup_ready,
    .lookup_payload,
    .result_valid(desc_valid),
    .result_ready(desc_ready),
    .result_payload(desc_payload),
    .gmem_req_valid(cg_req_valid),
    .gmem_req_ready(cg_req_ready),
    .gmem_req_payload(cg_req_payload),
    .gmem_rsp_valid(gmem_rsp_valid && gmem_rsp_payload.id.cls == 1),
    .gmem_rsp_ready(cg_rsp_ready),
    .gmem_rsp_payload(gmem_return),
    .drained(cache_drained)
  );
  logic
      request_valid,
      request_ready,
      result_valid,
      result_ready,
      arm_valid,
      arm_ready,
      walk_start_valid,
      walk_start_ready,
      slot_release_valid,
      slot_release_ready;
  tma_setup_req_t request_payload;
  tma_setup_rsp_t result_payload;
  tma_context_ref_t arm_payload, walk_start_payload, slot_release_payload;
  tma_context_t ctx[2];
  setup_state_t slot_state[2];
  ticket_t slot_ticket[2];
  tma_span_t span[2];
  blackwell_tma_setup setup (
    .clk,
    .rst_n,
    .request_valid,
    .request_ready,
    .request_payload,
    .result_valid,
    .result_ready,
    .result_payload,
    .arm_valid,
    .arm_ready,
    .arm_payload,
    .walk_start_valid,
    .walk_start_ready,
    .walk_start_payload,
    .slot_release_valid,
    .slot_release_ready,
    .slot_release_payload,
    .ctx,
    .slot_state,
    .slot_ticket,
    .span,
    .drained(setup_drained)
  );
  logic head_valid, segment_valid, segment_ready, generated_valid, generated_ready;
  tma_context_ref_t head_payload;
  tma_segment_t segment_payload;
  ticket_t generated_payload;
  blackwell_tma_request_generator walker (
    .clk,
    .rst_n,
    .head_valid,
    .head_payload,
    .ctx,
    .walk_start_valid,
    .walk_start_payload,
    .slot_release_valid,
    .slot_release_payload,
    .segment_valid,
    .segment_ready,
    .segment_payload,
    .generated_valid,
    .generated_ready,
    .generated_payload,
    .drained(walk_drained)
  );
  logic
      begin_valid,
      begin_ready,
      start_valid,
      start_ready,
      progress_valid,
      progress_ready,
      finish_valid,
      finish_ready;
  ticket_t begin_payload, finish_payload;
  tma_start_t start_payload;
  tma_progress_t progress_payload;
  tma_tag_t tag_view[64];
  logic [19:0] event_valid;
  tma_xfer_event_t event_payload[20];
  logic [63:0] data_ref;
  logic [17:0] ticket_busy, target_visible;
  blackwell_tma_completion_tracker tracker (
    .clk,
    .rst_n,
    .begin_valid,
    .begin_ready,
    .begin_payload,
    .allocate_valid(segment_valid),
    .allocate_ready(segment_ready),
    .allocate_payload(segment_payload),
    .generated_valid,
    .generated_ready,
    .generated_payload,
    .start_valid,
    .start_ready,
    .start_payload,
    .owner_view,
    .tag_view,
    .event_valid,
    .event_payload,
    .data_ref,
    .ticket_busy,
    .target_visible,
    .progress_valid,
    .progress_ready,
    .progress_payload,
    .finish_valid,
    .finish_ready,
    .finish_payload,
    .producer_done_valid,
    .producer_done_ready,
    .producer_done_payload,
    .producer_rsp_valid,
    .producer_rsp_ready,
    .producer_rsp_payload,
    .drained(track_drained)
  );
  blackwell_tma_data_path data_path (
    .clk,
    .rst_n,
    .start_valid,
    .start_ready,
    .start_payload,
    .tag_view,
    .owner_view,
    .event_valid,
    .event_payload,
    .data_ref,
    .gmem_req_valid(dg_req_valid),
    .gmem_req_ready(dg_req_ready),
    .gmem_req_payload(dg_req_payload),
    .gmem_rsp_valid(gmem_rsp_valid && gmem_rsp_payload.id.cls == 0),
    .gmem_rsp_ready(dg_rsp_ready),
    .gmem_rsp_payload(gmem_return),
    .smem_req_valid,
    .smem_req_ready,
    .smem_req_payload,
    .smem_rsp_valid,
    .smem_rsp_ready,
    .smem_read_blocked,
    .smem_rsp_payload,
    .drained(data_drained)
  );
  for (genvar i = 0; i < 18; i++)
    assign owner_view[i] = '{
            live: state[i] != FREE,
            id: id[i],
            store: op[i] == STORE_TENSOR,
            cache_policy: policy[i],
            total_bytes: total[i],
            bound: bound[i]
        };
  assign req_cache = mem_lock ? mem_hold : cg_req_valid && (!dg_req_valid || mem_turn);
  assign gmem_req_payload = req_cache ? cg_req_payload : dg_req_payload;
  assign gmem_req_valid = cg_req_valid || dg_req_valid;
  assign cg_req_ready = req_cache && gmem_req_ready;
  assign dg_req_ready = !req_cache && gmem_req_ready;
  assign gmem_rsp_ready = gmem_rsp_payload.id.cls == 1 ? cg_rsp_ready : dg_rsp_ready;
  always_comb begin
    is_control = cmd_payload.opcode inside {COMMIT_GROUP, WAIT_GROUP_READ, PROXY_FENCE, PREFETCH_MAP};
    uses_fifo = !(cmd_payload.opcode inside {COMMIT_GROUP, WAIT_GROUP_READ});
    new_ticket = 0;
    available = 0;
    rsp_valid = 0;
    rsp_t = 0;
    drained = cache_drained && setup_drained && walk_drained && track_drained && data_drained &&
        !out_valid;
    for (int i = 0; i < 20; i++) begin
      ticket_t r;
      r = 5'((int'(rsp_cursor) + i) % 20);
      if (state[i] != FREE) drained = 0;
      if (!available && state[i] == FREE && (i < 18 || is_control)) begin
        new_ticket = 5'(i);
        available = 1;
      end
      if (!rsp_valid && state[r] == RESULT) begin
        rsp_valid = 1;
        rsp_t = r;
      end
    end
    // Preserve the general tickets while either reserved control ticket is free.
    if (is_control && state[19] == FREE) new_ticket = 19;
    if (is_control && state[18] == FREE) new_ticket = 18;
    if (ticket_locked) new_ticket = held_ticket;
    if (rsp_locked) begin
      rsp_t = held_rsp;
      rsp_valid = 1;
    end
    rsp_payload = '{done: '{id: id[rsp_t]}, logical_bytes: total[rsp_t]};
    in_payload = '{ticket: new_ticket, cmd: cmd_payload};
    in_valid = rst_n && !stop && available && cmd_valid && uses_fifo;
    cmd_ready = rst_n && !stop && available && (!uses_fifo || in_ready);
  end
  logic deps_clear, fence_clear;
  always_comb begin
    deps_clear = 1;
    fence_clear = 1;
    for (int i = 0; i < 18; i++) begin
      logic sm, gm, old_store, new_store, old_src, old_target;
      logic [10:0] old_object, new_object;
      sm = !spans[i].smem_empty && !spans[head_t%18].smem_empty && spans[i].smem_low <=
          spans[head_t%18].smem_high && spans[head_t%18].smem_low <= spans[i].smem_high;
      gm = !spans[i].gmem_empty && !spans[head_t%18].gmem_empty && spans[i].gmem_low <=
          spans[head_t%18].gmem_high && spans[head_t%18].gmem_low <= spans[i].gmem_high;
      old_store = op[i] == STORE_TENSOR;
      new_store = out_payload.cmd.opcode == STORE_TENSOR;
      old_src = source_done[i];
      old_target = target_visible[i] || target_done[i];
      old_object = barrier[i][17:7];
      new_object = out_payload.cmd.barrier_addr[17:7];
      if (head_t < 20 && older[head_t][i] && state[i] != FREE &&
          op[i] inside {LOAD_LINEAR, LOAD_TENSOR, STORE_TENSOR}) begin
        if (sm && (!new_store && old_store && !old_src || !old_store && !old_target))
          deps_clear = 0;
        if (gm && (new_store && !old_store && !old_src || old_store && !old_target)) deps_clear = 0;
        if (!old_store && !target_done[i] && !spans[head_t%18].smem_empty &&
            spans[head_t%18].smem_low <= old_object && old_object <= spans[head_t%18].smem_high)
          deps_clear = 0;
        if (!new_store && !spans[i].smem_empty && spans[i].smem_low <= new_object &&
            new_object <= spans[i].smem_high && (old_store ? !old_src : !old_target))
          deps_clear = 0;
        if (id[i].issuer == out_payload.cmd.id.issuer && !old_target) fence_clear = 0;
      end
    end
  end
  assign lookup_valid = out_valid && state[head_t] == QUEUED &&
      out_payload.cmd.opcode inside {LOAD_TENSOR, STORE_TENSOR, PREFETCH_MAP};
  assign lookup_payload = '{
          ticket: head_t,
          id: out_payload.cmd.id,
          addr: out_payload.cmd.map_addr,
          prefetch: out_payload.cmd.opcode == PREFETCH_MAP
      };
  assign desc_ready = out_valid && state[head_t] == DESC &&
      (out_payload.cmd.opcode == PREFETCH_MAP || request_ready);
  assign request_valid = out_valid &&
      ((state[head_t] == QUEUED && out_payload.cmd.opcode == LOAD_LINEAR) ||
       (state[head_t] == DESC && desc_valid && out_payload.cmd.opcode != PREFETCH_MAP));
  assign request_payload = '{
          issue: out_payload,
          raw: out_payload.cmd.opcode == LOAD_LINEAR ? '0 : desc_payload.raw
      };
  assign result_ready = rst_n;
  assign bar_bind_valid = out_valid && state[head_t] == CHECK_DEPS && deps_clear &&
      out_payload.cmd.opcode != STORE_TENSOR;
  assign bar_bind_payload = '{id: out_payload.cmd.id, addr: out_payload.cmd.barrier_addr};
  assign bar_bind_rsp_ready = rst_n;
  assign arm_payload = '{ticket: head_t, context_slot: slot[head_t]};
  assign arm_valid = out_valid && state[head_t] == PREPARED && begin_ready;
  assign begin_valid = out_valid && state[head_t] == PREPARED && arm_ready;
  assign begin_payload = head_t;
  assign head_valid = out_valid && state[head_t] == ARMED_HEAD;
  assign head_payload = arm_payload;
  assign order_req_valid = out_valid && state[head_t] == QUEUED &&
      out_payload.cmd.opcode == PROXY_FENCE && fence_clear;
  assign order_req_payload = '{
          id: out_payload.cmd.id,
          kind: 3'd2,
          scope: 2'd0,
          from_proxy: 2'd0,
          to_proxy: 2'd1,
          addr: 64'd0,
          bytes: 32'd0
      };
  assign order_rsp_ready = rst_n;
  assign out_ready = walk_start_valid ||
      (desc_valid && desc_ready && out_payload.cmd.opcode == PREFETCH_MAP) ||
      (order_rsp_valid && order_rsp_ready && state[head_t] == FENCE_WAIT);
  assign progress_ready = rst_n;
  assign finish_ready = rst_n;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < 20; i++) begin
        state[i] <= FREE;
        older[i] <= 0;
      end
      bound <= 0;
      source_done <= 0;
      target_done <= 0;
      mem_lock <= 0;
      mem_turn <= 0;
      rsp_cursor <= 0;
      rsp_locked <= 0;
      ticket_locked <= 0;
    end else begin
      // Only this ingress allocates tickets. A held ticket stays free until fire.
      ticket_locked <= in_valid && !in_ready;
      if (in_valid && !in_ready && !ticket_locked) held_ticket <= new_ticket;
      if (gmem_req_valid) begin
        mem_lock <= !gmem_req_ready;
        mem_hold <= req_cache;
        if (gmem_req_ready) mem_turn <= !req_cache;
      end
      for (int i = 0; i < 20; i++)
      if (state[i] == GROUP_WAIT) begin
        logic [17:0] remaining;
        remaining = wait_pending[i];
        if (progress_valid && progress_payload.boundary == 1)
          remaining[progress_payload.ticket] = 0;
        wait_pending[i] <= remaining;
        if (remaining == 0) state[i] <= RESULT;
      end
      if (rsp_valid) begin
        rsp_locked <= !rsp_ready;
        held_rsp <= rsp_t;
        if (rsp_ready) begin
          state[rsp_t] <= FREE;
          rsp_cursor <= rsp_t == 19 ? 0 : rsp_t + 5'd1;
        end
      end
      if (cmd_valid && cmd_ready) begin
        logic [17:0] pending_set;
        pending_set = 0;
        for (int i = 0; i < 20; i++) begin
          older[new_ticket][i] <= state[i] != FREE && !(rsp_valid && rsp_ready && rsp_t == 5'(i));
          older[i][new_ticket] <= 0;
          if (i < 18 && state[i] != FREE && id[i].issuer == cmd_payload.id.issuer &&
              op[i] inside {LOAD_TENSOR, STORE_TENSOR}) begin
            if (cmd_payload.opcode == COMMIT_GROUP && age[i] != 2)
              age[i] <= age[i] + 2'd1;
            if (age[i] > 2'(cmd_payload.wait_n) && !source_done[i] &&
                !(progress_valid && progress_payload.boundary == 1 &&
                  progress_payload.ticket == 5'(i)))
              pending_set[i] = 1;
          end
        end
        state[new_ticket] <= cmd_payload.opcode == COMMIT_GROUP ? RESULT :
            cmd_payload.opcode == WAIT_GROUP_READ ? (pending_set == 0 ? RESULT : GROUP_WAIT) :
            QUEUED;
        id[new_ticket] <= cmd_payload.id;
        op[new_ticket] <= cmd_payload.opcode;
        total[new_ticket] <= 0;
        bound[new_ticket] <= 0;
        source_done[new_ticket] <= 0;
        target_done[new_ticket] <= 0;
        wait_pending[new_ticket] <= pending_set;
        if (new_ticket < 18) begin
          age[new_ticket] <= 0;
          barrier[new_ticket] <= cmd_payload.barrier_addr;
          policy[new_ticket] <= cmd_payload.cache_policy;
        end
      end
      if (lookup_valid && lookup_ready) state[head_t] <= DESC;
      if (desc_valid && desc_ready && out_payload.cmd.opcode == PREFETCH_MAP) state[head_t] <= RESULT;
      if (request_valid && request_ready) state[head_t] <= SETUP;
      if (result_valid && result_ready) begin
        total[head_t] <= result_payload.total_bytes;
        spans[head_t] <= span[result_payload.context_slot];
        slot[head_t] <= result_payload.context_slot;
        state[head_t] <= CHECK_DEPS;
      end
      if (out_valid && state[head_t] == CHECK_DEPS && out_payload.cmd.opcode == STORE_TENSOR &&
          deps_clear)
        state[head_t] <= PREPARED;
      if (bar_bind_valid && bar_bind_ready) state[head_t] <= BIND_WAIT;
      if (bar_bind_rsp_valid && bar_bind_rsp_ready) begin
        bound[head_t] <= 1;
        state[head_t] <= PREPARED;
      end
      if (arm_valid && arm_ready) state[head_t] <= ARMED_HEAD;
      if (walk_start_valid) state[head_t] <= ISSUED;
      if (progress_valid && progress_ready) begin
        if (progress_payload.boundary == 1) source_done[progress_payload.ticket] <= 1;
        else target_done[progress_payload.ticket] <= 1;
      end
      if (finish_valid && finish_ready) state[finish_payload] <= RESULT;
      if (order_req_valid && order_req_ready) state[head_t] <= FENCE_WAIT;
      if (order_rsp_valid && order_rsp_ready) state[head_t] <= RESULT;
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (cmd_valid) begin
        assert (cmd_payload.id.epoch == epoch && cmd_payload.id.seq != '1);
        for (int i = 0; i < 20; i++)
          assert (state[i] == FREE || id[i] != cmd_payload.id);
        assert (cmd_payload.opcode inside {LOAD_TENSOR, STORE_TENSOR, LOAD_LINEAR, COMMIT_GROUP,
                                          WAIT_GROUP_READ, PROXY_FENCE, PREFETCH_MAP})
            else $fatal(1, "TMA_CMD_OPCODE");
        if (!(cmd_payload.opcode inside {LOAD_TENSOR, STORE_TENSOR, PREFETCH_MAP}))
          assert (cmd_payload.map_addr == 0);
        if (!(cmd_payload.opcode inside {LOAD_TENSOR, STORE_TENSOR, LOAD_LINEAR}))
          assert (cmd_payload.smem_addr == 0);
        if (!(cmd_payload.opcode inside {LOAD_TENSOR, STORE_TENSOR}))
          assert ({cmd_payload.coord, cmd_payload.cache_policy} == '0);
        if (!(cmd_payload.opcode inside {LOAD_TENSOR, LOAD_LINEAR}))
          assert (cmd_payload.barrier_addr == 0);
        if (cmd_payload.opcode != LOAD_LINEAR) assert ({cmd_payload.global_addr, cmd_payload.bytes} == '0);
        if (cmd_payload.opcode != WAIT_GROUP_READ) assert (!cmd_payload.wait_n);
        if (cmd_payload.opcode inside {LOAD_TENSOR, STORE_TENSOR, PREFETCH_MAP})
          assert (cmd_payload.map_addr[6:0] == 0) else $fatal(1, "TMA_MAP_ALIGNMENT");
        if (cmd_payload.opcode inside {LOAD_TENSOR, STORE_TENSOR, LOAD_LINEAR})
          assert (cmd_payload.smem_addr[3:0] == 0);
        if (cmd_payload.opcode inside {LOAD_TENSOR, LOAD_LINEAR})
          assert (cmd_payload.barrier_addr[2:0] == 0 && cmd_payload.barrier_addr < 233472);
        if (cmd_payload.opcode == LOAD_LINEAR)
          assert (cmd_payload.global_addr[3:0] == 0 && cmd_payload.bytes[3:0] == 0 &&
                  cmd_payload.bytes <= 1048575 &&
                  33'(cmd_payload.smem_addr) + 33'(cmd_payload.bytes) <= 233472 &&
                  65'(cmd_payload.global_addr) + 65'(cmd_payload.bytes) <= 65'h1_0000000000000000);
      end
      if (gmem_rsp_valid) begin
        assert (gmem_rsp_payload.status == OK) else $fatal(1, "TMA GMEM response status must be OK");
        assert (gmem_rsp_payload.id.cls <= 1);
      end
      if (desc_valid) assert (out_valid && state[head_t] == DESC && desc_payload.ticket == head_t);
      if (result_valid) assert (out_valid && state[head_t] == SETUP && result_payload.ticket == head_t);
      if (bar_bind_rsp_valid)
        assert (out_valid && state[head_t] == BIND_WAIT && bar_bind_rsp_payload.id == id[head_t]);
      if (order_rsp_valid)
        assert (out_valid && state[head_t] == FENCE_WAIT && order_rsp_payload.id == id[head_t]);
    end
  end
  assert property (@(posedge clk) disable iff (!rst_n)
      in_valid && !in_ready |=> in_valid && $stable(in_payload));
  assert property (@(posedge clk) disable iff (!rst_n)
      cmd_valid && !cmd_ready |=> cmd_valid && $stable(cmd_payload));
  assert property (@(posedge clk) disable iff (!rst_n)
      gmem_rsp_valid && !gmem_rsp_ready |=> gmem_rsp_valid && $stable(gmem_rsp_payload));
`endif
endmodule
