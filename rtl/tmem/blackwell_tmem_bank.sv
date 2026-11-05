// Implements frozen A1: doc/specs/blackwell_tmem_bank.md
module blackwell_tmem_bank
  import blackwell_async_pkg::*;
#(
  parameter int unsigned CONTEXTS = 32,
  parameter int unsigned TAG_W = ASYNC_TAG_W
) (
  input logic clk,
  input logic rst_n,
  input logic ctx_vld_i,
  input logic [CTX_ID_W-1:0] ctx_id_i,
  input logic [EPOCH_W-1:0] ctx_epoch_i,
  input logic [TAG_W-1:0] ctx_tag_i,
  input logic ctx_create_i,
  input logic alloc_vld_i,
  input logic [CTX_ID_W-1:0] alloc_ctx_i,
  input logic [EPOCH_W-1:0] alloc_epoch_i,
  input logic [TAG_W-1:0] alloc_tag_i,
  input logic [TMEM_COLUMNS_COUNT_W-1:0] alloc_columns_i,
  input logic free_vld_i,
  input logic [CTX_ID_W-1:0] free_ctx_i,
  input logic [EPOCH_W-1:0] free_epoch_i,
  input logic [TAG_W-1:0] free_tag_i,
  input logic [TMEM_COLUMN_INDEX_W-1:0] free_base_i,
  input logic [TMEM_COLUMNS_COUNT_W-1:0] free_columns_i,
  input logic relinquish_vld_i,
  input logic [CTX_ID_W-1:0] relinquish_ctx_i,
  input logic [EPOCH_W-1:0] relinquish_epoch_i,
  input logic [TAG_W-1:0] relinquish_tag_i,
  input logic ctrl_rsp_rdy_i,
  input logic rd_vld_i,
  input logic [CTX_ID_W-1:0] rd_ctx_i,
  input logic [EPOCH_W-1:0] rd_epoch_i,
  input logic [TMEM_COLUMN_BUS_W-1:0] rd_column_i,
  input logic [TAG_W-1:0] rd_tag_i,
  input logic [TMEM_LANE_MASK_W-1:0] rd_lane_mask_i,
  input logic rd_rsp_rdy_i,
  input logic wr_vld_i,
  input logic [CTX_ID_W-1:0] wr_ctx_i,
  input logic [EPOCH_W-1:0] wr_epoch_i,
  input logic [TMEM_COLUMN_BUS_W-1:0] wr_column_i,
  input logic [TMEM_DATA_W-1:0] wr_data_i,
  input logic [TAG_W-1:0] wr_tag_i,
  input logic [TMEM_BYTE_MASK_W-1:0] wr_byte_mask_i,
  input logic wr_rsp_rdy_i,
  output logic ctx_rdy_o,
  output logic alloc_rdy_o,
  output logic free_rdy_o,
  output logic relinquish_rdy_o,
  output logic ctrl_rsp_vld_o,
  output logic [TAG_W-1:0] ctrl_rsp_tag_o,
  output logic [STATUS_W-1:0] ctrl_rsp_status_o,
  output logic [TMEM_COLUMN_INDEX_W-1:0] ctrl_rsp_base_o,
  output logic rd_rdy_o,
  output logic rd_rsp_vld_o,
  output logic [TMEM_DATA_W-1:0] rd_rsp_data_o,
  output logic [TAG_W-1:0] rd_rsp_tag_o,
  output logic [STATUS_W-1:0] rd_rsp_status_o,
  output logic wr_rdy_o,
  output logic wr_rsp_vld_o,
  output logic [TAG_W-1:0] wr_rsp_tag_o,
  output logic [STATUS_W-1:0] wr_rsp_status_o,
  output logic idle_o,
  output logic drained_o
);
    logic ctrl_rsp_vld_q;
    assign ctrl_rsp_vld_o = ctrl_rsp_vld_q;
    logic [TAG_W-1:0] ctrl_rsp_tag_q;
    assign ctrl_rsp_tag_o = ctrl_rsp_tag_q;
    logic [STATUS_W-1:0] ctrl_rsp_status_q;
    assign ctrl_rsp_status_o = ctrl_rsp_status_q;
    logic [TMEM_COLUMN_INDEX_W-1:0] ctrl_rsp_base_q;
    assign ctrl_rsp_base_o = ctrl_rsp_base_q;

    localparam logic [7:0] OK=0, BAD_CONTEXT=3, BAD_SIZE=7,
                            BAD_OWNER=6, BAD_ADDR=5, BAD_PERMIT=8,
                            BAD_BUSY=17;
    // Packed owner/control tables retain variable-index hardware muxes while
    // remaining accepted by the synthesis frontend used for this project.
    logic [CONTEXTS-1:0] ctx_live_q, permit_q;
    logic [CONTEXTS*16-1:0] ctx_epoch_q;
    logic [CONTEXTS*10-1:0] last_cols_q;
    logic [CONTEXTS*9-1:0] outstanding_q;
    logic [15:0] unit_live_q;
    logic [79:0] unit_ctx_q;
    logic [255:0] unit_epoch_q;
    logic [895:0] mem_rd_addr, mem_wr_addr;
    logic [127:0] mem_rd_mask;
    logic [2047:0] mem_wr_mask;
    wire mem_rd_rdy, mem_wr_rdy, mem_rd_rsp, mem_wr_rsp;
    wire [16383:0] mem_rd_data;
    wire [TAG_W-1:0] mem_rd_tag, mem_wr_tag;
    wire mem_rd_error, mem_wr_error;
    logic [7:0] rd_bad, wr_bad;
    logic [7:0] rd_bad_q, wr_bad_q;
    logic [4:0] rd_rsp_ctx_q, wr_rsp_ctx_q;
    logic rw_turn_q, same_word_conflict;
    logic [3:0] alloc_first;
    logic [4:0] alloc_units;
    logic alloc_found, alloc_valid, free_valid;
    logic [7:0] ctx_error, alloc_error, free_error, relinquish_error;
    logic ctx_has_units, free_has_all_units;
    wire rd_fire = rd_vld_i && rd_rdy_o;
    wire wr_fire = wr_vld_i && wr_rdy_o;
    wire rd_retire = rd_rsp_vld_o && rd_rsp_rdy_i;
    wire wr_retire = wr_rsp_vld_o && wr_rsp_rdy_i;
    wire ctrl_space = !ctrl_rsp_vld_q || ctrl_rsp_rdy_i;

    function automatic logic legal_size(input logic [9:0] n);
        return n == 10'd32 || n == 10'd64 || n == 10'd128 ||
               n == 10'd256 || n == 10'd512;
    endfunction
    function automatic logic context_ok(input logic [4:0] c,input logic [15:0] e);
        return int'(c) < CONTEXTS && ctx_live_q[c] && ctx_epoch_q[c*16+:16] == e;
    endfunction
    function automatic logic word_owned(input logic [4:0] c,input logic [15:0] e,
                                          input logic [15:0] column);
        return column <= 16'd508 && column[1:0] == 2'b00 &&
               unit_live_q[column[8:5]] && unit_ctx_q[column[8:5]*5+:5] == c &&
               unit_epoch_q[column[8:5]*16+:16] == e;
    endfunction

    always_comb begin
      int b;
      b = 0;
        rd_bad = context_ok(rd_ctx_i,rd_epoch_i) ? OK : BAD_CONTEXT;
        wr_bad = context_ok(wr_ctx_i,wr_epoch_i) ? OK : BAD_CONTEXT;
        same_word_conflict = 1'b0;
        mem_rd_addr = '0; mem_wr_addr = '0;
        for (b=0;b<128;b++) begin
            mem_rd_addr[b*7+:7] = rd_column_i[b*16+2+:7];
            mem_wr_addr[b*7+:7] = wr_column_i[b*16+2+:7];
            if (rd_bad == OK && rd_lane_mask_i[b] &&
                !word_owned(rd_ctx_i,rd_epoch_i,rd_column_i[b*16+:16]))
                rd_bad = rd_column_i[b*16+:16] > 16'd508 ||
                    (rd_column_i[b*16+:16] & 16'h0003) != 0 ? BAD_ADDR : BAD_OWNER;
            if (wr_bad == OK && (|wr_byte_mask_i[b*16+:16]) &&
                !word_owned(wr_ctx_i,wr_epoch_i,wr_column_i[b*16+:16]))
                wr_bad = wr_column_i[b*16+:16] > 16'd508 ||
                    (wr_column_i[b*16+:16] & 16'h0003) != 0 ? BAD_ADDR : BAD_OWNER;
            if (rd_lane_mask_i[b] && (|wr_byte_mask_i[b*16+:16]) &&
                rd_column_i[b*16+:16] == wr_column_i[b*16+:16]) same_word_conflict = 1'b1;
        end
        mem_rd_mask = rd_bad == OK ? rd_lane_mask_i : '0;
        mem_wr_mask = wr_bad == OK ? wr_byte_mask_i : '0;
        rd_rdy_o = mem_rd_rdy && (!same_word_conflict || !rw_turn_q || !wr_vld_i || !rd_vld_i);
        wr_rdy_o = mem_wr_rdy && (!same_word_conflict || rw_turn_q || !wr_vld_i || !rd_vld_i);
    end
    // Permission failure is an acknowledged transaction with all SRAM masks
    // clear. This preserves response ordering without exposing unowned data.
    blackwell_banked_sram #(.BANKS(128),.DEPTH(128),.DATA_W(128),.TAG_W(TAG_W)) storage (
        .clk,.rst_n,
        .rd_vld_i(rd_fire),.rd_rdy_o(mem_rd_rdy),.rd_mask_i(mem_rd_mask),
        .rd_addr_i(mem_rd_addr),.rd_tag_i(rd_tag_i),
        .rd_rsp_vld_o(mem_rd_rsp),.rd_rsp_rdy_i(rd_rsp_rdy_i),
        .rd_data_o(mem_rd_data),.rd_tag_o(mem_rd_tag),.rd_error_o(mem_rd_error),
        .wr_vld_i(wr_fire),.wr_rdy_o(mem_wr_rdy),.wr_addr_i(mem_wr_addr),
        .wr_data_i(wr_data_i),.wr_mask_i(mem_wr_mask),.wr_tag_i(wr_tag_i),
        .wr_rsp_vld_o(mem_wr_rsp),.wr_rsp_rdy_i(wr_rsp_rdy_i),
        .wr_tag_o(mem_wr_tag),.wr_error_o(mem_wr_error)
    );
    assign rd_rsp_vld_o = mem_rd_rsp;
    assign wr_rsp_vld_o = mem_wr_rsp;
    assign rd_rsp_data_o = mem_rd_data;
    assign rd_rsp_tag_o = mem_rd_tag;
    assign wr_rsp_tag_o = mem_wr_tag;
    assign rd_rsp_status_o = rd_bad_q != OK ? rd_bad_q : (mem_rd_error ? BAD_ADDR : OK);
    assign wr_rsp_status_o = wr_bad_q != OK ? wr_bad_q : (mem_wr_error ? BAD_ADDR : OK);

    always_comb begin
      int base;
      int u;
      base = 0;
      u = 0;
        alloc_found = 1'b0; alloc_first = '0;
        alloc_valid = legal_size(alloc_columns_i);
        case (alloc_columns_i)
            10'd32: alloc_units=5'd1;
            10'd64: alloc_units=5'd2;
            10'd128: alloc_units=5'd4;
            10'd256: alloc_units=5'd8;
            10'd512: alloc_units=5'd16;
            default: alloc_units=5'd0;
        endcase
        for (base=0;base<16;base++) begin
            logic fit;
            fit = alloc_valid && ((base & (int'(alloc_units)-1)) == 0) &&
                  base + int'(alloc_units) <= 16;
            for (u=0;u<16;u++)
                if (u >= base && u < base + int'(alloc_units) && unit_live_q[u]) fit = 1'b0;
            if (fit && !alloc_found) begin alloc_found=1'b1; alloc_first=4'(base); end
        end
        ctx_has_units=1'b0; free_has_all_units=1'b1;
        for (u=0;u<16;u++) begin
            if (unit_live_q[u] && unit_ctx_q[u*5+:5] == ctx_id_i && unit_epoch_q[u*16+:16] == ctx_epoch_i)
                ctx_has_units=1'b1;
            if (u >= int'(free_base_i)/32 && u < (int'(free_base_i)+int'(free_columns_i))/32 &&
                !(unit_live_q[u] && unit_ctx_q[u*5+:5] == free_ctx_i && unit_epoch_q[u*16+:16] == free_epoch_i))
                free_has_all_units=1'b0;
        end
        ctx_error = OK;
        if (int'(ctx_id_i) >= CONTEXTS) ctx_error=BAD_CONTEXT;
        else if (ctx_create_i ? ctx_live_q[ctx_id_i] : !context_ok(ctx_id_i,ctx_epoch_i)) ctx_error=BAD_CONTEXT;
        else if ((!ctx_create_i && ctx_has_units) || outstanding_q[ctx_id_i*9+:9] != 0 ||
                 (rd_fire && rd_ctx_i == ctx_id_i) ||
                 (wr_fire && wr_ctx_i == ctx_id_i)) ctx_error=BAD_BUSY;
        alloc_error=OK;
        if (!context_ok(alloc_ctx_i,alloc_epoch_i)) alloc_error=BAD_CONTEXT;
        else if (!permit_q[alloc_ctx_i]) alloc_error=BAD_PERMIT;
        else if (!alloc_valid || alloc_columns_i > last_cols_q[alloc_ctx_i*10+:10]) alloc_error=BAD_SIZE;
        free_valid=free_columns_i != 0 && free_columns_i[4:0] == 0 && free_base_i[4:0]==0 &&
                   (int'(free_base_i)+int'(free_columns_i) <= 512);
        free_error=OK;
        if (!context_ok(free_ctx_i,free_epoch_i)) free_error=BAD_CONTEXT;
        else if (!free_valid) free_error=BAD_ADDR;
        else if (!free_has_all_units) free_error=BAD_OWNER;
        relinquish_error=context_ok(relinquish_ctx_i,relinquish_epoch_i) ? OK : BAD_CONTEXT;
        ctx_rdy_o=1'b0; alloc_rdy_o=1'b0; free_rdy_o=1'b0; relinquish_rdy_o=1'b0;
        if (ctrl_space) begin
            if (free_vld_i && (free_error != OK ||
                (outstanding_q[free_ctx_i*9+:9] == 0 && !(rd_fire && rd_ctx_i == free_ctx_i) &&
                 !(wr_fire && wr_ctx_i == free_ctx_i)))) free_rdy_o=1'b1;
            else if (relinquish_vld_i && (relinquish_error != OK ||
                (outstanding_q[relinquish_ctx_i*9+:9] == 0 &&
                 !(rd_fire && rd_ctx_i == relinquish_ctx_i) &&
                 !(wr_fire && wr_ctx_i == relinquish_ctx_i)))) relinquish_rdy_o=1'b1;
            else if (ctx_vld_i) ctx_rdy_o=1'b1;
            else if (alloc_vld_i && (alloc_error != OK ||
                (alloc_found && outstanding_q[alloc_ctx_i*9+:9] == 0 &&
                 !(rd_fire && rd_ctx_i == alloc_ctx_i) &&
                 !(wr_fire && wr_ctx_i == alloc_ctx_i)))) alloc_rdy_o=1'b1;
        end
    end
    assign idle_o = outstanding_q == '0;
    assign drained_o = idle_o && !ctrl_rsp_vld_q && !mem_rd_rsp && !mem_wr_rsp;
    logic ctrl_rsp_vld_d ;
    logic [TAG_W-1:0] ctrl_rsp_tag_d ;
    logic [STATUS_W-1:0] ctrl_rsp_status_d ;
    logic [TMEM_COLUMN_INDEX_W-1:0] ctrl_rsp_base_d ;
    logic [CONTEXTS-1:0] ctx_live_d ;
    logic [CONTEXTS-1:0] permit_d ;
    logic [CONTEXTS*16-1:0] ctx_epoch_d ;
    logic [CONTEXTS*10-1:0] last_cols_d ;
    logic [CONTEXTS*9-1:0] outstanding_d ;
    logic [15:0] unit_live_d ;
    logic [79:0] unit_ctx_d ;
    logic [255:0] unit_epoch_d ;
    logic [7:0] rd_bad_d ;
    logic [7:0] wr_bad_d ;
    logic [4:0] rd_rsp_ctx_d ;
    logic [4:0] wr_rsp_ctx_d ;
    logic rw_turn_d ;

    always_comb begin
      int c;
      int u;
      c = 0;
      u = 0;
        ctrl_rsp_vld_d = ctrl_rsp_vld_q;
        ctrl_rsp_tag_d = ctrl_rsp_tag_q;
        ctrl_rsp_status_d = ctrl_rsp_status_q;
        ctrl_rsp_base_d = ctrl_rsp_base_q;
        ctx_live_d = ctx_live_q;
        permit_d = permit_q;
        ctx_epoch_d = ctx_epoch_q;
        last_cols_d = last_cols_q;
        outstanding_d = outstanding_q;
        unit_live_d = unit_live_q;
        unit_ctx_d = unit_ctx_q;
        unit_epoch_d = unit_epoch_q;
        rd_bad_d = rd_bad_q;
        wr_bad_d = wr_bad_q;
        rd_rsp_ctx_d = rd_rsp_ctx_q;
        wr_rsp_ctx_d = wr_rsp_ctx_q;
        rw_turn_d = rw_turn_q;
            if (same_word_conflict && rd_vld_i && wr_vld_i && (rd_fire || wr_fire)) rw_turn_d = ~rw_turn_q;
            if (rd_fire) begin rd_bad_d = rd_bad; rd_rsp_ctx_d = rd_ctx_i; end
            if (wr_fire) begin wr_bad_d = wr_bad; wr_rsp_ctx_d = wr_ctx_i; end
            for (c=0;c<CONTEXTS;c++) begin
                // A response remains outstanding until the consumer accepts it.
                outstanding_d[c*9+:9] = outstanding_q[c*9+:9] +
                    9'(rd_fire && rd_ctx_i == 5'(c)) + 9'(wr_fire && wr_ctx_i == 5'(c)) -
                    9'(rd_retire && rd_rsp_ctx_q == 5'(c)) -
                    9'(wr_retire && wr_rsp_ctx_q == 5'(c));
`ifndef SYNTHESIS
                assert (int'(outstanding_q[c*9+:9]) + int'(rd_fire && rd_ctx_i == 5'(c)) +
                    int'(wr_fire && wr_ctx_i == 5'(c)) >=
                    int'(rd_retire && rd_rsp_ctx_q == 5'(c)) +
                    int'(wr_retire && wr_rsp_ctx_q == 5'(c)))
                    else $error("TMEM outstanding underflow");
`endif
            end
            if (ctrl_space) begin
                ctrl_rsp_vld_d = free_rdy_o || relinquish_rdy_o || ctx_rdy_o || alloc_rdy_o;
                if (free_rdy_o) begin
                    ctrl_rsp_tag_d = free_tag_i; ctrl_rsp_status_d = free_error; ctrl_rsp_base_d = free_base_i;
                    if (free_error == OK)
                        for (u=0;u<16;u++)
                            if (u >= int'(free_base_i)/32 && u < (int'(free_base_i)+int'(free_columns_i))/32)
                                unit_live_d[u] = 1'b0;
                end else if (relinquish_rdy_o) begin
                    ctrl_rsp_tag_d = relinquish_tag_i; ctrl_rsp_status_d = relinquish_error; ctrl_rsp_base_d = '0;
                    if (relinquish_error == OK) permit_d[relinquish_ctx_i] = 1'b0;
                end else if (ctx_rdy_o) begin
                    ctrl_rsp_tag_d = ctx_tag_i; ctrl_rsp_status_d = ctx_error; ctrl_rsp_base_d = '0;
                    if (ctx_error == OK) begin
                        ctx_live_d[ctx_id_i] = ctx_create_i;
                        if (ctx_create_i) begin
                            ctx_epoch_d[ctx_id_i*16+:16] = ctx_epoch_i;
                            permit_d[ctx_id_i] = 1'b1; last_cols_d[ctx_id_i*10+:10] = 10'd512;
                        end
                    end
                end else if (alloc_rdy_o) begin
                    ctrl_rsp_tag_d = alloc_tag_i; ctrl_rsp_status_d = alloc_error;
                    ctrl_rsp_base_d = {alloc_first,5'b0};
                    if (alloc_error == OK) begin
                        last_cols_d[alloc_ctx_i*10+:10] = alloc_columns_i;
                        for (u=0;u<16;u++)
                            if (u >= int'(alloc_first) && u < int'(alloc_first)+int'(alloc_units)) begin
                                unit_live_d[u] = 1'b1;
                                unit_ctx_d[u*5+:5] = alloc_ctx_i; unit_epoch_d[u*16+:16] = alloc_epoch_i;
                            end
                    end
                end
            end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_rsp_vld_q <= 1'b0; ctrl_rsp_tag_q <= '0;
            ctrl_rsp_status_q <= OK; ctrl_rsp_base_q <= '0;
            rw_turn_q <= 1'b0; rd_bad_q <= OK; wr_bad_q <= OK;
            rd_rsp_ctx_q <= '0; wr_rsp_ctx_q <= '0;
            for (int c=0;c<CONTEXTS;c++) begin
                ctx_live_q[c] <= 1'b0; ctx_epoch_q[c*16+:16] <= '0;
                permit_q[c] <= 1'b0; last_cols_q[c*10+:10] <= 10'd512;
                outstanding_q[c*9+:9] <= '0;
            end
            for (int u=0;u<16;u++) begin
                unit_live_q[u] <= 1'b0; unit_ctx_q[u*5+:5] <= '0; unit_epoch_q[u*16+:16] <= '0;
            end
        end else begin
            ctrl_rsp_vld_q <= ctrl_rsp_vld_d;
            ctrl_rsp_tag_q <= ctrl_rsp_tag_d;
            ctrl_rsp_status_q <= ctrl_rsp_status_d;
            ctrl_rsp_base_q <= ctrl_rsp_base_d;
            ctx_live_q <= ctx_live_d;
            permit_q <= permit_d;
            ctx_epoch_q <= ctx_epoch_d;
            last_cols_q <= last_cols_d;
            outstanding_q <= outstanding_d;
            unit_live_q <= unit_live_d;
            unit_ctx_q <= unit_ctx_d;
            unit_epoch_q <= unit_epoch_d;
            rd_bad_q <= rd_bad_d;
            wr_bad_q <= wr_bad_d;
            rd_rsp_ctx_q <= rd_rsp_ctx_d;
            wr_rsp_ctx_q <= wr_rsp_ctx_d;
            rw_turn_q <= rw_turn_d;
        end
    end
    initial begin
        if (CONTEXTS < 1 || CONTEXTS > (1 << CTX_ID_W) || TAG_W < 1) $fatal(1, "TMEM parameter range");
    end
endmodule
