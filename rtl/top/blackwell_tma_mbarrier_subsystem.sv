// Implements frozen A1: doc/specs/blackwell_tma_mbarrier_subsystem.md
module blackwell_tma_mbarrier_subsystem
  import blackwell_async_pkg::*;
#(
parameter int unsigned BAR_ASYNC_ENTRIES = 16,
    parameter int unsigned ADDR_W             = GMEM_ADDR_W,
    parameter int unsigned SMEM_ADDR_W        = SMEM_BYTE_ADDR_W,
    parameter int unsigned CMD_QUEUE_DEPTH    = 8,
    parameter int unsigned DESC_CACHE_ENTRIES = 4,
    parameter int unsigned MSHR_ENTRIES       = TMA_MSHR_ENTRIES,
    parameter int unsigned BAR_CACHE_ENTRIES  = 4,
    parameter int unsigned WAIT_ENTRIES       = 32,
    parameter int unsigned WRITE_BUF_DEPTH    = 8,
    parameter int unsigned GMEM_ID_W          = GMEM_ID_DEFAULT_W,
    parameter int unsigned SMEM_ID_W          = SUBSYSTEM_SMEM_ID_DEFAULT_W,
    parameter int unsigned BAR_CLOCK_PERIOD_NS = 10,
    parameter int unsigned BAR_WAIT_DEFAULT_CYCLES = 64
) (
  input logic clk,
  input logic rst_n,
  input logic tma_cmd_vld_i,
  input tma_mbarrier_pkg::tma_cmd_t tma_cmd_i,
  input logic tma_rsp_rdy_i,
  input logic gmem_req_rdy_i,
  input logic smem_req_rdy_i,
  input logic tma_order_req_rdy_i,
  input logic tma_order_rsp_vld_i,
  input tma_mbarrier_pkg::bw_order_rsp_t tma_order_rsp_i,
  input logic tc_arrive_vld_i,
  input tma_mbarrier_pkg::bar_cmd_t tc_arrive_i,
  input logic tc_arrive_rsp_rdy_i,
  input logic bar_cmd_vld_i,
  input tma_mbarrier_pkg::bar_cmd_t bar_cmd_i,
  input logic bar_rsp_rdy_i,
  input logic async_cpl_req_vld_i,
  input tma_mbarrier_pkg::bw_async_req_t async_cpl_req_i,
  input logic async_req_vld_i,
  input tma_mbarrier_pkg::bw_async_req_t async_req_i,
  input logic async_rsp_rdy_i,
  input logic report_req_vld_i,
  input tma_mbarrier_pkg::bar_report_req_t report_req_i,
  input logic report_rsp_rdy_i,
  input logic bar_order_req_rdy_i,
  input logic bar_order_rsp_vld_i,
  input tma_mbarrier_pkg::bw_order_rsp_t bar_order_rsp_i,
  input logic gmem_rsp_vld_i,
  input logic [GMEM_DATA_W-1:0] gmem_rsp_data_i,
  input logic [MEM_STATUS_W-1:0] gmem_rsp_status_i,
  input logic [GMEM_ID_W-1:0] gmem_rsp_id_i,
  input logic smem_rsp_vld_i,
  input logic [SMEM_DATA_W-1:0] smem_rsp_data_i,
  input logic [MEM_STATUS_W-1:0] smem_rsp_status_i,
  input logic [SMEM_ID_W-1:0] smem_rsp_id_i,
  input logic stop_i,
  output logic tma_cmd_rdy_o,
  output logic tma_rsp_vld_o,
  output tma_mbarrier_pkg::tma_rsp_t tma_rsp_o,
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
  output logic tc_arrive_rdy_o,
  output logic tc_arrive_rsp_vld_o,
  output tma_mbarrier_pkg::bar_rsp_t tc_arrive_rsp_o,
  output logic bar_cmd_rdy_o,
  output logic bar_rsp_vld_o,
  output tma_mbarrier_pkg::bar_rsp_t bar_rsp_o,
  output logic async_cpl_req_rdy_o,
  output logic async_req_rdy_o,
  output logic async_rsp_vld_o,
  output tma_mbarrier_pkg::bw_async_rsp_t async_rsp_o,
  output logic report_req_rdy_o,
  output logic report_rsp_vld_o,
  output tma_mbarrier_pkg::bar_rsp_t report_rsp_o,
  output logic bar_order_req_vld_o,
  output tma_mbarrier_pkg::bw_order_req_t bar_order_req_o,
  output logic bar_order_rsp_rdy_o,
  output logic gmem_rsp_rdy_o,
  output logic smem_rsp_rdy_o,
  output logic idle_o,
  output logic drained_o
);


    localparam int unsigned TMA_SMEM_ID_W = (MSHR_ENTRIES <= 1) ? 1 : $clog2(MSHR_ENTRIES);
    localparam int unsigned BAR_MEM_ID_W = BARRIER_MEM_ID_DEFAULT_W;

    wire                         tma_smem_req_vld;
    wire                         tma_smem_req_rdy;
    wire                         tma_smem_req_write;
    wire [SMEM_ADDR_W-1:0]       tma_smem_req_addr;
    wire [255:0]                 tma_smem_req_data;
    wire [31:0]                  tma_smem_req_mask;
    wire [TMA_SMEM_ID_W-1:0]     tma_smem_req_id;
    wire                         tma_smem_rsp_vld;
    wire                         tma_smem_rsp_rdy;
    wire [TMA_SMEM_ID_W-1:0]     tma_smem_rsp_id;

    wire                         bar_mem_req_vld;
    wire                         bar_mem_req_rdy;
    wire                         bar_mem_req_write;
    wire [SMEM_ADDR_W-1:0]       bar_mem_req_addr;
    wire [255:0]                 bar_mem_req_data;
    wire [31:0]                  bar_mem_req_mask;
    wire [BAR_MEM_ID_W-1:0]      bar_mem_req_id;
    wire                         bar_mem_rsp_vld;
    wire                         bar_mem_rsp_rdy;
    wire [BAR_MEM_ID_W-1:0]      bar_mem_rsp_id;

    wire                         tx_cpl_vld;
    wire                         tx_cpl_rdy;
    wire [15:0]                  tx_cpl_tag;
    wire [SMEM_ADDR_W-1:0]       tx_cpl_addr;
    wire [BARRIER_TX_BYTES_W-1:0] tx_cpl_bytes;
    wire                         tx_rsp_vld;
    wire                         tx_rsp_rdy;
    wire [15:0]                  tx_rsp_tag;
    wire [7:0]                   tx_rsp_status;
    wire                         tx_rsp_phase;

    tma_mbarrier_pkg::bw_mem_attr_t tma_smem_req_attr, bar_mem_attr;
    always_comb begin
        bar_mem_attr = '0;
        bar_mem_attr.kind = bar_mem_req_write ? tma_mbarrier_pkg::BW_MEM_WRITE : tma_mbarrier_pkg::BW_MEM_READ;
        bar_mem_attr.dtype = tma_mbarrier_pkg::TMA_TYPE_U64;
        bar_mem_attr.proxy = tma_mbarrier_pkg::BW_PROXY_GENERIC;
    end
    assign smem_req_attr_o = smem_grant_bar ? bar_mem_attr : tma_smem_req_attr;
    logic smem_hold_q, smem_hold_bar_q;
    logic                        smem_grant_bar;
    logic                        smem_bar_turn_q;
    wire                         smem_req_fire;
    wire                         bar_mem_addr_upper_nonzero;

    assign smem_grant_bar = smem_hold_q ? smem_hold_bar_q :
        (bar_mem_req_vld && (!tma_smem_req_vld || smem_bar_turn_q));
    assign smem_req_vld_o = smem_grant_bar ? bar_mem_req_vld : tma_smem_req_vld;
    assign smem_req_write_o = smem_grant_bar ? bar_mem_req_write : tma_smem_req_write;
    assign smem_req_addr_o = smem_grant_bar ?
        bar_mem_req_addr[SMEM_ADDR_W-1:0] : tma_smem_req_addr;
    assign smem_req_data_o = smem_grant_bar ? bar_mem_req_data : tma_smem_req_data;
    assign smem_req_byte_mask_o = smem_grant_bar ? bar_mem_req_mask : tma_smem_req_mask;
    assign smem_req_id_o = smem_grant_bar ?
        {1'b1, {(SMEM_ID_W-BAR_MEM_ID_W-1){1'b0}}, bar_mem_req_id} :
        {1'b0, {(SMEM_ID_W-TMA_SMEM_ID_W-1){1'b0}}, tma_smem_req_id};
    assign bar_mem_req_rdy = smem_req_rdy_i && smem_grant_bar;
    assign tma_smem_req_rdy = smem_req_rdy_i && !smem_grant_bar;
    assign smem_req_fire = smem_req_vld_o && smem_req_rdy_i;
    assign bar_mem_addr_upper_nonzero = 1'b0;

    logic bad_smem_route;
    logic [1:0] route_fault_q, route_fault_d;
    logic [MEM_STATUS_W-1:0] routed_smem_status;
    assign bad_smem_route = smem_rsp_id_i[SMEM_ID_W-1] ?
        ((SMEM_ID_W'(smem_rsp_id_i[BAR_MEM_ID_W-1:0]) | (SMEM_ID_W'(1) << (SMEM_ID_W-1))) != smem_rsp_id_i) :
        SMEM_ID_W'(smem_rsp_id_i[TMA_SMEM_ID_W-1:0]) != smem_rsp_id_i;
    assign routed_smem_status = route_fault_q[smem_rsp_id_i[SMEM_ID_W-1]] ? 2'd3 : smem_rsp_status_i;
    always_comb begin
      route_fault_d = route_fault_q;
      if (smem_rsp_vld_i && smem_rsp_rdy_o && bad_smem_route) route_fault_d[smem_rsp_id_i[SMEM_ID_W-1]] = 1'b1;
      if (smem_rsp_vld_i && smem_rsp_rdy_o && !bad_smem_route) route_fault_d[smem_rsp_id_i[SMEM_ID_W-1]] = 1'b0;
    end
    always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) route_fault_q <= '0;
      else route_fault_q <= route_fault_d;
    end
    assign bar_mem_rsp_vld = smem_rsp_vld_i && !bad_smem_route && smem_rsp_id_i[SMEM_ID_W-1];
    assign tma_smem_rsp_vld = smem_rsp_vld_i && !bad_smem_route && !smem_rsp_id_i[SMEM_ID_W-1];
    assign bar_mem_rsp_id = smem_rsp_id_i[BAR_MEM_ID_W-1:0];
    assign tma_smem_rsp_id = smem_rsp_id_i[TMA_SMEM_ID_W-1:0];
    assign smem_rsp_rdy_o = bad_smem_route ? 1'b1 : smem_rsp_id_i[SMEM_ID_W-1] ?
                            bar_mem_rsp_rdy : tma_smem_rsp_rdy;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            smem_bar_turn_q <= 1'b0;
        end else if (smem_req_fire && bar_mem_req_vld && tma_smem_req_vld) begin
            smem_bar_turn_q <= ~smem_bar_turn_q;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin smem_hold_q <= 1'b0; smem_hold_bar_q <= 1'b0; end
        else begin
            if (smem_req_vld_o && !smem_req_rdy_i) begin
                smem_hold_q <= 1'b1; smem_hold_bar_q <= smem_grant_bar;
            end else if (smem_req_fire) smem_hold_q <= 1'b0;
        end
    end
    logic tma_idle, tma_drained, bar_idle, bar_drained;
    assign idle_o = tma_idle && bar_idle;
    assign drained_o = tma_drained && bar_drained && !smem_hold_q;
    blackwell_tma_engine #(
        .ADDR_W             (ADDR_W),
        .SMEM_ADDR_W        (SMEM_ADDR_W),
        .CMD_QUEUE_DEPTH    (CMD_QUEUE_DEPTH),
        .DESC_CACHE_ENTRIES (DESC_CACHE_ENTRIES),
        .MSHR_ENTRIES       (MSHR_ENTRIES),
        .GMEM_ID_W          (GMEM_ID_W),
        .SMEM_ID_W          (TMA_SMEM_ID_W)
    ) u_tma_engine (
        .stop_i(stop_i), .idle_o(tma_idle), .drained_o(tma_drained),
        .clk                    (clk),
        .rst_n                  (rst_n),
        .tma_cmd_i(tma_cmd_i),
        .gmem_req_attr_o(gmem_req_attr_o),
        .tma_order_req_vld_o(tma_order_req_vld_o),
        .tma_order_req_rdy_i(tma_order_req_rdy_i),
        .tma_order_req_o(tma_order_req_o),
        .tma_order_rsp_vld_i(tma_order_rsp_vld_i),
        .tma_order_rsp_rdy_o(tma_order_rsp_rdy_o),
        .tma_order_rsp_i(tma_order_rsp_i),
        .smem_req_attr_o(tma_smem_req_attr),

        .tma_cmd_vld_i          (tma_cmd_vld_i),
        .tma_cmd_rdy_o          (tma_cmd_rdy_o),

        .tma_rsp_o(tma_rsp_o),
        .tma_rsp_vld_o          (tma_rsp_vld_o),
        .tma_rsp_rdy_i          (tma_rsp_rdy_i),
        .gmem_req_vld_o         (gmem_req_vld_o),
        .gmem_req_rdy_i         (gmem_req_rdy_i),
        .gmem_req_write_o       (gmem_req_write_o),
        .gmem_req_addr_o        (gmem_req_addr_o),
        .gmem_req_data_o        (gmem_req_data_o),
        .gmem_req_byte_mask_o        (gmem_req_byte_mask_o),
        .gmem_req_id_o          (gmem_req_id_o),
        .gmem_rsp_vld_i         (gmem_rsp_vld_i),
        .gmem_rsp_rdy_o         (gmem_rsp_rdy_o),
        .gmem_rsp_data_i        (gmem_rsp_data_i),
        .gmem_rsp_status_i      (gmem_rsp_status_i),
        .gmem_rsp_id_i          (gmem_rsp_id_i),
        .smem_req_vld_o         (tma_smem_req_vld),
        .smem_req_rdy_i         (tma_smem_req_rdy),
        .smem_req_write_o       (tma_smem_req_write),
        .smem_req_addr_o        (tma_smem_req_addr),
        .smem_req_data_o        (tma_smem_req_data),
        .smem_req_byte_mask_o        (tma_smem_req_mask),
        .smem_req_id_o          (tma_smem_req_id),
        .smem_rsp_vld_i         (tma_smem_rsp_vld),
        .smem_rsp_rdy_o         (tma_smem_rsp_rdy),
        .smem_rsp_data_i        (smem_rsp_data_i),
        .smem_rsp_status_i      (routed_smem_status),
        .smem_rsp_id_i          (tma_smem_rsp_id),
        .tx_cpl_vld_o           (tx_cpl_vld),
        .tx_cpl_rdy_i           (tx_cpl_rdy),
        .tx_cpl_tag_o           (tx_cpl_tag),
        .tx_cpl_addr_o          (tx_cpl_addr),
        .tx_cpl_bytes_o         (tx_cpl_bytes),
        .tx_rsp_vld_i           (tx_rsp_vld),
        .tx_rsp_rdy_o           (tx_rsp_rdy),
        .tx_rsp_tag_i           (tx_rsp_tag),
        .tx_rsp_status_i        (tx_rsp_status),
        .tx_rsp_phase_i         (tx_rsp_phase)
    );

    blackwell_mbarrier_frontend #(
        .ASYNC_ENTRIES(BAR_ASYNC_ENTRIES),
        .ADDR_W          (SMEM_ADDR_W),
        .CACHE_ENTRIES   (BAR_CACHE_ENTRIES),
        .WAIT_ENTRIES    (WAIT_ENTRIES),
        .WRITE_BUF_DEPTH (WRITE_BUF_DEPTH),
        .MEM_ID_W        (BAR_MEM_ID_W),
        .CLOCK_PERIOD_NS (BAR_CLOCK_PERIOD_NS),
        .WAIT_DEFAULT_CYCLES (BAR_WAIT_DEFAULT_CYCLES)
    ) u_mbarrier_unit (
        .stop_i(stop_i), .idle_o(bar_idle), .drained_o(bar_drained),
        .clk                    (clk),
        .rst_n                  (rst_n),

        .async_cpl_req_vld_i(async_cpl_req_vld_i), .async_cpl_req_rdy_o(async_cpl_req_rdy_o),
        .async_cpl_req_i(async_cpl_req_i), .async_req_vld_i(async_req_vld_i),
        .async_req_rdy_o(async_req_rdy_o),
        .async_req_i(async_req_i),
        .async_rsp_vld_o(async_rsp_vld_o),
        .async_rsp_rdy_i(async_rsp_rdy_i),
        .async_rsp_o(async_rsp_o),
        .report_req_vld_i(report_req_vld_i),
        .report_req_rdy_o(report_req_rdy_o),
        .report_req_i(report_req_i),
        .report_rsp_vld_o(report_rsp_vld_o),
        .report_rsp_rdy_i(report_rsp_rdy_i),
        .report_rsp_o(report_rsp_o),
        .order_req_vld_o(bar_order_req_vld_o),
        .order_req_rdy_i(bar_order_req_rdy_i),
        .order_req_o(bar_order_req_o),
        .order_rsp_vld_i(bar_order_rsp_vld_i),
        .order_rsp_rdy_o(bar_order_rsp_rdy_o),
        .order_rsp_i(bar_order_rsp_i),
        .tc_arrive_vld_i(tc_arrive_vld_i), .tc_arrive_rdy_o(tc_arrive_rdy_o),
        .tc_arrive_i(tc_arrive_i), .tc_arrive_rsp_vld_o(tc_arrive_rsp_vld_o),
        .tc_arrive_rsp_rdy_i(tc_arrive_rsp_rdy_i), .tc_arrive_rsp_o(tc_arrive_rsp_o),
        .bar_cmd_i(bar_cmd_i), .bar_rsp_o(bar_rsp_o),
        .bar_cmd_vld_i          (bar_cmd_vld_i),
        .bar_cmd_rdy_o          (bar_cmd_rdy_o),

        .bar_rsp_vld_o          (bar_rsp_vld_o),
        .bar_rsp_rdy_i          (bar_rsp_rdy_i),

        .tx_cpl_vld_i           (tx_cpl_vld),
        .tx_cpl_rdy_o           (tx_cpl_rdy),
        .tx_cpl_tag_i           (tx_cpl_tag),
        .tx_cpl_addr_i          (tx_cpl_addr),
        .tx_cpl_bytes_i         (tx_cpl_bytes),
        .tx_rsp_vld_o           (tx_rsp_vld),
        .tx_rsp_rdy_i           (tx_rsp_rdy),
        .tx_rsp_tag_o           (tx_rsp_tag),
        .tx_rsp_status_o        (tx_rsp_status),
        .tx_rsp_phase_o         (tx_rsp_phase),
        .mem_req_vld_o          (bar_mem_req_vld),
        .mem_req_rdy_i          (bar_mem_req_rdy),
        .mem_req_write_o        (bar_mem_req_write),
        .mem_req_addr_o         (bar_mem_req_addr),
        .mem_req_data_o         (bar_mem_req_data),
        .mem_req_byte_mask_o         (bar_mem_req_mask),
        .mem_req_id_o           (bar_mem_req_id),
        .mem_rsp_vld_i          (bar_mem_rsp_vld),
        .mem_rsp_rdy_o          (bar_mem_rsp_rdy),
        .mem_rsp_data_i         (smem_rsp_data_i),
        .mem_rsp_status_i       (routed_smem_status),
        .mem_rsp_id_i           (bar_mem_rsp_id)
    );

    initial begin
        if (SMEM_ID_W <= TMA_SMEM_ID_W)
            $error("SMEM_ID_W must reserve one source bit");
        if (SMEM_ID_W <= BAR_MEM_ID_W)
            $error("SMEM_ID_W must reserve one source bit for mbarrier");
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && bar_mem_req_vld) begin
            assert (!bar_mem_addr_upper_nonzero)
                else $error("mbarrier backing address exceeds SMEM address width");
        end
    end
`endif

endmodule

`default_nettype wire
