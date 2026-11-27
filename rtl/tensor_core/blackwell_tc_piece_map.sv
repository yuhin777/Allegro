// Each K-major 16-byte destination uses one source atom, including compressed
// types with a padded 16-element container. MN-major operands have whole-byte
// elements and touch at most one atom per element. Sort at atom granularity.
module blackwell_tc_piece_map
  import blackwell_tc_pkg::*;
(
  input b_load_t src,
  input logic [7:0] row_idx,
  input logic half,
  output logic [15:0] required,
  output logic [15:0][31:0] address,
  output logic [15:0][15:0] byte_mask,
  output logic [127:0] used,
  output logic [127:0][3:0] part,
  output logic [127:0][6:0] source_offset
);
  logic packed4, packed6;
  logic [ 1:0] byte_shift;
  logic [ 4:0] elements;
  logic [ 9:0] row_byte;
  logic [15:0] row_mask;
  logic [31:0] k_address;
  assign packed4 = src.kind < 5 && src.dtype == 7;
  assign packed6 = src.dtype == 5 || src.dtype == 6;
  assign byte_shift = src.dtype <= 1 ? 1 : (src.dtype == 2 ? 2 : 0);
  assign elements = 5'd16 >> byte_shift;
  assign row_byte = 10'(row_idx) << byte_shift;
  assign row_mask = (src.dtype <= 1 ? 16'h3 : (src.dtype == 2 ? 16'hf : 16'h1)) << row_byte[3:0];
  assign k_address = 32'(matrix_byte(src.desc, 0, int'(row_idx), half ? 16 : 0));

  // Legal MN-major widths generate a single increasing run (4 TF32 or
  // 8 FP16/BF16 elements), or two 8-element runs for byte operands.
  // In either run consecutive K values advance by a whole stripe. XOR only
  // permutes addresses within a stripe, so it preserves the run's order.
  logic [2:0] stripe_shift;
  logic [7:0] stripe_mask, xor_mask;
  logic [17:0] base, stride_k, stride_row, start, lbo, sbo;
  logic [18:0] bucket_delta;
  logic [3:0] gap;
  logic duplicate_lanes;
  assign start = {src.desc[13:0], 4'b0};
  assign lbo = {src.desc[29:16], 4'b0}, sbo = {src.desc[45:32], 4'b0};
  always_comb begin
    case (src.desc[63:61])
      1: begin
        stripe_shift = 7;
        stripe_mask = 127;
        xor_mask = 'h60;
      end
      2: begin
        stripe_shift = 7;
        stripe_mask = 127;
        xor_mask = 'h70;
      end
      4: begin
        stripe_shift = 6;
        stripe_mask = 63;
        xor_mask = 'h30;
      end
      6: begin
        stripe_shift = 5;
        stripe_mask = 31;
        xor_mask = 'h10;
      end
      default: begin
        stripe_shift = 4;
        stripe_mask = 15;
        xor_mask = 0;
      end
    endcase
  end
  assign stride_k = src.desc[63:61] == 0 ? lbo : sbo;
  assign stride_row = src.desc[63:61] == 0 ? sbo : lbo;
  // CHECK proves every source is below 228 KiB using extended arithmetic.
  // Only post-check physical address generation narrows to 18 bits.
  assign base = start + {10'b0, (row_byte[7:0] & stripe_mask)} + (18'(row_byte) >> stripe_shift) *
      stride_row + (half ? (elements == 16 ? stride_k << 1 : stride_k) : 18'b0);
  assign bucket_delta = ({11'b0, (base[7:0] & stripe_mask)} + 19'(stride_k)) >> stripe_shift;
  assign gap = bucket_delta >= 8 ? 4'd8 : bucket_delta[3:0];
  assign duplicate_lanes = (stride_k[7:0] & stripe_mask) == 0;

  logic [15:0][13:0] atom;
  logic [15:0] distinct;
  logic [15:0][3:0] rank;
  for (genvar e = 0; e < 16; e++) begin : g_source
    logic [17:0] canonical, physical;
    assign canonical = base + (e >= 8 ? stride_k : 18'b0) + (18'(e % 8) << stripe_shift);
    assign physical = canonical ^ ((canonical >> (src.desc[63:61] == 1 ? 2 : 3)) & 18'(xor_mask));
    assign atom[e] = physical[17:4];

    // Only atoms in the same stripe need a comparison. Clip the other
    // run's count at eight. Coincident lanes share a single request.
    if (e < 8) begin : g_first_run
      logic [3:0] other;
      assign other = 4'(e) - gap;
      assign distinct[e] = e < int'(elements);
      always_comb begin
        rank[e] = 4'(e);
        if (elements == 16 && !duplicate_lanes && 4'(e) >= gap)
          rank[e] = 4'(e) + other + 4'(atom[{1'b1, other[2:0]}] < atom[e]);
      end
    end else begin : g_second_run
      logic [3:0] first_index;
      assign first_index = gap + 4'(e - 8);
      assign distinct[e] = elements == 16 && (!duplicate_lanes || first_index >= 8);
      always_comb begin
        if (duplicate_lanes) rank[e] = first_index;
        else if (first_index >= 8) rank[e] = 4'(e);
        else rank[e] = 4'(e - 8) + first_index + 4'(atom[{1'b0, first_index[2:0]}] < atom[e]);
      end
    end
  end
  for (genvar dst = 0; dst < 16; dst++) begin : g_part
    logic [15:0] choose;
    logic [13:0] selected_atom;
    always_comb begin
      selected_atom = 0;
      for (int e = 0; e < 16; e++) begin
        choose[e] = distinct[e] && rank[e] == 4'(dst);
        selected_atom |= atom[e] & {14{choose[e]}};
      end
    end
    assign required[dst] = src.transpose ? (|choose) : dst == 0;
    assign address[dst] = src.transpose ?
        {14'b0, selected_atom, 4'b0} : (dst == 0 ? k_address : 32'b0);
    assign byte_mask[dst] = !required[dst] ?
        0 : (src.transpose ? row_mask : (packed4 ? 16'h00ff : (packed6 ? 16'h0fff : 16'hffff)));
  end
  for (genvar b = 0; b < 16; b++) begin : g_byte
    logic [3:0] physical_byte;
    assign physical_byte = row_byte[3:0] + (4'(b) & ((4'd1 << byte_shift) - 1'b1));
    for (genvar bit_index = 0; bit_index < 8; bit_index++) begin : g_bit
      localparam int BIT = b * 8 + bit_index;
      assign used[BIT] = (!packed4 || bit_index < 4) && (!packed6 || bit_index < 6);
      assign part[BIT] = src.transpose ? rank[4'(b)>>byte_shift] : 0;
      assign source_offset[BIT] = src.transpose ? {physical_byte, 3'(bit_index)} :
          (packed4 ? 7'(b * 4 + bit_index) : (packed6 ? 7'(b * 6 + bit_index) : 7'(BIT)));
    end
  end
endmodule
