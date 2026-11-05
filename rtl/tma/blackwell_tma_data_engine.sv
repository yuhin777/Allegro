// Implements frozen A1: doc/specs/blackwell_tma_data_engine.md
module blackwell_tma_data_engine
  import blackwell_async_pkg::*;
#(
parameter int unsigned ADDR_W             = GMEM_ADDR_W,
    parameter int unsigned SMEM_ADDR_W        = SMEM_BYTE_ADDR_W,
    parameter int unsigned CMD_QUEUE_DEPTH    = 8,
    parameter int unsigned DESC_CACHE_ENTRIES = 4,
    parameter int unsigned MSHR_ENTRIES       = TMA_MSHR_ENTRIES,
    parameter int unsigned GMEM_ID_W          = GMEM_ID_DEFAULT_W,
    parameter int unsigned SMEM_ID_W          = TMA_SMEM_ID_DEFAULT_W
) (
  input logic clk,
  input logic rst_n,
  input logic invalidate_i,
  input logic tma_cmd_vld_i,
  input tma_mbarrier_pkg::tma_cmd_t tma_cmd_i,
  input logic gmem_req_rdy_i,
  input logic smem_req_rdy_i,
  input logic tma_order_req_rdy_i,
  input logic tma_order_rsp_vld_i,
  input tma_mbarrier_pkg::bw_order_rsp_t tma_order_rsp_i,
  input logic tma_rsp_rdy_i,
  input logic gmem_rsp_vld_i,
  input logic [GMEM_DATA_W-1:0] gmem_rsp_data_i,
  input logic [MEM_STATUS_W-1:0] gmem_rsp_status_i,
  input logic [GMEM_ID_W-1:0] gmem_rsp_id_i,
  input logic smem_rsp_vld_i,
  input logic [SMEM_DATA_W-1:0] smem_rsp_data_i,
  input logic [MEM_STATUS_W-1:0] smem_rsp_status_i,
  input logic [SMEM_ID_W-1:0] smem_rsp_id_i,
  input logic tx_cpl_rdy_i,
  input logic tx_rsp_vld_i,
  input logic [ASYNC_TAG_W-1:0] tx_rsp_tag_i,
  input logic [STATUS_W-1:0] tx_rsp_status_i,
  input logic tx_rsp_phase_i,
  input logic stop_i,
  output logic tma_cmd_rdy_o,
  output logic gmem_req_vld_o,
  output tma_mbarrier_pkg::bw_mem_attr_t gmem_req_attr_o,
  output logic [ADDR_W-1:0] gmem_req_addr_o,
  output logic [GMEM_DATA_W-1:0] gmem_req_data_o,
  output logic [GMEM_MASK_W-1:0] gmem_req_byte_mask_o,
  output logic [GMEM_ID_W-1:0] gmem_req_id_o,
  output logic gmem_req_write_o,
  output logic smem_req_vld_o,
  output tma_mbarrier_pkg::bw_mem_attr_t smem_req_attr_o,
  output logic [SMEM_ADDR_W-1:0] smem_req_addr_o,
  output logic [SMEM_DATA_W-1:0] smem_req_data_o,
  output logic [SMEM_MASK_W-1:0] smem_req_byte_mask_o,
  output logic [SMEM_ID_W-1:0] smem_req_id_o,
  output logic smem_req_write_o,
  output logic tma_order_req_vld_o,
  output tma_mbarrier_pkg::bw_order_req_t tma_order_req_o,
  output logic tma_order_rsp_rdy_o,
  output logic desc_done_o,
  output logic source_done_o,
  output logic [ASYNC_TAG_W-1:0] event_tag_o,
  output logic tma_rsp_vld_o,
  output logic [ASYNC_TAG_W-1:0] tma_rsp_tag_o,
  output logic [STATUS_W-1:0] tma_rsp_status_o,
  output logic [BYTE_COUNT_W-1:0] tma_rsp_bytes_o,
  output logic gmem_rsp_rdy_o,
  output logic smem_rsp_rdy_o,
  output logic tx_cpl_vld_o,
  output logic [ASYNC_TAG_W-1:0] tx_cpl_tag_o,
  output logic [SMEM_ADDR_W-1:0] tx_cpl_addr_o,
  output logic [BARRIER_TX_BYTES_W-1:0] tx_cpl_bytes_o,
  output logic tx_rsp_rdy_o,
  output logic idle_o,
  output logic drained_o
);

    wire [3:0] tma_cmd_opcode_i = tma_cmd_i.opcode;
    wire [15:0] tma_cmd_tag_i = tma_cmd_i.tag;
    wire [63:0] tma_cmd_desc_ptr_i = tma_cmd_i.desc_ptr;
    wire [159:0] tma_cmd_coord_i = tma_cmd_i.coord;
    wire [31:0] tma_cmd_smem_addr_i = tma_cmd_i.smem_addr;
    wire [63:0] tma_cmd_linear_addr_i = tma_cmd_i.linear_addr;
    wire [31:0] tma_cmd_linear_bytes_i = tma_cmd_i.linear_bytes;
    wire [SMEM_BYTE_ADDR_W-1:0] tma_cmd_barrier_addr_i = tma_cmd_i.barrier_addr;
    wire [2:0] tma_cmd_mode_i = tma_cmd_i.mode;
    wire [79:0] tma_cmd_im2col_i = tma_cmd_i.im2col;
    wire [1:0] tma_cmd_completion_i = tma_cmd_i.completion;

    import tma_mbarrier_pkg::*;

    localparam int unsigned CMD_PTR_W  = (CMD_QUEUE_DEPTH <= 1) ? 1 : $clog2(CMD_QUEUE_DEPTH);
    localparam int unsigned CMD_CNT_W  = $clog2(CMD_QUEUE_DEPTH + 1);
    localparam int unsigned DESC_IDX_W = (DESC_CACHE_ENTRIES <= 1) ? 1 : $clog2(DESC_CACHE_ENTRIES);
    localparam int unsigned MSHR_IDX_W = (MSHR_ENTRIES <= 1) ? 1 : $clog2(MSHR_ENTRIES);
    localparam int unsigned MSHR_CNT_W = $clog2(MSHR_ENTRIES + 1);

    typedef enum logic [3:0] {
      ST_IDLE, ST_DESC_LOOKUP, ST_DESC_WAIT, ST_SETUP, ST_GENERATE,
      ST_WAIT_MSHR, ST_TX_REQ, ST_TX_RSP, ST_RESP, ST_DESC_INV,
      ST_ORDER_REQ, ST_ORDER_RSP
    } state_e;
    typedef enum logic [3:0] {
      M_FREE, M_LD_GREQ, M_LD_GRSP, M_LD_SREQ, M_LD_SRSP,
      M_ST_SREQ, M_ST_SRSP, M_ST_GREQ, M_ST_GRSP
    } mshr_state_e;

    tma_cmd_t cmd_full_q [0:CMD_QUEUE_DEPTH-1], active_cmd_q;
    bw_mem_attr_t g_attr_q, s_attr_q;
    bw_order_req_t order_q;
    wire active_tensor = active_opcode_q == TMA_OP_LOAD_TENSOR || active_opcode_q == TMA_OP_STORE_TENSOR ||
        active_opcode_q == TMA_OP_REDUCE_TENSOR || active_opcode_q == TMA_OP_PREFETCH_TENSOR;
    wire active_prefetch = active_opcode_q == TMA_OP_PREFETCH_LINEAR || active_opcode_q == TMA_OP_PREFETCH_TENSOR;
    wire active_shared = active_opcode_q == TMA_OP_COPY_SHARED || active_opcode_q == TMA_OP_REDUCE_SHARED;
    wire active_reduce = active_opcode_q == TMA_OP_REDUCE_LINEAR || active_opcode_q == TMA_OP_REDUCE_TENSOR || active_opcode_q == TMA_OP_REDUCE_SHARED;
    wire active_store = active_opcode_q == TMA_OP_STORE_TENSOR || active_opcode_q == TMA_OP_STORE_LINEAR || active_reduce || active_shared;
    assign gmem_req_attr_o = g_attr_q;
    assign smem_req_attr_o = s_attr_q;
    logic mshrs_empty;
    always_comb begin
      int entry;
      entry = 0;
      mshrs_empty = 1'b1;
      for (entry = 0; entry < MSHR_ENTRIES; entry++) begin
        if (m_state_q[entry] != M_FREE) mshrs_empty = 1'b0;
      end
    end
    assign idle_o = state_q == ST_IDLE && cmd_count_q == 0 && mshrs_empty &&
        !g_req_vld_q && !s_req_vld_q;
    assign drained_o = idle_o && !rsp_vld_q;
    assign tma_order_req_vld_o = state_q == ST_ORDER_REQ;
    assign tma_order_req_o = order_q;
    assign tma_order_rsp_rdy_o = state_q == ST_ORDER_RSP;
    function automatic bw_mem_attr_t mem_attr(input logic write_req, descriptor_req);
        bw_mem_attr_t a;
        begin
            a = '0;
            a.kind = descriptor_req ? BW_MEM_READ : (write_req ? (active_reduce ? BW_MEM_REDUCE : BW_MEM_WRITE) :
                     (active_prefetch ? BW_MEM_PREFETCH : BW_MEM_READ));
            a.dtype = descriptor_req ? TMA_TYPE_U8 : active_dtype_q;
            a.reduce_op = active_cmd_q.reduce_op;
            a.multimem = !descriptor_req && write_req && active_cmd_q.multimem;
            a.atomic128 = !descriptor_req && active_cmd_q.atomic128;
            a.issuer = active_cmd_q.issuer; a.seq = active_cmd_q.seq;
            a.scope = active_opcode_q == TMA_OP_REDUCE_TENSOR ? BW_SCOPE_GPU : active_cmd_q.scope;
            a.proxy = descriptor_req ? BW_PROXY_TENSORMAP : BW_PROXY_ASYNC;
            a.cache_hint = !descriptor_req && (active_cmd_q.cache_hint || (active_tensor && desc_data_q[873]));
            a.cache_policy = active_cmd_q.cache_hint ? active_cmd_q.cache_policy : (active_tensor ? desc_data_q[943:880] : 64'd0);
            a.l2_promotion = active_tensor ? desc_data_q[872:871] : 2'd0;
            mem_attr = a;
        end
    endfunction

    logic [CMD_PTR_W-1:0]         cmd_rd_ptr_q;
    logic [CMD_PTR_W-1:0]         cmd_wr_ptr_q;
    logic [CMD_CNT_W-1:0]         cmd_count_q;

    logic [2:0] active_mode_q;
    logic [79:0] active_im2col_q;
    logic [1:0] active_completion_q;
    logic source_reported_q, sources_pending;
    wire [7:0] map_status;
    wire [63:0] map_total, map_gaddr;
    wire [31:0] map_saddr;
    wire [3:0] map_elem;
    wire [2:0] map_packed_shift;
    logic [2:0] m_packed_shift_q [0:MSHR_ENTRIES-1];
    logic [3:0] active_dtype_q;
    wire map_in_bounds, map_address_valid;
    wire [159:0] map_coords;
    for (genvar d = 0; d < 5; d = d + 1) begin : g_coords
        assign map_coords[d*32 +: 32] = active_coord_q[d];
    end
    blackwell_tma_tensor_map u_map (
        .desc_i(desc_data_q), .mode_i(active_mode_q),
        .store_i(active_store), .coord_i(map_coords),
        .im2col_i(active_im2col_q), .smem_base_i(active_smem_base_q[31:0]),
        .offset_i(logical_offset_q), .status_o(map_status), .total_bytes_o(map_total),
        .packed_shift_o(map_packed_shift), .elem_bytes_o(map_elem), .gmem_addr_o(map_gaddr), .smem_addr_o(map_saddr),
        .in_bounds_o(map_in_bounds), .address_valid_o(map_address_valid)
    );
    assign event_tag_o = active_tag_q;
    assign desc_done_o = (state_q == ST_SETUP) &&
        active_tensor && map_status == TMA_STATUS_OK && active_status_q == TMA_STATUS_OK;
    assign source_done_o = generation_done_q && !sources_pending && !source_reported_q &&
        active_status_after_rsp == TMA_STATUS_OK &&
        (state_q == ST_WAIT_MSHR || state_q == ST_GENERATE);
    always_comb begin
      int m;
      m = 0;
        sources_pending = 1'b0;
        for (m = 0; m < MSHR_ENTRIES; m = m + 1) begin
            if (m_state_q[m] == M_ST_SREQ || m_state_q[m] == M_ST_SRSP ||
                m_state_q[m] == M_LD_GREQ || m_state_q[m] == M_LD_GRSP)
                sources_pending = 1'b1;
        end
    end
    state_e                   state_q;
    logic [3:0]                   active_opcode_q;
    logic [15:0]                  active_tag_q;
    logic [ADDR_W-1:0]            active_desc_ptr_q;
    logic signed [31:0]           active_coord_q [0:4];
    logic [SMEM_ADDR_W-1:0]       active_smem_base_q;
    logic [ADDR_W-1:0]            active_linear_addr_q;
    logic [31:0]                  active_linear_bytes_q;
    logic [SMEM_ADDR_W-1:0] active_barrier_addr_q;
    logic [7:0]                   active_status_q;
    logic [63:0]                  active_total_bytes_q;
    logic [63:0]                  logical_offset_q;
    logic order_fault_q, tx_fault_q;
    logic g_rsp_expected, s_rsp_expected, desc_rsp_expected;
    logic                         generation_done_q;

    logic [1023:0]                desc_data_q;
    logic desc_second_q;
    logic [511:0] desc_first_q;
    logic                         desc_cache_vld_q [0:DESC_CACHE_ENTRIES-1];
    logic [ADDR_W-1:0]            desc_cache_addr_q [0:DESC_CACHE_ENTRIES-1];
    logic [1023:0]                desc_cache_data_q [0:DESC_CACHE_ENTRIES-1];
    logic [DESC_IDX_W-1:0]        desc_replace_q;
    logic                         desc_fetch_pending_q;
    logic                         desc_fetch_issued_q;

    logic [3:0] desc_elem_bytes_q;

    mshr_state_e                   m_state_q [0:MSHR_ENTRIES-1];
    logic [ADDR_W-1:0]            m_gmem_addr_q [0:MSHR_ENTRIES-1];
    logic [6:0]                   m_gmem_off_q [0:MSHR_ENTRIES-1];
    logic [SMEM_ADDR_W-1:0]       m_smem_addr_q [0:MSHR_ENTRIES-1];
    logic [4:0]                   m_smem_off_q [0:MSHR_ENTRIES-1];
    logic [5:0]                   m_len_q [0:MSHR_ENTRIES-1];
    logic [1023:0]                m_data_q [0:MSHR_ENTRIES-1];
    logic [127:0]                 gen_read_mask;
    logic [127:0]                 m_mask_q [0:MSHR_ENTRIES-1];

    logic                         g_req_vld_q;
    logic                         g_req_write_q;
    logic [ADDR_W-1:0]            g_req_addr_q;
    logic [1023:0]                g_req_data_q;
    logic [127:0]                 g_req_mask_q;
    logic [GMEM_ID_W-1:0]         g_req_id_q;
    logic                         s_req_vld_q;
    logic                         s_req_write_q;
    logic [SMEM_ADDR_W-1:0]       s_req_addr_q;
    logic [255:0]                 s_req_data_q;
    logic [31:0]                  s_req_mask_q;
    logic [SMEM_ID_W-1:0]         s_req_id_q;

    logic                         rsp_vld_q;
    logic [15:0]                  rsp_tag_q;
    logic [7:0]                   rsp_status_q;
    logic [63:0]                  rsp_bytes_q;
    logic                         tx_cpl_vld_q;

    logic                         cmd_fire;
    logic                         cmd_pop;
    logic                         rsp_fire;
    logic                         g_req_fire;
    logic                         s_req_fire;
    logic                         g_rsp_fire;
    logic                         s_rsp_fire;
    logic                         tx_cpl_fire;
    logic                         tx_rsp_fire;

    logic                         desc_cache_hit;
    logic [DESC_IDX_W-1:0]        desc_cache_hit_idx;
    logic                         free_mshr_found;
    logic [MSHR_IDX_W-1:0]        free_mshr_idx;
    logic                         g_send_found;
    logic [MSHR_IDX_W-1:0]        g_send_idx;
    logic                         s_send_found;
    logic [MSHR_IDX_W-1:0]        s_send_idx;


    logic [ADDR_W:0]              gen_linear_gaddr_ext;
    logic [64:0]                  gen_saddr_ext;
    logic [ADDR_W-1:0]            gen_gaddr;
    logic [SMEM_ADDR_W-1:0]       gen_saddr;
    logic                         gen_in_bounds;
    logic                         gen_addr_valid;
    logic [5:0]                   gen_segment_bytes;
    logic [63:0]                  gen_remaining_bytes;
    logic [7:0]                   gen_gline_bytes;
    logic                         gen_is_load;
    logic                         gen_is_store;
    logic                         gen_advance;
    logic                         gen_allocate;
    logic                         gen_last;

    logic [MSHR_IDX_W-1:0]        g_rsp_mshr_idx;
    logic [MSHR_IDX_W-1:0]        s_rsp_mshr_idx;
    logic                         active_done_after_rsp;
    logic [7:0]                   active_status_after_rsp;

    localparam logic [GMEM_ID_W:0] MSHR_ENTRIES_GMEM_EXT =
        (GMEM_ID_W + 1)'(MSHR_ENTRIES);
    localparam logic [SMEM_ID_W:0] MSHR_ENTRIES_SMEM_EXT =
        (SMEM_ID_W + 1)'(MSHR_ENTRIES);

    function automatic logic [31:0] make_mask32(
        input logic [5:0] length,
        input logic [4:0] offset
    );
        int unsigned mask_bit;
        begin
            mask_bit = 0;
            make_mask32 = 32'd0;
            for (mask_bit = 0; mask_bit < 32;
                 mask_bit = mask_bit + 1) begin
                if ((mask_bit >= 32'(offset)) &&
                    (mask_bit < (32'(offset) + 32'(length)))) begin
                    make_mask32[mask_bit] = 1'b1;
                end
            end
        end
    endfunction

    function automatic logic [127:0] make_mask128(
        input logic [5:0] length,
        input logic [6:0] offset
    );
        int unsigned mask_bit;
        begin
            mask_bit = 0;
            make_mask128 = 128'd0;
            for (mask_bit = 0; mask_bit < 128;
                 mask_bit = mask_bit + 1) begin
                if ((mask_bit >= 32'(offset)) &&
                    (mask_bit < (32'(offset) + 32'(length)))) begin
                    make_mask128[mask_bit] = 1'b1;
                end
            end
        end
    endfunction

    assign tma_cmd_rdy_o = !stop_i && (cmd_count_q != CMD_CNT_W'(CMD_QUEUE_DEPTH));
    assign cmd_fire = tma_cmd_vld_i && tma_cmd_rdy_o;
    assign cmd_pop = (state_q == ST_IDLE) && (cmd_count_q != 0) && !rsp_vld_q;

    assign tma_rsp_vld_o = rsp_vld_q;
    assign tma_rsp_tag_o = rsp_tag_q;
    assign tma_rsp_status_o = rsp_status_q;
    assign tma_rsp_bytes_o = rsp_bytes_q;
    assign rsp_fire = rsp_vld_q && tma_rsp_rdy_i;

    assign gmem_req_vld_o = g_req_vld_q;
    assign gmem_req_write_o = g_req_write_q;
    assign gmem_req_addr_o = g_req_addr_q;
    assign gmem_req_data_o = g_req_data_q;
    assign gmem_req_byte_mask_o = g_req_mask_q;
    assign gmem_req_id_o = g_req_id_q;
    assign gmem_rsp_rdy_o = 1'b1;
    assign g_req_fire = g_req_vld_q && gmem_req_rdy_i;
    assign g_rsp_fire = gmem_rsp_vld_i && gmem_rsp_rdy_o;

    assign smem_req_vld_o = s_req_vld_q;
    assign smem_req_write_o = s_req_write_q;
    assign smem_req_addr_o = s_req_addr_q;
    assign smem_req_data_o = s_req_data_q;
    assign smem_req_byte_mask_o = s_req_mask_q;
    assign smem_req_id_o = s_req_id_q;
    assign smem_rsp_rdy_o = 1'b1;
    assign s_req_fire = s_req_vld_q && smem_req_rdy_i;
    assign s_rsp_fire = smem_rsp_vld_i && smem_rsp_rdy_o;

    assign tx_cpl_vld_o = tx_cpl_vld_q;
    assign tx_cpl_tag_o = active_tag_q;
    assign tx_cpl_addr_o = active_barrier_addr_q;
    assign tx_cpl_bytes_o = BARRIER_TX_BYTES_W'(active_total_bytes_q);
    assign tx_cpl_fire = tx_cpl_vld_q && tx_cpl_rdy_i;
    assign tx_rsp_rdy_o = (state_q == ST_TX_RSP);
    assign tx_rsp_fire = tx_rsp_vld_i && tx_rsp_rdy_o;

    always_comb begin
      int unsigned cache_idx;
      cache_idx = 0;
        desc_cache_hit = 1'b0;
        desc_cache_hit_idx = {DESC_IDX_W{1'b0}};
        for (cache_idx = 0;
             cache_idx < DESC_CACHE_ENTRIES; cache_idx = cache_idx + 1) begin
            if (desc_cache_vld_q[cache_idx] &&
                (desc_cache_addr_q[cache_idx] == active_desc_ptr_q)) begin
                desc_cache_hit = 1'b1;
                desc_cache_hit_idx = DESC_IDX_W'(cache_idx);
            end
        end
    end

    always_comb begin
      int unsigned mshr_idx;
      mshr_idx = 0;
        free_mshr_found = 1'b0;
        free_mshr_idx = {MSHR_IDX_W{1'b0}};
        g_send_found = 1'b0;
        g_send_idx = {MSHR_IDX_W{1'b0}};
        s_send_found = 1'b0;
        s_send_idx = {MSHR_IDX_W{1'b0}};
        for (mshr_idx = 0;
             mshr_idx < MSHR_ENTRIES; mshr_idx = mshr_idx + 1) begin
            if ((m_state_q[mshr_idx] == M_FREE) && !free_mshr_found) begin
                free_mshr_found = 1'b1;
                free_mshr_idx = MSHR_IDX_W'(mshr_idx);
            end
            if (((m_state_q[mshr_idx] == M_LD_GREQ) ||
                 (m_state_q[mshr_idx] == M_ST_GREQ)) && !active_shared && !g_send_found) begin
                g_send_found = 1'b1;
                g_send_idx = MSHR_IDX_W'(mshr_idx);
            end
            if (((m_state_q[mshr_idx] == M_LD_SREQ) ||
                 (m_state_q[mshr_idx] == M_ST_SREQ) || (active_shared && m_state_q[mshr_idx] == M_ST_GREQ)) && !s_send_found) begin
                s_send_found = 1'b1;
                s_send_idx = MSHR_IDX_W'(mshr_idx);
            end
        end
    end

    // Address generation and one-dimensional coalescing.  A segment never
    // crosses a 128-byte GMEM line or a 32-byte SMEM beat.
    always_comb begin
      int b;
      b = 0;
        gen_is_load = (active_opcode_q == TMA_OP_LOAD_TENSOR) ||
                      (active_opcode_q == TMA_OP_LOAD_LINEAR) || active_prefetch;
        gen_is_store = active_store;
        gen_remaining_bytes = active_total_bytes_q - logical_offset_q;
        gen_linear_gaddr_ext = {1'b0, active_linear_addr_q} + logical_offset_q;
        gen_saddr_ext = {{(65-SMEM_ADDR_W){1'b0}}, active_smem_base_q} +
                        {1'b0, logical_offset_q};
        gen_gaddr = gen_linear_gaddr_ext[ADDR_W-1:0];
        gen_saddr = gen_saddr_ext[SMEM_ADDR_W-1:0];
        gen_in_bounds = 1'b1;
        gen_addr_valid = (gen_linear_gaddr_ext[ADDR_W] == 1'b0) &&
                         (gen_saddr_ext[64:SMEM_ADDR_W] == '0);
        gen_segment_bytes = 6'd1;
        gen_gline_bytes = 8'd128 - {1'b0, gen_gaddr[6:0]};
        gen_allocate = 1'b0;
        gen_advance = 1'b0;
        gen_last = 1'b0;
        if (!active_tensor) begin
            if (gen_remaining_bytes < 64'd32) begin
                gen_segment_bytes = gen_remaining_bytes[5:0];
            end else begin
                gen_segment_bytes = 6'd32;
            end
            if (gen_segment_bytes > (6'd32 - {1'b0, gen_saddr[4:0]})) begin
                gen_segment_bytes = 6'd32 - {1'b0, gen_saddr[4:0]};
            end
            gen_gline_bytes = 8'd128 - {1'b0, gen_gaddr[6:0]};
            if ({2'd0, gen_segment_bytes} > gen_gline_bytes) begin
                gen_segment_bytes = gen_gline_bytes[5:0];
            end
        end else begin
            gen_gaddr = map_gaddr;
            gen_saddr = SMEM_ADDR_W'(map_saddr);
            gen_in_bounds = map_in_bounds;
            gen_addr_valid = map_address_valid;
            // One element per segment preserves every swizzle atom and OOB
            // boundary. Memory responses still overlap through the MSHRs.
            gen_segment_bytes = {2'b0, desc_elem_bytes_q};
        end

        gen_read_mask = make_mask128(gen_segment_bytes,gen_gaddr[6:0]);
        if (active_cmd_q.ignore_oob) begin
            if (gen_segment_bytes > 16) gen_segment_bytes = 6'd16;
            gen_read_mask = make_mask128(gen_segment_bytes,gen_gaddr[6:0]);
            for (b=0; b<128; b=b+1) begin
                if (64'(b) >= {57'd0,gen_gaddr[6:0]} &&
                    ((logical_offset_q+64'(b)-{57'd0,gen_gaddr[6:0]}) < {60'd0,active_cmd_q.oob_start} ||
                     (logical_offset_q+64'(b)-{57'd0,gen_gaddr[6:0]}) >= active_total_bytes_q-{60'd0,active_cmd_q.oob_end}))
                    gen_read_mask[b] = 1'b0;
            end
        end
        if (active_cmd_q.atomic128 && gen_segment_bytes > 16) gen_segment_bytes = 6'd16;
        if (!active_cmd_q.ignore_oob) gen_read_mask = make_mask128(gen_segment_bytes,gen_gaddr[6:0]);
        gen_allocate = (state_q == ST_GENERATE) && !generation_done_q &&
                       active_status_after_rsp == TMA_STATUS_OK &&
                       gen_addr_valid && (gen_is_load || gen_is_store) &&
                       (gen_in_bounds || (gen_is_load && !active_prefetch)) && free_mshr_found;
        gen_advance = (state_q == ST_GENERATE) && !generation_done_q &&
                       active_status_after_rsp == TMA_STATUS_OK &&
                      gen_addr_valid && (gen_is_load || gen_is_store) &&
                      ((!gen_in_bounds && (gen_is_store || active_prefetch)) || gen_allocate);
        gen_last = (logical_offset_q + {58'd0, gen_segment_bytes} >=
                    active_total_bytes_q);


    end

    assign g_rsp_mshr_idx = gmem_rsp_id_i[MSHR_IDX_W-1:0];
    assign s_rsp_mshr_idx = smem_rsp_id_i[MSHR_IDX_W-1:0];
    assign desc_rsp_expected = gmem_rsp_id_i == GMEM_ID_W'(MSHR_ENTRIES) &&
        desc_fetch_issued_q && state_q == ST_DESC_WAIT;
    assign g_rsp_expected = ({1'b0,gmem_rsp_id_i} < MSHR_ENTRIES_GMEM_EXT) &&
        (m_state_q[g_rsp_mshr_idx] == M_LD_GRSP ||
         (!active_shared && m_state_q[g_rsp_mshr_idx] == M_ST_GRSP));
    assign s_rsp_expected = ({1'b0,smem_rsp_id_i} < MSHR_ENTRIES_SMEM_EXT) &&
        (m_state_q[s_rsp_mshr_idx] == M_ST_SRSP || m_state_q[s_rsp_mshr_idx] == M_LD_SRSP ||
         (active_shared && m_state_q[s_rsp_mshr_idx] == M_ST_GRSP));
    // A protocol failure never retires an unrelated live ID. Keep receiving
    // the actual issued acknowledgements, then terminate the copy once drained.
    always_comb begin
        active_status_after_rsp = active_status_q;
        if (active_status_q == TMA_STATUS_OK && state_q != ST_IDLE && state_q != ST_RESP) begin
            if (g_rsp_fire && !g_rsp_expected && !desc_rsp_expected)
                active_status_after_rsp = TMA_STATUS_INTERNAL;
            else if (s_rsp_fire && !s_rsp_expected)
                active_status_after_rsp = TMA_STATUS_INTERNAL;
            else if (g_rsp_fire && gmem_rsp_status_i != 0)
                active_status_after_rsp = TMA_STATUS_GMEM;
            else if (s_rsp_fire && smem_rsp_status_i != 0)
                active_status_after_rsp = TMA_STATUS_SMEM;
        end
    end
    assign active_done_after_rsp = generation_done_q && mshrs_empty &&
        !g_req_vld_q && !s_req_vld_q;

    tma_cmd_t cmd_full_d [0:CMD_QUEUE_DEPTH-1];
    tma_cmd_t active_cmd_d ;
    bw_mem_attr_t g_attr_d ;
    bw_mem_attr_t s_attr_d ;
    bw_order_req_t order_d ;
    logic [CMD_PTR_W-1:0] cmd_rd_ptr_d ;
    logic [CMD_PTR_W-1:0] cmd_wr_ptr_d ;
    logic [CMD_CNT_W-1:0] cmd_count_d ;
    logic [2:0] active_mode_d ;
    logic [79:0] active_im2col_d ;
    logic [1:0] active_completion_d ;
    logic source_reported_d ;
    logic [2:0] m_packed_shift_d [0:MSHR_ENTRIES-1];
    logic [3:0] active_dtype_d ;
    state_e state_d ;
    logic [3:0] active_opcode_d ;
    logic [15:0] active_tag_d ;
    logic [ADDR_W-1:0] active_desc_ptr_d ;
    logic signed [31:0] active_coord_d [0:4];
    logic [SMEM_ADDR_W-1:0] active_smem_base_d ;
    logic [ADDR_W-1:0] active_linear_addr_d ;
    logic [31:0] active_linear_bytes_d ;
    logic [SMEM_ADDR_W-1:0] active_barrier_addr_d ;
    logic [7:0] active_status_d ;
    logic [63:0] active_total_bytes_d ;
    logic [63:0] logical_offset_d ;
    logic order_fault_d ;
    logic tx_fault_d ;
    logic generation_done_d ;
    logic [1023:0] desc_data_d ;
    logic desc_second_d ;
    logic [511:0] desc_first_d ;
    logic desc_cache_vld_d [0:DESC_CACHE_ENTRIES-1];
    logic [ADDR_W-1:0] desc_cache_addr_d [0:DESC_CACHE_ENTRIES-1];
    logic [1023:0] desc_cache_data_d [0:DESC_CACHE_ENTRIES-1];
    logic [DESC_IDX_W-1:0] desc_replace_d ;
    logic desc_fetch_pending_d ;
    logic desc_fetch_issued_d ;
    logic [3:0] desc_elem_bytes_d ;
    mshr_state_e m_state_d [0:MSHR_ENTRIES-1];
    logic [ADDR_W-1:0] m_gmem_addr_d [0:MSHR_ENTRIES-1];
    logic [6:0] m_gmem_off_d [0:MSHR_ENTRIES-1];
    logic [SMEM_ADDR_W-1:0] m_smem_addr_d [0:MSHR_ENTRIES-1];
    logic [4:0] m_smem_off_d [0:MSHR_ENTRIES-1];
    logic [5:0] m_len_d [0:MSHR_ENTRIES-1];
    logic [1023:0] m_data_d [0:MSHR_ENTRIES-1];
    logic [127:0] m_mask_d [0:MSHR_ENTRIES-1];
    logic g_req_vld_d ;
    logic g_req_write_d ;
    logic [ADDR_W-1:0] g_req_addr_d ;
    logic [1023:0] g_req_data_d ;
    logic [127:0] g_req_mask_d ;
    logic [GMEM_ID_W-1:0] g_req_id_d ;
    logic s_req_vld_d ;
    logic s_req_write_d ;
    logic [SMEM_ADDR_W-1:0] s_req_addr_d ;
    logic [255:0] s_req_data_d ;
    logic [31:0] s_req_mask_d ;
    logic [SMEM_ID_W-1:0] s_req_id_d ;
    logic rsp_vld_d ;
    logic [15:0] rsp_tag_d ;
    logic [7:0] rsp_status_d ;
    logic [63:0] rsp_bytes_d ;
    logic tx_cpl_vld_d ;

    always_comb begin
      int i;
      int unsigned pop_dim;
      int unsigned inv_idx;
      int entry;
      i = 0;
      pop_dim = 0;
      inv_idx = 0;
      entry = 0;
        foreach (cmd_full_q[idx]) cmd_full_d[idx] = cmd_full_q[idx];
        active_cmd_d = active_cmd_q;
        g_attr_d = g_attr_q;
        s_attr_d = s_attr_q;
        order_d = order_q;
        cmd_rd_ptr_d = cmd_rd_ptr_q;
        cmd_wr_ptr_d = cmd_wr_ptr_q;
        cmd_count_d = cmd_count_q;
        active_mode_d = active_mode_q;
        active_im2col_d = active_im2col_q;
        active_completion_d = active_completion_q;
        source_reported_d = source_reported_q;
        foreach (m_packed_shift_q[idx]) m_packed_shift_d[idx] = m_packed_shift_q[idx];
        active_dtype_d = active_dtype_q;
        state_d = state_q;
        active_opcode_d = active_opcode_q;
        active_tag_d = active_tag_q;
        active_desc_ptr_d = active_desc_ptr_q;
        foreach (active_coord_q[idx]) active_coord_d[idx] = active_coord_q[idx];
        active_smem_base_d = active_smem_base_q;
        active_linear_addr_d = active_linear_addr_q;
        active_linear_bytes_d = active_linear_bytes_q;
        active_barrier_addr_d = active_barrier_addr_q;
        active_status_d = active_status_q;
        active_total_bytes_d = active_total_bytes_q;
        logical_offset_d = logical_offset_q;
        order_fault_d = order_fault_q;
        tx_fault_d = tx_fault_q;
        generation_done_d = generation_done_q;
        desc_data_d = desc_data_q;
        desc_second_d = desc_second_q;
        desc_first_d = desc_first_q;
        foreach (desc_cache_vld_q[idx]) desc_cache_vld_d[idx] = desc_cache_vld_q[idx];
        foreach (desc_cache_addr_q[idx]) desc_cache_addr_d[idx] = desc_cache_addr_q[idx];
        foreach (desc_cache_data_q[idx]) desc_cache_data_d[idx] = desc_cache_data_q[idx];
        desc_replace_d = desc_replace_q;
        desc_fetch_pending_d = desc_fetch_pending_q;
        desc_fetch_issued_d = desc_fetch_issued_q;
        desc_elem_bytes_d = desc_elem_bytes_q;
        foreach (m_state_q[idx]) m_state_d[idx] = m_state_q[idx];
        foreach (m_gmem_addr_q[idx]) m_gmem_addr_d[idx] = m_gmem_addr_q[idx];
        foreach (m_gmem_off_q[idx]) m_gmem_off_d[idx] = m_gmem_off_q[idx];
        foreach (m_smem_addr_q[idx]) m_smem_addr_d[idx] = m_smem_addr_q[idx];
        foreach (m_smem_off_q[idx]) m_smem_off_d[idx] = m_smem_off_q[idx];
        foreach (m_len_q[idx]) m_len_d[idx] = m_len_q[idx];
        foreach (m_data_q[idx]) m_data_d[idx] = m_data_q[idx];
        foreach (m_mask_q[idx]) m_mask_d[idx] = m_mask_q[idx];
        g_req_vld_d = g_req_vld_q;
        g_req_write_d = g_req_write_q;
        g_req_addr_d = g_req_addr_q;
        g_req_data_d = g_req_data_q;
        g_req_mask_d = g_req_mask_q;
        g_req_id_d = g_req_id_q;
        s_req_vld_d = s_req_vld_q;
        s_req_write_d = s_req_write_q;
        s_req_addr_d = s_req_addr_q;
        s_req_data_d = s_req_data_q;
        s_req_mask_d = s_req_mask_q;
        s_req_id_d = s_req_id_q;
        rsp_vld_d = rsp_vld_q;
        rsp_tag_d = rsp_tag_q;
        rsp_status_d = rsp_status_q;
        rsp_bytes_d = rsp_bytes_q;
        tx_cpl_vld_d = tx_cpl_vld_q;
            if (invalidate_i) begin
                for (i=0; i<DESC_CACHE_ENTRIES; i=i+1) desc_cache_vld_d[i] = 1'b0;
            end
            if (source_done_o) source_reported_d = 1'b1;
            if (cmd_fire) begin
                cmd_full_d[cmd_wr_ptr_q] = tma_cmd_i;

                cmd_wr_ptr_d = (cmd_wr_ptr_q == CMD_PTR_W'(CMD_QUEUE_DEPTH-1)) ?
                                {CMD_PTR_W{1'b0}} : cmd_wr_ptr_q + CMD_PTR_W'(1);
            end
            if (cmd_pop) begin
                active_cmd_d = cmd_full_q[cmd_rd_ptr_q];
                active_mode_d = cmd_full_q[cmd_rd_ptr_q].mode;
                active_im2col_d = cmd_full_q[cmd_rd_ptr_q].im2col;
                active_completion_d = cmd_full_q[cmd_rd_ptr_q].completion;
                source_reported_d = 1'b0;
                order_fault_d = 1'b0; tx_fault_d = 1'b0;
                active_opcode_d = cmd_full_q[cmd_rd_ptr_q].opcode;
                active_tag_d = cmd_full_q[cmd_rd_ptr_q].tag;
                active_desc_ptr_d = cmd_full_q[cmd_rd_ptr_q].desc_ptr;
                active_smem_base_d = (cmd_full_q[cmd_rd_ptr_q].opcode == TMA_OP_PREFETCH_LINEAR || cmd_full_q[cmd_rd_ptr_q].opcode == TMA_OP_PREFETCH_TENSOR) ? '0 : cmd_full_q[cmd_rd_ptr_q].smem_addr;
                active_linear_addr_d = cmd_full_q[cmd_rd_ptr_q].linear_addr;
                active_linear_bytes_d = cmd_full_q[cmd_rd_ptr_q].linear_bytes;
                active_barrier_addr_d = cmd_full_q[cmd_rd_ptr_q].barrier_addr;
                active_status_d = TMA_STATUS_OK;
                active_dtype_d = cmd_full_q[cmd_rd_ptr_q].dtype;
                active_total_bytes_d = 64'd0;
                logical_offset_d = 64'd0;

                generation_done_d = 1'b0;
                for (pop_dim = 0; pop_dim < 5;
                     pop_dim = pop_dim + 1) begin
                    active_coord_d[pop_dim] =
                        $signed(cmd_full_q[cmd_rd_ptr_q].coord[pop_dim*32 +: 32]);
                end
                cmd_rd_ptr_d = (cmd_rd_ptr_q == CMD_PTR_W'(CMD_QUEUE_DEPTH-1)) ?
                                {CMD_PTR_W{1'b0}} : cmd_rd_ptr_q + CMD_PTR_W'(1);
                case (cmd_full_q[cmd_rd_ptr_q].opcode)
                    TMA_OP_LOAD_TENSOR,
                    TMA_OP_STORE_TENSOR, TMA_OP_REDUCE_TENSOR, TMA_OP_PREFETCH_TENSOR: state_d = ST_DESC_LOOKUP;
                    TMA_OP_LOAD_LINEAR,
                    TMA_OP_STORE_LINEAR, TMA_OP_COPY_SHARED, TMA_OP_REDUCE_LINEAR, TMA_OP_REDUCE_SHARED, TMA_OP_PREFETCH_LINEAR: state_d = ST_SETUP;
                    TMA_OP_DESC_INV: state_d = ST_DESC_INV;
                    default: begin
                        rsp_vld_d = 1'b1;
                        rsp_tag_d = cmd_full_q[cmd_rd_ptr_q].tag;
                        rsp_status_d = TMA_STATUS_BAD_OPCODE;
                        rsp_bytes_d = 64'd0;
                        state_d = ST_RESP;
                    end
                endcase
            end
            case ({cmd_fire, cmd_pop})
                2'b10: cmd_count_d = cmd_count_q + CMD_CNT_W'(1);
                2'b01: cmd_count_d = cmd_count_q - CMD_CNT_W'(1);
                default: cmd_count_d = cmd_count_q;
            endcase

            if (rsp_fire) begin
                rsp_vld_d = 1'b0;
                if (state_q == ST_RESP) state_d = ST_IDLE;
            end

            case (state_q)
                ST_DESC_LOOKUP: begin
                    if (active_desc_ptr_q[5:0] != 6'd0) begin
                        rsp_vld_d = 1'b1;
                        rsp_tag_d = active_tag_q;
                        rsp_status_d = TMA_STATUS_BAD_DESC_ALIGN;
                        rsp_bytes_d = 64'd0;
                        state_d = ST_RESP;
                    end else if (({1'b0,active_desc_ptr_q} + 65'(TENSOR_MAP_BYTES)) >
                                 65'h1_0000_0000_0000_0000) begin
                        rsp_vld_d = 1'b1;
                        rsp_tag_d = active_tag_q;
                        rsp_status_d = TMA_STATUS_ADDR_OVERFLOW;
                        rsp_bytes_d = 64'd0;
                        state_d = ST_RESP;
                    end else if (desc_cache_hit) begin
                        desc_data_d = desc_cache_data_q[desc_cache_hit_idx];
                        state_d = ST_SETUP;
                    end else begin
                        desc_fetch_pending_d = 1'b1;
                        desc_second_d = 1'b0;
                        state_d = ST_DESC_WAIT;
                    end
                end

                ST_SETUP: begin
                    if ((active_smem_base_q[3:0] != 4'd0)) begin
                        rsp_vld_d = 1'b1;
                        rsp_tag_d = active_tag_q;
                        rsp_status_d = TMA_STATUS_BAD_SMEM_ALIGN;
                        rsp_bytes_d = 64'd0;
                        state_d = ST_RESP;
                    end else if (active_reduce && !reduction_legal(active_tensor ? desc_data_q[867:864] : active_cmd_q.dtype,
                                 active_cmd_q.reduce_op, active_shared, active_tensor)) begin
                        rsp_vld_d = 1'b1; rsp_tag_d = active_tag_q;
                        rsp_status_d = TMA_STATUS_UNSUPPORTED; rsp_bytes_d = 0; state_d = ST_RESP;
                    end else if (!active_tensor) begin
                        if (({1'b0,active_linear_addr_q} + {33'd0,active_linear_bytes_q} > {1'b1,64'd0}) ||
                            ({1'b0,active_smem_base_q} + {1'b0,active_linear_bytes_q} > 33'h100000000) ||
                            (active_shared && ({1'b0,active_linear_addr_q} + {33'd0,active_linear_bytes_q} > 65'h100000000))) begin
                            rsp_vld_d = 1'b1;
                            rsp_tag_d = active_tag_q;
                            rsp_status_d = TMA_STATUS_ADDR_OVERFLOW;
                            rsp_bytes_d = 64'd0;
                            state_d = ST_RESP;
                        end else if ((active_linear_bytes_q[3:0] != 0) ||
                                     (active_linear_addr_q[3:0] != 0)) begin
                            rsp_vld_d = 1'b1;
                            rsp_tag_d = active_tag_q;
                            rsp_status_d = TMA_STATUS_BAD_DESC;
                            rsp_bytes_d = 64'd0;
                            state_d = ST_RESP;
                        end else begin
                            active_total_bytes_d = {32'd0, active_linear_bytes_q};
                            logical_offset_d = 64'd0;
                            state_d = active_linear_bytes_q == 0 ? ST_WAIT_MSHR : ST_GENERATE;
                            generation_done_d = active_linear_bytes_q == 0;
                        end
                    end else if (map_status != TMA_STATUS_OK || (active_completion_q == TMA_CPL_MBAR && map_total > 64'hffff_ffff)) begin
                        rsp_vld_d = 1'b1;
                        rsp_tag_d = active_tag_q;
                        rsp_status_d = map_status != TMA_STATUS_OK ? map_status : TMA_STATUS_ADDR_OVERFLOW;
                        rsp_bytes_d = 64'd0;
                        state_d = ST_RESP;
                    end else begin
                        desc_elem_bytes_d = map_elem;
                        active_dtype_d = desc_data_q[867:864];
                        active_total_bytes_d = map_total;
                        logical_offset_d = 64'd0;
                        state_d = ST_GENERATE;
                    end
                end

                ST_DESC_INV: begin
                    for (inv_idx = 0;
                         inv_idx < DESC_CACHE_ENTRIES;
                         inv_idx = inv_idx + 1) begin
                        if ((active_desc_ptr_q == {ADDR_W{1'b0}}) ||
                            (desc_cache_addr_q[inv_idx] == active_desc_ptr_q)) begin
                            desc_cache_vld_d[inv_idx] = 1'b0;
                        end
                    end
                    rsp_vld_d = 1'b1;
                    rsp_tag_d = active_tag_q;
                    rsp_status_d = TMA_STATUS_OK;
                    rsp_bytes_d = 64'd0;
                    state_d = ST_RESP;
                end

                ST_GENERATE: begin
                    if (active_status_after_rsp != TMA_STATUS_OK || !gen_addr_valid) begin
                        active_status_d = active_status_after_rsp != TMA_STATUS_OK ? active_status_after_rsp : TMA_STATUS_ADDR_OVERFLOW;
                        generation_done_d = 1'b1;
                        state_d = ST_WAIT_MSHR;
                    end else if (gen_advance) begin
                        logical_offset_d = logical_offset_q +
                                            {58'd0, gen_segment_bytes};
                        if (gen_last) begin
                            generation_done_d = 1'b1;
                            state_d = ST_WAIT_MSHR;
                        end
                    end
                end

                ST_WAIT_MSHR: begin
                    if (active_done_after_rsp) begin
                        if (!active_prefetch && active_status_after_rsp == TMA_STATUS_OK) begin
                            order_d = '0;
                            order_d.id = active_tag_q; order_d.issuer = active_cmd_q.issuer; order_d.seq = active_cmd_q.seq;
                            order_d.kind = BW_ORDER_RELEASE;
                            order_d.scope = active_completion_q == TMA_CPL_MBAR ? BW_SCOPE_CLUSTER : active_cmd_q.scope;
                            order_d.from_proxy = BW_PROXY_ASYNC; order_d.to_proxy = BW_PROXY_GENERIC;
                            order_d.addr = active_tensor ? 64'd0 : active_completion_q == TMA_CPL_MBAR ? {32'd0,active_smem_base_q[31:0]} : active_linear_addr_q;
                            order_d.bytes = active_tensor ? 64'd0 : active_total_bytes_q;
                            state_d = ST_ORDER_REQ;
                        end else begin
                            rsp_vld_d = 1'b1;
                            rsp_tag_d = active_tag_q;
                            rsp_status_d = active_status_after_rsp;
                            rsp_bytes_d = active_prefetch ? 64'd0 : active_total_bytes_q;
                            state_d = ST_RESP;
                        end
                    end
                end

                ST_ORDER_REQ: if (tma_order_req_rdy_i) state_d = ST_ORDER_RSP;
                ST_ORDER_RSP: if (tma_order_rsp_vld_i) begin
                    if (tma_order_rsp_i.id != active_tag_q) order_fault_d = 1'b1;
                    else if (order_fault_q || tma_order_rsp_i.status != 0 || active_status_after_rsp != TMA_STATUS_OK) begin
                        rsp_vld_d = 1'b1; rsp_tag_d = active_tag_q; rsp_status_d = TMA_STATUS_ORDER;
                        rsp_bytes_d = active_total_bytes_q; state_d = ST_RESP;
                    end else if (active_completion_q == TMA_CPL_MBAR) begin
                        tx_cpl_vld_d = 1'b1; state_d = ST_TX_REQ;
                    end else begin
                        rsp_vld_d = 1'b1; rsp_tag_d = active_tag_q; rsp_status_d = TMA_STATUS_OK;
                        rsp_bytes_d = active_total_bytes_q; state_d = ST_RESP;
                    end
                end
                ST_TX_REQ: begin
                    if (tx_cpl_fire) begin
                        tx_cpl_vld_d = 1'b0;
                        state_d = ST_TX_RSP;
                    end
                end

                ST_TX_RSP: begin
                    if (tx_rsp_fire) begin
                        if (tx_rsp_tag_i != active_tag_q) tx_fault_d = 1'b1;
                        else begin
                            rsp_vld_d = 1'b1; rsp_tag_d = active_tag_q;
                            rsp_status_d = tx_fault_q || tx_rsp_status_i != MBAR_STATUS_OK ?
                                TMA_STATUS_MBARRIER : active_status_after_rsp;
                            rsp_bytes_d = active_total_bytes_q; state_d = ST_RESP;
                        end
                    end
                end

                default: begin
                end
            endcase

            if (gen_allocate) begin
                m_gmem_addr_d[free_mshr_idx] =
                    active_shared ? {gen_gaddr[ADDR_W-1:5],5'd0} : {gen_gaddr[ADDR_W-1:7], 7'd0};
                m_gmem_off_d[free_mshr_idx] = active_shared ? {2'd0,gen_gaddr[4:0]} : gen_gaddr[6:0];
                m_smem_addr_d[free_mshr_idx] =
                    {gen_saddr[SMEM_ADDR_W-1:5], 5'd0};
                m_smem_off_d[free_mshr_idx] = gen_saddr[4:0];
                m_len_d[free_mshr_idx] = gen_segment_bytes;
                m_packed_shift_d[free_mshr_idx] = map_packed_shift;
                m_mask_d[free_mshr_idx] = make_mask128(gen_segment_bytes,
                    active_shared ? {2'd0,gen_gaddr[4:0]} : gen_gaddr[6:0]) &
                    (active_cmd_q.cp_mask_enable ? {8{active_cmd_q.cp_mask}} : {128{1'b1}});
                if (gen_is_load) m_mask_d[free_mshr_idx] = gen_read_mask;
                if (gen_is_load) begin
                    if (gen_in_bounds) begin
                        m_state_d[free_mshr_idx] = M_LD_GREQ;
                    end else begin
                        m_state_d[free_mshr_idx] = M_LD_SREQ;
                        m_data_d[free_mshr_idx] = desc_data_q[870] && active_opcode_q == TMA_OP_LOAD_TENSOR ? {64{16'h7ff7}} : 1024'd0;
                    end
                end else begin
                    m_state_d[free_mshr_idx] = M_ST_SREQ;
                end
            end

            // Register outgoing requests so every payload remains stable under
            // external backpressure.
            if (g_req_fire) begin
                g_req_vld_d = 1'b0;
                if (g_req_id_q == GMEM_ID_W'(MSHR_ENTRIES)) begin
                    desc_fetch_pending_d = 1'b0;
                    desc_fetch_issued_d = 1'b1;
                end else if (g_req_write_q) begin
                    m_state_d[g_req_id_q[MSHR_IDX_W-1:0]] = M_ST_GRSP;
                end else begin
                    m_state_d[g_req_id_q[MSHR_IDX_W-1:0]] = M_LD_GRSP;
                end
            end
            if (!g_req_vld_q && active_status_after_rsp == TMA_STATUS_OK) begin
                if (desc_fetch_pending_q) begin
                    g_req_vld_d = 1'b1;
                    g_attr_d = mem_attr(1'b0,1'b1);
                    g_req_write_d = 1'b0;
                    g_req_addr_d = {active_desc_ptr_q[63:7],7'd0} + (desc_second_q ? 64'd128 : 64'd0);
                    g_req_data_d = 1024'd0;
                    g_req_mask_d = active_desc_ptr_q[6] ? (desc_second_q ? {64'd0,{64{1'b1}}} : {{64{1'b1}},64'd0}) : {128{1'b1}};
                    g_req_id_d = GMEM_ID_W'(MSHR_ENTRIES);
                end else if (g_send_found) begin
                    g_req_vld_d = 1'b1;
                    g_req_write_d = (m_state_q[g_send_idx] == M_ST_GREQ);
                    g_attr_d = mem_attr(m_state_q[g_send_idx] == M_ST_GREQ,1'b0);
                    g_req_addr_d = m_gmem_addr_q[g_send_idx];
                    g_req_data_d = m_data_q[g_send_idx];
                    g_req_mask_d = m_mask_q[g_send_idx];
                    g_req_id_d = GMEM_ID_W'(g_send_idx);
                end
            end

            if (s_req_fire) begin
                s_req_vld_d = 1'b0;
                if (s_req_write_q && active_shared) begin
                    m_state_d[s_req_id_q[MSHR_IDX_W-1:0]] = M_ST_GRSP;
                end else if (s_req_write_q) begin
                    m_state_d[s_req_id_q[MSHR_IDX_W-1:0]] = M_LD_SRSP;
                end else begin
                    m_state_d[s_req_id_q[MSHR_IDX_W-1:0]] = M_ST_SRSP;
                end
            end
            if (!s_req_vld_q && s_send_found && active_status_after_rsp == TMA_STATUS_OK) begin
                s_req_vld_d = 1'b1;
                s_req_write_d = (m_state_q[s_send_idx] == M_LD_SREQ) || (active_shared && m_state_q[s_send_idx] == M_ST_GREQ);
                s_attr_d = mem_attr((m_state_q[s_send_idx] == M_LD_SREQ) || (active_shared && m_state_q[s_send_idx] == M_ST_GREQ),1'b0);
                s_req_addr_d = m_smem_addr_q[s_send_idx];
                s_req_data_d = m_data_q[s_send_idx][255:0] <<
                                (m_smem_off_q[s_send_idx] * 8);
                s_req_mask_d = (m_state_q[s_send_idx] == M_LD_SREQ) ?
                    make_mask32(m_len_q[s_send_idx], m_smem_off_q[s_send_idx]) :
                    make_mask32(active_dtype_q == TMA_TYPE_B6X16 ? 6'd2 : m_len_q[s_send_idx], m_smem_off_q[s_send_idx]);
                if (active_shared && m_state_q[s_send_idx] == M_ST_GREQ) begin
                    s_req_addr_d = m_gmem_addr_q[s_send_idx][SMEM_ADDR_W-1:0];
                    s_req_data_d = m_data_q[s_send_idx][255:0];
                    s_req_mask_d = m_mask_q[s_send_idx][31:0];
                end
                s_req_id_d = SMEM_ID_W'(s_send_idx);
            end

            if (g_rsp_fire && desc_rsp_expected) begin
                desc_fetch_issued_d = 1'b0;
                if (active_status_after_rsp != TMA_STATUS_OK) begin
                    rsp_vld_d = 1'b1; rsp_tag_d = active_tag_q;
                    rsp_status_d = active_status_after_rsp; rsp_bytes_d = 0; state_d = ST_RESP;
                end else if (active_desc_ptr_q[6] && !desc_second_q) begin
                    desc_first_d = gmem_rsp_data_i[1023:512];
                    desc_second_d = 1'b1; desc_fetch_pending_d = 1'b1;
                end else begin
                    desc_data_d = active_desc_ptr_q[6] ? {gmem_rsp_data_i[511:0],desc_first_q} : gmem_rsp_data_i;
                    desc_cache_vld_d[desc_replace_q] = 1'b1;
                    desc_cache_addr_d[desc_replace_q] = active_desc_ptr_q;
                    desc_cache_data_d[desc_replace_q] = active_desc_ptr_q[6] ? {gmem_rsp_data_i[511:0],desc_first_q} : gmem_rsp_data_i;
                    desc_replace_d = desc_replace_q == DESC_IDX_W'(DESC_CACHE_ENTRIES-1) ? '0 : desc_replace_q+DESC_IDX_W'(1);
                    state_d = ST_SETUP;
                end
            end
            if (g_rsp_fire && g_rsp_expected) begin
                if (m_state_q[g_rsp_mshr_idx] == M_LD_GRSP && !active_prefetch && active_status_after_rsp == TMA_STATUS_OK) begin
                    m_data_d[g_rsp_mshr_idx] = tensor_convert(gmem_rsp_data_i >>
                        (m_gmem_off_q[g_rsp_mshr_idx]*8),active_dtype_q,1'b0,3'd0);
                    m_state_d[g_rsp_mshr_idx] = M_LD_SREQ;
                end else m_state_d[g_rsp_mshr_idx] = M_FREE;
            end
            if (s_rsp_fire && s_rsp_expected) begin
                if (m_state_q[s_rsp_mshr_idx] == M_ST_SRSP && active_status_after_rsp == TMA_STATUS_OK) begin
                    m_data_d[s_rsp_mshr_idx] = tensor_convert({768'd0,smem_rsp_data_i} >>
                        (m_smem_off_q[s_rsp_mshr_idx]*8),active_dtype_q,1'b1,
                        m_packed_shift_q[s_rsp_mshr_idx]) << (m_gmem_off_q[s_rsp_mshr_idx]*8);
                    m_state_d[s_rsp_mshr_idx] = M_ST_GREQ;
                end else m_state_d[s_rsp_mshr_idx] = M_FREE;
            end
            if (active_status_after_rsp != TMA_STATUS_OK && state_q != ST_IDLE && state_q != ST_RESP) begin
                active_status_d = active_status_after_rsp;
                if ((state_q == ST_DESC_LOOKUP || state_q == ST_DESC_WAIT || state_q == ST_SETUP) &&
                    !desc_fetch_issued_q && !g_req_vld_q) begin
                    desc_fetch_pending_d = 1'b0;
                    rsp_vld_d = 1'b1; rsp_tag_d = active_tag_q;
                    rsp_status_d = active_status_after_rsp; rsp_bytes_d = 0; state_d = ST_RESP;
                end
                // Cancel segments which have not entered an external vld/rdy
                // channel. Held requests must still handshake and retire.
                for (entry=0;entry<MSHR_ENTRIES;entry++) begin
                    if ((m_state_q[entry] == M_LD_GREQ || m_state_q[entry] == M_ST_GREQ ||
                         m_state_q[entry] == M_LD_SREQ || m_state_q[entry] == M_ST_SREQ) &&
                        !(g_req_vld_q && g_req_id_q == GMEM_ID_W'(entry)) &&
                        !(s_req_vld_q && s_req_id_q == SMEM_ID_W'(entry)))
                        m_state_d[entry] = M_FREE;
                end
            end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cmd_rd_ptr_q <= {CMD_PTR_W{1'b0}};
            cmd_wr_ptr_q <= {CMD_PTR_W{1'b0}};
            cmd_count_q <= {CMD_CNT_W{1'b0}};
            active_cmd_q <= '0; g_attr_q <= '0; s_attr_q <= '0; order_q <= '0;
            active_mode_q <= 3'd0;
            active_im2col_q <= 80'd0;
            active_completion_q <= TMA_CPL_MBAR;
            source_reported_q <= 1'b0;
            state_q <= ST_IDLE;
            active_opcode_q <= TMA_OP_LOAD_TENSOR;
            active_tag_q <= 16'd0;
            active_desc_ptr_q <= {ADDR_W{1'b0}};
            active_smem_base_q <= {SMEM_ADDR_W{1'b0}};
            active_linear_addr_q <= {ADDR_W{1'b0}};
            active_linear_bytes_q <= 32'd0;
            active_barrier_addr_q <= '0;
            active_status_q <= TMA_STATUS_OK;
            active_total_bytes_q <= 64'd0;
            logical_offset_q <= 64'd0;

            generation_done_q <= 1'b0;
            desc_data_q <= 1024'd0; desc_second_q <= 1'b0; desc_first_q <= '0;
            desc_replace_q <= {DESC_IDX_W{1'b0}};
            desc_fetch_pending_q <= 1'b0;
            desc_fetch_issued_q <= 1'b0;
            desc_elem_bytes_q <= 4'd1;
            active_dtype_q <= TMA_TYPE_U8;
            g_req_vld_q <= 1'b0;
            g_req_write_q <= 1'b0;
            g_req_addr_q <= {ADDR_W{1'b0}};
            g_req_data_q <= 1024'd0;
            g_req_mask_q <= 128'd0;
            g_req_id_q <= {GMEM_ID_W{1'b0}};
            s_req_vld_q <= 1'b0;
            s_req_write_q <= 1'b0;
            s_req_addr_q <= {SMEM_ADDR_W{1'b0}};
            s_req_data_q <= 256'd0;
            s_req_mask_q <= 32'd0;
            s_req_id_q <= {SMEM_ID_W{1'b0}};
            rsp_vld_q <= 1'b0;
            rsp_tag_q <= 16'd0;
            rsp_status_q <= TMA_STATUS_OK;
            rsp_bytes_q <= 64'd0;
            tx_cpl_vld_q <= 1'b0;
            order_fault_q <= 1'b0; tx_fault_q <= 1'b0;
            for (int unsigned reset_dim = 0; reset_dim < 5;
                 reset_dim = reset_dim + 1) begin
                active_coord_q[reset_dim] <= 32'sd0;
            end
            for (int unsigned reset_cache = 0;
                 reset_cache < DESC_CACHE_ENTRIES;
                 reset_cache = reset_cache + 1) begin
                desc_cache_vld_q[reset_cache] <= 1'b0;
                desc_cache_addr_q[reset_cache] <= {ADDR_W{1'b0}};
                desc_cache_data_q[reset_cache] <= 1024'd0;
            end
            for (int unsigned reset_mshr = 0; reset_mshr < MSHR_ENTRIES;
                 reset_mshr = reset_mshr + 1) begin
                m_state_q[reset_mshr] <= M_FREE;
                m_gmem_addr_q[reset_mshr] <= {ADDR_W{1'b0}};
                m_gmem_off_q[reset_mshr] <= 7'd0;
                m_smem_addr_q[reset_mshr] <= {SMEM_ADDR_W{1'b0}};
                m_smem_off_q[reset_mshr] <= 5'd0;
                m_len_q[reset_mshr] <= 6'd0;
                m_packed_shift_q[reset_mshr] <= 3'd0;
                m_data_q[reset_mshr] <= 1024'd0;
                m_mask_q[reset_mshr] <= 128'd0;
            end
        end else begin
            foreach (cmd_full_q[idx]) cmd_full_q[idx] <= cmd_full_d[idx];
            active_cmd_q <= active_cmd_d;
            g_attr_q <= g_attr_d;
            s_attr_q <= s_attr_d;
            order_q <= order_d;
            cmd_rd_ptr_q <= cmd_rd_ptr_d;
            cmd_wr_ptr_q <= cmd_wr_ptr_d;
            cmd_count_q <= cmd_count_d;
            active_mode_q <= active_mode_d;
            active_im2col_q <= active_im2col_d;
            active_completion_q <= active_completion_d;
            source_reported_q <= source_reported_d;
            foreach (m_packed_shift_q[idx]) m_packed_shift_q[idx] <= m_packed_shift_d[idx];
            active_dtype_q <= active_dtype_d;
            state_q <= state_d;
            active_opcode_q <= active_opcode_d;
            active_tag_q <= active_tag_d;
            active_desc_ptr_q <= active_desc_ptr_d;
            foreach (active_coord_q[idx]) active_coord_q[idx] <= active_coord_d[idx];
            active_smem_base_q <= active_smem_base_d;
            active_linear_addr_q <= active_linear_addr_d;
            active_linear_bytes_q <= active_linear_bytes_d;
            active_barrier_addr_q <= active_barrier_addr_d;
            active_status_q <= active_status_d;
            active_total_bytes_q <= active_total_bytes_d;
            logical_offset_q <= logical_offset_d;
            order_fault_q <= order_fault_d;
            tx_fault_q <= tx_fault_d;
            generation_done_q <= generation_done_d;
            desc_data_q <= desc_data_d;
            desc_second_q <= desc_second_d;
            desc_first_q <= desc_first_d;
            foreach (desc_cache_vld_q[idx]) desc_cache_vld_q[idx] <= desc_cache_vld_d[idx];
            foreach (desc_cache_addr_q[idx]) desc_cache_addr_q[idx] <= desc_cache_addr_d[idx];
            foreach (desc_cache_data_q[idx]) desc_cache_data_q[idx] <= desc_cache_data_d[idx];
            desc_replace_q <= desc_replace_d;
            desc_fetch_pending_q <= desc_fetch_pending_d;
            desc_fetch_issued_q <= desc_fetch_issued_d;
            desc_elem_bytes_q <= desc_elem_bytes_d;
            foreach (m_state_q[idx]) m_state_q[idx] <= m_state_d[idx];
            foreach (m_gmem_addr_q[idx]) m_gmem_addr_q[idx] <= m_gmem_addr_d[idx];
            foreach (m_gmem_off_q[idx]) m_gmem_off_q[idx] <= m_gmem_off_d[idx];
            foreach (m_smem_addr_q[idx]) m_smem_addr_q[idx] <= m_smem_addr_d[idx];
            foreach (m_smem_off_q[idx]) m_smem_off_q[idx] <= m_smem_off_d[idx];
            foreach (m_len_q[idx]) m_len_q[idx] <= m_len_d[idx];
            foreach (m_data_q[idx]) m_data_q[idx] <= m_data_d[idx];
            foreach (m_mask_q[idx]) m_mask_q[idx] <= m_mask_d[idx];
            g_req_vld_q <= g_req_vld_d;
            g_req_write_q <= g_req_write_d;
            g_req_addr_q <= g_req_addr_d;
            g_req_data_q <= g_req_data_d;
            g_req_mask_q <= g_req_mask_d;
            g_req_id_q <= g_req_id_d;
            s_req_vld_q <= s_req_vld_d;
            s_req_write_q <= s_req_write_d;
            s_req_addr_q <= s_req_addr_d;
            s_req_data_q <= s_req_data_d;
            s_req_mask_q <= s_req_mask_d;
            s_req_id_q <= s_req_id_d;
            rsp_vld_q <= rsp_vld_d;
            rsp_tag_q <= rsp_tag_d;
            rsp_status_q <= rsp_status_d;
            rsp_bytes_q <= rsp_bytes_d;
            tx_cpl_vld_q <= tx_cpl_vld_d;
        end
    end

    initial begin
        if (ADDR_W != 64) $error("The v3 descriptor layout requires ADDR_W=64");
        if (SMEM_ADDR_W < 32) $error("SMEM_ADDR_W must be at least 32");
        if (CMD_QUEUE_DEPTH < 2) $error("CMD_QUEUE_DEPTH must be at least two");
        if (DESC_CACHE_ENTRIES < 1) $error("DESC_CACHE_ENTRIES must be positive");
        if (MSHR_ENTRIES < 2) $error("MSHR_ENTRIES must be at least two");
        if ((1 << GMEM_ID_W) <= MSHR_ENTRIES)
            $error("GMEM_ID_W must include a reserved descriptor-fetch ID");
        if ((1 << SMEM_ID_W) < MSHR_ENTRIES)
            $error("SMEM_ID_W is too small for MSHR_ENTRIES");
    end

`ifndef SYNTHESIS
    logic                         assert_g_stalled_q;
    logic                         assert_g_write_q;
    logic [ADDR_W-1:0]            assert_g_addr_q;
    logic [1023:0]                assert_g_data_q;
    logic [127:0]                 assert_g_mask_q;
    logic [GMEM_ID_W-1:0]         assert_g_id_q;
    logic                         assert_s_stalled_q;
    logic                         assert_s_write_q;
    logic [SMEM_ADDR_W-1:0]       assert_s_addr_q;
    logic [255:0]                 assert_s_data_q;
    logic [31:0]                  assert_s_mask_q;
    logic [SMEM_ID_W-1:0]         assert_s_id_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            assert_g_stalled_q <= 1'b0;
            assert_s_stalled_q <= 1'b0;
        end else begin
            if (assert_g_stalled_q) begin
                assert (gmem_req_vld_o &&
                        (gmem_req_write_o == assert_g_write_q) &&
                        (gmem_req_addr_o == assert_g_addr_q) &&
                        (gmem_req_data_o == assert_g_data_q) &&
                        (gmem_req_byte_mask_o == assert_g_mask_q) &&
                        (gmem_req_id_o == assert_g_id_q))
                    else $error("GMEM request changed while stalled");
            end
            if (assert_s_stalled_q) begin
                assert (smem_req_vld_o &&
                        (smem_req_write_o == assert_s_write_q) &&
                        (smem_req_addr_o == assert_s_addr_q) &&
                        (smem_req_data_o == assert_s_data_q) &&
                        (smem_req_byte_mask_o == assert_s_mask_q) &&
                        (smem_req_id_o == assert_s_id_q))
                    else $error("SMEM request changed while stalled");
            end
            if (tx_cpl_vld_o) begin
                assert (generation_done_q && mshrs_empty)
                    else $error("TX_COMPLETE preceded data acknowledgements");
            end

            assert_g_stalled_q <= gmem_req_vld_o && !gmem_req_rdy_i;
            assert_g_write_q <= gmem_req_write_o;
            assert_g_addr_q <= gmem_req_addr_o;
            assert_g_data_q <= gmem_req_data_o;
            assert_g_mask_q <= gmem_req_byte_mask_o;
            assert_g_id_q <= gmem_req_id_o;
            assert_s_stalled_q <= smem_req_vld_o && !smem_req_rdy_i;
            assert_s_write_q <= smem_req_write_o;
            assert_s_addr_q <= smem_req_addr_o;
            assert_s_data_q <= smem_req_data_o;
            assert_s_mask_q <= smem_req_byte_mask_o;
            assert_s_id_q <= smem_req_id_o;
        end
    end
`endif

endmodule

`default_nettype wire
