// A1 single-CTA protocol ABI. Field order is MSB to LSB.
package blackwell_async_pkg;
  localparam int unsigned BYTE_W = 8;
  localparam int unsigned CTX_ID_W = 5;
  localparam int unsigned ISSUER_ID_W = 10;
  localparam int unsigned WARP_ID_W = 5;
  localparam int unsigned ASYNC_TAG_W = 16;
  localparam int unsigned EPOCH_W = 16;
  localparam int unsigned SEQ_W = 64;
  localparam int unsigned STATUS_W = 8;
  localparam int unsigned MEM_STATUS_W = 2;
  localparam int unsigned BYTE_COUNT_W = 64;
  localparam int unsigned BARRIER_TX_BYTES_W = 32;
  localparam int unsigned BARRIER_COUNT_W = 32;
  localparam int unsigned BARRIER_STATE_W = 64;
  localparam int unsigned BARRIER_TIME_HINT_W = 32;
  localparam int unsigned BARRIER_REPORT_W = 8;
  localparam int unsigned CACHE_POLICY_W = 64;
  localparam int unsigned GMEM_ADDR_W = 64;
  localparam int unsigned SMEM_BYTE_ADDR_W = 32;
  localparam int unsigned MATRIX_DESC_W = 64;
  localparam int unsigned TENSOR_MAP_BYTES = 128;
  localparam int unsigned TENSOR_DIMS = 5;
  localparam int unsigned TENSOR_COORD_VECTOR_W = TENSOR_DIMS * 32;
  localparam int unsigned IM2COL_W = 5 * 16;
  localparam int unsigned TMEM_LANES = 128;
  localparam int unsigned TMEM_COLUMNS = 512;
  localparam int unsigned TMEM_CELL_W = 32;
  localparam int unsigned TMEM_WORD_COLUMNS = 4;
  localparam int unsigned TMEM_WORD_W = TMEM_WORD_COLUMNS * TMEM_CELL_W;
  localparam int unsigned TMEM_ADDR_LANE_W = 16;
  localparam int unsigned TMEM_COLUMN_FIELD_W = 16;
  localparam int unsigned TMEM_ADDR_W = TMEM_ADDR_LANE_W + TMEM_COLUMN_FIELD_W;
  localparam int unsigned TMEM_COLUMN_INDEX_W = $clog2(TMEM_COLUMNS);
  localparam int unsigned TMEM_COLUMNS_COUNT_W = $clog2(TMEM_COLUMNS + 1);
  localparam int unsigned TMEM_HALF_OFFSET_W = 32;
  localparam int unsigned TMEM_LANE_MASK_W = TMEM_LANES;
  localparam int unsigned TMEM_COLUMN_BUS_W = TMEM_LANES * TMEM_COLUMN_FIELD_W;
  localparam int unsigned TMEM_DATA_W = TMEM_LANES * TMEM_WORD_W;
  localparam int unsigned TMEM_BYTE_MASK_W = TMEM_LANES * TMEM_WORD_W / BYTE_W;
  localparam int unsigned RF_THREADS = 32;
  localparam int unsigned RF_REG_W = 32;
  localparam int unsigned RF_REPEAT_W = 8;
  localparam int unsigned RF_INDEX_W = 7;
  localparam int unsigned RF_BEAT_W = RF_THREADS * RF_REG_W;
  localparam int unsigned GMEM_BEAT_BYTES = 128;
  localparam int unsigned SMEM_BEAT_BYTES = 32;
  localparam int unsigned GMEM_DATA_W = GMEM_BEAT_BYTES * BYTE_W;
  localparam int unsigned GMEM_MASK_W = GMEM_BEAT_BYTES;
  localparam int unsigned SMEM_DATA_W = SMEM_BEAT_BYTES * BYTE_W;
  localparam int unsigned SMEM_MASK_W = SMEM_BEAT_BYTES;
  localparam int unsigned TMA_MSHR_ENTRIES = 16;
  localparam int unsigned BARRIER_MEM_ID_DEFAULT_W = 1;
  localparam int unsigned TENSOR_SMEM_ID_W = 7;
  localparam int unsigned ORDER_ID_W = 16;
  localparam int unsigned ASYNC_ID_W = ISSUER_ID_W + WARP_ID_W + ASYNC_TAG_W + SEQ_W + EPOCH_W;
  localparam int unsigned ASYNC_EVENT_W = ASYNC_ID_W + 3 + STATUS_W + 1;
  localparam int unsigned TC_COMMIT_W = ASYNC_ID_W + SMEM_BYTE_ADDR_W;
  localparam int unsigned ASYNC_KEY_A1_W = CTX_ID_W + ASYNC_ID_W;
  localparam int unsigned ASYNC_EVENT_A1_W = CTX_ID_W + ASYNC_EVENT_W;
  localparam int unsigned TC_COMMIT_A1_W = CTX_ID_W + TC_COMMIT_W;
  localparam int unsigned MMA_CMD_A1_W = CTX_ID_W + ASYNC_ID_W + 3 + 2 * 4 + 2 + 8 + 9 + 8 + 3 * MATRIX_DESC_W + 5 * TMEM_ADDR_W + 12 * 1 + 4 + 6 * 2 + 1 + 2 + TMEM_LANE_MASK_W;
  localparam int unsigned CP_CMD_A1_W = CTX_ID_W + ASYNC_ID_W + TMEM_ADDR_W + MATRIX_DESC_W + 3 + 2 * 2;
  localparam int unsigned SHIFT_CMD_A1_W = CTX_ID_W + ASYNC_ID_W + TMEM_ADDR_W;
  localparam int unsigned TMA_CMD_W = 4 + ASYNC_TAG_W + ISSUER_ID_W + SEQ_W + ((GMEM_ADDR_W > SMEM_BYTE_ADDR_W) ? GMEM_ADDR_W : SMEM_BYTE_ADDR_W) + TENSOR_COORD_VECTOR_W + SMEM_BYTE_ADDR_W + ((GMEM_ADDR_W > SMEM_BYTE_ADDR_W) ? GMEM_ADDR_W : SMEM_BYTE_ADDR_W) + 32 + SMEM_BYTE_ADDR_W + 2 * 3 + IM2COL_W + 5 * 2 + 9 * 1 + 32 + 4 * 4 + 3 + 16 + CACHE_POLICY_W + 64;
  localparam int unsigned TMA_RSP_W = ASYNC_TAG_W + ISSUER_ID_W + STATUS_W + BYTE_COUNT_W;
  localparam int unsigned BAR_CMD_W = 5 + ASYNC_TAG_W + ISSUER_ID_W + SEQ_W + SMEM_BYTE_ADDR_W + BARRIER_COUNT_W + BARRIER_TX_BYTES_W + 6 * 1 + BARRIER_STATE_W + BARRIER_TIME_HINT_W + BARRIER_REPORT_W + 2 * 2;
  localparam int unsigned BAR_RSP_W = ASYNC_TAG_W + ISSUER_ID_W + STATUS_W + 5 * 1 + BARRIER_STATE_W + BARRIER_COUNT_W + BARRIER_REPORT_W;
  localparam int unsigned BAR_REPORT_REQ_W = ASYNC_TAG_W + SMEM_BYTE_ADDR_W + BARRIER_REPORT_W;
  localparam int unsigned BW_ASYNC_REQ_W = 1 + ISSUER_ID_W + SEQ_W + STATUS_W;
  localparam int unsigned BW_ASYNC_RSP_W = ISSUER_ID_W + SEQ_W + STATUS_W;
  localparam int unsigned BW_MEM_ATTR_W = 2 + 4 + 3 + 3 * 1 + ISSUER_ID_W + SEQ_W + 3 * 2 + CACHE_POLICY_W;
  localparam int unsigned BW_ORDER_REQ_W = ORDER_ID_W + ISSUER_ID_W + SEQ_W + 2 + 3 * 2 + ((GMEM_ADDR_W > SMEM_BYTE_ADDR_W) ? GMEM_ADDR_W : SMEM_BYTE_ADDR_W) + BYTE_COUNT_W;
  localparam int unsigned BW_ORDER_RSP_W = ORDER_ID_W + STATUS_W;
  localparam int unsigned GMEM_ID_DEFAULT_W = ((1 > $clog2(TMA_MSHR_ENTRIES + 1)) ? 1 : $clog2(TMA_MSHR_ENTRIES + 1));
  localparam int unsigned TMA_SMEM_ID_DEFAULT_W = ((1 > $clog2(TMA_MSHR_ENTRIES)) ? 1 : $clog2(TMA_MSHR_ENTRIES));
  localparam int unsigned SUBSYSTEM_SMEM_ID_DEFAULT_W = 1 + ((TMA_SMEM_ID_DEFAULT_W > BARRIER_MEM_ID_DEFAULT_W) ? TMA_SMEM_ID_DEFAULT_W : BARRIER_MEM_ID_DEFAULT_W);
  localparam int unsigned SMEM_BYTES = 228 * 1024;
    typedef enum logic [2:0] {
        CPL_TC, CPL_TMEM_LD, CPL_TMEM_ST, CPL_TMA_BYTES, CPL_BULK_GROUP
    } completion_domain_t;
  typedef struct packed {
    logic [ISSUER_ID_W-1:0] issuer;
    logic [WARP_ID_W-1:0] warp;
    logic [ASYNC_TAG_W-1:0] tag;
    logic [SEQ_W-1:0] seq;
    logic [EPOCH_W-1:0] epoch;
  } async_id_t;
  typedef struct packed {
    async_id_t id;
    logic [3-1:0] domain;
    logic [STATUS_W-1:0] status;
    logic value;
  } async_event_t;
  typedef struct packed {
    async_id_t id;
    logic [SMEM_BYTE_ADDR_W-1:0] barrier;
  } tc_commit_t;
  typedef struct packed {
    logic [CTX_ID_W-1:0] ctx;
    async_id_t id;
  } async_key_a1_t;
  typedef struct packed {
    logic [CTX_ID_W-1:0] ctx;
    async_event_t \event ;
  } async_event_a1_t;
  typedef struct packed {
    logic [CTX_ID_W-1:0] ctx;
    tc_commit_t commit;
  } tc_commit_a1_t;
  typedef struct packed {
    logic [CTX_ID_W-1:0] ctx;
    async_id_t id;
    logic [3-1:0] kind;
    logic [4-1:0] a_type;
    logic [4-1:0] b_type;
    logic [2-1:0] d_type;
    logic [8-1:0] m;
    logic [9-1:0] n;
    logic [8-1:0] k;
    logic [MATRIX_DESC_W-1:0] a_desc;
    logic [MATRIX_DESC_W-1:0] b_desc;
    logic [TMEM_ADDR_W-1:0] a_tmem;
    logic [TMEM_ADDR_W-1:0] d_tmem;
    logic [TMEM_ADDR_W-1:0] scale_a;
    logic [TMEM_ADDR_W-1:0] scale_b;
    logic [TMEM_ADDR_W-1:0] sparse_meta;
    logic a_from_tmem;
    logic sparse;
    logic ws;
    logic ashift;
    logic input_d;
    logic transpose_a;
    logic transpose_b;
    logic negate_a;
    logic negate_b;
    logic int_sat;
    logic [2-1:0] sp_selector;
    logic [4-1:0] scale_input_d;
    logic scale_type;
    logic [2-1:0] scale_vec;
    logic scale_a_layout;
    logic [2-1:0] scale_a_id;
    logic [2-1:0] scale_b_id;
    logic [2-1:0] collector_op;
    logic [2-1:0] collector_buffer;
    logic [TMEM_LANE_MASK_W-1:0] disable_lane_mask;
    logic zero_mask_enable;
    logic [MATRIX_DESC_W-1:0] zero_mask_desc;
    logic [2-1:0] ws_max_shift;
  } mma_cmd_a1_t;
  typedef struct packed {
    logic [CTX_ID_W-1:0] ctx;
    async_id_t id;
    logic [TMEM_ADDR_W-1:0] base_addr;
    logic [MATRIX_DESC_W-1:0] smem_desc;
    logic [3-1:0] shape;
    logic [2-1:0] multicast;
    logic [2-1:0] source_format;
  } cp_cmd_a1_t;
  typedef struct packed {
    logic [CTX_ID_W-1:0] ctx;
    async_id_t id;
    logic [TMEM_ADDR_W-1:0] base_addr;
  } shift_cmd_a1_t;

    localparam logic [7:0] ASYNC_OK = 8'd0;
    localparam logic [7:0] ASYNC_BAD_COMPLETION = 8'd1;
    localparam logic [7:0] ASYNC_EXECUTION_ERROR = 8'd2;
    function automatic logic same_operation(input async_id_t a, input async_id_t b);
        return a == b;
    endfunction
  function automatic logic same_key(input async_key_a1_t a, input async_key_a1_t b);
    return a == b;
  endfunction

  // PTX 9.4 shared descriptor, relative-stride canonical K/MN layouts.
  function automatic logic matrix_descriptor_valid(input logic [MATRIX_DESC_W-1:0] desc);
    return !desc[15] && !desc[31] && desc[48:46] == 3'b001 &&
        !desc[52] && !desc[53] && desc[60:54] == 0 &&
        (desc[63:61] == 0 || desc[63:61] == 1 || desc[63:61] == 2 ||
         desc[63:61] == 4 || desc[63:61] == 6);
  endfunction

  function automatic logic [63:0] matrix_byte_address(
      input logic [MATRIX_DESC_W-1:0] desc,
      input logic [31:0] row, column_byte,
      input logic mn_major);
    logic [63:0] offset, lbo, sbo, start, base, swizzled;
    logic [63:0] pattern_width, xor_mask;
    start = {45'd0,desc[14:0],4'd0};
    lbo = {45'd0,desc[30:16],4'd0};
    sbo = {46'd0,desc[45:32],4'd0};
    base = 64'(desc[51:49]) << 7;
    pattern_width = 64'd16;
    xor_mask = '0;
    case (desc[63:61])
      3'd1: begin pattern_width = 64'd128; xor_mask = 64'h60; end
      3'd2: begin pattern_width = 64'd128; xor_mask = 64'h70; end
      3'd4: begin pattern_width = 64'd64; xor_mask = 64'h30; end
      3'd6: begin pattern_width = 64'd32; xor_mask = 64'h10; end
      default: ;
    endcase
    if (!mn_major) begin
      offset = (64'(row) % 64'd8) * pattern_width + (64'(row) / 64'd8) * sbo;
      offset += (desc[63:61] == 0) ?
          (64'(column_byte) % 64'd16) + (64'(column_byte) / 64'd16) * lbo : 64'(column_byte);
    end else if (desc[63:61] == 0) begin
      offset = (64'(row) % 64'd16) + (64'(row) / 64'd16) * sbo +
          (64'(column_byte) % 64'd8) * 16 + (64'(column_byte) / 64'd8) * lbo;
    end else begin
      offset = (64'(row) % pattern_width) +
          (64'(row) / pattern_width) * lbo +
          (64'(column_byte) % ((desc[63:61] == 1) ? 64'd4 : 64'd8)) * pattern_width +
          (64'(column_byte) / ((desc[63:61] == 1) ? 64'd4 : 64'd8)) * sbo;
    end
    swizzled = (offset + base) ^
        (((offset + base) >> ((desc[63:61] == 1) ? 2 : 3)) & xor_mask);
    return start + swizzled - base;
  endfunction
endpackage
