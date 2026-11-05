// Implements frozen A1: doc/specs/blackwell_mbarrier_frontend.md
module blackwell_mbarrier_frontend
  import blackwell_async_pkg::*;
#(
parameter int unsigned ADDR_W = SMEM_BYTE_ADDR_W,
    parameter int unsigned CACHE_ENTRIES = 4,
    parameter int unsigned WAIT_ENTRIES = 32,
    parameter int unsigned WRITE_BUF_DEPTH = 8,
    parameter int unsigned MEM_ID_W = BARRIER_MEM_ID_DEFAULT_W,
    parameter int unsigned CLOCK_PERIOD_NS = 10,
    parameter int unsigned WAIT_DEFAULT_CYCLES = 64,
    parameter int unsigned ASYNC_ENTRIES = 16,
    parameter int unsigned COMMAND_ENTRIES = WAIT_ENTRIES + WRITE_BUF_DEPTH + 4
) (
  input logic clk,
  input logic rst_n,
  input logic bar_cmd_vld_i,
  input tma_mbarrier_pkg::bar_cmd_t bar_cmd_i,
  input logic tc_arrive_vld_i,
  input tma_mbarrier_pkg::bar_cmd_t tc_arrive_i,
  input logic tc_arrive_rsp_rdy_i,
  input logic bar_rsp_rdy_i,
  input logic async_req_vld_i,
  input tma_mbarrier_pkg::bw_async_req_t async_req_i,
  input logic async_cpl_req_vld_i,
  input tma_mbarrier_pkg::bw_async_req_t async_cpl_req_i,
  input logic async_rsp_rdy_i,
  input logic report_req_vld_i,
  input tma_mbarrier_pkg::bar_report_req_t report_req_i,
  input logic report_rsp_rdy_i,
  input logic order_req_rdy_i,
  input logic order_rsp_vld_i,
  input tma_mbarrier_pkg::bw_order_rsp_t order_rsp_i,
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
  input logic stop_i,
  output logic bar_cmd_rdy_o,
  output logic tc_arrive_rdy_o,
  output logic tc_arrive_rsp_vld_o,
  output tma_mbarrier_pkg::bar_rsp_t tc_arrive_rsp_o,
  output logic bar_rsp_vld_o,
  output tma_mbarrier_pkg::bar_rsp_t bar_rsp_o,
  output logic async_req_rdy_o,
  output logic async_cpl_req_rdy_o,
  output logic async_rsp_vld_o,
  output tma_mbarrier_pkg::bw_async_rsp_t async_rsp_o,
  output logic report_req_rdy_o,
  output logic report_rsp_vld_o,
  output tma_mbarrier_pkg::bar_rsp_t report_rsp_o,
  output logic order_req_vld_o,
  output tma_mbarrier_pkg::bw_order_req_t order_req_o,
  output logic order_rsp_rdy_o,
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
    // A full registration table cannot block the completion path that frees it.
    wire selected_async_req_vld_i = async_req_vld_i || async_cpl_req_vld_i;
    wire selected_async_req_rdy_o;
    bw_async_req_t selected_async_req_i;
    always_comb begin
        selected_async_req_i = async_cpl_req_vld_i ? async_cpl_req_i : async_req_i;
        selected_async_req_i.complete = async_cpl_req_vld_i;
    end
    assign async_req_rdy_o = selected_async_req_rdy_o && !async_cpl_req_vld_i;
    assign async_cpl_req_rdy_o = selected_async_req_rdy_o;
    localparam int unsigned IDX_W = (COMMAND_ENTRIES <= 1) ? 1 : $clog2(COMMAND_ENTRIES);
    localparam int unsigned ASYNC_IDX_W = (ASYNC_ENTRIES <= 1) ? 1 : $clog2(ASYNC_ENTRIES);
    typedef enum logic [3:0] {E_FREE, E_RELEASE, E_ORDER, E_ISSUE, E_CORE,
        E_ACQUIRE, E_READY, E_CP_WAIT, E_CP_ISSUE, E_CP_CORE, E_CP_READY, E_HELD} entry_state_t;
    entry_state_t state_q [0:COMMAND_ENTRIES-1];
    bar_cmd_t cmd_q [0:COMMAND_ENTRIES-1];
    bar_rsp_t result_q [0:COMMAND_ENTRIES-1];
    logic report_source_q [0:COMMAND_ENTRIES-1];
    logic cp_ack_q [0:COMMAND_ENTRIES-1];
    logic [ASYNC_ENTRIES-1:0] cp_predecessors_q [0:COMMAND_ENTRIES-1], cp_predecessors_d [0:COMMAND_ENTRIES-1];
    logic cp_retired_q [0:COMMAND_ENTRIES-1], cp_retired_d [0:COMMAND_ENTRIES-1];
    logic [63:0] acceptance_q;
    logic [63:0] age_q [0:COMMAND_ENTRIES-1];
    logic issue_blocked [0:COMMAND_ENTRIES-1];
    logic cp_pending [0:COMMAND_ENTRIES-1];
    logic [1023:0] issuer_failed_q;
    logic async_vld_q [0:ASYNC_ENTRIES-1];
    logic [9:0] async_issuer_q [0:ASYNC_ENTRIES-1];
    logic [63:0] async_seq_q [0:ASYNC_ENTRIES-1];
    logic [1023:0] issuer_seen_q;
    logic [1023:0][63:0] issuer_last_seq_q;
    logic free_found, issue_found, order_found, response_found, async_free, async_match;
    logic [IDX_W-1:0] free_idx, issue_idx, order_idx, response_idx;
    logic [ASYNC_IDX_W-1:0] async_free_idx, async_match_idx;
    logic [IDX_W-1:0] issue_rr_q, response_rr_q, order_rr_q;
    logic [7:0] input_status;
    logic input_release;
    logic core_cmd_vld_q, core_cmd_rdy;
    logic [IDX_W-1:0] core_slot_q;
    bar_cmd_t core_cmd_q;
    logic core_rsp_vld;
    bar_rsp_t core_rsp;
    logic [15:0] core_rsp_tag;
    logic order_vld_q, order_busy_q, order_acquire_q;
    logic [IDX_W-1:0] order_slot_q;
    bw_order_req_t order_q;
    logic rsp_vld_q, rsp_report_q;
    wire bar_rsp_t rsp_q;
    logic [IDX_W-1:0] rsp_slot_q;
    assign rsp_q = result_q[rsp_slot_q];
    logic async_rsp_vld_q;
    logic order_fault_q;
    bw_async_rsp_t async_rsp_q;
    integer scan;

    assign bar_cmd_rdy_o = free_found && !stop_i && acceptance_q != '1;
    assign report_req_rdy_o = free_found && !bar_cmd_vld_i && !stop_i && acceptance_q != '1;
    assign bar_rsp_vld_o = rsp_vld_q && !rsp_report_q;
    assign report_rsp_vld_o = rsp_vld_q && rsp_report_q;
    assign bar_rsp_o = rsp_q;
    assign report_rsp_o = rsp_q;
    assign order_req_vld_o = order_vld_q;
    assign order_req_o = order_q;
    assign order_rsp_rdy_o = order_busy_q;
    assign async_rsp_vld_o = async_rsp_vld_q;
    assign async_rsp_o = async_rsp_q;
    assign selected_async_req_rdy_o = (!async_rsp_vld_q || async_rsp_rdy_i) &&
        (selected_async_req_i.complete || (!stop_i && (async_free ||
         (issuer_seen_q[selected_async_req_i.issuer] && selected_async_req_i.seq <= issuer_last_seq_q[selected_async_req_i.issuer]))));

    always_comb begin
      int i;
      int k;
      i = 0;
      k = 0;
        async_free = 1'b0; async_match = 1'b0;
        async_free_idx = '0; async_match_idx = '0;
        for (i = 0; i < ASYNC_ENTRIES; i = i + 1) begin
            if (!async_vld_q[i] && !async_free) begin
                async_free = 1'b1; async_free_idx = ASYNC_IDX_W'(i);
            end
            if (async_vld_q[i] && async_issuer_q[i] == selected_async_req_i.issuer && async_seq_q[i] == selected_async_req_i.seq) begin
                async_match = 1'b1; async_match_idx = ASYNC_IDX_W'(i);
            end
        end
        for (i = 0; i < COMMAND_ENTRIES; i = i + 1) begin
            cp_pending[i] = |cp_predecessors_q[i];
            issue_blocked[i] = 1'b0;
            for (k = 0; k < COMMAND_ENTRIES; k = k + 1) begin
                if (age_q[k] < age_q[i] && cmd_q[k].issuer == cmd_q[i].issuer && !report_source_q[k] && !report_source_q[i] &&
                    (state_q[k] == E_RELEASE || state_q[k] == E_ISSUE ||
                     (state_q[k] == E_ORDER && !(order_busy_q && order_acquire_q && order_slot_q == IDX_W'(k)))))
                    issue_blocked[i] = 1'b1;
            end
        end
    end

    always_comb begin
      int i;
      i = 0;
        input_status = MBAR_STATUS_OK;
        input_release = 1'b0;
        if (bar_cmd_i.opcode > MBAR_OP_CP_ASYNC_ARRIVE) input_status = MBAR_STATUS_BAD_OPCODE;
        if (bar_cmd_i.scope > BW_SCOPE_CLUSTER) input_status = MBAR_STATUS_BAD_MODIFIER;
        case (bar_cmd_i.opcode)
            MBAR_OP_ARRIVE, MBAR_OP_ARRIVE_EXPECT_TX, MBAR_OP_ARRIVE_DROP, MBAR_OP_DROP_EXPECT_TX: begin
                if (bar_cmd_i.sem > BW_SEM_RELEASE || (bar_cmd_i.no_complete &&
                    (bar_cmd_i.sem != BW_SEM_RELEASE || bar_cmd_i.scope != BW_SCOPE_CTA)))
                    input_status = MBAR_STATUS_BAD_MODIFIER;
                input_release = bar_cmd_i.sem == BW_SEM_RELEASE;
            end
            MBAR_OP_TRY_WAIT, MBAR_OP_TEST_WAIT: begin
                if (bar_cmd_i.sem != BW_SEM_RELAXED && bar_cmd_i.sem != BW_SEM_ACQUIRE)
                    input_status = MBAR_STATUS_BAD_MODIFIER;
            end
            default: if (bar_cmd_i.sem != BW_SEM_RELAXED) input_status = MBAR_STATUS_BAD_MODIFIER;
        endcase
        if (bar_cmd_i.no_complete && bar_cmd_i.opcode != MBAR_OP_ARRIVE && bar_cmd_i.opcode != MBAR_OP_ARRIVE_DROP)
            input_status = MBAR_STATUS_BAD_MODIFIER;
        free_found = 1'b0; free_idx = '0;
        issue_found = 1'b0; issue_idx = '0;
        order_found = 1'b0; order_idx = '0;
        response_found = 1'b0; response_idx = '0;
        scan = 0;
        for (i = 0; i < COMMAND_ENTRIES; i = i + 1) begin
            if (state_q[i] == E_FREE && !free_found) begin free_found = 1'b1; free_idx = IDX_W'(i); end
            scan = (int'(issue_rr_q) + i) % COMMAND_ENTRIES;
            if (!issue_found && !issue_blocked[scan] && (state_q[scan] == E_ISSUE || state_q[scan] == E_CP_ISSUE)) begin
                issue_found = 1'b1; issue_idx = IDX_W'(scan);
            end
            scan = (int'(order_rr_q) + i) % COMMAND_ENTRIES;
            if (!order_found && (state_q[scan] == E_RELEASE || state_q[scan] == E_ACQUIRE)) begin
                order_found = 1'b1; order_idx = IDX_W'(scan);
            end
            scan = (int'(response_rr_q) + i) % COMMAND_ENTRIES;
            if (!response_found && !(rsp_vld_q && rsp_slot_q == IDX_W'(scan)) &&
                (state_q[scan] == E_READY ||
                 ((state_q[scan] == E_CP_WAIT || state_q[scan] == E_CP_READY ||
                   state_q[scan] == E_CP_ISSUE || state_q[scan] == E_CP_CORE) && !cp_ack_q[scan]))) begin
                response_found = 1'b1; response_idx = IDX_W'(scan);
            end
        end
    end

    entry_state_t state_d [0:COMMAND_ENTRIES-1];
    bar_cmd_t cmd_d [0:COMMAND_ENTRIES-1];
    bar_rsp_t result_d [0:COMMAND_ENTRIES-1];
    logic report_source_d [0:COMMAND_ENTRIES-1];
    logic cp_ack_d [0:COMMAND_ENTRIES-1];
    logic [63:0] acceptance_d ;
    logic [63:0] age_d [0:COMMAND_ENTRIES-1];
    logic [1023:0] issuer_failed_d ;
    logic async_vld_d [0:ASYNC_ENTRIES-1];
    logic [9:0] async_issuer_d [0:ASYNC_ENTRIES-1];
    logic [63:0] async_seq_d [0:ASYNC_ENTRIES-1];
    logic [1023:0] issuer_seen_d ;
    logic [1023:0][63:0] issuer_last_seq_d ;
    logic [IDX_W-1:0] issue_rr_d ;
    logic [IDX_W-1:0] response_rr_d ;
    logic [IDX_W-1:0] order_rr_d ;
    logic core_cmd_vld_d ;
    logic [IDX_W-1:0] core_slot_d ;
    bar_cmd_t core_cmd_d ;
    logic order_vld_d ;
    logic order_busy_d ;
    logic order_acquire_d ;
    logic [IDX_W-1:0] order_slot_d ;
    bw_order_req_t order_d ;
    logic rsp_vld_d ;
    logic rsp_report_d ;
    logic [IDX_W-1:0] rsp_slot_d ;
    logic async_rsp_vld_d ;
    logic order_fault_d ;
    bw_async_rsp_t async_rsp_d ;

    always_comb begin
        int i, entry, predecessor;
        i = 0;
        entry = 0;
        predecessor = 0;
        foreach (state_q[idx]) state_d[idx] = state_q[idx];
        foreach (cmd_q[idx]) cmd_d[idx] = cmd_q[idx];
        foreach (result_q[idx]) result_d[idx] = result_q[idx];
        foreach (report_source_q[idx]) report_source_d[idx] = report_source_q[idx];
        foreach (cp_ack_q[idx]) cp_ack_d[idx] = cp_ack_q[idx];
        foreach (cp_predecessors_q[idx]) cp_predecessors_d[idx] = cp_predecessors_q[idx];
        foreach (cp_retired_q[idx]) cp_retired_d[idx] = cp_retired_q[idx];
        acceptance_d = acceptance_q;
        foreach (age_q[idx]) age_d[idx] = age_q[idx];
        issuer_failed_d = issuer_failed_q;
        foreach (async_vld_q[idx]) async_vld_d[idx] = async_vld_q[idx];
        foreach (async_issuer_q[idx]) async_issuer_d[idx] = async_issuer_q[idx];
        foreach (async_seq_q[idx]) async_seq_d[idx] = async_seq_q[idx];
        issuer_seen_d = issuer_seen_q;
        issuer_last_seq_d = issuer_last_seq_q;
        issue_rr_d = issue_rr_q;
        response_rr_d = response_rr_q;
        order_rr_d = order_rr_q;
        core_cmd_vld_d = core_cmd_vld_q;
        core_slot_d = core_slot_q;
        core_cmd_d = core_cmd_q;
        order_vld_d = order_vld_q;
        order_busy_d = order_busy_q;
        order_acquire_d = order_acquire_q;
        order_slot_d = order_slot_q;
        order_d = order_q;
        rsp_vld_d = rsp_vld_q;
        rsp_report_d = rsp_report_q;
        rsp_slot_d = rsp_slot_q;
        async_rsp_vld_d = async_rsp_vld_q;
        order_fault_d = order_fault_q;
        async_rsp_d = async_rsp_q;
            if (async_rsp_vld_q && async_rsp_rdy_i) async_rsp_vld_d = 1'b0;
            if (selected_async_req_vld_i && selected_async_req_rdy_o) begin
                async_rsp_vld_d = 1'b1;
                async_rsp_d.issuer = selected_async_req_i.issuer;
                async_rsp_d.seq = selected_async_req_i.seq;
                async_rsp_d.status = 8'd0;
                if (selected_async_req_i.complete) begin
                    if (!async_match) async_rsp_d.status = MBAR_STATUS_BAD_TOKEN;
                    else begin
                        async_vld_d[async_match_idx] = 1'b0;
                        for (entry=0;entry<COMMAND_ENTRIES;entry++)
                            cp_predecessors_d[entry][async_match_idx] = 1'b0;
                        async_rsp_d.status = selected_async_req_i.status;
                        if (selected_async_req_i.status != 0) issuer_failed_d[selected_async_req_i.issuer] = 1'b1;
                    end
                end else if (issuer_seen_q[selected_async_req_i.issuer] && selected_async_req_i.seq <= issuer_last_seq_q[selected_async_req_i.issuer]) begin
                    async_rsp_d.status = MBAR_STATUS_BAD_TOKEN;
                end else begin
                    async_vld_d[async_free_idx] = 1'b1;
                    async_issuer_d[async_free_idx] = selected_async_req_i.issuer;
                    async_seq_d[async_free_idx] = selected_async_req_i.seq;
                    issuer_seen_d[selected_async_req_i.issuer] = 1'b1;
                    issuer_last_seq_d[selected_async_req_i.issuer] = selected_async_req_i.seq;
                end
            end
            if (bar_cmd_vld_i && bar_cmd_rdy_o) begin
                cmd_d[free_idx] = bar_cmd_i;
                cp_predecessors_d[free_idx] = '0;
                if (bar_cmd_i.opcode == MBAR_OP_CP_ASYNC_ARRIVE) begin
                    for (predecessor=0;predecessor<ASYNC_ENTRIES;predecessor++)
                        cp_predecessors_d[free_idx][predecessor] = async_vld_q[predecessor] &&
                            async_issuer_q[predecessor] == bar_cmd_i.issuer && async_seq_q[predecessor] < bar_cmd_i.seq &&
                            !(selected_async_req_vld_i && selected_async_req_rdy_o && selected_async_req_i.complete &&
                              async_match && async_match_idx == ASYNC_IDX_W'(predecessor));
                end
                result_d[free_idx] = '0;
                result_d[free_idx].tag = bar_cmd_i.tag;
                result_d[free_idx].issuer = bar_cmd_i.issuer;
                result_d[free_idx].status = input_status;
                report_source_d[free_idx] = 1'b0;
                cp_ack_d[free_idx] = 1'b0; cp_retired_d[free_idx] = input_status != MBAR_STATUS_OK; age_d[free_idx] = acceptance_q;
                acceptance_d = acceptance_q + 64'd1;
                if (input_status != MBAR_STATUS_OK) state_d[free_idx] = E_READY;
                else if (bar_cmd_i.opcode == MBAR_OP_CP_ASYNC_ARRIVE && bar_cmd_i.noinc) state_d[free_idx] = E_CP_WAIT;
                else state_d[free_idx] = input_release ? E_RELEASE : E_ISSUE;
            end else if (report_req_vld_i && report_req_rdy_o) begin
                cmd_d[free_idx] = '0;
                cmd_d[free_idx].opcode = MBAR_OP_REPORT;
                cmd_d[free_idx].addr = report_req_i.addr;
                cmd_d[free_idx].tag = report_req_i.tag;
                cmd_d[free_idx].report = report_req_i.value;
                result_d[free_idx] = '0;
                report_source_d[free_idx] = 1'b1;
                state_d[free_idx] = E_ISSUE;
                cp_ack_d[free_idx] = 1'b0;
                cp_retired_d[free_idx] = 1'b0;
                cp_predecessors_d[free_idx] = '0;
                age_d[free_idx] = acceptance_q;
                acceptance_d = acceptance_q + 64'd1;
            end
            // Request registers preserve payload across arbitrary core backpressure.
            if (issue_found && !core_cmd_vld_q) begin
                core_cmd_d = cmd_q[issue_idx];
                core_cmd_d.tag = 16'(issue_idx);
                core_slot_d = issue_idx;
                core_cmd_vld_d = 1'b1;
                if (state_q[issue_idx] == E_CP_ISSUE) begin
                    core_cmd_d.opcode = issuer_failed_q[cmd_q[issue_idx].issuer] ? MBAR_OP_FAULT : MBAR_OP_ARRIVE;
                    core_cmd_d.arrive_count = 32'd1;
                    core_cmd_d.no_complete = 1'b0;
                    state_d[issue_idx] = E_CP_CORE;
                end else begin
                    if (cmd_q[issue_idx].opcode == MBAR_OP_CP_ASYNC_ARRIVE) core_cmd_d.opcode = MBAR_OP_PENDING_INC;
                    state_d[issue_idx] = E_CORE;
                end
                issue_rr_d = (issue_idx == IDX_W'(COMMAND_ENTRIES-1)) ? '0 : issue_idx + IDX_W'(1);
            end
            if (core_cmd_vld_q && core_cmd_rdy) core_cmd_vld_d = 1'b0;
            for (i = 0; i < COMMAND_ENTRIES; i = i + 1) begin
                // Internal deferred progress is independent of user response
                // consumption. The same record remains reserved until both retire.
                if (state_q[i] == E_CP_WAIT && !cp_pending[i]) state_d[i] = E_CP_ISSUE;
            end
            if (core_rsp_vld && int'(core_rsp_tag) < COMMAND_ENTRIES) begin
                if (state_q[core_rsp_tag[IDX_W-1:0]] == E_CP_CORE) begin
                    cp_retired_d[core_rsp_tag[IDX_W-1:0]] = 1'b1;
                    state_d[core_rsp_tag[IDX_W-1:0]] = cp_ack_q[core_rsp_tag[IDX_W-1:0]] ? E_FREE : E_CP_READY;
                    if (core_rsp.status != 0)
                        issuer_failed_d[cmd_q[core_rsp_tag[IDX_W-1:0]].issuer] = 1'b1;
                end else begin
                    result_d[core_rsp_tag[IDX_W-1:0]] = core_rsp;
                    result_d[core_rsp_tag[IDX_W-1:0]].tag = cmd_q[core_rsp_tag[IDX_W-1:0]].tag;
                    result_d[core_rsp_tag[IDX_W-1:0]].issuer = cmd_q[core_rsp_tag[IDX_W-1:0]].issuer;
                    if (core_rsp.status != MBAR_STATUS_OK &&
                        cmd_q[core_rsp_tag[IDX_W-1:0]].opcode == MBAR_OP_CP_ASYNC_ARRIVE)
                        cp_retired_d[core_rsp_tag[IDX_W-1:0]] = 1'b1;
                    if (core_rsp.status == 0 && cmd_q[core_rsp_tag[IDX_W-1:0]].opcode == MBAR_OP_CP_ASYNC_ARRIVE)
                        state_d[core_rsp_tag[IDX_W-1:0]] = E_CP_WAIT;
                    else if (core_rsp.status == 0 && core_rsp.wait_complete && cmd_q[core_rsp_tag[IDX_W-1:0]].sem == BW_SEM_ACQUIRE)
                        state_d[core_rsp_tag[IDX_W-1:0]] = E_ACQUIRE;
                    else state_d[core_rsp_tag[IDX_W-1:0]] = E_READY;
                end
            end
            if (order_found && !order_vld_q && !order_busy_q) begin
                order_vld_d = 1'b1;
                order_slot_d = order_idx;
                order_acquire_d = state_q[order_idx] == E_ACQUIRE;
                order_d.id = 16'(order_idx);
                order_d.issuer = cmd_q[order_idx].issuer;
                order_d.seq = cmd_q[order_idx].seq;
                order_d.kind = (state_q[order_idx] == E_ACQUIRE) ? BW_ORDER_ACQUIRE : BW_ORDER_RELEASE;
                order_d.scope = cmd_q[order_idx].scope;
                order_d.from_proxy = BW_PROXY_GENERIC;
                order_d.to_proxy = BW_PROXY_GENERIC;
                order_d.addr = {32'd0,cmd_q[order_idx].addr};
                order_d.bytes = 64'd8;
                state_d[order_idx] = E_ORDER;
                order_rr_d = (order_idx == IDX_W'(COMMAND_ENTRIES-1)) ? '0 : order_idx + IDX_W'(1);
            end
            if (order_vld_q && order_req_rdy_i) begin order_vld_d = 1'b0; order_busy_d = 1'b1; order_fault_d = 1'b0; end
            if (order_rsp_vld_i && order_rsp_rdy_o && order_rsp_i.id != 16'(order_slot_q)) begin
                order_fault_d = 1'b1;
            end else if (order_rsp_vld_i && order_rsp_rdy_o) begin
                order_busy_d = 1'b0;
                if (order_rsp_i.status != 0 || order_fault_q) begin
                    result_d[order_slot_q].status = MBAR_STATUS_MEMORY;
                    result_d[order_slot_q].wait_complete = 1'b0;
                    state_d[order_slot_q] = E_READY;
                end else state_d[order_slot_q] = order_acquire_q ? E_READY : E_ISSUE;
            end
            if (rsp_vld_q && (rsp_report_q ? report_rsp_rdy_i : bar_rsp_rdy_i)) begin
                rsp_vld_d = 1'b0;
                if (cmd_q[rsp_slot_q].opcode == MBAR_OP_CP_ASYNC_ARRIVE) begin
                    cp_ack_d[rsp_slot_q] = 1'b1;
                    if (cp_retired_d[rsp_slot_q]) state_d[rsp_slot_q] = E_FREE;
                end else state_d[rsp_slot_q] = E_FREE;
            end
            if (response_found && (!rsp_vld_q || (rsp_report_q ? report_rsp_rdy_i : bar_rsp_rdy_i))) begin
                rsp_vld_d = 1'b1; rsp_slot_d = response_idx; rsp_report_d = report_source_q[response_idx];
                if (cmd_q[response_idx].opcode != MBAR_OP_CP_ASYNC_ARRIVE)
                    state_d[response_idx] = E_HELD;
                response_rr_d = (response_idx == IDX_W'(COMMAND_ENTRIES-1)) ? '0 : response_idx + IDX_W'(1);
            end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < COMMAND_ENTRIES; i = i + 1) begin
                state_q[i] <= E_FREE; cmd_q[i] <= '0; result_q[i] <= '0;
                report_source_q[i] <= 1'b0; cp_ack_q[i] <= 1'b0; cp_retired_q[i] <= 1'b0; cp_predecessors_q[i] <= '0; age_q[i] <= 64'd0;
            end
            for (int i = 0; i < ASYNC_ENTRIES; i = i + 1) begin
                async_vld_q[i] <= 1'b0; async_issuer_q[i] <= '0; async_seq_q[i] <= '0;
            end
            acceptance_q <= 64'd0;
            issuer_failed_q <= '0; issuer_seen_q <= '0;
            /* verilator lint_off WIDTHCONCAT */
            issuer_last_seq_q <= '0;
            /* verilator lint_on WIDTHCONCAT */
            issue_rr_q <= '0; response_rr_q <= '0; order_rr_q <= '0;
            core_cmd_vld_q <= 1'b0; core_cmd_q <= '0; core_slot_q <= '0;
            order_vld_q <= 1'b0; order_busy_q <= 1'b0; order_slot_q <= '0; order_acquire_q <= 1'b0; order_q <= '0;
            rsp_vld_q <= 1'b0; rsp_slot_q <= '0; rsp_report_q <= 1'b0;
            async_rsp_vld_q <= 1'b0; async_rsp_q <= '0;
            order_fault_q <= 1'b0;
        end else begin
            foreach (state_q[idx]) state_q[idx] <= state_d[idx];
            foreach (cmd_q[idx]) cmd_q[idx] <= cmd_d[idx];
            foreach (result_q[idx]) result_q[idx] <= result_d[idx];
            foreach (report_source_q[idx]) report_source_q[idx] <= report_source_d[idx];
            foreach (cp_ack_q[idx]) cp_ack_q[idx] <= cp_ack_d[idx];
            foreach (cp_predecessors_q[idx]) cp_predecessors_q[idx] <= cp_predecessors_d[idx];
            foreach (cp_retired_q[idx]) cp_retired_q[idx] <= cp_retired_d[idx];
            acceptance_q <= acceptance_d;
            foreach (age_q[idx]) age_q[idx] <= age_d[idx];
            issuer_failed_q <= issuer_failed_d;
            foreach (async_vld_q[idx]) async_vld_q[idx] <= async_vld_d[idx];
            foreach (async_issuer_q[idx]) async_issuer_q[idx] <= async_issuer_d[idx];
            foreach (async_seq_q[idx]) async_seq_q[idx] <= async_seq_d[idx];
            issuer_seen_q <= issuer_seen_d;
            issuer_last_seq_q <= issuer_last_seq_d;
            issue_rr_q <= issue_rr_d;
            response_rr_q <= response_rr_d;
            order_rr_q <= order_rr_d;
            core_cmd_vld_q <= core_cmd_vld_d;
            core_slot_q <= core_slot_d;
            core_cmd_q <= core_cmd_d;
            order_vld_q <= order_vld_d;
            order_busy_q <= order_busy_d;
            order_acquire_q <= order_acquire_d;
            order_slot_q <= order_slot_d;
            order_q <= order_d;
            rsp_vld_q <= rsp_vld_d;
            rsp_report_q <= rsp_report_d;
            rsp_slot_q <= rsp_slot_d;
            async_rsp_vld_q <= async_rsp_vld_d;
            order_fault_q <= order_fault_d;
            async_rsp_q <= async_rsp_d;
        end
    end

    wire arb_vld, arb_rdy, arb_rsp_vld, arb_rsp_rdy;
    bar_cmd_t arb_cmd, arb_tc_cmd;
    wire arb_tc_vld, arb_tc_rdy;
    bar_rsp_t arb_rsp;

    logic tc_live_q, tc_live_d, tc_rsp_vld_q, tc_rsp_vld_d;
    logic [ASYNC_TAG_W-1:0] tc_tag_q, tc_tag_d;
    logic [ISSUER_ID_W-1:0] tc_issuer_q, tc_issuer_d;
    bar_rsp_t tc_rsp_q, tc_rsp_d;
    logic unit_idle, unit_drained, records_empty, producers_empty;
    // Arrival payload remains upstream until the same unit/frontend accepting edge.
    assign arb_vld = core_cmd_vld_q;
    assign core_cmd_rdy = arb_rdy;
    assign arb_cmd = core_cmd_q;
    assign arb_tc_vld = tc_arrive_vld_i && !tc_live_q && !tc_rsp_vld_q;
    assign tc_arrive_rdy_o = arb_tc_rdy && !tc_live_q && !tc_rsp_vld_q;
    always_comb begin
      arb_tc_cmd = '0;
      arb_tc_cmd.opcode = tc_arrive_i.opcode == MBAR_OP_FAULT ? MBAR_OP_FAULT : MBAR_OP_ARRIVE;
      arb_tc_cmd.tag = 16'h8000;
      arb_tc_cmd.issuer = tc_arrive_i.issuer;
      arb_tc_cmd.seq = tc_arrive_i.seq;
      arb_tc_cmd.addr = tc_arrive_i.addr;
      arb_tc_cmd.arrive_count = 32'd1;
    end
    assign core_rsp_vld = arb_rsp_vld && !arb_rsp.tag[15];
    assign core_rsp = arb_rsp;
    // Each software command has already reserved a result record. It is never
    // blocked by the externally held software response.
    assign arb_rsp_rdy = arb_rsp.tag[15] ? !tc_rsp_vld_q : 1'b1;
    assign tc_arrive_rsp_vld_o = tc_rsp_vld_q;
    assign tc_arrive_rsp_o = tc_rsp_q;
    always_comb begin
      int entry;
      entry = 0;
      tc_live_d = tc_live_q;
      tc_rsp_vld_d = tc_rsp_vld_q;
      tc_tag_d = tc_tag_q;
      tc_issuer_d = tc_issuer_q;
      tc_rsp_d = tc_rsp_q;
      if (tc_arrive_vld_i && tc_arrive_rdy_o) begin
        tc_live_d = 1'b1;
        tc_tag_d = tc_arrive_i.tag;
        tc_issuer_d = tc_arrive_i.issuer;
      end
      if (arb_rsp_vld && arb_rsp_rdy && arb_rsp.tag[15]) begin
        tc_rsp_d = arb_rsp;
        if (!tc_live_q || arb_rsp.tag != 16'h8000 ||
            arb_rsp.issuer != tc_issuer_q) begin
          tc_rsp_d.status = ASYNC_BAD_COMPLETION;
        end
        // Check the unit-returned identity before restoring the user identity.
        tc_rsp_d.tag = tc_tag_q;
        tc_rsp_d.issuer = tc_issuer_q;
        tc_rsp_vld_d = 1'b1;
      end
      if (tc_rsp_vld_q && tc_arrive_rsp_rdy_i) begin
        tc_rsp_vld_d = 1'b0;
        tc_live_d = 1'b0;
      end
      records_empty = 1'b1;
      producers_empty = 1'b1;
      for (entry = 0; entry < COMMAND_ENTRIES; entry++) begin
        if (state_q[entry] != E_FREE) records_empty = 1'b0;
      end
      for (entry = 0; entry < ASYNC_ENTRIES; entry++) begin
        if (async_vld_q[entry]) producers_empty = 1'b0;
      end
    end
    assign idle_o = unit_idle && !core_cmd_vld_q && !order_vld_q && !order_busy_q;
    assign drained_o = idle_o && unit_drained && records_empty && producers_empty &&
        !rsp_vld_q && !async_rsp_vld_q && !tc_live_q && !tc_rsp_vld_q;
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
        tc_live_q <= 1'b0;
        tc_rsp_vld_q <= 1'b0;
        tc_tag_q <= '0;
        tc_issuer_q <= '0;
        tc_rsp_q <= '0;
      end else begin
        tc_live_q <= tc_live_d;
        tc_rsp_vld_q <= tc_rsp_vld_d;
        tc_tag_q <= tc_tag_d;
        tc_issuer_q <= tc_issuer_d;
        tc_rsp_q <= tc_rsp_d;
      end
    end
`ifndef SYNTHESIS
    assert property (@(posedge clk) disable iff (!rst_n)
        arb_rsp_vld && arb_rsp_rdy && arb_rsp.tag[15] &&
        (!tc_live_q || arb_rsp.tag != 16'h8000 || arb_rsp.issuer != tc_issuer_q)
        |=> tc_arrive_rsp_vld_o && tc_arrive_rsp_o.status == ASYNC_BAD_COMPLETION);
    assert property (@(posedge clk) disable iff (!rst_n)
        tc_arrive_vld_i && tc_arrive_rdy_o |-> arb_tc_vld && arb_tc_rdy);
    assert property (@(posedge clk) disable iff (!rst_n)
        tc_arrive_rsp_vld_o && !tc_arrive_rsp_rdy_i |=> tc_arrive_rsp_vld_o && $stable(tc_arrive_rsp_o));
`endif
    blackwell_mbarrier_unit #(
        .ADDR_W(ADDR_W), .CACHE_ENTRIES(CACHE_ENTRIES), .WAIT_ENTRIES(WAIT_ENTRIES),
        .WRITE_BUF_DEPTH(WRITE_BUF_DEPTH), .MEM_ID_W(MEM_ID_W),
        .CLOCK_PERIOD_NS(CLOCK_PERIOD_NS), .WAIT_DEFAULT_CYCLES(WAIT_DEFAULT_CYCLES)
    ) u_state (
        .clk(clk), .rst_n(rst_n),
        .tc_cmd_vld_i(arb_tc_vld), .tc_cmd_rdy_o(arb_tc_rdy), .tc_cmd_i(arb_tc_cmd),
        .bar_cmd_vld_i(arb_vld), .bar_cmd_rdy_o(arb_rdy),
        .bar_cmd_opcode_i(arb_cmd.opcode), .bar_cmd_tag_i(arb_cmd.tag),
        .bar_cmd_addr_i(arb_cmd.addr), .bar_cmd_arrive_count_i(arb_cmd.arrive_count),
        .bar_cmd_tx_bytes_i(arb_cmd.tx_bytes), .bar_cmd_phase_token_i(arb_cmd.phase_token),
        .bar_cmd_wait_parity_i(arb_cmd.wait_parity), .bar_cmd_state_i(arb_cmd.state),
        .bar_cmd_time_hint_i(arb_cmd.time_hint), .bar_cmd_layout_i(arb_cmd.layout),
        .bar_cmd_no_complete_i(arb_cmd.no_complete), .bar_cmd_conditional_i(arb_cmd.conditional),
        .bar_cmd_report_i(arb_cmd.report),
        .bar_rsp_vld_o(arb_rsp_vld), .bar_rsp_rdy_i(arb_rsp_rdy),
        .bar_rsp_tag_o(arb_rsp.tag), .bar_rsp_issuer_o(arb_rsp.issuer),
        .bar_rsp_status_o(arb_rsp.status), .bar_rsp_phase_o(arb_rsp.phase),
        .bar_rsp_locked_o(arb_rsp.locked), .bar_rsp_state_o(arb_rsp.state),
        .bar_rsp_wait_complete_o(arb_rsp.wait_complete), .bar_rsp_pending_count_o(arb_rsp.value),
        .bar_rsp_predicate_o(arb_rsp.predicate), .bar_rsp_report_o(arb_rsp.report),
        .bar_rsp_report_predicate_o(arb_rsp.report_predicate),
        .tx_cpl_vld_i(tx_cpl_vld_i), .tx_cpl_rdy_o(tx_cpl_rdy_o), .tx_cpl_tag_i(tx_cpl_tag_i),
        .tx_cpl_addr_i(tx_cpl_addr_i), .tx_cpl_bytes_i(tx_cpl_bytes_i), .tx_rsp_vld_o(tx_rsp_vld_o),
        .tx_rsp_rdy_i(tx_rsp_rdy_i), .tx_rsp_tag_o(tx_rsp_tag_o), .tx_rsp_status_o(tx_rsp_status_o),
        .tx_rsp_phase_o(tx_rsp_phase_o), .mem_req_vld_o(mem_req_vld_o), .mem_req_rdy_i(mem_req_rdy_i),
        .mem_req_write_o(mem_req_write_o), .mem_req_addr_o(mem_req_addr_o), .mem_req_data_o(mem_req_data_o),
        .mem_req_byte_mask_o(mem_req_byte_mask_o), .mem_req_id_o(mem_req_id_o), .mem_rsp_vld_i(mem_rsp_vld_i),
        .mem_rsp_rdy_o(mem_rsp_rdy_o), .mem_rsp_data_i(mem_rsp_data_i),
        .mem_rsp_status_i(mem_rsp_status_i), .mem_rsp_id_i(mem_rsp_id_i),
        .idle_o(unit_idle), .drained_o(unit_drained)
    );
    assign core_rsp_tag = core_rsp.tag;

    initial begin
        if (COMMAND_ENTRIES < 4 || COMMAND_ENTRIES > 32768 || ASYNC_ENTRIES < 1)
            $error("mbarrier frontend table bounds invalid");
    end
endmodule
`default_nettype wire
