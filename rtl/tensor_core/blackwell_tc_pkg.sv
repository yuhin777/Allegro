package blackwell_tc_pkg;
  import blackwell_async_pkg::*;
  typedef struct packed {
    async_id_t id;
    logic [2:0] kind;
    logic [3:0] a_type, b_type;
    logic [1:0] n_code;
    logic a_from_tmem, ws, input_d;
    logic transpose_a, transpose_b, negate_a, negate_b, int_sat;
    logic [3:0] scale_input_d;
    logic [1:0] collector_op, collector_buffer;
    logic [127:0] disable_lane_mask;
    logic scale_type;
    logic [1:0] scale_vec, scale_a_id, scale_b_id;
    logic [63:0] a_ref, b_desc;
    logic [31:0] d_tmem, scale_a, scale_b;
  } mma_cmd_t;
  typedef struct packed {
    async_id_t   id;
    logic [31:0] barrier_addr;
  } tc_commit_t;
  typedef struct packed {
    tc_commit_t commit;
    logic [2:0] slot;
  } tc_ready_commit_t;
  typedef struct packed {
    logic [2:0] slot;
    async_id_t  id;
  } tc_commit_retire_t;
  typedef struct packed {
    logic [1:0] rec;
    logic bank;
    mma_cmd_t cmd;
  } prepare_t;
  typedef struct packed {
    async_id_t id;
    logic [63:0] desc;
    logic [3:0] dtype;
    logic [2:0] kind;
    logic transpose;
    logic [1:0] n_code;
  } b_load_t;
  typedef struct packed {
    async_id_t id;
    logic [4:0] block_idx;
    logic [2047:0] data;
  } b_data_t;
  typedef struct packed {
    async_id_t id;
    logic [1:0] base_part, n_code;
    logic reuse;
  } b_select_t;
  typedef struct packed {
    async_id_t  id;
    logic [1:0] core;
    logic [5:0] block_idx;
    logic [1:0] row_idx;
    logic [7:0] generation;
  } tile_tag_t;

  function automatic int element_bits(logic [3:0] dtype);
    case (dtype)
      0, 1: return 16;
      2: return 32;
      5, 6: return 6;
      7: return 4;
      default: return 8;
    endcase
  endfunction
  // Absolute-address XOR includes the phase of the submatrix start.
  function automatic logic [63:0] matrix_byte(logic [63:0] desc, logic transpose,
                                              int unsigned row_coord, k_coord);
    logic [63:0] addr, r, z, lbo, sbo;
    logic [7:0] xor_mask, row_mask;
    logic [2:0] width_shift, height_shift;
    r = 64'(row_coord);
    z = 64'(k_coord);
    lbo = {46'd0, desc[29:16], 4'd0};
    sbo = {46'd0, desc[45:32], 4'd0};
    // Every geometry uses a power-of-two stripe. Dynamic division by a
    // decoded 64-bit width would infer a divider in each address port.
    case (desc[63:61])
      1: begin
        width_shift = 7;
        row_mask = 127;
        xor_mask = 'h60;
      end
      2: begin
        width_shift = 7;
        row_mask = 127;
        xor_mask = 'h70;
      end
      4: begin
        width_shift = 6;
        row_mask = 63;
        xor_mask = 'h30;
      end
      6: begin
        width_shift = 5;
        row_mask = 31;
        xor_mask = 'h10;
      end
      default: begin
        width_shift = 4;
        row_mask = 15;
        xor_mask = 0;
      end
    endcase
    height_shift = desc[63:61] == 1 ? 2 : 3;
    addr = {46'd0, desc[13:0], 4'd0};
    if (!transpose) begin
      addr += (64'(r[2:0]) << width_shift) + (r >> 3) * sbo;
      addr += desc[63:61] == 0 ? 64'(z[3:0]) + (z >> 4) * lbo : z;
    end else if (desc[63:61] == 0)
      addr += 64'(r[3:0]) + (r >> 4) * sbo + (64'(z[2:0]) << 4) + (z >> 3) * lbo;
    else
      addr += (r & {56'd0, row_mask}) + (r >> width_shift) * lbo +
          ((desc[63:61] == 1 ? 64'(z[1:0]) : 64'(z[2:0])) << width_shift) +
          (z >> height_shift) * sbo;
    return addr ^ ((addr >> (desc[63:61] == 1 ? 2 : 3)) & 64'(xor_mask));
  endfunction
  // Map one logical operand bit to its physical SMEM bit address.
  function automatic logic [63:0] source_bit(b_load_t src, int row_idx, k, bit_idx);
    int width_bits, e, offset_bits;
    logic [63:0] byte_addr;
    width_bits = element_bits(src.dtype);
    e = src.transpose ? row_idx : k;
    if (width_bits < 8 && src.kind < 5)
      offset_bits = (e / 16) * 128 + (e % 16) * width_bits + bit_idx;
    else offset_bits = e * width_bits + bit_idx;
    byte_addr = src.transpose ? matrix_byte(src.desc, 1, offset_bits / 8, k) :
        matrix_byte(src.desc, 0, row_idx, offset_bits / 8);
    return (byte_addr << 3) + 64'(offset_bits[2:0]);
  endfunction
endpackage
