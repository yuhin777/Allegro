// Implements frozen A1: doc/specs/blackwell_mbarrier_unit.md
module blackwell_mbarrier_unit
  import blackwell_async_pkg::*;
#(
parameter int unsigned ADDR_W          = SMEM_BYTE_ADDR_W,
    parameter int unsigned CACHE_ENTRIES   = 4,
    parameter int unsigned WAIT_ENTRIES    = 32,
    parameter int unsigned WRITE_BUF_DEPTH = 8,
    parameter int unsigned MEM_ID_W        = BARRIER_MEM_ID_DEFAULT_W,
    parameter int unsigned CLOCK_PERIOD_NS = 10,
    parameter int unsigned WAIT_DEFAULT_CYCLES = 64
) (
  input logic clk,
  input logic rst_n,
  input logic bar_cmd_vld_i,
  input logic bar_cmd_layout_i,
  input logic bar_cmd_no_complete_i,
  input logic bar_cmd_conditional_i,
  input logic [BARRIER_REPORT_W-1:0] bar_cmd_report_i,
  input logic [ASYNC_TAG_W-1:0] bar_cmd_tag_i,
  input logic [ADDR_W-1:0] bar_cmd_addr_i,
  input logic [5-1:0] bar_cmd_opcode_i,
  input logic [BARRIER_COUNT_W-1:0] bar_cmd_arrive_count_i,
  input logic [BARRIER_TX_BYTES_W-1:0] bar_cmd_tx_bytes_i,
  input logic bar_cmd_phase_token_i,
  input logic bar_cmd_wait_parity_i,
  input logic [BARRIER_STATE_W-1:0] bar_cmd_state_i,
  input logic [BARRIER_TIME_HINT_W-1:0] bar_cmd_time_hint_i,
  input logic bar_rsp_rdy_i,
  input logic tc_cmd_vld_i,
  input tma_mbarrier_pkg::bar_cmd_t tc_cmd_i,
  input logic tx_cpl_vld_i,
  input logic [ASYNC_TAG_W-1:0] tx_cpl_tag_i,
  input logic [ADDR_W-1:0] tx_cpl_addr_i,
  input logic [BARRIER_TX_BYTES_W-1:0] tx_cpl_bytes_i,
  input logic tx_rsp_rdy_i,
  input logic mem_req_rdy_i,
  input logic mem_rsp_vld_i,
  input logic [SMEM_DATA_W-1:0] mem_rsp_data_i,
  input logic [MEM_STATUS_W-1:0] mem_rsp_status_i,
  input logic [MEM_ID_W-1:0] mem_rsp_id_i,
  output logic bar_cmd_rdy_o,
  output logic bar_rsp_vld_o,
  output logic [BARRIER_COUNT_W-1:0] bar_rsp_pending_count_o,
  output logic bar_rsp_predicate_o,
  output logic [BARRIER_REPORT_W-1:0] bar_rsp_report_o,
  output logic bar_rsp_report_predicate_o,
  output logic [BARRIER_STATE_W-1:0] bar_rsp_state_o,
  output logic bar_rsp_wait_complete_o,
  output logic [ASYNC_TAG_W-1:0] bar_rsp_tag_o,
  output logic [ISSUER_ID_W-1:0] bar_rsp_issuer_o,
  output logic [STATUS_W-1:0] bar_rsp_status_o,
  output logic bar_rsp_phase_o,
  output logic bar_rsp_locked_o,
  output logic tc_cmd_rdy_o,
  output logic tx_cpl_rdy_o,
  output logic tx_rsp_vld_o,
  output logic [ASYNC_TAG_W-1:0] tx_rsp_tag_o,
  output logic [STATUS_W-1:0] tx_rsp_status_o,
  output logic tx_rsp_phase_o,
  output logic mem_req_vld_o,
  output logic [ADDR_W-1:0] mem_req_addr_o,
  output logic [SMEM_DATA_W-1:0] mem_req_data_o,
  output logic [SMEM_MASK_W-1:0] mem_req_byte_mask_o,
  output logic [MEM_ID_W-1:0] mem_req_id_o,
  output logic mem_req_write_o,
  output logic mem_rsp_rdy_o,
  output logic idle_o,
  output logic drained_o
);

    import tma_mbarrier_pkg::*;

    localparam int unsigned CACHE_IDX_W = (CACHE_ENTRIES <= 1) ? 1 : $clog2(CACHE_ENTRIES);
    localparam int unsigned WAIT_IDX_W  = (WAIT_ENTRIES <= 1) ? 1 : $clog2(WAIT_ENTRIES);
    localparam int unsigned WR_PTR_W    = (WRITE_BUF_DEPTH <= 1) ? 1 : $clog2(WRITE_BUF_DEPTH);
    localparam int unsigned WR_CNT_W    = $clog2(WRITE_BUF_DEPTH + 1);


    logic                    cache_locked_q [0:CACHE_ENTRIES-1];
    logic                    op_layout_q, op_no_complete_q, op_conditional_q, op_parity_q;
    logic [63:0]             op_input_state_q;
    logic [7:0]              op_report_q;
    logic                    wait_conditional_q [0:WAIT_ENTRIES-1];
    logic [31:0]             bar_rsp_value_q;
    logic                    bar_rsp_predicate_q;
    logic [7:0]              bar_rsp_report_q;
    logic [7:0]              wake_report;
    logic [31:0]             op_value;
    logic                    op_predicate, op_wait_complete;
    bar_object_t             op_object_cur, op_object_next;
    logic [63:0]             op_token;
    logic [31:0]             op_count_limit;
    logic                    cache_vld_q [0:CACHE_ENTRIES-1];
    logic [ADDR_W-1:0]       cache_addr_q [0:CACHE_ENTRIES-1];
    logic [63:0]             cache_state_q [0:CACHE_ENTRIES-1];
    logic [CACHE_IDX_W-1:0]  cache_replace_q;

    logic                    wait_vld_q [0:WAIT_ENTRIES-1];
    logic [ADDR_W-1:0]       wait_addr_q [0:WAIT_ENTRIES-1];
    logic [15:0]             wait_tag_q [0:WAIT_ENTRIES-1];
    logic                    wait_phase_q [0:WAIT_ENTRIES-1];

    logic [ADDR_W-1:0]       wr_addr_q [0:WRITE_BUF_DEPTH-1];
    logic [63:0]             wr_state_q [0:WRITE_BUF_DEPTH-1];
    logic                    wr_vld_q [0:WRITE_BUF_DEPTH-1];
    logic                    wr_is_tx_q [0:WRITE_BUF_DEPTH-1];
    logic [15:0]             wr_tag_q [0:WRITE_BUF_DEPTH-1];
    logic [ISSUER_ID_W-1:0]   wr_issuer_q [0:WRITE_BUF_DEPTH-1];
    logic [7:0]              wr_status_q [0:WRITE_BUF_DEPTH-1];
    logic                    wr_phase_q [0:WRITE_BUF_DEPTH-1];
    logic                    wr_locked_q [0:WRITE_BUF_DEPTH-1];
    logic [WR_PTR_W-1:0]     wr_rd_ptr_q;
    logic [WR_PTR_W-1:0]     wr_wr_ptr_q;
    logic [WR_CNT_W-1:0]     wr_count_q;

    logic [63:0]             wr_token_q [0:WRITE_BUF_DEPTH-1];
    logic [63:0]             mem_busy_token_q;
    logic [63:0]             bar_rsp_state_q;
    logic                    bar_rsp_wait_complete_q;
    logic [31:0]             wait_cycles_q [0:WAIT_ENTRIES-1];
    logic [31:0]             op_wait_cycles_q;
    logic                    wake_complete;
    logic                    op_vld_q;
    logic                    op_is_tx_q;
    logic [4:0]              op_opcode_q;
    logic [15:0]             op_tag_q;
    logic [ISSUER_ID_W-1:0]   op_issuer_q;
    logic [ADDR_W-1:0]       op_addr_q;
    logic [31:0]             op_arrive_q;
    logic [BARRIER_TX_BYTES_W-1:0]             op_tx_bytes_q;
    logic                    op_phase_token_q;
    logic [1:0]              arb_next_q;
    logic [2:0]              arb_requests, arb_grant;
    logic                    accept_tc;
    logic                    op_force_error_q;

    logic                    miss_active_q;
    logic                    miss_sent_q;
    logic [ADDR_W-1:0]       miss_addr_q;
    logic [CACHE_IDX_W-1:0]  miss_slot_q;

    logic                    mem_req_vld_q;
    logic                    mem_req_write_q;
    logic [ADDR_W-1:0]       mem_req_addr_q;
    logic [255:0]            mem_req_data_q;
    logic [31:0]             mem_req_mask_q;
    logic [MEM_ID_W-1:0]     mem_req_id_q;
    logic                    mem_busy_q;
    logic                    mem_busy_write_q;
    logic [ADDR_W-1:0]       mem_busy_addr_q;
    logic                    mem_busy_is_tx_q;
    logic [15:0]             mem_busy_tag_q;
    logic [ISSUER_ID_W-1:0]   mem_busy_issuer_q;
    logic [7:0]              mem_busy_status_q;
    logic                    mem_busy_phase_q;
    logic                    mem_busy_locked_q;

    logic                    bar_rsp_vld_q;
    logic [15:0]             bar_rsp_tag_q;
    logic [ISSUER_ID_W-1:0]   bar_rsp_issuer_q;
    logic [7:0]              bar_rsp_status_q;
    logic                    bar_rsp_phase_q;
    logic                    bar_rsp_locked_q;
    logic                    tx_rsp_vld_q;
    logic [15:0]             tx_rsp_tag_q;
    logic [7:0]              tx_rsp_status_q;
    logic                    tx_rsp_phase_q;

    logic                    op_cache_hit;
    logic [CACHE_IDX_W-1:0]  op_cache_idx;
    logic [63:0]             op_state_cur;
    logic [63:0]             op_state_next;
    logic                    op_state_change;
    logic                    op_phase_flip;
    logic                    op_phase_cur;
    logic                    op_lock_cur;
    logic [19:0]             op_expected_cur;
    logic [19:0]             op_remaining_cur;
    logic signed [20:0]      op_tx_balance_cur;
    logic                    op_phase_next;
    logic                    op_lock_next;
    logic [19:0]             op_remaining_next;
    logic signed [20:0]      op_tx_balance_next;
    logic signed [64:0]      op_tx_ext;
    logic [7:0]              op_status;
    logic                    op_rsp_needed;
    logic                    op_wait_enqueue;
    logic                    op_finish;
    logic                    op_can_process;
    logic                    op_init_slot_found;
    logic [CACHE_IDX_W-1:0]  op_init_slot;

    logic                    wait_free_found;
    logic                    wait_second_free_found;
    logic [WAIT_IDX_W-1:0]   wait_free_idx;
    logic                    wake_found;
    logic [WAIT_IDX_W-1:0]   wake_idx;
    logic [7:0]              wake_status;
    logic                    wake_phase;
    logic                    wake_locked;
    logic [CACHE_ENTRIES-1:0] cache_has_wait;
    logic [CACHE_ENTRIES-1:0] cache_has_pending_write;

    logic                    op_accept;
    logic                    accept_tx;
    logic                    bar_rsp_slot_rdy;
    logic                    tx_rsp_slot_rdy;
    logic                    mem_req_fire;
    logic                    mem_rsp_fire;
    logic                    wr_pop;
    logic                    wr_enq;
    logic                    victim_has_wait;
    logic                    incoming_wait_blocked;
    logic                    bar_rsp_slot_for_op;
    logic                    tx_rsp_slot_for_op;

    assign bar_rsp_slot_rdy = !bar_rsp_vld_q || bar_rsp_rdy_i;
    assign tx_rsp_slot_rdy = !tx_rsp_vld_q || tx_rsp_rdy_i;
    assign bar_rsp_slot_for_op = bar_rsp_slot_rdy &&
        !(mem_rsp_vld_i && mem_busy_q && mem_busy_write_q &&
          !mem_busy_is_tx_q) && !wake_found;
    assign tx_rsp_slot_for_op = tx_rsp_slot_rdy &&
        !(mem_rsp_vld_i && mem_busy_q && mem_busy_write_q &&
          mem_busy_is_tx_q);

    logic waits_empty;
    always_comb begin
      int entry;
      entry = 0;
      waits_empty = 1'b1;
      for (entry = 0; entry < WAIT_ENTRIES; entry++) begin
        if (wait_vld_q[entry]) waits_empty = 1'b0;
      end
    end
    assign idle_o = !op_vld_q && !mem_req_vld_q && !mem_busy_q && wr_count_q == 0;
    assign drained_o = idle_o && waits_empty && !bar_rsp_vld_q && !tx_rsp_vld_q;
    assign bar_rsp_pending_count_o = bar_rsp_value_q;
    assign bar_rsp_predicate_o = bar_rsp_predicate_q;
    assign bar_rsp_report_o = bar_rsp_report_q;
    assign bar_rsp_report_predicate_o = |bar_rsp_report_q;
    assign bar_rsp_state_o = bar_rsp_state_q;
    assign bar_rsp_wait_complete_o = bar_rsp_wait_complete_q;
    assign bar_rsp_vld_o = bar_rsp_vld_q;
    assign bar_rsp_tag_o = bar_rsp_tag_q;
    assign bar_rsp_issuer_o = bar_rsp_issuer_q;
    assign bar_rsp_status_o = bar_rsp_status_q;
    assign bar_rsp_phase_o = bar_rsp_phase_q;
    assign bar_rsp_locked_o = bar_rsp_locked_q;
    assign tx_rsp_vld_o = tx_rsp_vld_q;
    assign tx_rsp_tag_o = tx_rsp_tag_q;
    assign tx_rsp_status_o = tx_rsp_status_q;
    assign tx_rsp_phase_o = tx_rsp_phase_q;

    assign mem_req_vld_o = mem_req_vld_q;
    assign mem_req_write_o = mem_req_write_q;
    assign mem_req_addr_o = {mem_req_addr_q[ADDR_W-1:5], 5'd0};
    assign mem_req_data_o = mem_req_data_q;
    assign mem_req_byte_mask_o = mem_req_mask_q;
    assign mem_req_id_o = mem_req_id_q;
    assign mem_rsp_rdy_o = mem_busy_q &&
        (!mem_busy_write_q ||
         (mem_busy_is_tx_q ? tx_rsp_slot_rdy : bar_rsp_slot_rdy));
    assign mem_req_fire = mem_req_vld_q && mem_req_rdy_i;
    assign mem_rsp_fire = mem_rsp_vld_i && mem_rsp_rdy_o &&
        mem_rsp_id_i == MEM_ID_W'(mem_busy_write_q);
    logic memory_protocol_fault_q, memory_protocol_fault_d;
    logic [MEM_STATUS_W-1:0] effective_mem_rsp_status;
    assign effective_mem_rsp_status = memory_protocol_fault_q ? 2'd3 : mem_rsp_status_i;
    always_comb begin
      memory_protocol_fault_d = memory_protocol_fault_q;
      if (mem_rsp_vld_i && mem_rsp_rdy_o && !mem_rsp_fire) memory_protocol_fault_d = 1'b1;
      if (mem_rsp_fire) memory_protocol_fault_d = 1'b0;
    end
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) memory_protocol_fault_q <= 1'b0;
      else memory_protocol_fault_q <= memory_protocol_fault_d;
    end
    assign wr_pop = mem_req_fire && mem_req_write_q;

    // Three independent producers reach this arbitration point. In particular,
    // a software TRY_WAIT blocked by a full waiter table cannot hide a TC arrival.
    assign incoming_wait_blocked = bar_cmd_vld_i &&
        (bar_cmd_opcode_i == MBAR_OP_TRY_WAIT) &&
        (!wait_free_found ||
         (op_vld_q && op_finish && op_wait_enqueue && !wait_second_free_found));
    assign arb_requests = {tc_cmd_vld_i, tx_cpl_vld_i,
                           bar_cmd_vld_i && !incoming_wait_blocked};
    always_comb begin
      int offset;
      offset = 0;
        arb_grant = '0;
        for (offset = 0; offset < 3; offset++) begin
            if (arb_grant == '0 && arb_requests[(int'(arb_next_q)+offset)%3])
                arb_grant[(int'(arb_next_q)+offset)%3] = 1'b1;
        end
    end
    assign accept_tx = arb_grant[1];
    assign accept_tc = arb_grant[2];
    assign op_accept = (!op_vld_q || op_finish) && (|arb_grant);
    assign tx_cpl_rdy_o = (!op_vld_q || op_finish) && arb_grant[1];
    assign tc_cmd_rdy_o = (!op_vld_q || op_finish) && arb_grant[2];
    assign bar_cmd_rdy_o = (!op_vld_q || op_finish) && arb_grant[0];

    always_comb begin
      int unsigned hit_idx;
      hit_idx = 0;
        op_cache_hit = 1'b0;
        op_cache_idx = {CACHE_IDX_W{1'b0}};
        for (hit_idx = 0; hit_idx < CACHE_ENTRIES;
             hit_idx = hit_idx + 1) begin
            if (cache_vld_q[hit_idx] &&
                (cache_addr_q[hit_idx] == op_addr_q)) begin
                op_cache_hit = 1'b1;
                op_cache_idx = CACHE_IDX_W'(hit_idx);
            end
        end
    end

    always_comb begin
      int unsigned free_idx;
      free_idx = 0;
        wait_free_found = 1'b0;
        wait_second_free_found = 1'b0;
        wait_free_idx = {WAIT_IDX_W{1'b0}};
        for (free_idx = 0; free_idx < WAIT_ENTRIES;
             free_idx = free_idx + 1) begin
            if (!wait_vld_q[free_idx] && !wait_free_found) begin
                wait_free_found = 1'b1;
                wait_free_idx = WAIT_IDX_W'(free_idx);
            end else if (!wait_vld_q[free_idx]) begin
                wait_second_free_found = 1'b1;
            end
        end
    end

    always_comb begin
      int unsigned wait_scan;
      int unsigned cache_scan;
      wait_scan = 0;
      cache_scan = 0;
        cache_has_wait = '0;
        for (wait_scan = 0; wait_scan < WAIT_ENTRIES;
             wait_scan = wait_scan + 1) begin
            for (cache_scan = 0; cache_scan < CACHE_ENTRIES;
                 cache_scan = cache_scan + 1) begin
                if (wait_vld_q[wait_scan] && cache_vld_q[cache_scan] &&
                    (wait_addr_q[wait_scan] == cache_addr_q[cache_scan])) begin
                    cache_has_wait[cache_scan] = 1'b1;
                end
            end
        end
    end

    // A phase or lock update is not visible to waiters until every older
    // write-through update for the same cache line has been acknowledged.
    // This prevents a waiter from reporting success before a failing backing
    // write has had the opportunity to lock the barrier.
    always_comb begin
      int unsigned cache_scan;
      int unsigned wr_scan;
      cache_scan = 0;
      wr_scan = 0;
        cache_has_pending_write = '0;
        for (cache_scan = 0; cache_scan < CACHE_ENTRIES;
             cache_scan = cache_scan + 1) begin
            if (cache_vld_q[cache_scan]) begin
                if (mem_busy_q && mem_busy_write_q &&
                    (mem_busy_addr_q == cache_addr_q[cache_scan])) begin
                    cache_has_pending_write[cache_scan] = 1'b1;
                end
                for (wr_scan = 0; wr_scan < WRITE_BUF_DEPTH;
                     wr_scan = wr_scan + 1) begin
                    if (wr_vld_q[wr_scan] &&
                        (wr_addr_q[wr_scan] == cache_addr_q[cache_scan])) begin
                        cache_has_pending_write[cache_scan] = 1'b1;
                    end
                end
            end
        end
    end

    // Prefer an invalid cache line.  Otherwise select the round-robin line if
    // it has no resident waiter, then fall back to the first waiter-free line.
    always_comb begin
      int unsigned invalid_idx;
      int unsigned victim_idx;
      invalid_idx = 0;
      victim_idx = 0;
        op_init_slot_found = 1'b0;
        op_init_slot = cache_replace_q;
        victim_has_wait = 1'b0;
        victim_has_wait = cache_has_wait[cache_replace_q] || cache_has_pending_write[cache_replace_q] ||
            (cache_vld_q[cache_replace_q] && cache_locked_q[cache_replace_q]);
        for (invalid_idx = 0;
             invalid_idx < CACHE_ENTRIES; invalid_idx = invalid_idx + 1) begin
            if (!cache_vld_q[invalid_idx] && !op_init_slot_found) begin
                op_init_slot_found = 1'b1;
                op_init_slot = CACHE_IDX_W'(invalid_idx);
            end
        end
        if (!op_init_slot_found && !victim_has_wait) begin
            op_init_slot_found = 1'b1;
            op_init_slot = cache_replace_q;
        end
        if (!op_init_slot_found) begin
            for (victim_idx = 0;
                 victim_idx < CACHE_ENTRIES; victim_idx = victim_idx + 1) begin
                if (!cache_has_wait[victim_idx] && !cache_has_pending_write[victim_idx] &&
                    !cache_locked_q[victim_idx] && !op_init_slot_found) begin
                    op_init_slot_found = 1'b1;
                    op_init_slot = CACHE_IDX_W'(victim_idx);
                end
            end
        end
    end

    always_comb begin
        op_state_cur = op_cache_hit ? cache_state_q[op_cache_idx] : 64'd0;
        op_object_cur = bar_unpack(op_state_cur);
        op_object_next = op_object_cur;
        op_phase_cur = op_object_cur.phase;
        op_lock_cur = op_cache_hit && cache_locked_q[op_cache_idx];
        op_expected_cur = op_object_cur.expected;
        op_remaining_cur = op_object_cur.pending;
        op_tx_balance_cur = op_object_cur.tx;
        op_count_limit = (op_opcode_q == MBAR_OP_INIT ? op_layout_q : op_object_cur.layout_v1) ?
            32'd511 : 32'd1048575;
        op_token = bar_token(op_object_cur, op_no_complete_q);
        op_state_change = 1'b0;
        op_phase_flip = 1'b0;
        op_lock_next = op_lock_cur;
        op_tx_ext = {{44{op_tx_balance_cur[20]}}, op_tx_balance_cur};
        op_status = MBAR_STATUS_OK;
        op_rsp_needed = 1'b1;
        op_wait_enqueue = 1'b0;
        op_can_process = 1'b0;
        op_value = 32'd0;
        op_predicate = 1'b0;
        op_wait_complete = 1'b0;

        // pending_count reads only the captured token, never backing memory.
        if (op_opcode_q == MBAR_OP_PENDING_COUNT) begin
            op_can_process = 1'b1;
            if (op_input_state_q[63:56] != 8'ha7 || !op_input_state_q[0] ||
                op_input_state_q[2] || !op_input_state_q[3] || op_layout_q)
                op_status = MBAR_STATUS_BAD_TOKEN;
            else op_value = {12'd0, op_input_state_q[4 +: 20]};
        end else if (op_addr_q[2:0] != 3'd0) begin
            op_can_process = 1'b1;
            op_status = MBAR_STATUS_BAD_ALIGN;
        end else if (op_force_error_q) begin
            op_can_process = 1'b1;
            op_status = MBAR_STATUS_MEMORY;
        end else if (op_no_complete_q && op_opcode_q != MBAR_OP_ARRIVE && op_opcode_q != MBAR_OP_ARRIVE_DROP) begin
            op_can_process = 1'b1;
            op_status = MBAR_STATUS_BAD_MODIFIER;
        end else if (op_opcode_q == MBAR_OP_INIT && op_cache_hit && op_lock_cur) begin
            op_can_process = 1'b1;
            op_status = MBAR_STATUS_LOCKED;
        end else if (op_opcode_q == MBAR_OP_INIT) begin
            op_can_process = op_cache_hit || op_init_slot_found;
            op_object_next = '0;
            op_object_next.valid = 1'b1;
            op_object_next.layout_v1 = op_layout_q;
            op_object_next.expected = op_arrive_q[19:0];
            op_object_next.pending = op_arrive_q[19:0];
            op_state_change = op_can_process;
            op_lock_next = 1'b0;
            if (op_arrive_q == 0 || op_arrive_q > op_count_limit) begin
                op_status = MBAR_STATUS_BAD_ARRIVE;
                op_lock_next = 1'b1;
            end
        end else if (op_cache_hit) begin
            op_can_process = 1'b1;
            if (op_opcode_q == MBAR_OP_INVAL) begin
                op_object_next = '0;
                op_lock_next = 1'b0;
                op_state_change = 1'b1;
            end else if (!op_object_cur.valid) begin
                op_status = MBAR_STATUS_UNINITIALIZED;
            end else if (op_lock_cur) begin
                op_status = MBAR_STATUS_LOCKED;
            end else begin
                case (op_opcode_q)
                    MBAR_OP_ARRIVE, MBAR_OP_ARRIVE_EXPECT_TX,
                    MBAR_OP_ARRIVE_DROP, MBAR_OP_DROP_EXPECT_TX: begin
                        op_state_change = 1'b1;
                        if (op_arrive_q == 0 || op_arrive_q > {12'd0, op_object_cur.pending}) begin
                            op_status = MBAR_STATUS_BAD_ARRIVE;
                        end else begin
                            op_object_next.pending = op_object_cur.pending - op_arrive_q[19:0];
                        end
                        if (op_opcode_q == MBAR_OP_ARRIVE_DROP || op_opcode_q == MBAR_OP_DROP_EXPECT_TX) begin
                            if (op_arrive_q >= {12'd0, op_object_cur.expected}) op_status = MBAR_STATUS_BAD_ARRIVE;
                            else op_object_next.expected = op_object_cur.expected - op_arrive_q[19:0];
                        end
                        if (op_opcode_q == MBAR_OP_ARRIVE_EXPECT_TX || op_opcode_q == MBAR_OP_DROP_EXPECT_TX) begin
                            op_tx_ext = op_tx_ext + $signed({33'd0, op_tx_bytes_q});
                            if (op_tx_ext > 65'sd1048575 || op_tx_ext < -65'sd1048575)
                                op_status = MBAR_STATUS_OVERFLOW;
                            else op_object_next.tx = op_tx_ext[20:0];
                        end
                        if (op_no_complete_q && op_object_next.pending == 0 && op_object_next.tx == 0)
                            op_status = MBAR_STATUS_BAD_ARRIVE;
                    end
                    MBAR_OP_EXPECT_TX, MBAR_OP_COMPLETE_TX, MBAR_OP_TX_COMPLETE: begin
                        op_state_change = 1'b1;
                        op_tx_ext = (op_opcode_q == MBAR_OP_EXPECT_TX) ?
                            op_tx_ext + $signed({33'd0, op_tx_bytes_q}) :
                            op_tx_ext - $signed({33'd0, op_tx_bytes_q});
                        if (op_tx_ext > 65'sd1048575 || op_tx_ext < -65'sd1048575)
                            op_status = MBAR_STATUS_OVERFLOW;
                        else op_object_next.tx = op_tx_ext[20:0];
                    end
                    MBAR_OP_FAULT: begin
                        op_state_change = 1'b1;
                        op_status = MBAR_STATUS_MEMORY;
                    end
                    MBAR_OP_REPORT: begin
                        if (!op_object_cur.layout_v1) op_status = MBAR_STATUS_BAD_MODIFIER;
                        else begin
                            op_state_change = 1'b1;
                            // The producer supplies an already encoded b8 report. Reports
                            // accumulate by bitwise OR in this project's producer contract.
                            if (op_phase_cur) op_object_next.report1 = op_object_cur.report1 | op_report_q;
                            else op_object_next.report0 = op_object_cur.report0 | op_report_q;
                        end
                    end
                    MBAR_OP_PENDING_INC: begin
                        op_state_change = 1'b1;
                        if ({12'd0, op_object_cur.pending} == op_count_limit) op_status = MBAR_STATUS_BAD_ARRIVE;
                        else op_object_next.pending = op_object_cur.pending + 20'd1;
                    end
                    MBAR_OP_TRY_WAIT, MBAR_OP_TEST_WAIT: begin
                        if ((op_conditional_q && !op_parity_q) || (!op_parity_q &&
                            (op_input_state_q[63:56] != 8'ha7 || !op_input_state_q[0] ||
                             op_input_state_q[2] != op_object_cur.layout_v1))) begin
                            op_status = MBAR_STATUS_BAD_TOKEN;
                        end else begin
                            op_wait_complete = (bar_wait_phase(op_state_cur, op_conditional_q) != op_phase_token_q) &&
                                !cache_has_pending_write[op_cache_idx];
                            if (!op_wait_complete && op_opcode_q == MBAR_OP_TRY_WAIT) begin
                                op_rsp_needed = 1'b0;
                                op_wait_enqueue = 1'b1;
                            end
                        end
                    end
                    MBAR_OP_CHECK_LAYOUT: op_predicate = op_object_cur.layout_v1 == op_layout_q;
                    default: op_status = MBAR_STATUS_BAD_OPCODE;
                endcase
            end
        end
        if (op_state_change) begin
            if (op_status != MBAR_STATUS_OK) begin
                // Invalid operands have project-defined fault containment, not NV behavior.
                if (op_opcode_q != MBAR_OP_INIT) op_object_next = op_object_cur;
                op_lock_next = 1'b1;
            end
            if (op_opcode_q != MBAR_OP_INIT && op_opcode_q != MBAR_OP_INVAL && !op_lock_next &&
                op_object_next.pending == 0 && op_object_next.tx == 0) begin
                op_phase_flip = 1'b1;
                op_object_next.phase = ~op_phase_cur;
                if (!op_object_next.layout_v1 || (op_phase_cur ? op_object_next.report1 : op_object_next.report0) == 0)
                    op_object_next.conditional_phase = ~op_object_cur.conditional_phase;
                if (op_object_next.phase) op_object_next.report1 = 8'd0;
                else op_object_next.report0 = 8'd0;
                op_object_next.pending = op_object_next.expected;
            end
        end
        op_phase_next = op_object_next.phase;
        op_remaining_next = op_object_next.pending;
        op_tx_balance_next = op_object_next.tx;
        op_state_next = bar_pack(op_object_next);

        if (op_force_error_q) begin
            op_finish = op_is_tx_q ? tx_rsp_slot_for_op : bar_rsp_slot_for_op;
        end else if (!op_vld_q || !op_can_process) begin
            op_finish = 1'b0;
        end else if (op_state_change && (wr_count_q == WR_CNT_W'(WRITE_BUF_DEPTH))) begin
            op_finish = 1'b0;
        end else if (op_state_change) begin
            // State-changing operations retire into the write-through FIFO.
            // Their sole response is generated after backing-memory confirms
            // the write, so a backend error can be reported precisely.
            op_finish = 1'b1;
        end else if (op_wait_enqueue) begin
            op_finish = wait_free_found;
        end else if (op_rsp_needed) begin
            op_finish = op_is_tx_q ? tx_rsp_slot_for_op : bar_rsp_slot_for_op;
        end else begin
            op_finish = 1'b1;
        end
    end

    assign wr_enq = op_vld_q && op_finish && op_state_change;

    // Background waiter wakeup.  Cached barriers with changed phase or lock
    // state are drained one response per cycle.
    always_comb begin
      int unsigned wake_wait_idx;
      int unsigned wake_cache_idx;
      wake_wait_idx = 0;
      wake_cache_idx = 0;
        wake_complete = 1'b0;
        wake_report = 8'd0;
        wake_found = 1'b0;
        wake_idx = {WAIT_IDX_W{1'b0}};
        wake_status = MBAR_STATUS_OK;
        wake_phase = 1'b0;
        wake_locked = 1'b0;
        for (wake_wait_idx = 0;
             wake_wait_idx < WAIT_ENTRIES;
             wake_wait_idx = wake_wait_idx + 1) begin
            if (wait_vld_q[wake_wait_idx] && !wake_found) begin
                for (wake_cache_idx = 0;
                     wake_cache_idx < CACHE_ENTRIES;
                     wake_cache_idx = wake_cache_idx + 1) begin
                    if (cache_vld_q[wake_cache_idx] &&
                        (cache_addr_q[wake_cache_idx] ==
                         wait_addr_q[wake_wait_idx]) &&
                        (!cache_has_pending_write[wake_cache_idx] ||
                         wait_cycles_q[wake_wait_idx] == 0)) begin
                        if (!cache_state_q[wake_cache_idx][BAR_STATE_VALID_BIT] ||
                            (wait_cycles_q[wake_wait_idx] == 0) ||
                            cache_locked_q[wake_cache_idx] ||
                            (bar_wait_phase(cache_state_q[wake_cache_idx], wait_conditional_q[wake_wait_idx]) !=
                             wait_phase_q[wake_wait_idx])) begin
                            wake_found = 1'b1;
                            wake_complete = cache_state_q[wake_cache_idx][BAR_STATE_VALID_BIT] &&
                                !cache_locked_q[wake_cache_idx] &&
                                !cache_has_pending_write[wake_cache_idx] &&
                                (bar_wait_phase(cache_state_q[wake_cache_idx], wait_conditional_q[wake_wait_idx]) != wait_phase_q[wake_wait_idx]);
                            if (wake_complete && !wait_conditional_q[wake_wait_idx])
                                wake_report = bar_report(cache_state_q[wake_cache_idx], wait_phase_q[wake_wait_idx]);
                            wake_idx = WAIT_IDX_W'(wake_wait_idx);
                            wake_phase =
                                cache_state_q[wake_cache_idx][BAR_STATE_PHASE_BIT];
                            wake_locked =
                                cache_locked_q[wake_cache_idx];
                            wake_status =
                                !cache_state_q[wake_cache_idx][BAR_STATE_VALID_BIT] ? MBAR_STATUS_UNINITIALIZED :
                                (cache_locked_q[wake_cache_idx] ? MBAR_STATUS_LOCKED : MBAR_STATUS_OK);
                        end
                    end
                end
            end
        end
    end

    logic cache_locked_d [0:CACHE_ENTRIES-1];
    logic op_layout_d ;
    logic op_no_complete_d ;
    logic op_conditional_d ;
    logic op_parity_d ;
    logic [63:0] op_input_state_d ;
    logic [7:0] op_report_d ;
    logic wait_conditional_d [0:WAIT_ENTRIES-1];
    logic [31:0] bar_rsp_value_d ;
    logic bar_rsp_predicate_d ;
    logic [7:0] bar_rsp_report_d ;
    logic cache_vld_d [0:CACHE_ENTRIES-1];
    logic [ADDR_W-1:0] cache_addr_d [0:CACHE_ENTRIES-1];
    logic [63:0] cache_state_d [0:CACHE_ENTRIES-1];
    logic [CACHE_IDX_W-1:0] cache_replace_d ;
    logic wait_vld_d [0:WAIT_ENTRIES-1];
    logic [ADDR_W-1:0] wait_addr_d [0:WAIT_ENTRIES-1];
    logic [15:0] wait_tag_d [0:WAIT_ENTRIES-1];
    logic wait_phase_d [0:WAIT_ENTRIES-1];
    logic [ADDR_W-1:0] wr_addr_d [0:WRITE_BUF_DEPTH-1];
    logic [63:0] wr_state_d [0:WRITE_BUF_DEPTH-1];
    logic wr_vld_d [0:WRITE_BUF_DEPTH-1];
    logic wr_is_tx_d [0:WRITE_BUF_DEPTH-1];
    logic [15:0] wr_tag_d [0:WRITE_BUF_DEPTH-1];
    logic [ISSUER_ID_W-1:0] wr_issuer_d [0:WRITE_BUF_DEPTH-1];
    logic [7:0] wr_status_d [0:WRITE_BUF_DEPTH-1];
    logic wr_phase_d [0:WRITE_BUF_DEPTH-1];
    logic wr_locked_d [0:WRITE_BUF_DEPTH-1];
    logic [WR_PTR_W-1:0] wr_rd_ptr_d ;
    logic [WR_PTR_W-1:0] wr_wr_ptr_d ;
    logic [WR_CNT_W-1:0] wr_count_d ;
    logic [63:0] wr_token_d [0:WRITE_BUF_DEPTH-1];
    logic [63:0] mem_busy_token_d ;
    logic [63:0] bar_rsp_state_d ;
    logic bar_rsp_wait_complete_d ;
    logic [31:0] wait_cycles_d [0:WAIT_ENTRIES-1];
    logic [31:0] op_wait_cycles_d ;
    logic op_vld_d ;
    logic op_is_tx_d ;
    logic [4:0] op_opcode_d ;
    logic [15:0] op_tag_d ;
    logic [ISSUER_ID_W-1:0] op_issuer_d;
    logic [ADDR_W-1:0] op_addr_d ;
    logic [31:0] op_arrive_d ;
    logic [BARRIER_TX_BYTES_W-1:0] op_tx_bytes_d ;
    logic op_phase_token_d ;
    logic [1:0] arb_next_d ;
    logic op_force_error_d ;
    logic miss_active_d ;
    logic miss_sent_d ;
    logic [ADDR_W-1:0] miss_addr_d ;
    logic [CACHE_IDX_W-1:0] miss_slot_d ;
    logic mem_req_vld_d ;
    logic mem_req_write_d ;
    logic [ADDR_W-1:0] mem_req_addr_d ;
    logic [255:0] mem_req_data_d ;
    logic [31:0] mem_req_mask_d ;
    logic [MEM_ID_W-1:0] mem_req_id_d ;
    logic mem_busy_d ;
    logic mem_busy_write_d ;
    logic [ADDR_W-1:0] mem_busy_addr_d ;
    logic mem_busy_is_tx_d ;
    logic [15:0] mem_busy_tag_d ;
    logic [ISSUER_ID_W-1:0] mem_busy_issuer_d;
    logic [7:0] mem_busy_status_d ;
    logic mem_busy_phase_d ;
    logic mem_busy_locked_d ;
    logic bar_rsp_vld_d ;
    logic [15:0] bar_rsp_tag_d ;
    logic [ISSUER_ID_W-1:0] bar_rsp_issuer_d;
    logic [7:0] bar_rsp_status_d ;
    logic bar_rsp_phase_d ;
    logic bar_rsp_locked_d ;
    logic tx_rsp_vld_d ;
    logic [15:0] tx_rsp_tag_d ;
    logic [7:0] tx_rsp_status_d ;
    logic tx_rsp_phase_d ;

    always_comb begin
      int wi;
      int unsigned lock_cache;
      int unsigned poison_wr;
      wi = 0;
      lock_cache = 0;
      poison_wr = 0;
        foreach (cache_locked_q[idx]) cache_locked_d[idx] = cache_locked_q[idx];
        op_layout_d = op_layout_q;
        op_no_complete_d = op_no_complete_q;
        op_conditional_d = op_conditional_q;
        op_parity_d = op_parity_q;
        op_input_state_d = op_input_state_q;
        op_report_d = op_report_q;
        foreach (wait_conditional_q[idx]) wait_conditional_d[idx] = wait_conditional_q[idx];
        bar_rsp_value_d = bar_rsp_value_q;
        bar_rsp_predicate_d = bar_rsp_predicate_q;
        bar_rsp_report_d = bar_rsp_report_q;
        foreach (cache_vld_q[idx]) cache_vld_d[idx] = cache_vld_q[idx];
        foreach (cache_addr_q[idx]) cache_addr_d[idx] = cache_addr_q[idx];
        foreach (cache_state_q[idx]) cache_state_d[idx] = cache_state_q[idx];
        cache_replace_d = cache_replace_q;
        foreach (wait_vld_q[idx]) wait_vld_d[idx] = wait_vld_q[idx];
        foreach (wait_addr_q[idx]) wait_addr_d[idx] = wait_addr_q[idx];
        foreach (wait_tag_q[idx]) wait_tag_d[idx] = wait_tag_q[idx];
        foreach (wait_phase_q[idx]) wait_phase_d[idx] = wait_phase_q[idx];
        foreach (wr_addr_q[idx]) wr_addr_d[idx] = wr_addr_q[idx];
        foreach (wr_state_q[idx]) wr_state_d[idx] = wr_state_q[idx];
        foreach (wr_vld_q[idx]) wr_vld_d[idx] = wr_vld_q[idx];
        foreach (wr_is_tx_q[idx]) wr_is_tx_d[idx] = wr_is_tx_q[idx];
        foreach (wr_tag_q[idx]) wr_tag_d[idx] = wr_tag_q[idx];
        foreach (wr_issuer_q[idx]) wr_issuer_d[idx] = wr_issuer_q[idx];
        foreach (wr_status_q[idx]) wr_status_d[idx] = wr_status_q[idx];
        foreach (wr_phase_q[idx]) wr_phase_d[idx] = wr_phase_q[idx];
        foreach (wr_locked_q[idx]) wr_locked_d[idx] = wr_locked_q[idx];
        wr_rd_ptr_d = wr_rd_ptr_q;
        wr_wr_ptr_d = wr_wr_ptr_q;
        wr_count_d = wr_count_q;
        foreach (wr_token_q[idx]) wr_token_d[idx] = wr_token_q[idx];
        mem_busy_token_d = mem_busy_token_q;
        bar_rsp_state_d = bar_rsp_state_q;
        bar_rsp_wait_complete_d = bar_rsp_wait_complete_q;
        foreach (wait_cycles_q[idx]) wait_cycles_d[idx] = wait_cycles_q[idx];
        op_wait_cycles_d = op_wait_cycles_q;
        op_vld_d = op_vld_q;
        op_is_tx_d = op_is_tx_q;
        op_opcode_d = op_opcode_q;
        op_tag_d = op_tag_q;
        op_issuer_d = op_issuer_q;
        op_addr_d = op_addr_q;
        op_arrive_d = op_arrive_q;
        op_tx_bytes_d = op_tx_bytes_q;
        op_phase_token_d = op_phase_token_q;
        arb_next_d = arb_next_q;
        op_force_error_d = op_force_error_q;
        miss_active_d = miss_active_q;
        miss_sent_d = miss_sent_q;
        miss_addr_d = miss_addr_q;
        miss_slot_d = miss_slot_q;
        mem_req_vld_d = mem_req_vld_q;
        mem_req_write_d = mem_req_write_q;
        mem_req_addr_d = mem_req_addr_q;
        mem_req_data_d = mem_req_data_q;
        mem_req_mask_d = mem_req_mask_q;
        mem_req_id_d = mem_req_id_q;
        mem_busy_d = mem_busy_q;
        mem_busy_write_d = mem_busy_write_q;
        mem_busy_addr_d = mem_busy_addr_q;
        mem_busy_is_tx_d = mem_busy_is_tx_q;
        mem_busy_tag_d = mem_busy_tag_q;
        mem_busy_issuer_d = mem_busy_issuer_q;
        mem_busy_status_d = mem_busy_status_q;
        mem_busy_phase_d = mem_busy_phase_q;
        mem_busy_locked_d = mem_busy_locked_q;
        bar_rsp_vld_d = bar_rsp_vld_q;
        bar_rsp_tag_d = bar_rsp_tag_q;
        bar_rsp_issuer_d = bar_rsp_issuer_q;
        bar_rsp_status_d = bar_rsp_status_q;
        bar_rsp_phase_d = bar_rsp_phase_q;
        bar_rsp_locked_d = bar_rsp_locked_q;
        tx_rsp_vld_d = tx_rsp_vld_q;
        tx_rsp_tag_d = tx_rsp_tag_q;
        tx_rsp_status_d = tx_rsp_status_q;
        tx_rsp_phase_d = tx_rsp_phase_q;
            for (wi = 0; wi < WAIT_ENTRIES; wi = wi + 1) begin
                if (wait_vld_q[wi] && (wait_cycles_q[wi] != 0))
                    wait_cycles_d[wi] = wait_cycles_q[wi] - 32'd1;
            end
            if (bar_rsp_vld_q && bar_rsp_rdy_i) begin
                bar_rsp_vld_d = 1'b0;
            end
            if (tx_rsp_vld_q && tx_rsp_rdy_i) begin
                tx_rsp_vld_d = 1'b0;
            end

            if (op_vld_q && !op_force_error_q &&
                (op_opcode_q != MBAR_OP_INIT) && (op_opcode_q != MBAR_OP_PENDING_COUNT) && !op_cache_hit &&
                (op_addr_q[2:0] == 3'd0) && !op_finish &&
                !miss_active_q && op_init_slot_found) begin
                miss_active_d = 1'b1;
                miss_sent_d = 1'b0;
                miss_addr_d = op_addr_q;
                miss_slot_d = op_init_slot;
            end

            if (op_vld_q && op_finish) begin
                if (op_state_change) begin
                    if (op_cache_hit) begin
                        cache_locked_d[op_cache_idx] = op_lock_next;
                        cache_state_d[op_cache_idx] = op_state_next;
                        cache_addr_d[op_cache_idx] = op_addr_q;
                        cache_vld_d[op_cache_idx] = 1'b1;
                    end else begin
                        cache_locked_d[op_init_slot] = op_lock_next;
                        cache_state_d[op_init_slot] = op_state_next;
                        cache_addr_d[op_init_slot] = op_addr_q;
                        cache_vld_d[op_init_slot] = 1'b1;
                        cache_replace_d = (op_init_slot == CACHE_IDX_W'(CACHE_ENTRIES-1)) ?
                                           {CACHE_IDX_W{1'b0}} :
                                           op_init_slot + CACHE_IDX_W'(1);
                    end
                    wr_addr_d[wr_wr_ptr_q] = op_addr_q;
                    wr_state_d[wr_wr_ptr_q] = op_state_next;
                    wr_token_d[wr_wr_ptr_q] = op_token;
                    wr_vld_d[wr_wr_ptr_q] = 1'b1;
                    wr_is_tx_d[wr_wr_ptr_q] = op_is_tx_q;
                    wr_tag_d[wr_wr_ptr_q] = op_tag_q;
                    wr_issuer_d[wr_wr_ptr_q] = op_issuer_q;
                    wr_status_d[wr_wr_ptr_q] = op_status;
                    wr_phase_d[wr_wr_ptr_q] = op_phase_next;
                    wr_locked_d[wr_wr_ptr_q] = op_lock_next;
                    wr_wr_ptr_d = (wr_wr_ptr_q == WR_PTR_W'(WRITE_BUF_DEPTH-1)) ?
                                   {WR_PTR_W{1'b0}} : wr_wr_ptr_q + WR_PTR_W'(1);
                end
                if (op_wait_enqueue) begin
                    wait_conditional_d[wait_free_idx] = op_conditional_q;
                    wait_vld_d[wait_free_idx] = 1'b1;
                    wait_addr_d[wait_free_idx] = op_addr_q;
                    wait_tag_d[wait_free_idx] = op_tag_q;
                    wait_phase_d[wait_free_idx] = op_phase_token_q;
                    wait_cycles_d[wait_free_idx] = op_wait_cycles_q;
                end else if (!op_state_change &&
                             (op_rsp_needed || op_force_error_q)) begin
                    if (op_is_tx_q) begin
                        tx_rsp_vld_d = 1'b1;
                        tx_rsp_tag_d = op_tag_q;
                        tx_rsp_status_d = op_status;
                        tx_rsp_phase_d = op_phase_next;
                    end else begin
                        bar_rsp_vld_d = 1'b1;
                        bar_rsp_tag_d = op_tag_q;
                        bar_rsp_issuer_d = op_issuer_q;
                        bar_rsp_status_d = op_status;
                        bar_rsp_phase_d = op_phase_next;
                        bar_rsp_state_d = op_token;
                        bar_rsp_value_d = op_value;
                        bar_rsp_predicate_d = op_predicate;
                        bar_rsp_report_d = (op_wait_complete && !op_conditional_q) ?
                            bar_report(op_state_cur, op_phase_token_q) : 8'd0;
                        bar_rsp_wait_complete_d = op_wait_complete;
                        bar_rsp_locked_d = op_lock_next;
                    end
                end
                op_vld_d = 1'b0;
                op_force_error_d = 1'b0;
            end

            if (op_accept) begin
                op_layout_d = !accept_tx && !accept_tc && bar_cmd_layout_i;
                op_no_complete_d = !accept_tx && !accept_tc && bar_cmd_no_complete_i;
                op_conditional_d = !accept_tx && !accept_tc && bar_cmd_conditional_i;
                op_parity_d = bar_cmd_wait_parity_i;
                op_input_state_d = bar_cmd_state_i;
                op_report_d = accept_tc ? 8'd0 : bar_cmd_report_i;
                op_vld_d = 1'b1;
                op_is_tx_d = accept_tx;
                op_opcode_d = accept_tx ? MBAR_OP_TX_COMPLETE :
                    (accept_tc ? (tc_cmd_i.opcode == MBAR_OP_FAULT ? MBAR_OP_FAULT : MBAR_OP_ARRIVE) : bar_cmd_opcode_i);
                op_tag_d = accept_tx ? tx_cpl_tag_i : (accept_tc ? tc_cmd_i.tag : bar_cmd_tag_i);
                op_issuer_d = accept_tc ? tc_cmd_i.issuer : ISSUER_ID_W'(0);
                op_addr_d = accept_tx ? tx_cpl_addr_i : (accept_tc ? ADDR_W'(tc_cmd_i.addr) : bar_cmd_addr_i);
                op_arrive_d = accept_tx ? 32'd0 : accept_tc ? 32'd1 :
                    ((bar_cmd_opcode_i == MBAR_OP_ARRIVE_EXPECT_TX || bar_cmd_opcode_i == MBAR_OP_DROP_EXPECT_TX) ? 32'd1 : bar_cmd_arrive_count_i);
                op_tx_bytes_d = accept_tx ? tx_cpl_bytes_i : (accept_tc ? 32'd0 : bar_cmd_tx_bytes_i);
                op_phase_token_d = bar_cmd_wait_parity_i ? bar_cmd_phase_token_i : bar_cmd_state_i[BAR_STATE_PHASE_BIT];
                op_wait_cycles_d = (bar_cmd_time_hint_i == 0) ? WAIT_DEFAULT_CYCLES :
                    32'(({32'd0, bar_cmd_time_hint_i} + 64'(CLOCK_PERIOD_NS) - 64'd1) / 64'(CLOCK_PERIOD_NS));
                op_force_error_d = 1'b0;
                arb_next_d = accept_tc ? 2'd0 : (accept_tx ? 2'd2 : 2'd1);
            end

            // Backing acknowledgements have priority. Ready/expired waiters
            // precede direct software responses, so polls cannot starve them.
            if (wake_found && bar_rsp_slot_rdy &&
                !(mem_rsp_fire && mem_busy_write_q && !mem_busy_is_tx_q) &&
                !(op_vld_q && op_finish && !op_is_tx_q &&
                  !op_state_change && !op_wait_enqueue &&
                  (op_rsp_needed || op_force_error_q))) begin
                bar_rsp_vld_d = 1'b1;
                bar_rsp_tag_d = wait_tag_q[wake_idx];
                bar_rsp_issuer_d = '0;
                bar_rsp_status_d = wake_status;
                bar_rsp_phase_d = wake_phase;
                bar_rsp_state_d = 64'd0;
                bar_rsp_value_d = 32'd0;
                bar_rsp_predicate_d = 1'b0;
                bar_rsp_report_d = wake_report;
                bar_rsp_wait_complete_d = wake_complete;
                bar_rsp_locked_d = wake_locked;
                wait_vld_d[wake_idx] = 1'b0;
            end

            if (mem_req_fire) begin
                mem_req_vld_d = 1'b0;
                mem_busy_d = 1'b1;
                mem_busy_write_d = mem_req_write_q;
                mem_busy_addr_d = mem_req_addr_q;
                if (mem_req_write_q) begin
                    mem_busy_is_tx_d = wr_is_tx_q[wr_rd_ptr_q];
                    mem_busy_tag_d = wr_tag_q[wr_rd_ptr_q];
                    mem_busy_issuer_d = wr_issuer_q[wr_rd_ptr_q];
                    mem_busy_status_d = wr_status_q[wr_rd_ptr_q];
                    mem_busy_phase_d = wr_phase_q[wr_rd_ptr_q];
                    mem_busy_token_d = wr_token_q[wr_rd_ptr_q];
                    mem_busy_locked_d = wr_locked_q[wr_rd_ptr_q];
                    wr_vld_d[wr_rd_ptr_q] = 1'b0;
                    wr_rd_ptr_d = (wr_rd_ptr_q == WR_PTR_W'(WRITE_BUF_DEPTH-1)) ?
                                   {WR_PTR_W{1'b0}} : wr_rd_ptr_q + WR_PTR_W'(1);
                end else begin
                    miss_sent_d = 1'b1;
                end
            end

            if (!mem_req_vld_q && !mem_busy_q) begin
                if (miss_active_q && !miss_sent_q) begin
                    mem_req_vld_d = 1'b1;
                    mem_req_write_d = 1'b0;
                    mem_req_addr_d = miss_addr_q;
                    mem_req_data_d = 256'd0;
                    mem_req_mask_d = 32'd0;
                    mem_req_id_d = MEM_ID_W'(0);
                end else if (wr_count_q != 0) begin
                    mem_req_vld_d = 1'b1;
                    mem_req_write_d = 1'b1;
                    mem_req_addr_d = wr_addr_q[wr_rd_ptr_q];
                    mem_req_data_d = {192'd0, wr_state_q[wr_rd_ptr_q]} << (wr_addr_q[wr_rd_ptr_q][4:3] * 64);
                    mem_req_mask_d = 32'h0000_00ff << (wr_addr_q[wr_rd_ptr_q][4:3] * 8);
                    mem_req_id_d = MEM_ID_W'(1);
                end
            end

            if (mem_rsp_fire) begin
                mem_busy_d = 1'b0;
                if (!mem_busy_write_q) begin
                    miss_active_d = 1'b0;
                    miss_sent_d = 1'b0;
                    if ((effective_mem_rsp_status == 2'd0) &&
                        (mem_rsp_id_i == MEM_ID_W'(0))) begin
                        cache_locked_d[miss_slot_q] = 1'b0;
                        cache_vld_d[miss_slot_q] = 1'b1;
                        cache_addr_d[miss_slot_q] = miss_addr_q;
                        cache_state_d[miss_slot_q] = mem_rsp_data_i[miss_addr_q[4:3]*64 +: 64];
                        cache_replace_d = (miss_slot_q == CACHE_IDX_W'(CACHE_ENTRIES-1)) ?
                                           {CACHE_IDX_W{1'b0}} :
                                           miss_slot_q + CACHE_IDX_W'(1);
                    end else begin
                        op_force_error_d = 1'b1;
                    end
                end else if ((effective_mem_rsp_status != 2'd0) ||
                             (mem_rsp_id_i != MEM_ID_W'(1))) begin
                    for (lock_cache = 0;
                         lock_cache < CACHE_ENTRIES;
                         lock_cache = lock_cache + 1) begin
                        if (cache_vld_q[lock_cache] &&
                            (cache_addr_q[lock_cache] == mem_busy_addr_q)) begin
                            cache_locked_d[lock_cache] = 1'b1;
                        end
                    end
                    // Include an enqueue on the same edge as the failed ack;
                    // wr_vld_q still contains its old value during this scan.
                    if (wr_enq && op_addr_q == mem_busy_addr_q) begin

                        wr_status_d[wr_wr_ptr_q] = MBAR_STATUS_LOCKED;
                        wr_locked_d[wr_wr_ptr_q] = 1'b1;
                    end
                    for (poison_wr = 0;
                         poison_wr < WRITE_BUF_DEPTH;
                         poison_wr = poison_wr + 1) begin
                        if (wr_vld_q[poison_wr] &&
                            (wr_addr_q[poison_wr] == mem_busy_addr_q)) begin

                            wr_status_d[poison_wr] = MBAR_STATUS_LOCKED;
                            wr_locked_d[poison_wr] = 1'b1;
                        end
                    end
                end
                if (mem_busy_write_q) begin
                    if (mem_busy_is_tx_q) begin
                        tx_rsp_vld_d = 1'b1;
                        tx_rsp_tag_d = mem_busy_tag_q;
                        tx_rsp_status_d =
                            ((effective_mem_rsp_status != 2'd0) ||
                             (mem_rsp_id_i != MEM_ID_W'(1))) ?
                            MBAR_STATUS_MEMORY : mem_busy_status_q;
                        tx_rsp_phase_d = mem_busy_phase_q;
                    end else begin
                        bar_rsp_vld_d = 1'b1;
                        bar_rsp_tag_d = mem_busy_tag_q;
                        bar_rsp_issuer_d = mem_busy_issuer_q;
                        bar_rsp_status_d =
                            ((effective_mem_rsp_status != 2'd0) ||
                             (mem_rsp_id_i != MEM_ID_W'(1))) ?
                            MBAR_STATUS_MEMORY : mem_busy_status_q;
                        bar_rsp_phase_d = mem_busy_phase_q;
                        bar_rsp_state_d = mem_busy_token_q;
                        bar_rsp_value_d = 32'd0;
                        bar_rsp_predicate_d = 1'b0;
                        bar_rsp_report_d = 8'd0;
                        bar_rsp_wait_complete_d = 1'b0;
                        bar_rsp_locked_d =
                            ((effective_mem_rsp_status != 2'd0) ||
                             (mem_rsp_id_i != MEM_ID_W'(1))) ?
                            1'b1 : mem_busy_locked_q;
                    end
                end
            end

            case ({wr_enq, wr_pop})
                2'b10: wr_count_d = wr_count_q + WR_CNT_W'(1);
                2'b01: wr_count_d = wr_count_q - WR_CNT_W'(1);
                default: wr_count_d = wr_count_q;
            endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            op_layout_q <= 1'b0;
            op_no_complete_q <= 1'b0;
            op_conditional_q <= 1'b0;
            op_parity_q <= 1'b0;
            op_input_state_q <= 64'd0;
            op_report_q <= 8'd0;
            bar_rsp_value_q <= 32'd0;
            bar_rsp_predicate_q <= 1'b0;
            bar_rsp_report_q <= 8'd0;
            op_wait_cycles_q <= 32'd0;
            mem_busy_token_q <= 64'd0;
            bar_rsp_state_q <= 64'd0;
            bar_rsp_wait_complete_q <= 1'b0;
            op_vld_q <= 1'b0;
            op_is_tx_q <= 1'b0;
            op_opcode_q <= MBAR_OP_INIT;
            op_tag_q <= 16'd0;
            op_issuer_q <= '0;
            op_addr_q <= {ADDR_W{1'b0}};
            op_arrive_q <= 32'd0;
            op_tx_bytes_q <= '0;
            op_phase_token_q <= 1'b0;
            arb_next_q <= 2'd0;
            op_force_error_q <= 1'b0;
            cache_replace_q <= {CACHE_IDX_W{1'b0}};
            miss_active_q <= 1'b0;
            miss_sent_q <= 1'b0;
            miss_addr_q <= {ADDR_W{1'b0}};
            miss_slot_q <= {CACHE_IDX_W{1'b0}};
            wr_rd_ptr_q <= {WR_PTR_W{1'b0}};
            wr_wr_ptr_q <= {WR_PTR_W{1'b0}};
            wr_count_q <= {WR_CNT_W{1'b0}};
            mem_req_vld_q <= 1'b0;
            mem_req_write_q <= 1'b0;
            mem_req_addr_q <= {ADDR_W{1'b0}};
            mem_req_data_q <= 256'd0;
            mem_req_mask_q <= 32'd0;
            mem_req_id_q <= {MEM_ID_W{1'b0}};
            mem_busy_q <= 1'b0;
            mem_busy_write_q <= 1'b0;
            mem_busy_addr_q <= {ADDR_W{1'b0}};
            mem_busy_is_tx_q <= 1'b0;
            mem_busy_tag_q <= 16'd0;
            mem_busy_issuer_q <= '0;
            mem_busy_status_q <= MBAR_STATUS_OK;
            mem_busy_phase_q <= 1'b0;
            mem_busy_locked_q <= 1'b0;
            bar_rsp_vld_q <= 1'b0;
            bar_rsp_tag_q <= 16'd0;
            bar_rsp_issuer_q <= '0;
            bar_rsp_status_q <= MBAR_STATUS_OK;
            bar_rsp_phase_q <= 1'b0;
            bar_rsp_locked_q <= 1'b0;
            tx_rsp_vld_q <= 1'b0;
            tx_rsp_tag_q <= 16'd0;
            tx_rsp_status_q <= MBAR_STATUS_OK;
            tx_rsp_phase_q <= 1'b0;
            for (int unsigned reset_cache = 0; reset_cache < CACHE_ENTRIES;
                 reset_cache = reset_cache + 1) begin
                cache_locked_q[reset_cache] <= 1'b0;
                cache_vld_q[reset_cache] <= 1'b0;
                cache_addr_q[reset_cache] <= {ADDR_W{1'b0}};
                cache_state_q[reset_cache] <= 64'd0;
            end
            for (int unsigned reset_wait = 0; reset_wait < WAIT_ENTRIES;
                 reset_wait = reset_wait + 1) begin
                wait_conditional_q[reset_wait] <= 1'b0;
                wait_cycles_q[reset_wait] <= 32'd0;
                wait_vld_q[reset_wait] <= 1'b0;
                wait_addr_q[reset_wait] <= {ADDR_W{1'b0}};
                wait_tag_q[reset_wait] <= 16'd0;
                wait_phase_q[reset_wait] <= 1'b0;
            end
            for (int unsigned reset_wr = 0; reset_wr < WRITE_BUF_DEPTH;
                 reset_wr = reset_wr + 1) begin
                wr_vld_q[reset_wr] <= 1'b0;
                wr_issuer_q[reset_wr] <= '0;
            end
        end else begin
            foreach (cache_locked_q[idx]) cache_locked_q[idx] <= cache_locked_d[idx];
            op_layout_q <= op_layout_d;
            op_no_complete_q <= op_no_complete_d;
            op_conditional_q <= op_conditional_d;
            op_parity_q <= op_parity_d;
            op_input_state_q <= op_input_state_d;
            op_report_q <= op_report_d;
            foreach (wait_conditional_q[idx]) wait_conditional_q[idx] <= wait_conditional_d[idx];
            bar_rsp_value_q <= bar_rsp_value_d;
            bar_rsp_predicate_q <= bar_rsp_predicate_d;
            bar_rsp_report_q <= bar_rsp_report_d;
            foreach (cache_vld_q[idx]) cache_vld_q[idx] <= cache_vld_d[idx];
            foreach (cache_addr_q[idx]) cache_addr_q[idx] <= cache_addr_d[idx];
            foreach (cache_state_q[idx]) cache_state_q[idx] <= cache_state_d[idx];
            cache_replace_q <= cache_replace_d;
            foreach (wait_vld_q[idx]) wait_vld_q[idx] <= wait_vld_d[idx];
            foreach (wait_addr_q[idx]) wait_addr_q[idx] <= wait_addr_d[idx];
            foreach (wait_tag_q[idx]) wait_tag_q[idx] <= wait_tag_d[idx];
            foreach (wait_phase_q[idx]) wait_phase_q[idx] <= wait_phase_d[idx];
            foreach (wr_addr_q[idx]) wr_addr_q[idx] <= wr_addr_d[idx];
            foreach (wr_state_q[idx]) wr_state_q[idx] <= wr_state_d[idx];
            foreach (wr_vld_q[idx]) wr_vld_q[idx] <= wr_vld_d[idx];
            foreach (wr_is_tx_q[idx]) wr_is_tx_q[idx] <= wr_is_tx_d[idx];
            foreach (wr_tag_q[idx]) wr_tag_q[idx] <= wr_tag_d[idx];
            foreach (wr_issuer_q[idx]) wr_issuer_q[idx] <= wr_issuer_d[idx];
            foreach (wr_status_q[idx]) wr_status_q[idx] <= wr_status_d[idx];
            foreach (wr_phase_q[idx]) wr_phase_q[idx] <= wr_phase_d[idx];
            foreach (wr_locked_q[idx]) wr_locked_q[idx] <= wr_locked_d[idx];
            wr_rd_ptr_q <= wr_rd_ptr_d;
            wr_wr_ptr_q <= wr_wr_ptr_d;
            wr_count_q <= wr_count_d;
            foreach (wr_token_q[idx]) wr_token_q[idx] <= wr_token_d[idx];
            mem_busy_token_q <= mem_busy_token_d;
            bar_rsp_state_q <= bar_rsp_state_d;
            bar_rsp_wait_complete_q <= bar_rsp_wait_complete_d;
            foreach (wait_cycles_q[idx]) wait_cycles_q[idx] <= wait_cycles_d[idx];
            op_wait_cycles_q <= op_wait_cycles_d;
            op_vld_q <= op_vld_d;
            op_is_tx_q <= op_is_tx_d;
            op_opcode_q <= op_opcode_d;
            op_tag_q <= op_tag_d;
            op_issuer_q <= op_issuer_d;
            op_addr_q <= op_addr_d;
            op_arrive_q <= op_arrive_d;
            op_tx_bytes_q <= op_tx_bytes_d;
            op_phase_token_q <= op_phase_token_d;
            arb_next_q <= arb_next_d;
            op_force_error_q <= op_force_error_d;
            miss_active_q <= miss_active_d;
            miss_sent_q <= miss_sent_d;
            miss_addr_q <= miss_addr_d;
            miss_slot_q <= miss_slot_d;
            mem_req_vld_q <= mem_req_vld_d;
            mem_req_write_q <= mem_req_write_d;
            mem_req_addr_q <= mem_req_addr_d;
            mem_req_data_q <= mem_req_data_d;
            mem_req_mask_q <= mem_req_mask_d;
            mem_req_id_q <= mem_req_id_d;
            mem_busy_q <= mem_busy_d;
            mem_busy_write_q <= mem_busy_write_d;
            mem_busy_addr_q <= mem_busy_addr_d;
            mem_busy_is_tx_q <= mem_busy_is_tx_d;
            mem_busy_tag_q <= mem_busy_tag_d;
            mem_busy_issuer_q <= mem_busy_issuer_d;
            mem_busy_status_q <= mem_busy_status_d;
            mem_busy_phase_q <= mem_busy_phase_d;
            mem_busy_locked_q <= mem_busy_locked_d;
            bar_rsp_vld_q <= bar_rsp_vld_d;
            bar_rsp_tag_q <= bar_rsp_tag_d;
            bar_rsp_issuer_q <= bar_rsp_issuer_d;
            bar_rsp_status_q <= bar_rsp_status_d;
            bar_rsp_phase_q <= bar_rsp_phase_d;
            bar_rsp_locked_q <= bar_rsp_locked_d;
            tx_rsp_vld_q <= tx_rsp_vld_d;
            tx_rsp_tag_q <= tx_rsp_tag_d;
            tx_rsp_status_q <= tx_rsp_status_d;
            tx_rsp_phase_q <= tx_rsp_phase_d;
        end
    end

    initial begin
        if (ADDR_W != SMEM_BYTE_ADDR_W || MEM_ID_W < 1 || CLOCK_PERIOD_NS == 0 || WAIT_DEFAULT_CYCLES == 0) $error("wait timing parameters must be positive");
        if (ADDR_W < 32) $error("ADDR_W must be at least 32");
        if (CACHE_ENTRIES < 1) $error("CACHE_ENTRIES must be positive");
        if (WAIT_ENTRIES < 1) $error("WAIT_ENTRIES must be positive");
        if (WRITE_BUF_DEPTH < 2) $error("WRITE_BUF_DEPTH must be at least two");
        if (MEM_ID_W < 1) $error("MEM_ID_W must be positive");
    end

`ifndef SYNTHESIS
    assert property (@(posedge clk) disable iff (!rst_n)
        bar_rsp_vld_o && !bar_rsp_rdy_i |=> bar_rsp_vld_o &&
        $stable({bar_rsp_tag_o, bar_rsp_issuer_o, bar_rsp_status_o}));
    logic                    assert_mem_stalled_q;
    logic                    assert_mem_write_q;
    logic [ADDR_W-1:0]       assert_mem_addr_q;
    logic [255:0]            assert_mem_data_q;
    logic [31:0]             assert_mem_mask_q;
    logic [MEM_ID_W-1:0]     assert_mem_id_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            assert_mem_stalled_q <= 1'b0;
        end else begin
            if (assert_mem_stalled_q) begin
                assert (mem_req_vld_o &&
                        (mem_req_write_o == assert_mem_write_q) &&
                        (mem_req_addr_o == assert_mem_addr_q) &&
                        (mem_req_data_o == assert_mem_data_q) &&
                        (mem_req_byte_mask_o == assert_mem_mask_q) &&
                        (mem_req_id_o == assert_mem_id_q))
                    else $error("mbarrier memory request changed while stalled");
            end
            if (op_vld_q && op_finish && op_state_change &&
                (op_phase_next != op_phase_cur) &&
                (op_opcode_q != MBAR_OP_INIT) && (op_opcode_q != MBAR_OP_INVAL)) begin
                assert (op_phase_flip &&
                        (op_tx_balance_next == 21'sd0) && !op_lock_next)
                    else $error("mbarrier phase changed before joint completion");
            end
            if (op_vld_q && op_finish && op_cache_hit && op_lock_cur &&
                (op_opcode_q != MBAR_OP_INIT) && (op_opcode_q != MBAR_OP_INVAL)) begin
                assert (!op_state_change)
                    else $error("locked mbarrier changed without INVAL");
            end
            assert (wr_count_q <= WR_CNT_W'(WRITE_BUF_DEPTH))
                else $error("mbarrier write buffer count overflow");

            assert_mem_stalled_q <= mem_req_vld_o && !mem_req_rdy_i;
            assert_mem_write_q <= mem_req_write_o;
            assert_mem_addr_q <= mem_req_addr_o;
            assert_mem_data_q <= mem_req_data_o;
            assert_mem_mask_q <= mem_req_byte_mask_o;
            assert_mem_id_q <= mem_req_id_o;
        end
    end
`endif

endmodule

`default_nettype wire
