module blackwell_mbarrier_frontend
  import blackwell_async_pkg::*;
  import blackwell_mbarrier_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic halt_i,
  input logic stop,
  input logic [15:0] epoch,
  output logic drained,
  output logic fault,
  input logic sw_cmd_valid,
  input logic sw_rsp_ready,
  input logic wait_cmd_ready,
  input logic wait_rsp_valid,
  output logic sw_cmd_ready,
  output logic sw_rsp_valid,
  output logic wait_cmd_valid,
  output logic wait_rsp_ready,
  input bar_cmd_t sw_cmd_payload,
  output bar_rsp_t sw_rsp_payload,
  output bar_cmd_t wait_cmd_payload,
  input bar_rsp_t wait_rsp_payload,
  input logic bind_req_valid,
  input logic bind_rsp_ready,
  input logic producer_done_valid,
  input logic producer_rsp_ready,
  input logic tc_req_valid,
  input logic tc_rsp_ready,
  output logic bind_req_ready,
  output logic bind_rsp_valid,
  output logic producer_done_ready,
  output logic producer_rsp_valid,
  output logic tc_req_ready,
  output logic tc_rsp_valid,
  input bar_bind_t bind_req_payload,
  input bar_producer_done_t producer_done_payload,
  input tc_bar_req_t tc_req_payload,
  output op_done_t bind_rsp_payload,
  output op_done_t producer_rsp_payload,
  output op_done_t tc_rsp_payload,
  input logic service_req_ready,
  input logic service_rsp_valid,
  input logic wait_probe_req_valid,
  input logic wait_probe_rsp_ready,
  output logic service_req_valid,
  output logic service_rsp_ready,
  output logic wait_probe_req_ready,
  output logic wait_probe_rsp_valid,
  output bar_service_req_t service_req_payload,
  input bar_service_rsp_t service_rsp_payload,
  input bar_service_req_t wait_probe_req_payload,
  output bar_service_rsp_t wait_probe_rsp_payload,
  input logic release_req_ready,
  input logic release_rsp_valid,
  output logic release_req_valid,
  output logic release_rsp_ready,
  output order_req_t release_req_payload,
  input order_rsp_t release_rsp_payload,
  output logic [31:0] wait_busy_addr,
  output logic [31:0] commit_busy_addr,
  input logic wait_addr_busy,
  input logic commit_addr_busy,
  input logic [31:0] commit_candidate_addr,
  output logic commit_blocked
);
  typedef enum logic [2:0] {
    S_FREE,
    S_NEW,
    S_ORDER,
    S_SERVICE,
    S_PENDING,
    S_TRY,
    S_RESULT
  } sw_state_t;
  typedef enum logic [2:0] {
    P_FREE,
    P_QUERY,
    P_QUERY_WAIT,
    P_BIND,
    P_DATA,
    P_UPDATE,
    P_UPDATE_WAIT,
    P_RESULT
  } producer_state_t;
  typedef enum logic [1:0] {
    T_FREE,
    T_ISSUE,
    T_PENDING,
    T_RESULT
  } tc_state_t;
  sw_state_t sw[8];
  producer_state_t ps[16];
  tc_state_t ts;
  bar_cmd_t cmd[8];
  bar_rsp_t result[8];
  logic [7:0] older[8];
  bar_bind_t producer[16];
  logic [31:0] bytes[16];
  logic [15:0] phase;
  tc_bar_req_t tc;

  logic [7:0] eligible, lifecycle;
  logic [2:0] free_s, result_s, wait_s, order_s, service_s, exclusive_s;
  logic [3:0] free_p, bind_p, done_p, update_p, match_p;
  logic [4:0] class_cursor[4], class_slot[4], held_service_slot;
  logic [1:0] class_rr, service_class, held_class;
  logic [3:0] class_valid;
  logic [2:0] result_cursor, wait_cursor, order_cursor, lifecycle_cursor;
  logic [3:0] bind_cursor, done_cursor;
  logic select_wait_rsp, wait_rsp_lock, prefer_wait_rsp;
  logic result_lock, wait_lock, order_lock, bind_lock, done_lock, service_lock, order_live;
  logic [2:0] held_result, held_wait, held_order, order_owner;
  logic [3:0] held_bind, held_done;
  logic free_sw, free_prod, have_svc, have_wait, have_order, have_result, have_bind, have_done;
  logic have_lifecycle, matches_prod, duplicate_prod, bind_blocked;
  logic tc_busy, producer_busy;
  function automatic logic lifecycle_op(input bar_op_t op);
    return op inside {BAR_INIT, BAR_INVAL};
  endfunction

  always_comb begin
    free_sw = 0;
    free_s = 0;
    eligible = 0;
    lifecycle = 0;
    drained = (ts == T_FREE);
    commit_blocked = 0;
    bind_blocked = 0;
    for (int i = 0; i < 8; i++) begin
      if (sw[i] == S_FREE && !free_sw) begin
        free_sw = 1;
        free_s = 3'(i);
      end
      if (sw[i] != S_FREE) begin
        drained = 0;
        if (lifecycle_op(cmd[i].op)) begin
          commit_blocked |= cmd[i].addr == commit_candidate_addr;
          bind_blocked |= cmd[i].addr == bind_req_payload.addr;
        end
      end
      eligible[i] = sw[i] inside {S_NEW, S_SERVICE};
      for (int j = 0; j < 8; j++) begin
        logic same_object;
        same_object = cmd[i].op != BAR_FENCE_INIT && cmd[j].op != BAR_FENCE_INIT &&
            cmd[i].addr == cmd[j].addr;
        if (older[i][j] && sw[j] != S_FREE) begin
          if (cmd[i].id.issuer == cmd[j].id.issuer && sw[j] != S_RESULT) eligible[i] = 0;
          if (same_object && (lifecycle_op(cmd[i].op) || lifecycle_op(cmd[j].op))) eligible[i] = 0;
        end
      end
      lifecycle[i] = eligible[i] && lifecycle_op(cmd[i].op);
    end
    sw_cmd_ready = rst_n && !stop && !fault && free_sw;
    if (sw_cmd_valid && sw_cmd_ready && lifecycle_op(sw_cmd_payload.op)) begin
      commit_blocked |= sw_cmd_payload.addr == commit_candidate_addr;
      bind_blocked |= sw_cmd_payload.addr == bind_req_payload.addr;
    end
    have_lifecycle = 0;
    exclusive_s = 0;
    for (int i = 0; i < 8; i++) begin
      logic [2:0] n;
      n = lifecycle_cursor + 3'(i);
      if (!have_lifecycle && lifecycle[n]) begin
        have_lifecycle = 1;
        exclusive_s = n;
      end
    end
    wait_busy_addr = cmd[exclusive_s].addr;
    commit_busy_addr = cmd[exclusive_s].addr;
    producer_busy = 0;
    free_prod = 0;
    free_p = 0;
    matches_prod = 0;
    match_p = 0;
    duplicate_prod = 0;
    for (int i = 0; i < 16; i++) begin
      if (ps[i] == P_FREE && !free_prod) begin
        free_prod = 1;
        free_p = 4'(i);
      end
      if (ps[i] != P_FREE) begin
        drained = 0;
        producer_busy |= producer[i].addr == cmd[exclusive_s].addr;
        duplicate_prod |= producer[i].id == bind_req_payload.id;
        if (producer[i].id == producer_done_payload.id && ps[i] == P_DATA) begin
          matches_prod = 1;
          match_p = 4'(i);
        end
      end
    end
    tc_busy = ts != T_FREE && tc.addr == cmd[exclusive_s].addr;
    bind_req_ready = rst_n && !fault && free_prod && !bind_blocked;
    producer_done_ready = rst_n && !fault;
    tc_req_ready = rst_n && !fault && ts == T_FREE;
  end
  always_comb begin
    have_order = 0;
    order_s = 0;
    have_wait = 0;
    wait_s = 0;
    have_result = 0;
    result_s = 0;
    for (int i = 0; i < 8; i++) begin
      logic [2:0] o, w, r;
      o = order_cursor + 3'(i);
      w = wait_cursor + 3'(i);
      r = result_cursor + 3'(i);
      if (!have_order && eligible[o] && sw[o] == S_NEW &&
          cmd[o].op inside {BAR_ARRIVE, BAR_EXPECT, BAR_FENCE_INIT}) begin
        have_order = 1;
        order_s = o;
      end
      if (!have_wait && eligible[w] && sw[w] == S_NEW && cmd[w].op == BAR_TRY) begin
        have_wait = 1;
        wait_s = w;
      end
      if (!have_result && sw[r] == S_RESULT) begin
        have_result = 1;
        result_s = r;
      end
    end
    if (order_lock) begin
      have_order = 1;
      order_s = held_order;
    end
    if (wait_lock) begin
      have_wait = 1;
      wait_s = held_wait;
    end
    if (result_lock) begin
      have_result = 1;
      result_s = held_result;
    end
    wait_cmd_valid = have_wait && !fault;
    wait_cmd_payload = cmd[wait_s];
    select_wait_rsp = wait_rsp_lock ||
        (!result_lock && wait_rsp_valid && (!have_result || prefer_wait_rsp));
    sw_rsp_valid = have_result || wait_rsp_valid;
    sw_rsp_payload = select_wait_rsp ? wait_rsp_payload : result[result_s];
    wait_rsp_ready = select_wait_rsp && sw_rsp_ready;
    release_req_valid = have_order && !order_live && !fault;
    release_req_payload = '0;
    release_req_payload.id = cmd[order_s].id;
    if (cmd[order_s].op == BAR_FENCE_INIT) begin
      release_req_payload.kind = 5;
      release_req_payload.scope = 3;
    end else release_req_payload.to_proxy = 1;
    release_rsp_ready = !fault;
  end
  always_comb begin
    class_valid = 0;
    class_slot = '{default: 0};
    for (int i = 0; i < 8; i++) begin
      logic [2:0] n;
      n = class_cursor[0][2:0] + 3'(i);
      if (!class_valid[0] && eligible[n] &&
          (sw[n] == S_SERVICE || (lifecycle[n] && n == exclusive_s && !wait_addr_busy &&
                                  !commit_addr_busy && !tc_busy && !producer_busy))) begin
        class_valid[0] = 1;
        class_slot[0] = 5'(n);
      end
    end
    class_valid[1] = wait_probe_req_valid;
    class_slot[1] = wait_probe_req_payload.slot;
    class_valid[2] = ts == T_ISSUE;
    have_bind = 0;
    bind_p = 0;
    have_done = 0;
    done_p = 0;
    for (int i = 0; i < 16; i++) begin
      logic [3:0] p, b, d;
      p = class_cursor[3][3:0] + 4'(i);
      b = bind_cursor + 4'(i);
      d = done_cursor + 4'(i);
      if (!class_valid[3] && ps[p] inside {P_QUERY, P_UPDATE}) begin
        class_valid[3] = 1;
        class_slot[3] = 5'(p);
      end
      if (!have_bind && ps[b] == P_BIND) begin
        have_bind = 1;
        bind_p = b;
      end
      if (!have_done && ps[d] == P_RESULT) begin
        have_done = 1;
        done_p = d;
      end
    end
    if (bind_lock) begin
      have_bind = 1;
      bind_p = held_bind;
    end
    if (done_lock) begin
      have_done = 1;
      done_p = held_done;
    end
    bind_rsp_valid = have_bind;
    bind_rsp_payload = '{id: producer[bind_p].id, status: OK};
    producer_rsp_valid = have_done;
    producer_rsp_payload = '{id: producer[done_p].id, status: OK};
    tc_rsp_valid = ts == T_RESULT;
    tc_rsp_payload = '{id: tc.id, status: OK};
    have_svc = 0;
    service_class = 0;
    for (int i = 0; i < 4; i++) begin
      logic [1:0] n;
      n = class_rr + 2'(i);
      if (!have_svc && class_valid[n]) begin
        have_svc = 1;
        service_class = n;
      end
    end
    if (service_lock) begin
      have_svc = 1;
      service_class = held_class;
    end
    service_req_valid = have_svc && !fault;
    service_req_payload = '0;
    service_req_payload.route = service_class;
    service_req_payload.slot = service_lock ? held_service_slot : class_slot[service_class];
    service_s = service_req_payload.slot[2:0];
    update_p = service_req_payload.slot[3:0];
    case (service_class)
      0: service_req_payload.cmd = cmd[service_s];
      1: service_req_payload = wait_probe_req_payload;
      2: begin
        service_req_payload.cmd.id = tc.id;
        service_req_payload.cmd.op = BAR_ARRIVE;
        service_req_payload.cmd.addr = tc.addr;
        service_req_payload.cmd.count = 1;
      end
      3: begin
        service_req_payload.cmd.id = producer[update_p].id;
        service_req_payload.cmd.addr = producer[update_p].addr;
        service_req_payload.cmd.op = ps[update_p] == P_QUERY ? BAR_QUERY : BAR_COMPLETE;
        if (ps[update_p] == P_UPDATE) begin
          service_req_payload.cmd.guard = 1;
          service_req_payload.cmd.parity = phase[update_p];
          service_req_payload.cmd.bytes = bytes[update_p];
        end
      end
    endcase
    wait_probe_req_ready = service_req_valid && service_class == 1 && service_req_ready;
    service_rsp_ready = !fault && (service_rsp_payload.route != 1 || wait_probe_rsp_ready);
    wait_probe_rsp_valid = service_rsp_valid && service_rsp_payload.route == 1;
    wait_probe_rsp_payload = service_rsp_payload;
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < 8; i++) begin
        sw[i] <= S_FREE;
        older[i] <= '0;
      end
      for (int i = 0; i < 16; i++) ps[i] <= P_FREE;
      for (int i = 0; i < 4; i++) class_cursor[i] <= 0;
      ts <= T_FREE;
      fault <= 0;
      order_live <= 0;
      result_lock <= 0;
      wait_rsp_lock <= 0;
      prefer_wait_rsp <= 0;
      wait_lock <= 0;
      order_lock <= 0;
      bind_lock <= 0;
      done_lock <= 0;
      service_lock <= 0;
      class_rr <= 0;
      result_cursor <= 0;
      wait_cursor <= 0;
      order_cursor <= 0;
      bind_cursor <= 0;
      done_cursor <= 0;
      lifecycle_cursor <= 0;
    end else if (!halt_i && !fault) begin
      lifecycle_cursor <= lifecycle_cursor + 3'd1;
      if (sw_cmd_valid && sw_cmd_ready) begin
        status_t status;
        status = OK;
        if (sw_cmd_payload.op > BAR_FENCE_INIT) status = UNSUPPORTED;
        else if (sw_cmd_payload.id.epoch != epoch) status = STALE;
        else if (sw_cmd_payload.op != BAR_FENCE_INIT &&
                 (sw_cmd_payload.addr[2:0] != 0 || sw_cmd_payload.addr >= 233472))
          status = RANGE;
        else if ((sw_cmd_payload.op inside {BAR_INIT, BAR_ARRIVE} &&
                  !(sw_cmd_payload.count inside {[1 : 1048575]})) ||
                 (sw_cmd_payload.op == BAR_EXPECT && sw_cmd_payload.bytes > 1048575))
          status = RANGE;
        cmd[free_s] <= sw_cmd_payload;
        result[free_s] <= '{id: sw_cmd_payload.id, status: status, completed: 0};
        sw[free_s] <= status == OK ? S_NEW : S_RESULT;
        for (int i = 0; i < 8; i++) begin
          older[free_s][i] <= sw[i] != S_FREE &&
              !(sw_rsp_valid && sw_rsp_ready && !select_wait_rsp && result_s == 3'(i));
          older[i][free_s] <= 0;
        end
      end
      if (sw_rsp_valid) begin
        result_lock <= !sw_rsp_ready && !select_wait_rsp;
        wait_rsp_lock <= !sw_rsp_ready && select_wait_rsp;
        held_result <= result_s;
        if (sw_rsp_ready) begin
          prefer_wait_rsp <= !select_wait_rsp;
          if (!select_wait_rsp) begin
            sw[result_s] <= S_FREE;
            result_cursor <= result_s + 3'd1;
          end
        end
      end
      if (wait_cmd_valid) begin
        wait_lock <= !wait_cmd_ready;
        held_wait <= wait_s;
        if (wait_cmd_ready) begin
          sw[wait_s] <= S_FREE;
          wait_cursor <= wait_s + 3'd1;
        end
      end
      if (release_req_valid) begin
        order_lock <= !release_req_ready;
        held_order <= order_s;
        if (release_req_ready) begin
          order_live <= 1;
          order_owner <= order_s;
          sw[order_s] <= S_ORDER;
          order_cursor <= order_s + 3'd1;
        end
      end
      if (release_rsp_valid) begin
        if (!order_live || release_rsp_payload.id != cmd[order_owner].id ||
            release_rsp_payload.status != OK)
          fault <= 1;
        else begin
          order_live <= 0;
          sw[order_owner] <= cmd[order_owner].op == BAR_FENCE_INIT ? S_RESULT : S_SERVICE;
        end
      end
      if (bind_req_valid && bind_req_ready) begin
        if (duplicate_prod || bind_req_payload.id.epoch != epoch) fault <= 1;
        else begin
          ps[free_p] <= P_QUERY;
          producer[free_p] <= bind_req_payload;
        end
      end
      if (bind_rsp_valid) begin
        bind_lock <= !bind_rsp_ready;
        held_bind <= bind_p;
        if (bind_rsp_ready) begin
          ps[bind_p] <= P_DATA;
          bind_cursor <= bind_p + 4'd1;
        end
      end
      if (producer_done_valid && producer_done_ready) begin
        if (!matches_prod || producer_done_payload.status != OK) fault <= 1;
        else begin
          ps[match_p] <= P_UPDATE;
          bytes[match_p] <= producer_done_payload.bytes;
        end
      end
      if (producer_rsp_valid) begin
        done_lock <= !producer_rsp_ready;
        held_done <= done_p;
        if (producer_rsp_ready) begin
          ps[done_p] <= P_FREE;
          done_cursor <= done_p + 4'd1;
        end
      end
      if (tc_req_valid && tc_req_ready) begin
        tc <= tc_req_payload;
        ts <= T_ISSUE;
      end
      if (tc_rsp_valid && tc_rsp_ready) ts <= T_FREE;
      if (service_req_valid) begin
        service_lock <= !service_req_ready;
        held_class <= service_class;
        held_service_slot <= service_req_payload.slot;
        if (service_req_ready) begin
          class_rr <= service_class + 2'd1;
          class_cursor[service_class] <= service_req_payload.slot + 5'd1;
          case (service_class)
            0: sw[service_s] <= S_PENDING;
            2: ts <= T_PENDING;
            3: ps[update_p] <= ps[update_p] == P_QUERY ? P_QUERY_WAIT : P_UPDATE_WAIT;
            default: ;
          endcase
        end
      end
      if (service_rsp_valid && service_rsp_ready) begin
        logic [2:0] s;
        logic [3:0] p;
        s = service_rsp_payload.slot[2:0];
        p = service_rsp_payload.slot[3:0];
        if (service_rsp_payload.rsp.status != OK) fault <= 1;
        else
          case (service_rsp_payload.route)
            0:
            if (service_rsp_payload.slot >= 8 || sw[s] != S_PENDING ||
                cmd[s].id != service_rsp_payload.rsp.id)
              fault <= 1;
            else begin
              result[s] <= service_rsp_payload.rsp;
              sw[s] <= S_RESULT;
            end
            2:
            if (ts != T_PENDING || service_rsp_payload.slot != 0 ||
                service_rsp_payload.rsp.id != tc.id)
              fault <= 1;
            else ts <= T_RESULT;
            3:
            if (service_rsp_payload.slot >= 16 || producer[p].id != service_rsp_payload.rsp.id)
              fault <= 1;
            else
              case (ps[p])
                P_QUERY_WAIT:
                if (!service_rsp_payload.initialized) fault <= 1;
                else begin
                  ps[p] <= P_BIND;
                  phase[p] <= service_rsp_payload.phase;
                end
                P_UPDATE_WAIT: ps[p] <= P_RESULT;
                default: fault <= 1;
              endcase
            default: ;
          endcase
      end
    end
  end
endmodule
