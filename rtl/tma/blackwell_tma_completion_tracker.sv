module blackwell_tma_completion_tracker
  import blackwell_async_pkg::*;
  import blackwell_mbarrier_pkg::*;
  import blackwell_tma_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic halt_i,
  input logic begin_valid,
  input logic allocate_valid,
  input logic generated_valid,
  input logic start_ready,
  output logic begin_ready,
  output logic allocate_ready,
  output logic generated_ready,
  output logic start_valid,
  input ticket_t begin_payload,
  input ticket_t generated_payload,
  input tma_segment_t allocate_payload,
  output tma_start_t start_payload,
  input tma_owner_view_t owner_view[18],
  output tma_tag_t tag_view[64],
  input logic [19:0] event_valid,
  input tma_xfer_event_t event_payload[20],
  input logic [63:0] data_ref,
  output logic [17:0] ticket_busy,
  output logic [17:0] target_visible,
  output logic progress_valid,
  output logic finish_valid,
  output logic producer_done_valid,
  output logic producer_rsp_ready,
  input logic progress_ready,
  input logic finish_ready,
  input logic producer_done_ready,
  input logic producer_rsp_valid,
  output tma_progress_t progress_payload,
  output ticket_t finish_payload,
  output bar_producer_done_t producer_done_payload,
  input op_done_t producer_rsp_payload,
  output logic drained,
  output logic fault
);
  tma_tag_t next_tag[64];
  logic [17:0] closed, source_reported, full_reported, bar_done;
  logic [6:0] pending_src[18], pending_dst[18], live_tags[18];
  logic [6:0] src_settled[18], dst_settled[18];
  logic free_tag, ret_any, events_bad;
  logic [5:0] free_index, ret_index, ret_cursor;
  logic [4:0]
      prog_cursor,
      finish_cursor,
      producer_cursor,
      prog_hold,
      finish_hold,
      producer_hold,
      producer_owner;
  logic prog_lock, finish_lock, producer_lock, producer_live;
  logic [1:0] boundary_hold;
  logic [4:0] p, f, b;
  always_comb begin
    free_tag = 0;
    free_index = 0;
    ret_any = 0;
    ret_index = 0;
    for (int i = 0; i < 64; i++) begin
      logic [5:0] r;
      r = ret_cursor + 6'(i);
      if (!free_tag && tag_view[i].state == TAG_FREE) begin
        free_tag = 1;
        free_index = 6'(i);
      end
      if (!ret_any && tag_view[r].state == RETIRE && !data_ref[r] &&
          !(start_valid && start_payload.key.tag == r)) begin
        ret_any = 1;
        ret_index = r;
      end
    end
    begin_ready = rst_n && !fault && begin_payload < 18 && !ticket_busy[begin_payload];
    allocate_ready = rst_n && !fault && free_tag && (!start_valid || start_ready);
    generated_ready = rst_n && !fault;
    drained = ticket_busy == 0 && !start_valid;
  end
  always_comb begin
    events_bad = 0;
    for (int i = 0; i < 64; i++) next_tag[i] = tag_view[i];
    for (int i = 0; i < 18; i++) begin
      src_settled[i] = 0;
      dst_settled[i] = 0;
    end
    if (start_valid && start_ready) next_tag[start_payload.key.tag].state = SOURCE;
    for (int i = 0; i < 20; i++) begin
      logic [5:0] t;
      logic [2:0] g;
      t = event_payload[i].key.tag;
      g = event_payload[i].grp;
      if (event_valid[i]) begin
        if (tag_view[t].state inside {TAG_FREE, RETIRE} ||
            event_payload[i].key.phase != tag_view[t].phase)
          events_bad = 1;
        else
          case (event_payload[i].kind)
            GMEM_REQ: begin
              if (tag_view[t].gmem_sent) events_bad = 1;
              next_tag[t].gmem_sent = 1;
            end
            GMEM_RSP: begin
              if (!tag_view[t].gmem_sent || tag_view[t].gmem_done) events_bad = 1;
              next_tag[t].gmem_done = 1;
            end
            SMEM_REQ: begin
              if (tag_view[t].smem_sent[g]) events_bad = 1;
              next_tag[t].smem_sent[g] = 1;
            end
            SMEM_RSP: begin
              if (!tag_view[t].smem_sent[g] || tag_view[t].smem_done[g]) events_bad = 1;
              next_tag[t].smem_done[g] = 1;
            end
            LOCAL_ZERO: next_tag[t].source_done = 1;
            NO_ACCESS: begin
              next_tag[t].source_done = 1;
              next_tag[t].target_done = 1;
            end
            default: events_bad = 1;
          endcase
      end
    end
    for (int i = 0; i < 64; i++) begin
      logic [7:0] groups;
      ticket_t t;
      t = tag_view[i].ticket;
      groups = active_groups(tag_view[i]);
      if (next_tag[i].state inside {SOURCE, TARGET}) begin
        if (owner_view[t].store) begin
          if (!tag_view[i].oob && (next_tag[i].smem_done & groups) == groups)
            next_tag[i].source_done = 1;
          if (next_tag[i].gmem_done) next_tag[i].target_done = 1;
        end else begin
          if (next_tag[i].gmem_done) next_tag[i].source_done = 1;
          if ((next_tag[i].smem_done & groups) == groups) next_tag[i].target_done = 1;
        end
        if (!tag_view[i].source_done && next_tag[i].source_done)
          src_settled[t] = src_settled[t] + 1'b1;
        if (!tag_view[i].target_done && next_tag[i].target_done)
          dst_settled[t] = dst_settled[t] + 1'b1;
        if (next_tag[i].source_done) next_tag[i].state = next_tag[i].target_done ? RETIRE : TARGET;
      end
    end
  end
  always_comb begin
    progress_valid = 0;
    finish_valid = 0;
    producer_done_valid = 0;
    p = 0;
    f = 0;
    b = 0;
    progress_payload.boundary = 0;
    for (int i = 0; i < 18; i++) begin
      ticket_t a, z, k;
      a = 5'((int'(prog_cursor) + i) % 18);
      z = 5'((int'(finish_cursor) + i) % 18);
      k = 5'((int'(producer_cursor) + i) % 18);
      target_visible[i] = ticket_busy[i] && closed[i] && pending_dst[i] == 0;
      if (!progress_valid && ticket_busy[a] && closed[a]) begin
        if (!source_reported[a] && pending_src[a] == 0) begin
          p = a;
          progress_valid = 1;
          progress_payload.boundary = 1;
        end else if (source_reported[a] && !full_reported[a] && live_tags[a] == 0 &&
                     (owner_view[a].store || bar_done[a])) begin
          p = a;
          progress_valid = 1;
          progress_payload.boundary = 2;
        end
      end
      if (!finish_valid && ticket_busy[z] && full_reported[z]) begin
        f = z;
        finish_valid = 1;
      end
      if (!producer_done_valid && ticket_busy[k] && owner_view[k].bound && closed[k] &&
          source_reported[k] && live_tags[k] == 0 && !bar_done[k] && !producer_live) begin
        b = k;
        producer_done_valid = 1;
      end
    end
    if (prog_lock) begin
      p = prog_hold;
      progress_valid = 1;
      progress_payload.boundary = boundary_hold;
    end
    if (finish_lock) begin
      f = finish_hold;
      finish_valid = 1;
    end
    if (producer_lock) begin
      b = producer_hold;
      producer_done_valid = 1;
    end
    progress_payload.ticket = p;
    finish_payload = f;
    producer_done_payload = '{
        id: owner_view[b].id,
        bytes: owner_view[b].total_bytes[31:0],
        status: OK
    };
    producer_rsp_ready = rst_n && !fault;
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < 64; i++) tag_view[i] <= '0;
      ticket_busy <= 0;
      closed <= 0;
      source_reported <= 0;
      full_reported <= 0;
      bar_done <= 0;
      start_valid <= 0;
      fault <= 0;
      ret_cursor <= 0;
      prog_cursor <= 0;
      finish_cursor <= 0;
      producer_cursor <= 0;
      prog_lock <= 0;
      finish_lock <= 0;
      producer_lock <= 0;
      producer_live <= 0;
    end else if (!halt_i && !fault) begin
      for (int i = 0; i < 64; i++) tag_view[i] <= next_tag[i];
      if (events_bad) fault <= 1;
      if (begin_valid && begin_ready) begin
        ticket_busy[begin_payload] <= 1;
        closed[begin_payload] <= 0;
        source_reported[begin_payload] <= 0;
        full_reported[begin_payload] <= 0;
        bar_done[begin_payload] <= 0;
        if (!owner_view[begin_payload].live) fault <= 1;
      end
      if (start_valid && start_ready) start_valid <= 0;
      if (allocate_valid && allocate_ready) begin
        tma_tag_t init_tag;
        init_tag = '0;
        init_tag.state = START;
        init_tag.phase = tag_view[free_index].phase;
        init_tag.ticket = allocate_payload.ticket;
        init_tag.sector = allocate_payload.smem_sector[17:7];
        init_tag.soff = allocate_payload.soff;
        init_tag.goff = allocate_payload.goff;
        init_tag.xor_group = allocate_payload.xor_group;
        init_tag.logical_bytes = allocate_payload.logical_bytes;
        init_tag.oob = allocate_payload.oob;
        if (allocate_payload.ticket >= 18 || !ticket_busy[allocate_payload.ticket] ||
            closed[allocate_payload.ticket])
          fault <= 1;
        tag_view[free_index] <= init_tag;
        start_valid <= 1;
        start_payload <= '{
            key: '{tag: free_index, phase: init_tag.phase},
            segment: allocate_payload
        };
        if (allocate_payload.last) closed[allocate_payload.ticket] <= 1;
      end
      if (generated_valid && generated_ready) begin
        if (generated_payload >= 18 || !ticket_busy[generated_payload] || closed[generated_payload])
          fault <= 1;
        closed[generated_payload] <= 1;
      end
      if (ret_any) begin
        tag_view[ret_index].state <= TAG_FREE;
        tag_view[ret_index].phase <= !tag_view[ret_index].phase;
        ret_cursor <= ret_index + 6'd1;
      end
      for (int i = 0; i < 18; i++) begin
        logic alloc, ret;
        alloc = allocate_valid && allocate_ready && allocate_payload.ticket == 5'(i);
        ret = ret_any && tag_view[ret_index].ticket == 5'(i);
        if (begin_valid && begin_ready && begin_payload == 5'(i)) begin
          pending_src[i] <= 0;
          pending_dst[i] <= 0;
          live_tags[i] <= 0;
        end else if (ticket_busy[i]) begin
          pending_src[i] <= pending_src[i] + 7'(alloc) - src_settled[i];
          pending_dst[i] <= pending_dst[i] + 7'(alloc) - dst_settled[i];
          live_tags[i] <= live_tags[i] + 7'(alloc) - 7'(ret);
        end
      end
      if (progress_valid) begin
        prog_lock <= !progress_ready;
        prog_hold <= p;
        boundary_hold <= progress_payload.boundary;
        if (progress_ready) begin
          prog_cursor <= p == 17 ? 0 : p + 5'd1;
          if (progress_payload.boundary == 1) source_reported[p] <= 1;
          else full_reported[p] <= 1;
        end
      end
      if (producer_done_valid) begin
        producer_lock <= !producer_done_ready;
        producer_hold <= b;
        if (producer_done_ready) begin
          producer_live <= 1;
          producer_owner <= b;
          producer_cursor <= b == 17 ? 0 : b + 5'd1;
        end
      end
      if (producer_rsp_valid) begin
        if (!producer_live || producer_rsp_payload.status != OK ||
            producer_rsp_payload.id != owner_view[producer_owner].id)
          fault <= 1;
        else begin
          producer_live <= 0;
          bar_done[producer_owner] <= 1;
        end
      end
      if (finish_valid) begin
        finish_lock <= !finish_ready;
        finish_hold <= f;
        if (finish_ready) begin
          ticket_busy[f] <= 0;
          finish_cursor <= f == 17 ? 0 : f + 5'd1;
        end
      end
    end
  end
endmodule
