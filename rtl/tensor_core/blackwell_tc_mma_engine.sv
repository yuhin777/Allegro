// Implements frozen A1: doc/specs/blackwell_tc_mma_engine.md
module blackwell_tc_mma_engine
  import blackwell_async_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic cmd_vld_i,
  input blackwell_async_pkg::mma_cmd_a1_t cmd_i,
  input logic complete_rdy_i,
  input logic smem_req_rdy_i,
  input logic smem_rsp_vld_i,
  input logic [SMEM_DATA_W-1:0] smem_rsp_data_i,
  input logic [TENSOR_SMEM_ID_W-1:0] smem_rsp_id_i,
  input logic [MEM_STATUS_W-1:0] smem_rsp_status_i,
  input logic tmem_rd_rdy_i,
  input logic tmem_rd_rsp_vld_i,
  input logic [TMEM_DATA_W-1:0] tmem_rd_rsp_data_i,
  input logic [STATUS_W-1:0] tmem_rd_rsp_status_i,
  input logic tmem_wr_rdy_i,
  input logic tmem_wr_rsp_vld_i,
  input logic [STATUS_W-1:0] tmem_wr_rsp_status_i,
  output logic cmd_rdy_o,
  output logic complete_vld_o,
  output blackwell_async_pkg::async_event_a1_t complete_o,
  output logic smem_req_vld_o,
  output logic [SMEM_BYTE_ADDR_W-1:0] smem_req_addr_o,
  output logic [TENSOR_SMEM_ID_W-1:0] smem_req_id_o,
  output logic [SMEM_MASK_W-1:0] smem_req_byte_mask_o,
  output logic smem_rsp_rdy_o,
  output logic tmem_rd_vld_o,
  output logic [CTX_ID_W-1:0] tmem_rd_ctx_o,
  output logic [EPOCH_W-1:0] tmem_rd_epoch_o,
  output logic [TMEM_LANE_MASK_W-1:0] tmem_rd_lane_mask_o,
  output logic [TMEM_COLUMN_BUS_W-1:0] tmem_rd_column_o,
  output logic [ASYNC_TAG_W-1:0] tmem_rd_tag_o,
  output logic tmem_rd_rsp_rdy_o,
  output logic tmem_wr_vld_o,
  output logic [CTX_ID_W-1:0] tmem_wr_ctx_o,
  output logic [EPOCH_W-1:0] tmem_wr_epoch_o,
  output logic [TMEM_COLUMN_BUS_W-1:0] tmem_wr_column_o,
  output logic [TMEM_DATA_W-1:0] tmem_wr_data_o,
  output logic [TMEM_BYTE_MASK_W-1:0] tmem_wr_byte_mask_o,
  output logic [ASYNC_TAG_W-1:0] tmem_wr_tag_o,
  output logic tmem_wr_rsp_rdy_o,
  output logic idle_o
);

  localparam int unsigned DOTS = 4 * 64;
  typedef enum logic [4:0] {Idle, AddressCheck, SourceReq, SourceRsp,
    TensorReq, TensorRsp, SparseCheck, DestProbeReq, DestProbeRsp, InitTile,
    OldDReq, OldDRsp, OldDScatter, GatherOperands, DotIssue, DotRsp, EncodeReq, EncodeRsp,
    WriteDReq, WriteDRsp, ShiftReq, ShiftRsp, Complete} state_t;
  state_t state_q, state_d;
  mma_cmd_a1_t cmd_q, cmd_d;
  logic [STATUS_W-1:0] status_q, status_d;
  logic source_q, source_d, fetch_fault_q, fetch_fault_d;
  logic [8:0] row_q, row_d, tile_q, tile_d, column_q, column_d;
  logic [7:0] element_q, element_d, chunk_q, chunk_d, dot_q, dot_d;
  logic [2:0] tensor_q, tensor_d;
  logic [7:0] cell_q, cell_d;
  logic [7:0] gather_q, gather_d;
  logic [5:0] gather_element_q, gather_element_d;
  // One operand element is prepared per cycle from the execution memories.
  // All 256 physical F16/TF32 dots still issue together; low precision uses
  // its microtile index. Transaction buffers are initialized before use.
  logic [DOTS-1:0][255:0] prepared_a_q;
  logic [255:0] prepared_a_d, gathered_a_q;
  logic [DOTS-1:0][255:0] prepared_b_q;
  logic [255:0] prepared_b_d, gathered_b_q;
  // Operand storage belongs to this execution slot. It is neither TMEM nor a
  // collector cache. Contents are overwritten before use and not reset.
  logic [31:0] a_q [0:127][0:127];
  logic a_source_wr_en;
  logic [63:0] a_source_mask, a_source_data;
  integer a_source_cell;
  logic [31:0] b_q [0:255][0:15];
  logic b_source_wr_en;
  logic [63:0] b_source_mask, b_source_data;
  integer b_source_cell;
  logic [31:0] meta_q [0:127][0:3];
  logic [31:0] sfa_q [0:127][0:7];
  logic [31:0] sfb_q [0:127][0:7];
  logic [DOTS-1:0][31:0] acc_q, acc_d;
  // One accepted old-D response is scattered over subsequent cycles.
  logic [TMEM_DATA_W-1:0] old_d_word_q, old_d_word_d;
  logic [DOTS-1:0][dot_prod_pkg::DOT_FINAL_W-1:0] final_q, final_d;
  logic [DOTS*dot_prod_pkg::DOT_FINAL_W-1:0] f16_final;
  dot_prod_pkg::dot_final_t low_final;
  logic signed [63:0] int_acc_q, int_acc_d;
  logic [4:0] collector_valid_q, collector_valid_d;
  logic [4:0][CTX_ID_W-1:0] collector_ctx_q, collector_ctx_d;
  logic [4:0][EPOCH_W-1:0] collector_epoch_q, collector_epoch_d;
  integer source_bits, source_count, source_rows, container_a_bits;
  integer row_logical, source_offset, read_bytes, collector_slot;
  integer tensor_cells, tensor_column, tensor_base;
  integer tile_columns, arithmetic_chunk, output_column, output_row, physical_column;
  logic [63:0] source_address;
  logic [TMEM_LANE_MASK_W-1:0] active_lanes;
  logic [31:0] tensor_address;
  logic [255:0] small_a, small_b;
  logic [DOTS*256-1:0] f16_a, f16_b;
  logic [DOTS*32-1:0] f16_c, f16_d;
  logic f16_in_rdy, f16_out_vld, low_in_rdy, low_out_vld;
  logic fp4_in_rdy, fp4_out_vld, int_in_rdy, int_out_vld;
  logic [31:0] low_result, fp4_result, int_result, small_result;
  logic [31:0] scale_a_vector, scale_b_vector;
  logic [1:0] fp4_mode;
  logic arithmetic_rdy, arithmetic_vld;
  logic [DOTS*32-1:0] encoded_result;
  logic encode_rdy, encode_vld;
  logic tensor_enabled, tensor_legal, dest_legal;

  function automatic int precision_bits(input logic [3:0] dtype);
    case (dtype)
      0,1: return 16;
      2: return 32;
      5,6: return 6;
      7: return 4;
      default: return 8;
    endcase
  endfunction
  function automatic int lane_for(input mma_cmd_a1_t c, input int m, input int n,
                                  input int alignment);
    if (c.ws && c.m == 32) return m + 32*(n/(int'(c.n)/4));
    if (c.ws && c.m == 64) return m + 64*(n/(int'(c.n)/2));
    if (c.m == 64) return 32*(m/16)+m%16+alignment;
    return m;
  endfunction
  function automatic int logical_row(input mma_cmd_a1_t c, input int p);
    if (c.ws) return p % int'(c.m);
    if (c.m == 64) return 16*(p/32)+p%16;
    return p;
  endfunction
  function automatic logic column_zero(input mma_cmd_a1_t c, input int n);
    int part, local_n, skipped, use_span, skip_span, phase;
    part=0; local_n=0; skipped=0; use_span=0; skip_span=0; phase=0;
    if (!c.zero_mask_enable || !c.zero_mask_desc[39]) return 1'b0;
    part = c.m == 32 ? n/(int'(c.n)/4) : c.m == 64 ? n/(int'(c.n)/2) : 0;
    local_n = c.m == 32 ? n%(int'(c.n)/4) : c.m == 64 ? n%(int'(c.n)/2) : n;
    skipped = int'(c.zero_mask_desc[part*8+:8]);
    skip_span = int'(c.zero_mask_desc[47:40])+1;
    use_span = int'(c.zero_mask_desc[55:48])+1;
    phase = local_n + skipped;
    if (c.zero_mask_desc[32+part]) return phase%(skip_span+use_span) < use_span;
    return phase%(skip_span+use_span) >= skip_span;
  endfunction
  function automatic logic legal_command(input mma_cmd_a1_t c);
    int dense_k, bits_a, bits_b;
    logic types_ok, dims_ok, scaled, desc_ok, modifiers_ok, hints_ok;
    dense_k = c.kind == 0 ? 16 : c.kind == 1 ? 8 : c.kind >= 5 ? 64 : 32;
    scaled = c.kind >= 4;
    bits_a=precision_bits(c.a_type); bits_b=precision_bits(c.b_type);
    types_ok = 1'b0;
    case (c.kind)
      0: types_ok = c.a_type <= 1 && c.b_type <= 1 &&
          (c.d_type == 1 || (c.d_type == 0 && c.a_type == 0 && c.b_type == 0));
      1: types_ok = c.a_type == 2 && c.b_type == 2 && c.d_type == 1;
      2: types_ok = c.a_type >= 3 && c.a_type <= 7 && c.b_type >= 3 &&
          c.b_type <= 7 && c.d_type <= 1;
      3: types_ok = c.a_type >= 8 && c.a_type <= 9 && c.b_type >= 8 &&
          c.b_type <= 9 && c.d_type == 2;
      4: types_ok = c.a_type >= 3 && c.a_type <= 7 && c.b_type >= 3 &&
          c.b_type <= 7 && c.d_type == 1 && c.scale_type == 0 && c.scale_vec == 1;
      5: types_ok = c.a_type == 7 && c.b_type == 7 && c.d_type == 1 &&
          c.scale_type == 0 && c.scale_vec == 2;
      6: types_ok = c.a_type == 7 && c.b_type == 7 && c.d_type == 1 &&
          ((c.scale_type == 0 && (c.scale_vec == 2 || c.scale_vec == 3)) ||
           (c.scale_type == 1 && c.scale_vec == 3));
      default: ;
    endcase
    dims_ok = int'(c.k) == dense_k * (c.sparse ? 2 : 1);
    if (c.ws) dims_ok &= c.kind <= 3 && (c.m == 32 || c.m == 64 || c.m == 128) &&
        (c.n == 64 || c.n == 128 || (!c.sparse && c.n == 256));
    else dims_ok &= (c.m == 128 || (!scaled && c.m == 64)) &&
        c.n >= 8 && c.n <= 256 && c.n[2:0] == 0;
    if (c.kind == 3 && !c.ws && c.n > 32) dims_ok &= c.n[3:0] == 0;
    desc_ok = matrix_descriptor_valid(c.b_desc) &&
        (c.transpose_b || c.b_desc[63:61] != 1) &&
        (c.a_from_tmem || c.transpose_a || c.a_desc[63:61] != 1) &&
        (c.a_from_tmem || matrix_descriptor_valid(c.a_desc));
    if (c.transpose_a && !c.a_from_tmem)
      desc_ok &= ((bits_a == 32) == (c.a_desc[63:61] == 1));
    if (c.transpose_b) desc_ok &=
        ((bits_b == 32) == (c.b_desc[63:61] == 1)) && (bits_b != 8 || c.n[3:0] == 0);
    modifiers_ok = (c.kind == 3 ? (!c.negate_a && !c.negate_b) : !c.int_sat);
    modifiers_ok &= c.kind <= 1 && !c.ws ? 1'b1 : c.scale_input_d == 0;
    modifiers_ok &= !c.ws || (!c.ashift && c.disable_lane_mask == 0);
    modifiers_ok &= !scaled || (c.disable_lane_mask == 0 && c.scale_a_layout == 0 &&
        c.sp_selector == 0 && c.scale_a[31:16] == 0 && c.scale_b[31:16] == 0);
    if (c.kind >= 5) modifiers_ok &= !c.transpose_a && !c.transpose_b &&
        !c.scale_a_id[0] && !c.scale_b_id[0] &&
        (c.scale_vec != 3 || (c.scale_a_id == 0 && c.scale_b_id == 0));
    if (!scaled) modifiers_ok &= c.scale_a == 0 && c.scale_b == 0 &&
        c.scale_type == 0 && c.scale_vec == 0 && c.scale_a_layout == 0 &&
        c.scale_a_id == 0 && c.scale_b_id == 0;
    if (!c.sparse) modifiers_ok &= c.sparse_meta == 0 && c.sp_selector == 0;
    if (c.kind >= 2) modifiers_ok &= c.sp_selector == 0;
    else modifiers_ok &= c.sp_selector <= 1;
    modifiers_ok &= !c.ashift || (!c.ws && !scaled && c.a_from_tmem && c.m == 128 &&
        c.collector_op != 1 && c.collector_op != 2);
    modifiers_ok &= c.ws || (c.ws_max_shift == 0 && c.collector_buffer == 0 &&
        !c.zero_mask_enable && c.zero_mask_desc == 0);
    if (c.ws && c.zero_mask_enable) modifiers_ok &= c.zero_mask_desc[63:62] == 0 &&
        c.zero_mask_desc[38:36] == 0 && c.zero_mask_desc[61:56] <= (c.m == 32 ? 16 : 32);
    if (!c.zero_mask_enable) modifiers_ok &= c.zero_mask_desc == 0;
    hints_ok = c.ws || c.collector_buffer == 0;
    return types_ok && dims_ok && desc_ok && modifiers_ok && hints_ok;
  endfunction
  function automatic logic [31:0] promote_half(input logic [15:0] value);
    logic [9:0] fraction;
    int exponent, shift;
    shift=0;
    fraction=value[9:0]; exponent=int'(value[14:10]);
    if (exponent == 31) return {value[15],8'hff,fraction,13'd0};
    if (exponent == 0) begin
      if (fraction == 0) return {value[15],31'd0};
      exponent=113;
      for (shift=0;shift<10;shift++) begin
        if (!fraction[9]) begin fraction=fraction<<1; exponent--; end
      end
      return {value[15],8'(exponent-1),fraction[8:0],14'd0};
    end
    return {value[15],8'(exponent+112),fraction,13'd0};
  endfunction
  // Each execution row keeps its original 4096-bit capacity as 32-bit cells.
  // Read the adjacent cell only for a compact element that crosses a boundary.
  function automatic logic [31:0] a_operand_bits(input int lane, input int offset,
                                                input int needed_bits);
    logic [63:0] words;
    words={32'd0,a_q[lane][offset/32]};
    if (offset%32+needed_bits>32) words[63:32]=a_q[lane][offset/32+1];
    return 32'(words >> (offset%32));
  endfunction
  function automatic logic [31:0] b_operand_bits(input int lane, input int offset,
                                                input int needed_bits);
    logic [63:0] words;
    words={32'd0,b_q[lane][offset/32]};
    if (offset%32+needed_bits>32) words[63:32]=b_q[lane][offset/32+1];
    return 32'(words >> (offset%32));
  endfunction
  function automatic logic [31:0] operand_value(input logic for_b, input int m,
      input int n, input int k);
    int stored_k, a_lane, bits, offset, group, index, meta_lane, meta_offset, pair;
    logic [3:0] selector;
    logic [31:0] value;
    group=0; index=0; meta_lane=0; meta_offset=0; pair=0;
    offset=0; selector='0;
    stored_k=k; value='0;
    a_lane=cmd_q.a_from_tmem ? lane_for(cmd_q,m,n,int'(cmd_q.a_tmem[31:16])) : m;
    bits=precision_bits(for_b ? cmd_q.b_type : cmd_q.a_type);
    if (!for_b && cmd_q.sparse) begin
      if (cmd_q.kind <= 1) begin
        group=k/(cmd_q.kind == 1 ? 2 : 4);
        meta_lane=(lane_for(cmd_q,m,n,int'(cmd_q.sparse_meta[31:16]))/16)*16 +
            m%8 + 8*(group/4);
        meta_offset=int'(cmd_q.sp_selector)*32 + 16*((m%16)/8)+4*(group%4);
      end else begin
        group=k/(cmd_q.kind >= 5 ? 8 : 4);
        meta_lane=lane_for(cmd_q,m,n,int'(cmd_q.sparse_meta[31:16]));
        meta_offset=group*4;
      end
      selector=meta_q[meta_lane][meta_offset/32][meta_offset%32+:4];
      if (cmd_q.kind == 1) begin
        index=selector == 4'he ? 1 : 0;
        if (k%2 != index) return '0;
        stored_k=k/2;
      end else if (cmd_q.kind >= 5) begin
        pair=(k%8)/2;
        if (pair == int'(selector[1:0])) stored_k=(k/8)*4+k%2;
        else if (pair == int'(selector[3:2])) stored_k=(k/8)*4+2+k%2;
        else return '0;
      end else begin
        if (k%4 == int'(selector[1:0])) stored_k=(k/4)*2;
        else if (k%4 == int'(selector[3:2])) stored_k=(k/4)*2+1;
        else return '0;
      end
    end
    if (for_b) begin
      if (column_zero(cmd_q,n)) return '0;
      value=b_operand_bits(n,k*bits,bits);
    end else if (cmd_q.a_from_tmem) begin
      if (cmd_q.transpose_a) begin
        a_lane=lane_for(cmd_q,stored_k,n,int'(cmd_q.a_tmem[31:16]));
        stored_k=m;
      end
      offset=stored_k*container_a_bits;
      value=a_operand_bits(a_lane,offset,container_a_bits);
      if (cmd_q.a_type == 7 && cmd_q.kind < 5) value=value>>2;
    end else value=a_operand_bits(a_lane,stored_k*bits,bits);
    value &= bits == 32 ? 32'hffffffff : ((32'd1<<bits)-1);
    if (for_b ? cmd_q.negate_b : cmd_q.negate_a) value ^= 32'd1<<(bits-1);
    return value;
  endfunction
  function automatic logic [7:0] scale_value(input logic for_b,input int row,input int k);
    int factors, block_k, byte_offset, column, physical_lane;
    factors=cmd_q.scale_vec == 1 ? 1 : cmd_q.scale_vec == 2 ? 2 : 4;
    block_k=int'(cmd_q.k)/factors;
    if (block_k == 0) block_k=1;
    byte_offset=(for_b ? int'(cmd_q.scale_b_id) : int'(cmd_q.scale_a_id))+k/block_k;
    column=row/32;
    physical_lane=row%32;
    if (for_b) return sfb_q[physical_lane][column+byte_offset/4][(byte_offset%4)*8+:8];
    return sfa_q[physical_lane][column+byte_offset/4][(byte_offset%4)*8+:8];
  endfunction

  assign source_bits=precision_bits(source_q ? cmd_q.b_type : cmd_q.a_type);
  assign source_count=(!source_q && cmd_q.sparse) ? int'(cmd_q.k)/2 : int'(cmd_q.k);
  assign source_rows=source_q ? int'(cmd_q.n) : int'(cmd_q.m);
  assign container_a_bits=(cmd_q.a_type >= 3 && cmd_q.a_type <= 7 && cmd_q.kind < 5) ?
      8 : precision_bits(cmd_q.a_type);
  assign row_logical=int'(row_q)+(source_q && cmd_q.ws && cmd_q.zero_mask_enable ?
      int'(cmd_q.zero_mask_desc[61:56]) : 0);
  always_comb begin
    source_offset=int'(element_q)*source_bits;
    if (cmd_q.kind == 2 || cmd_q.kind == 4)
      source_offset=(int'(element_q)/16)*128+(int'(element_q)%16)*source_bits;
    if (source_q ? cmd_q.transpose_b : cmd_q.transpose_a) begin
      // MN-major sub-byte operands pack the contiguous M/N elements in
      // sixteen-element containers, including the specified tail padding.
      source_offset=row_logical*source_bits;
      if (cmd_q.kind == 2 || cmd_q.kind == 4)
        source_offset=(row_logical/16)*128+(row_logical%16)*source_bits;
      source_address=matrix_byte_address(source_q ? cmd_q.b_desc : cmd_q.a_desc,
          32'(source_offset/8),32'(element_q),1'b1);
    end else source_address=matrix_byte_address(source_q ? cmd_q.b_desc : cmd_q.a_desc,
        32'(row_logical),32'(source_offset/8),1'b0);
    read_bytes=((source_offset%8)+source_bits+7)/8;
  end
  assign collector_slot=cmd_q.ws ? int'(cmd_q.collector_buffer)+1 : 0;
  assign tile_columns=256/(cmd_q.m == 0 ? 128 : int'(cmd_q.m));
  assign arithmetic_chunk=cmd_q.kind == 0 ? 16 : cmd_q.kind == 1 ? 8 : cmd_q.kind >= 5 ? 64 : 32;
  assign output_row=int'(dot_q)%(cmd_q.m == 0 ? 128 : int'(cmd_q.m));
  assign output_column=int'(tile_q)+int'(dot_q)/(cmd_q.m == 0 ? 128 : int'(cmd_q.m));
  always_comb begin
    int m;
    m=0;
    active_lanes='0;
    for (m=0;m<128;m++) if (m<int'(cmd_q.m))
      active_lanes[lane_for(cmd_q,m,int'(column_q),int'(cmd_q.d_tmem[31:16]))]=1'b1;
    tensor_address=cmd_q.a_tmem;
    tensor_cells=(container_a_bits*(cmd_q.transpose_a ? int'(cmd_q.m) :
        int'(cmd_q.k)/(cmd_q.sparse ? 2 : 1))+31)/32;
    case (tensor_q)
      1: begin
        tensor_address=cmd_q.sparse_meta;
        // F16/TF32 selectors address one 32-bit sub-column; all other
        // SM100a sparse layouts occupy two columns for sixteen 4-bit groups.
        tensor_cells=cmd_q.kind <= 1 ? int'(cmd_q.sp_selector)+1 : 2;
      end
      2: begin tensor_address=cmd_q.scale_a; tensor_cells=4; end
      3: begin tensor_address=cmd_q.scale_b; tensor_cells=(int'(cmd_q.n)+31)/32; end
      default: ;
    endcase
    tensor_column=int'(tensor_address[15:0])+int'(cell_q);
    tensor_base=int'(tensor_address[31:16]);
  end
  assign cmd_rdy_o=state_q == Idle;
  assign idle_o=state_q == Idle;
  assign complete_vld_o=state_q == Complete;
  assign complete_o={cmd_q.ctx,cmd_q.id,3'(CPL_TC),status_q,1'b0};
  assign smem_req_vld_o=state_q == SourceReq;
  assign smem_req_addr_o=SMEM_BYTE_ADDR_W'(source_address & ~64'd31);
  assign smem_req_id_o=TENSOR_SMEM_ID_W'(int'(row_q)%128);
  assign smem_rsp_rdy_o=state_q == SourceRsp;
  always_comb begin
    int byte_index;
    byte_index=0;
    smem_req_byte_mask_o='0;
    for (byte_index=0;byte_index<4;byte_index++) if (byte_index<read_bytes)
      smem_req_byte_mask_o[int'(source_address[4:0])+byte_index]=1'b1;
  end

  assign tensor_enabled=!((tensor_q == 0 && !cmd_q.a_from_tmem) ||
      (tensor_q == 1 && !cmd_q.sparse) || ((tensor_q == 2 || tensor_q == 3) && cmd_q.kind < 4));
  assign tensor_legal=(tensor_base == 0 || (tensor_q <= 1 && cmd_q.m == 64 && !cmd_q.ws && tensor_base == 16)) &&
      int'(tensor_address[15:0])+tensor_cells<=512;
  assign physical_column=cmd_q.ws && cmd_q.m == 32 ? int'(column_q)%(cmd_q.n == 0 ? 1 : int'(cmd_q.n)/4) :
      cmd_q.ws && cmd_q.m == 64 ? int'(column_q)%(cmd_q.n == 0 ? 1 : int'(cmd_q.n)/2) : int'(column_q);
  assign dest_legal=int'(cmd_q.d_tmem[15:0])+(cmd_q.ws && cmd_q.m == 32 ? int'(cmd_q.n)/4 : cmd_q.ws && cmd_q.m == 64 ? int'(cmd_q.n)/2 : int'(cmd_q.n))<=512;
  assign tmem_rd_vld_o=(state_q == TensorReq && tensor_enabled && tensor_legal) ||
      (state_q == DestProbeReq && dest_legal) || state_q == OldDReq;
  assign tmem_rd_rsp_rdy_o=state_q == TensorRsp || state_q == DestProbeRsp || state_q == OldDRsp;
  assign tmem_wr_vld_o=state_q == WriteDReq || state_q == ShiftReq;
  assign tmem_wr_rsp_rdy_o=state_q == WriteDRsp || state_q == ShiftRsp;
  assign tmem_rd_ctx_o=cmd_q.ctx;
  assign tmem_wr_ctx_o=cmd_q.ctx;
  assign tmem_rd_epoch_o=cmd_q.id.epoch;
  assign tmem_wr_epoch_o=cmd_q.id.epoch;
  assign tmem_rd_tag_o=cmd_q.id.tag;
  assign tmem_wr_tag_o=cmd_q.id.tag;
  always_comb begin
    int p, m, lane, col, index;
    p=0; m=0; lane=0; col=0; index=0;
    tmem_rd_lane_mask_o=active_lanes;
    tmem_rd_column_o={TMEM_LANES{16'((int'(cmd_q.d_tmem[15:0])+physical_column) & ~3)}};
    if (state_q == TensorReq || state_q == TensorRsp) begin
      tmem_rd_lane_mask_o='1;
      if (tensor_q == 0 && cmd_q.m == 64 && !cmd_q.ws) begin
        for (p=0;p<128;p++) tmem_rd_lane_mask_o[p]=(p%32>=tensor_base && p%32<tensor_base+16);
      end
      tmem_rd_column_o={TMEM_LANES{16'(tensor_column & ~3)}};
    end
    tmem_wr_column_o={TMEM_LANES{16'((int'(cmd_q.d_tmem[15:0])+physical_column) & ~3)}};
    tmem_wr_data_o='0; tmem_wr_byte_mask_o='0;
    for (m=0;m<128;m++) begin
      lane=lane_for(cmd_q,m,int'(column_q),int'(cmd_q.d_tmem[31:16]));
      col=int'(cmd_q.d_tmem[15:0])+physical_column;
      index=(int'(column_q)-int'(tile_q))*int'(cmd_q.m)+m;
      if (m<int'(cmd_q.m) && !cmd_q.disable_lane_mask[lane] && state_q == WriteDReq) begin
        tmem_wr_data_o[lane*128+:128]=128'(acc_q[index]) << ((col%4)*32);
        tmem_wr_byte_mask_o[lane*16+:16]=(cmd_q.d_type == 0 ? 16'h0003 : 16'h000f) << ((col%4)*4);
      end
    end
    if (state_q == ShiftReq) begin
      tmem_wr_column_o={TMEM_LANES{16'((int'(cmd_q.a_tmem[15:0])+int'(cell_q)) & ~3)}};
      for (p=0;p<127;p++) begin
        tmem_wr_data_o[p*128+:128]=128'(a_q[p+1][cell_q[6:0]]) <<
            (((int'(cmd_q.a_tmem[15:0])+int'(cell_q))%4)*32);
        tmem_wr_byte_mask_o[p*16+:16]=16'h000f <<
            (((int'(cmd_q.a_tmem[15:0])+int'(cell_q))%4)*4);
      end
    end
  end
  always_comb begin
    int block;
    block=0;
    f16_a=prepared_a_q; f16_b=prepared_b_q; f16_c=acc_q;
    small_a=gathered_a_q; small_b=gathered_b_q;
    scale_a_vector='0; scale_b_vector='0;
    for (block=0;block<4;block++) begin
      scale_a_vector[block*8+:8]=scale_value(1'b0,output_row,int'(chunk_q)+(cmd_q.scale_vec == 2 ? 32 : 16)*block);
      scale_b_vector[block*8+:8]=scale_value(1'b1,output_column,int'(chunk_q)+(cmd_q.scale_vec == 2 ? 32 : 16)*block);
    end
    fp4_mode=cmd_q.scale_type ? 2'd0 : cmd_q.scale_vec == 2 ? 2'd1 : 2'd3;
    arithmetic_rdy=f16_in_rdy;
    arithmetic_vld=f16_out_vld;
    small_result='0;
    case (cmd_q.kind)
      2,4: begin arithmetic_rdy=low_in_rdy; arithmetic_vld=low_out_vld; small_result=low_result; end
      3: begin arithmetic_rdy=int_in_rdy; arithmetic_vld=int_out_vld; small_result=int_result; end
      5,6: begin arithmetic_rdy=fp4_in_rdy; arithmetic_vld=fp4_out_vld; small_result=fp4_result; end
      default: ;
    endcase
  end
  blackwell_f16_dot_array #(.DOTS(DOTS)) u_f16 (
    .clk(clk),.rst_n(rst_n),.in_vld_i(state_q == DotIssue && cmd_q.kind <= 1),
    .in_rdy_o(f16_in_rdy),.tag_i(cmd_q.id.tag),.tag_o(),
    .a_dtype_i(cmd_q.a_type == 0 ? dot_prod_pkg::DOT_F16TF32_DTYPE_FP16 :
        cmd_q.a_type == 1 ? dot_prod_pkg::DOT_F16TF32_DTYPE_BF16 : dot_prod_pkg::DOT_F16TF32_DTYPE_TF32),
    .b_dtype_i(cmd_q.b_type == 0 ? dot_prod_pkg::DOT_F16TF32_DTYPE_FP16 :
        cmd_q.b_type == 1 ? dot_prod_pkg::DOT_F16TF32_DTYPE_BF16 : dot_prod_pkg::DOT_F16TF32_DTYPE_TF32),
    .a_vec_i(f16_a),.b_vec_i(f16_b),.c_i(f16_c),
    .scale_input_d_i(chunk_q == 0 ? cmd_q.scale_input_d : 4'd0),
    .out_vld_o(f16_out_vld),.out_rdy_i(state_q == DotRsp && cmd_q.kind <= 1),.d_o(f16_d),.final_o(f16_final)
  );
  f4f6f8_dot_prod u_low (
    .clk(clk),.rst_n(rst_n),.in_vld_i(state_q == DotIssue && (cmd_q.kind == 2 || cmd_q.kind == 4)),
    .in_rdy_o(low_in_rdy),.a_vec_i(small_a),.b_vec_i(small_b),.c_i(acc_q[dot_q]),
    .a_dtype_i(3'(int'(cmd_q.a_type)-3)),.b_dtype_i(3'(int'(cmd_q.b_type)-3)),
    .mxfp8_en_i(cmd_q.kind == 4),.a_mx_scale_i(scale_value(1'b0,output_row,0)),
    .b_mx_scale_i(scale_value(1'b1,output_column,0)),.out_vld_o(low_out_vld),
    .out_rdy_i(state_q == DotRsp && (cmd_q.kind == 2 || cmd_q.kind == 4)),.d_o(low_result),.final_o(low_final)
  );
  fp4_dot_prod u_fp4 (
    .clk(clk),.rst_n(rst_n),.in_vld_i(state_q == DotIssue && cmd_q.kind >= 5),
    .in_rdy_o(fp4_in_rdy),.a_fp4_i(small_a),.b_fp4_i(small_b),
    .fp4_mode_i(fp4_mode),.a_sf_i(scale_a_vector),.b_sf_i(scale_b_vector),
    .c_fp32_i(acc_q[dot_q]),.out_vld_o(fp4_out_vld),
    .out_rdy_i(state_q == DotRsp && cmd_q.kind >= 5),.d_fp32_o(fp4_result)
  );
  int8_dot_prod u_int (
    .clk(clk),.rst_n(rst_n),.in_vld_i(state_q == DotIssue && cmd_q.kind == 3),
    .in_rdy_o(int_in_rdy),.a_vec_i(small_a),.b_vec_i(small_b),.c_i(32'd0),
    .a_unsigned_i(cmd_q.a_type == 9),.b_unsigned_i(cmd_q.b_type == 9),.sat_en_i(1'b0),
    .out_vld_o(int_out_vld),.out_rdy_i(state_q == DotRsp && cmd_q.kind == 3),
    .d_o(int_result),.overflow_o()
  );
  blackwell_fp16_result_provider #(.DOTS(DOTS)) u_fp16_result (
    .clk(clk),.rst_n(rst_n),.in_vld_i(state_q == EncodeReq),.in_rdy_o(encode_rdy),
    .result_fp16_i(1'b1),.final_i(final_q),.out_vld_o(encode_vld),
    .out_rdy_i(state_q == EncodeRsp),.result_o(encoded_result)
  );

  always_comb begin
    int slot, check_p, check_offset, granularity, group_count;
    int old_p, old_index, old_col;
    int g_dot, g_m, g_n, g_ba, g_bb;
    logic [31:0] g_av, g_bv;
    logic [31:0] source_value, source_mask, old_value;
    logic selected;
    logic [3:0] code;
    logic signed [63:0] integer_sum;
    g_dot=0; g_m=0; g_n=0; g_ba=0; g_bb=0; g_av='0; g_bv='0;
    slot=0; check_p=0; check_offset=0; granularity=0; group_count=0;
    old_p=0; old_index=0; old_col=0;
    source_value='0; source_mask='0; old_value='0; selected=0; code='0; integer_sum='0;
    state_d=state_q; cmd_d=cmd_q; status_d=status_q;
    source_d=source_q; row_d=row_q; element_d=element_q;
    tile_d=tile_q; column_d=column_q; tensor_d=tensor_q; cell_d=cell_q;
    chunk_d=chunk_q; dot_d=dot_q; fetch_fault_d=fetch_fault_q;
    gather_d=gather_q; gather_element_d=gather_element_q;
    prepared_a_d=gathered_a_q; prepared_b_d=gathered_b_q;
    a_source_wr_en=1'b0;
    a_source_mask='0; a_source_data='0; a_source_cell=0;
    b_source_wr_en=1'b0; b_source_mask='0; b_source_data='0; b_source_cell=0;
    acc_d=acc_q; final_d=final_q; int_acc_d=int_acc_q; old_d_word_d=old_d_word_q;
    collector_valid_d=collector_valid_q; collector_ctx_d=collector_ctx_q;
    collector_epoch_d=collector_epoch_q;
    case (state_q)
      Idle: if (cmd_vld_i && cmd_rdy_o) begin
        slot=cmd_i.ws ? int'(cmd_i.collector_buffer)+1 : 0;
        cmd_d=cmd_i; status_d=ASYNC_OK; tile_d='0; column_d='0;
        chunk_d='0; dot_d='0; cell_d='0; tensor_d='0;
        source_d=cmd_i.a_from_tmem; row_d='0; element_d='0; fetch_fault_d=1'b0;
        if (!legal_command(cmd_i) ||
            ((cmd_i.collector_op == 2 || cmd_i.collector_op == 3) &&
             (!collector_valid_q[slot] || collector_ctx_q[slot] != cmd_i.ctx ||
              collector_epoch_q[slot] != cmd_i.id.epoch))) begin
          status_d=8'd10; state_d=Complete;
        end else if (cmd_i.d_tmem[31:16] != 0 && !(cmd_i.m == 64 && !cmd_i.ws && cmd_i.d_tmem[31:16] == 16)) begin
          status_d=8'd5; state_d=Complete;
        end else if ((cmd_i.a_from_tmem && cmd_i.a_tmem[31:16] != cmd_i.d_tmem[31:16]) ||
                     (cmd_i.sparse && cmd_i.sparse_meta[31:16] != cmd_i.d_tmem[31:16])) begin
          status_d=8'd5; state_d=Complete;
        end else state_d=AddressCheck;
      end
      AddressCheck: begin
        if (source_address+64'(read_bytes)>64'(SMEM_BYTES) ||
            int'(source_address[4:0])+read_bytes>32) begin status_d=8'd16; state_d=Complete; end
        else if (int'(element_q)+1<source_count) element_d=element_q+8'd1;
        else if (int'(row_q)+1<source_rows) begin row_d=row_q+9'd1; element_d='0; end
        else if (!source_q) begin source_d=1'b1; row_d='0; element_d='0; end
        else begin
          source_d=cmd_q.a_from_tmem; row_d='0; element_d='0;
          state_d=SourceReq;
        end
      end
      SourceReq: if (smem_req_vld_o && smem_req_rdy_i) state_d=SourceRsp;
      SourceRsp: if (smem_rsp_vld_i && smem_rsp_rdy_o) begin
        source_mask=source_bits == 32 ? 32'hffffffff : ((32'd1<<source_bits)-1);
        source_value=32'(smem_rsp_data_i >> (int'(source_address[4:0])*8+source_offset%8));
        if (smem_rsp_id_i != smem_req_id_o) fetch_fault_d=1'b1;
        else if (smem_rsp_status_i != 0 || fetch_fault_q) begin status_d=8'd16; state_d=Complete; end
        else begin
          source_value &= source_mask;
          if (source_q) begin
            b_source_wr_en=1'b1;
            b_source_cell=(int'(element_q)*source_bits)/32;
            b_source_mask=64'(source_mask)<<((int'(element_q)*source_bits)%32);
            b_source_data=64'(source_value)<<((int'(element_q)*source_bits)%32);
          end else begin
            a_source_wr_en=1'b1;
            a_source_cell=(int'(element_q)*source_bits)/32;
            a_source_mask=64'(source_mask)<<((int'(element_q)*source_bits)%32);
            a_source_data=64'(source_value)<<((int'(element_q)*source_bits)%32);
          end
          if (int'(element_q)+1<source_count) begin element_d=element_q+8'd1; state_d=SourceReq; end
          else if (int'(row_q)+1<source_rows) begin row_d=row_q+9'd1; element_d='0; state_d=SourceReq; end
          else if (!source_q) begin source_d=1'b1; row_d='0; element_d='0; state_d=SourceReq; end
          else begin tensor_d=0; cell_d=0; state_d=TensorReq; end
        end
      end
      TensorReq: begin
        if ((tensor_q == 0 && !cmd_q.a_from_tmem) || (tensor_q == 1 && !cmd_q.sparse) ||
            ((tensor_q == 2 || tensor_q == 3) && cmd_q.kind < 4)) begin
          if (tensor_q == 3) begin column_d='0; row_d='0; element_d='0; state_d=cmd_q.sparse ? SparseCheck : DestProbeReq; end
          else begin tensor_d=tensor_q+3'd1; cell_d='0; end
        end else if (tensor_base != 0 && !(tensor_q <= 1 && cmd_q.m == 64 && !cmd_q.ws && tensor_base == 16)) begin
          status_d=8'd5; state_d=Complete;
        end else if (int'(tensor_address[15:0])+tensor_cells>512) begin
          status_d=8'd5; state_d=Complete;
        end else if (tmem_rd_vld_o && tmem_rd_rdy_i) state_d=TensorRsp;
      end
      TensorRsp: if (tmem_rd_rsp_vld_i && tmem_rd_rsp_rdy_o) begin
        if (tmem_rd_rsp_status_i != 0) begin status_d=tmem_rd_rsp_status_i; state_d=Complete; end
        else begin
          // Cell write ports below consume this accepted tensor response.
          if (int'(cell_q)+1<tensor_cells) begin cell_d=cell_q+8'd1; state_d=TensorReq; end
          else if (tensor_q == 3) begin column_d='0; row_d='0; element_d='0; state_d=cmd_q.sparse ? SparseCheck : DestProbeReq; end
          else begin tensor_d=tensor_q+3'd1; cell_d='0; state_d=TensorReq; end
        end
      end

      SparseCheck: begin
        granularity=cmd_q.kind == 1 ? 2 : cmd_q.kind >= 5 ? 8 : 4;
        group_count=int'(cmd_q.k)/granularity;
        selected=!(cmd_q.m == 64 && !cmd_q.ws) ||
            (int'(row_q)%32>=int'(cmd_q.sparse_meta[31:16]) &&
             int'(row_q)%32<int'(cmd_q.sparse_meta[31:16])+16);
        if (cmd_q.kind <= 1) begin
          check_p=(int'(row_q)/16)*16+int'(row_q)%8+8*(int'(element_q)/4);
          check_offset=int'(cmd_q.sp_selector)*32+16*((int'(row_q)%16)/8)+4*(int'(element_q)%4);
        end else begin check_p=int'(row_q); check_offset=int'(element_q)*4; end
        code=meta_q[check_p][check_offset/32][check_offset%32+:4];
        if (selected && (cmd_q.kind == 1 ? (code != 4'he && code != 4'h4) :
            !(code == 4'h4 || code == 4'h8 || code == 4'hc || code == 4'h9 ||
              code == 4'hd || code == 4'h6 || code == 4'he))) begin
          status_d=8'd10; state_d=Complete;
        end else if (int'(element_q)+1<group_count) element_d=element_q+8'd1;
        else if (row_q<127) begin row_d=row_q+9'd1; element_d='0; end
        else state_d=DestProbeReq;
      end
      DestProbeReq: begin
        if (!dest_legal) begin status_d=8'd5; state_d=Complete; end
        else if (tmem_rd_vld_o && tmem_rd_rdy_i) state_d=DestProbeRsp;
      end
      DestProbeRsp: if (tmem_rd_rsp_vld_i && tmem_rd_rsp_rdy_o) begin
        if (tmem_rd_rsp_status_i != 0) begin status_d=tmem_rd_rsp_status_i; state_d=Complete; end
        else if (column_q+9'd1<cmd_q.n) begin column_d=column_q+9'd1; state_d=DestProbeReq; end
        else begin column_d='0; state_d=InitTile; end
      end
      InitTile: begin
        acc_d='0; chunk_d='0; dot_d='0; column_d=tile_q; int_acc_d='0; gather_d='0; gather_element_d='0;
        state_d=cmd_q.input_d ? OldDReq : GatherOperands;
      end
      OldDReq: if (tmem_rd_vld_o && tmem_rd_rdy_i) state_d=OldDRsp;
      OldDRsp: if (tmem_rd_rsp_vld_i && tmem_rd_rsp_rdy_o) begin
        if (tmem_rd_rsp_status_i != 0) begin status_d=tmem_rd_rsp_status_i; state_d=Complete; end
        else begin
          old_d_word_d=tmem_rd_rsp_data_i;
          row_d='0; state_d=OldDScatter;
        end
      end
      OldDScatter: begin
        old_p=lane_for(cmd_q,int'(row_q),int'(column_q),int'(cmd_q.d_tmem[31:16]));
        old_index=(int'(column_q)-int'(tile_q))*int'(cmd_q.m)+int'(row_q);
        old_col=int'(cmd_q.d_tmem[15:0])+physical_column;
        old_value=old_d_word_q[old_p*128+(old_col%4)*32+:32];
        acc_d[old_index]=cmd_q.d_type == 0 ? promote_half(old_value[15:0]) : old_value;
        if (row_q+9'd1<9'(cmd_q.m)) row_d=row_q+9'd1;
        else if (int'(column_q)+1<int'(tile_q)+tile_columns && column_q+9'd1<cmd_q.n) begin
          column_d=column_q+9'd1; state_d=OldDReq;
        end else begin
          column_d=tile_q; gather_d='0;
          gather_element_d='0; state_d=GatherOperands;
        end
      end
      GatherOperands: begin
        g_dot=cmd_q.kind <= 1 ? int'(gather_q) : int'(dot_q);
        g_m=g_dot%(cmd_q.m == 0 ? 128 : int'(cmd_q.m));
        g_n=int'(tile_q)+g_dot/(cmd_q.m == 0 ? 128 : int'(cmd_q.m));
        g_ba=precision_bits(cmd_q.a_type); g_bb=precision_bits(cmd_q.b_type);
        g_av='0; g_bv='0;
        if (g_n<int'(cmd_q.n)) begin
          g_av=operand_value(1'b0,g_m,g_n,int'(chunk_q)+int'(gather_element_q));
          g_bv=operand_value(1'b1,g_m,g_n,int'(chunk_q)+int'(gather_element_q));
        end
        prepared_a_d=(gather_element_q == 0 ? 256'd0 : gathered_a_q) |
            (256'(g_av)<<(int'(gather_element_q)*g_ba));
        prepared_b_d=(gather_element_q == 0 ? 256'd0 : gathered_b_q) |
            (256'(g_bv)<<(int'(gather_element_q)*g_bb));
        if (int'(gather_element_q)+1 == arithmetic_chunk) begin
          gather_element_d='0;
          if (cmd_q.kind >= 2 || gather_q == 8'hff) state_d=DotIssue;
          else gather_d=gather_q+8'd1;
        end else gather_element_d=gather_element_q+6'd1;
      end
      DotIssue: if (arithmetic_rdy) state_d=DotRsp;
      DotRsp: if (arithmetic_vld) begin
        // Preserve the final dot accumulator, including bits lost by FP32
        // packing, for the FP16 provider. No extra multiplication array.
        if (cmd_q.d_type == 0 && int'(chunk_q)+arithmetic_chunk>=int'(cmd_q.k)) begin
          if (cmd_q.kind == 0) final_d=f16_final;
          else final_d[dot_q]=low_final;
        end
        if (cmd_q.kind <= 1) acc_d=f16_d;
        else if (cmd_q.kind == 3) begin
          integer_sum=(chunk_q == 0 ? {{32{acc_q[dot_q][31]}},acc_q[dot_q]} : int_acc_q)+
              {{32{int_result[31]}},int_result};
          int_acc_d=integer_sum;
          if (int'(chunk_q)+arithmetic_chunk>=int'(cmd_q.k)) begin
            if (cmd_q.int_sat && integer_sum>64'sh7fffffff) acc_d[dot_q]=32'h7fffffff;
            else if (cmd_q.int_sat && integer_sum< -64'sh80000000) acc_d[dot_q]=32'h80000000;
            else acc_d[dot_q]=integer_sum[31:0];
          end
        end else acc_d[dot_q]=small_result;
        if (int'(chunk_q)+arithmetic_chunk<int'(cmd_q.k)) begin
          chunk_d=8'(int'(chunk_q)+arithmetic_chunk); gather_d='0;
          gather_element_d='0; state_d=GatherOperands;
        end else if (cmd_q.kind >= 2 && dot_q != 8'hff) begin
          dot_d=dot_q+8'd1; chunk_d='0; gather_d='0; gather_element_d='0; state_d=GatherOperands;
        end else begin
          column_d=tile_q;
          state_d=cmd_q.d_type == 0 ? EncodeReq : WriteDReq;
        end
      end
      EncodeReq: if (encode_rdy) state_d=EncodeRsp;
      EncodeRsp: if (encode_vld) begin acc_d=encoded_result; state_d=WriteDReq; end
      WriteDReq: if (tmem_wr_vld_o && tmem_wr_rdy_i) state_d=WriteDRsp;
      WriteDRsp: if (tmem_wr_rsp_vld_i && tmem_wr_rsp_rdy_o) begin
        if (tmem_wr_rsp_status_i != 0) begin status_d=tmem_wr_rsp_status_i; state_d=Complete; end
        else if (int'(column_q)+1<int'(tile_q)+tile_columns && column_q+9'd1<cmd_q.n) begin
          column_d=column_q+9'd1; state_d=WriteDReq;
        end else if (int'(tile_q)+tile_columns<int'(cmd_q.n)) begin
          tile_d=9'(int'(tile_q)+tile_columns); state_d=InitTile;
        end else if (cmd_q.ashift) begin cell_d='0; tensor_d='0; state_d=ShiftReq; end
        else state_d=Complete;
      end
      ShiftReq: if (tmem_wr_vld_o && tmem_wr_rdy_i) state_d=ShiftRsp;
      ShiftRsp: if (tmem_wr_rsp_vld_i && tmem_wr_rsp_rdy_o) begin
        if (tmem_wr_rsp_status_i != 0) begin status_d=tmem_wr_rsp_status_i; state_d=Complete; end
        else if (int'(cell_q)+1<tensor_cells) begin cell_d=cell_q+8'd1; state_d=ShiftReq; end
        else state_d=Complete;
      end
      Complete: if (complete_vld_o && complete_rdy_i) begin
        collector_valid_d[collector_slot]=status_q == 0 && cmd_q.collector_op == 1;
        if (status_q == 0 && cmd_q.collector_op == 2) collector_valid_d[collector_slot]=1'b1;
        collector_ctx_d[collector_slot]=cmd_q.ctx;
        collector_epoch_d[collector_slot]=cmd_q.id.epoch;
        state_d=Idle;
      end
      default: begin status_d=ASYNC_BAD_COMPLETION; state_d=Complete; end
    endcase
  end
  // The execution buffers are not externally addressable state; resetting their
  // payload is unnecessary because the FSM initializes every consumed field.
  for (genvar p=0;p<128;p++) begin : g_operand_rows
    always_ff @(posedge clk) begin
      if (a_source_wr_en && row_q[6:0] == 7'(p)) begin
        a_q[p][a_source_cell] <= (a_q[p][a_source_cell] & ~a_source_mask[31:0]) |
                                a_source_data[31:0];
        if (|a_source_mask[63:32])
          a_q[p][a_source_cell+1] <= (a_q[p][a_source_cell+1] & ~a_source_mask[63:32]) |
                                    a_source_data[63:32];
      end else if (state_q == TensorRsp && tmem_rd_rsp_vld_i &&
                   tmem_rd_rsp_status_i == 0 && tensor_q == 0) begin
        a_q[p][cell_q[6:0]] <= tmem_rd_rsp_data_i[p*128+(tensor_column%4)*32+:32];
      end
      if (state_q == TensorRsp && tmem_rd_rsp_vld_i && tmem_rd_rsp_status_i == 0 &&
          tmem_rd_lane_mask_o[p]) begin
        case (tensor_q)
          1: meta_q[p][cell_q[1:0]] <= tmem_rd_rsp_data_i[p*128+(tensor_column%4)*32+:32];
          2: sfa_q[p][cell_q[2:0]] <= tmem_rd_rsp_data_i[p*128+(tensor_column%4)*32+:32];
          3: sfb_q[p][cell_q[2:0]] <= tmem_rd_rsp_data_i[p*128+(tensor_column%4)*32+:32];
          default: ;
        endcase
      end
    end
  end
  for (genvar p=0;p<256;p++) begin : g_b_rows
    always_ff @(posedge clk) if (b_source_wr_en && row_q[7:0] == 8'(p)) begin
      b_q[p][b_source_cell] <= (b_q[p][b_source_cell] & ~b_source_mask[31:0]) |
                              b_source_data[31:0];
      if (|b_source_mask[63:32])
        b_q[p][b_source_cell+1] <= (b_q[p][b_source_cell+1] & ~b_source_mask[63:32]) |
                                  b_source_data[63:32];
    end
  end
  always_ff @(posedge clk) begin
    acc_q<=acc_d; final_q<=final_d; old_d_word_q<=old_d_word_d;
    gathered_a_q<=prepared_a_d; gathered_b_q<=prepared_b_d;
    for (int d=0;d<DOTS;d++) if (state_q == GatherOperands && cmd_q.kind <= 1 &&
        int'(gather_element_q)+1 == arithmetic_chunk &&
        gather_q == 8'(d)) begin
      prepared_a_q[d]<=prepared_a_d;
      prepared_b_q[d]<=prepared_b_d;
    end
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q<=Idle; cmd_q<='0; status_q<=ASYNC_OK; source_q<=0;
      row_q<='0; element_q<='0; tile_q<='0; column_q<='0; tensor_q<='0;
      cell_q<='0; chunk_q<='0; dot_q<='0; gather_q<='0; gather_element_q<='0; fetch_fault_q<=0; int_acc_q<='0;
      collector_valid_q<='0; collector_ctx_q<='0; collector_epoch_q<='0;
    end else begin
      state_q<=state_d; cmd_q<=cmd_d; status_q<=status_d; source_q<=source_d;
      row_q<=row_d; element_q<=element_d; tile_q<=tile_d; column_q<=column_d;
      tensor_q<=tensor_d; cell_q<=cell_d; chunk_q<=chunk_d; dot_q<=dot_d; gather_q<=gather_d; gather_element_q<=gather_element_d;
      fetch_fault_q<=fetch_fault_d; int_acc_q<=int_acc_d;
      collector_valid_q<=collector_valid_d; collector_ctx_q<=collector_ctx_d;
      collector_epoch_q<=collector_epoch_d;
    end
  end
`ifndef SYNTHESIS
  assert property (@(posedge clk) disable iff (!rst_n)
    complete_vld_o && !complete_rdy_i |=> complete_vld_o && $stable(complete_o));
  assert property (@(posedge clk) disable iff (!rst_n)
    smem_req_vld_o && !smem_req_rdy_i |=> smem_req_vld_o &&
      $stable({smem_req_addr_o,smem_req_id_o,smem_req_byte_mask_o}));
  assert property (@(posedge clk) disable iff (!rst_n)
    tmem_wr_vld_o && !tmem_wr_rdy_i |=> tmem_wr_vld_o &&
      $stable({tmem_wr_ctx_o,tmem_wr_epoch_o,tmem_wr_column_o,tmem_wr_data_o,tmem_wr_byte_mask_o,tmem_wr_tag_o}));

`endif
endmodule
