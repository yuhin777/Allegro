package blackwell_dot_pkg;
  typedef enum logic [1:0] {
    ZERO,
    FINITE,
    INF,
    NAN
  } class_t;
  typedef struct packed {
    class_t cls;
    logic sign;
    logic [10:0] sig;
    logic signed [7:0] e;
  } wide_t;
  typedef struct packed {
    class_t cls;
    logic sign;
    logic [3:0] sig;
    logic signed [4:0] e;
  } low_t;
  typedef struct packed {
    logic sign;
    logic [3:0] q;
  } nibble_t;
  typedef struct packed {
    logic nan;
    logic signed [7:0] e;
  } mx_t;
  typedef struct packed {
    logic nan;
    logic [3:0] sig;
    logic signed [8:0] e;
  } factor_t;
  typedef struct packed {
    wide_t [15:0] a, b;
    logic [31:0] c;
    logic [3:0] shift;
  } wide_req_t;
  typedef struct packed {
    low_t [31:0] a, b;
    logic [31:0] c;
    mx_t sa, sb;
  } low_req_t;
  typedef struct packed {
    nibble_t [63:0] a, b;
    logic [31:0] c;
    factor_t [3:0] sa, sb;
  } fp4_req_t;
  typedef struct packed {
    logic [31:0][8:0] a, b;
    logic [31:0] c;
    logic saturate;
  } int_req_t;
  typedef struct packed {
    logic [75:0] tag;
    logic [7:0][255:0] a, b;
    logic [63:0][31:0] c;
    logic [7:0][31:0] sa, sb;
  } operand_t;
  typedef struct packed {
    logic [75:0] tag;
    logic [63:0][31:0] cells;
  } result_t;
  typedef struct packed {
    class_t cls;
    logic sign;
    logic [23:0] sig;
    logic signed [8:0] e;
  } accum_t;
  typedef struct packed {
    logic sign;
    logic [21:0] sig;
    logic signed [8:0] e;
  } wide_product_t;
  typedef struct packed {
    logic sign;
    logic [23:0] sig;
    logic signed [8:0] e;
  } wide_c_t;
  typedef struct packed {
    logic [1:0] special;
    wide_product_t [15:0] prod;
    logic [3:0][8:0] group_max;
    wide_c_t c;
  } wide_products_t;
  typedef struct packed {
    logic [1:0] special;
    logic [15:0] prod_sign;
    logic [15:0][21:0] prod_sig;
    logic [15:0][4:0] prod_shift;
    logic c_sign;
    logic [23:0] c_sig;
    logic [4:0] c_shift;
    logic signed [8:0] emax;
  } wide_shifts_t;

  typedef struct packed {
    logic sign;
    logic [7:0] sig;
    logic signed [5:0] e;
  } low_product_t;
  typedef struct packed {
    low_product_t [31:0] prod;
    logic [3:0][8:0] group_max;
    logic [3:0] group_valid;
    logic c_sign, c_valid;
    logic [23:0] c_sig;
    logic signed [9:0] c_exp;
    logic signed [8:0] scale;
    logic [1:0] special;
  } low_products_t;
  typedef struct packed {
    logic [31:0] prod_sign;
    logic [31:0][7:0] prod_sig;
    logic [31:0][4:0] prod_shift;
    logic c_sign;
    logic [23:0] c_sig;
    logic [4:0] c_shift;
    logic signed [9:0] base;
    logic [1:0] special;
  } low_shifts_t;

  function automatic logic [4:0] alignment_shift(logic signed [9:0] emax,
                                                 logic signed [9:0] exponent);
    logic signed [10:0] distance;
    distance = 11'(emax) - 11'(exponent);
    return distance >= 11'sd27 ? 5'd27 : distance[4:0];
  endfunction

  localparam logic [31:0] QNAN = 32'h7fffffff, PINF = 32'h7f800000, NINF = 32'hff800000;

  function automatic wide_t wide_decode(logic [31:0] raw, logic [3:0] dtype, logic negate);
    wide_t v;
    logic [7:0] ef;
    logic [9:0] frac;
    logic special, nan_fraction;
    v = '0;
    case (dtype)
      0: begin
        ef = {3'b0, raw[14:10]};
        frac = raw[9:0];
        v.sign = raw[15] ^ negate;
        special = &ef[4:0];
        nan_fraction = |frac;
        v.e = ef == 0 ? -8'sd14 : ef - 8'd15;
      end
      1: begin
        ef = raw[14:7];
        frac = {raw[6:0], 3'b0};
        v.sign = raw[15] ^ negate;
        special = &ef;
        nan_fraction = |frac;
        v.e = ef == 0 ? -8'sd126 : ef - 8'd127;
      end
      default: begin
        ef = raw[30:23];
        frac = raw[22:13];
        v.sign = raw[31] ^ negate;
        special = &ef;
        nan_fraction = |raw[22:0];
        v.e = ef == 0 ? -8'sd126 : ef - 8'd127;
      end
    endcase
    v.sig = {|ef, frac};
    v.cls = special ? (nan_fraction ? NAN : INF) : (v.sig == 0 ? ZERO : FINITE);
    if (v.cls != FINITE) begin
      v.e = '0;
      v.sig = '0;
    end
    return v;
  endfunction

  function automatic low_t low_decode(logic [7:0] raw, logic [3:0] dtype, logic negate);
    low_t v;
    logic [4:0] ef;
    logic [2:0] frac;
    logic signed [4:0] bias;
    v = '0;
    case (dtype)
      3: begin
        ef = {1'b0, raw[6:3]};
        frac = raw[2:0];
        bias = 7;
        v.sign = raw[7];
      end
      4: begin
        ef = raw[6:2];
        frac = {raw[1:0], 1'b0};
        bias = 15;
        v.sign = raw[7];
      end
      5: begin
        ef = {2'b0, raw[4:2]};
        frac = {raw[1:0], 1'b0};
        bias = 3;
        v.sign = raw[5];
      end
      6: begin
        ef = {3'b0, raw[4:3]};
        frac = raw[2:0];
        bias = 1;
        v.sign = raw[5];
      end
      default: begin
        ef = {3'b0, raw[2:1]};
        frac = {raw[0], 2'b0};
        bias = 1;
        v.sign = raw[3];
      end
    endcase
    v.sign ^= negate;
    v.sig = {|ef, frac};
    v.e = 5'((ef == 0 ? 5'd1 : ef) - bias);
    v.cls = v.sig == 0 ? ZERO : FINITE;
    // MMA-Sim expands FP4/FP6 inputs to FP32 before extracting exponents.
    if (dtype >= 5 && ef == 0 && frac != 0) begin
      if (frac[2]) begin
        v.sig = v.sig << 1;
        v.e -= 5'sd1;
      end else if (frac[1]) begin
        v.sig = v.sig << 2;
        v.e -= 5'sd2;
      end else begin
        v.sig = v.sig << 3;
        v.e -= 5'sd3;
      end
    end
    if (dtype == 3 && raw[6:0] == 7'h7f) v.cls = NAN;
    if (dtype == 4 && (&ef)) v.cls = (|frac) ? NAN : INF;
    if (v.cls != FINITE) begin
      v.e = '0;
      v.sig = '0;
    end
    return v;
  endfunction

  function automatic nibble_t nibble_decode(logic [3:0] raw, logic negate);
    nibble_t v;
    v.sign = raw[3] ^ negate;
    case (raw[2:0])
      5: v.q = 6;
      6: v.q = 8;
      7: v.q = 12;
      default: v.q = {1'b0, raw[2:0]};
    endcase
    return v;
  endfunction

  function automatic mx_t mx_decode(logic [7:0] raw);
    mx_t v;
    v.nan = &raw;
    v.e = v.nan ? 0 : raw - 8'd127;
    return v;
  endfunction

  function automatic factor_t factor_decode(logic [7:0] raw, logic ue4m3);
    factor_t v;
    if (ue4m3) begin
      v.nan = &raw[6:0];
      v.sig = {|raw[6:3], raw[2:0]};
      v.e = raw[6:3] != 0 ? 9'({1'b0, raw[6:3]}) - 9'sd10 : (v.sig == 0 ? -9'sd129 : -9'sd9);
    end else begin
      v.nan = &raw;
      v.sig = raw == 0 ? 4 : 8;
      v.e = raw == 0 ? -9'sd129 : $signed({1'b0, raw}) - 9'sd130;
    end
    return v;
  endfunction

  function automatic accum_t accum_decode(logic [31:0] raw, logic [3:0] shift);
    accum_t v;
    logic [7:0] ef;
    int adjusted;
    ef = raw[30:23];
    v = '0;
    v.sign = raw[31];
    v.sig = {|ef, raw[22:0]};
    adjusted = (ef == 0 ? 1 : int'(ef)) - int'(shift);
    if (adjusted < 1) v.sig = v.sig >> (1 - adjusted);
    v.e = adjusted < 1 ? -9'sd126 : 9'(adjusted - 127);
    v.cls = (&ef) ? ((|raw[22:0]) ? NAN : INF) : (v.sig == 0 ? ZERO : FINITE);
    if (v.cls != FINITE) begin
      v.sig = 0;
      v.e = -9'sd126;
    end
    return v;
  endfunction

  // Bits denote NaN, negative infinity and positive infinity independently.
  function automatic logic [2:0] flags(class_t cls, logic signbit);
    return {cls == NAN, cls == INF && signbit, cls == INF && !signbit};
  endfunction

  function automatic logic [2:0] product_flags(class_t a, class_t b, logic signbit);
    if (a == NAN || b == NAN || (a == ZERO && b == INF) || (a == INF && b == ZERO)) return 3'b100;
    return flags((a == INF || b == INF) ? INF : FINITE, signbit);
  endfunction

  function automatic logic [1:0] special_code(logic [2:0] f);
    return (f[2] || (&f[1:0])) ? 2'd3 : f[1:0];
  endfunction
  function automatic logic [31:0] special_value(logic [1:0] code);
    case (code)
      1: return PINF;
      2: return NINF;
      default: return QNAN;
    endcase
  endfunction
endpackage
