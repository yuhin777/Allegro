// A mode bit selects the layout of each packed slot. In a single-family
// instance the unused front, tail and high groups disappear at elaboration.
module blackwell_fp_dot_lane
  import blackwell_dot_pkg::*;
#(
  parameter bit HAS_WIDE = 1,
  parameter bit HAS_LOW = 1,
  parameter bit WIDE_SPILL = HAS_LOW && HAS_WIDE
) (
  input logic clk,
  input logic req_low,
  input logic [6:0] advance,
  input logic [3:0] low_mode,
  input logic spill_write,
  input logic spill_valid,
  input logic [$bits(wide_req_t)-1:0] wide_req,
  input logic [$bits(low_req_t)-1:0] low_req,
  output logic [31:0] wide_result,
  output logic [31:0] low_result
);
  localparam int PAIRS  = HAS_LOW ? 16 : 8;
  localparam int GROUPS = PAIRS / 4;
  localparam int EXP_W  = HAS_LOW ? 10 : 9;
  localparam int S0_W   = HAS_WIDE ? $bits(wide_products_t) : $bits(low_products_t);
  localparam int S1_W   = HAS_LOW ? $bits(low_shifts_t) : $bits(wide_shifts_t);
  typedef struct packed {
    logic [1:0] special;
    logic signed [EXP_W-1:0] exponent;
    logic signed [26:0] c;
    logic [PAIRS-1:0][28:0] pairs;
  } pairs_t;
  typedef struct packed {
    logic [1:0] special;
    logic signed [9:0] base;
    logic signed [26:0] c;
    logic [3:0][30:0] groups;
  } groups_t;
  typedef struct packed {
    logic [1:0] special;
    logic signed [8:0] emax;
    logic signed [32:0] sum;
  } wide_sum_t;
  localparam int S3_W = HAS_LOW ? $bits(groups_t) : $bits(wide_sum_t);
  logic [S0_W-1:0] q0;
  logic [S1_W-1:0] q1;
  logic [S3_W-1:0] q3;
  pairs_t d2, q2;
  wide_products_t wide_products;
  low_products_t  low_products;
  wide_shifts_t wide_shifts, wide_q1;
  low_shifts_t low_shifts, low_q1;
  if (HAS_WIDE) begin : g_wide_front
    blackwell_wide_dot_front front (
      .req(wide_req),
      .q0(wide_products_t'(q0)),
      .d0(wide_products),
      .d1(wide_shifts)
    );
  end else assign wide_products = '0, wide_shifts = '0;
  if (HAS_LOW) begin : g_low_front
    blackwell_low_dot_front front (
      .req(low_req),
      .q0(low_products_t'(q0)),
      .d0(low_products),
      .d1(low_shifts)
    );
  end else assign low_products = '0, low_shifts = '0;
  always_ff @(posedge clk) begin
    if (advance[0]) q0 <= req_low ? S0_W'(low_products) : S0_W'(wide_products);
    if (advance[1]) q1 <= low_mode[0] ? S1_W'(low_shifts) : S1_W'(wide_shifts);
  end
  assign wide_q1 = wide_shifts_t'(q1), low_q1 = low_shifts_t'(q1);
  for (genvar p = 0; p < PAIRS; p++) begin : g_pair
    logic [1:0][27:0] terms;
    for (genvar i = 0; i < 2; i++) begin : g_term
      localparam int K = 2 * p + i;
      logic [26:0] mag, aligned;
      logic [4:0] distance;
      logic negative;
      if (K < 16 && HAS_WIDE) begin
        assign negative = low_mode[1] ? low_q1.prod_sign[K] : wide_q1.prod_sign[K];
        assign mag = low_mode[1] ? {low_q1.prod_sig[K], 19'b0} : {wide_q1.prod_sig[K], 5'b0};
        assign distance = low_mode[1] ? low_q1.prod_shift[K] : wide_q1.prod_shift[K];
      end else begin
        // Wide requests leave the upper half of the shared tree idle.
        assign negative = low_q1.prod_sign[K];
        assign mag = low_mode[1] ? {low_q1.prod_sig[K], 19'b0} : '0;
        assign distance = low_q1.prod_shift[K];
      end
      assign aligned = mag >> distance;
      assign terms[i] = negative ? -28'(aligned) : 28'(aligned);
    end
    blackwell_dot_signed_reduce_tree #(
      .TERM_N(2),
      .TERM_W(28),
      .SUM_W (29)
    ) add_pair (
      .term_flat_i(terms),
      .sum_o(d2.pairs[p])
    );
  end
  logic [25:0] c_mag;
  logic [23:0] c_sig;
  logic [4:0] c_shift;
  logic c_sign;
  assign c_sig = low_mode[1] ? low_q1.c_sig : wide_q1.c_sig;
  assign c_sign = low_mode[1] ? low_q1.c_sign : wide_q1.c_sign;
  assign c_shift = low_mode[1] ? low_q1.c_shift : wide_q1.c_shift;
  assign c_mag = {c_sig, 2'b0} >> c_shift;
  assign d2.c = c_sign ? -27'(c_mag) : 27'(c_mag);
  assign d2.special = low_mode[1] ? low_q1.special : wide_q1.special;
  assign d2.exponent = low_mode[1] ? EXP_W'($signed(low_q1.base)) : EXP_W'($signed(wide_q1.emax));
  always_ff @(posedge clk) if (advance[2]) q2 <= d2;

  logic [GROUPS-1:0][30:0] groups;
  for (genvar g = 0; g < GROUPS; g++) begin : g_group
    blackwell_dot_signed_reduce_tree #(
      .TERM_N(4),
      .TERM_W(29),
      .SUM_W(31),
      .CARRY_SAVE(1)
    ) add_group (
      .term_flat_i(q2.pairs[g*4+:4]),
      .sum_o(groups[g])
    );
  end
  wide_sum_t wide_sum;
  groups_t   low_groups;
  assign low_groups = {q2.special, 10'($signed(q2.exponent)), q2.c, 124'(groups)};
  assign wide_sum.special = q2.special, wide_sum.emax = 9'(q2.exponent);
  if (HAS_WIDE) begin : g_wide_tail
    blackwell_dot_signed_reduce_tree #(
      .TERM_N(3),
      .TERM_W(31),
      .SUM_W(33),
      .CARRY_SAVE(1)
    ) finish_sum (
      .term_flat_i({31'($signed(q2.c)), groups[1:0]}),
      .sum_o(wide_sum.sum)
    );
    wide_sum_t s;
    assign s = wide_sum_t'(q3);
    logic [31:0] packed_result, wide_q;
    blackwell_dot_fp32_pack pack_result (
      .sum(s.sum),
      .base_exp(10'($signed(s.emax)) - 10'sd25),
      .special_valid(|s.special),
      .special_result(special_value(s.special)),
      .result(packed_result)
    );
    always_ff @(posedge clk) if (advance[4]) wide_q <= packed_result;
    if (WIDE_SPILL) begin : g_spill
      logic [31:0] spill_q;
      always_ff @(posedge clk) if (spill_write) spill_q <= wide_q;
      assign wide_result = spill_valid ? spill_q : wide_q;
    end else assign wide_result = wide_q;
  end else assign wide_sum.sum = '0, wide_result = '0;
  always_ff @(posedge clk) if (advance[3]) q3 <= low_mode[2] ? S3_W'(low_groups) : S3_W'(wide_sum);
  if (HAS_LOW) begin : g_low_tail
    groups_t s;
    assign s = groups_t'(q3);
    logic signed [32:0] total, sum_q;
    logic signed [9:0] base_q;
    logic [1:0] special_q;
    logic [31:0] packed_result;
    blackwell_dot_signed_reduce_tree #(
      .TERM_N(5),
      .TERM_W(31),
      .SUM_W (33)
    ) finish_sum (
      .term_flat_i({31'($signed(s.c)), s.groups}),
      .sum_o(total)
    );
    always_ff @(posedge clk)
      if (advance[5])
        {special_q, base_q, sum_q} <= {s.special, s.base, total};
    blackwell_dot_fp32_pack pack_result (
      .sum(sum_q),
      .base_exp(base_q),
      .special_valid(|special_q),
      .special_result(special_value(special_q)),
      .result(packed_result)
    );
    always_ff @(posedge clk) if (advance[6]) low_result <= packed_result;
  end else assign low_result = '0;
`ifndef SYNTHESIS
  initial begin
    assert (HAS_WIDE || HAS_LOW);
    assert ($bits(q0) == (HAS_WIDE ? 584 : 567) && $bits(q1) == (HAS_LOW ? 490 : 489));
    assert ($bits(q2) == (HAS_LOW ? 503 : 270) && $bits(q3) == (HAS_LOW ? 163 : 44));
    assert ($bits(groups) == 31 * GROUPS && $bits(q2.pairs) == 29 * PAIRS);
  end
`endif
endmodule
