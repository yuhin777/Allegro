module blackwell_dot_signed_reduce_tree #(
  parameter int TERM_W = 33,
  parameter int TERM_N = 17,
  parameter int SUM_W = TERM_W,
  parameter bit CARRY_SAVE = 0
) (
  input logic [TERM_N*TERM_W-1:0] term_flat_i,
  output logic signed [SUM_W-1:0] sum_o
);

  function automatic int operands_at_level(int level);
    int count;
    count = TERM_N;
    repeat (level) begin
      if (CARRY_SAVE && count > 2) count -= count / 3;
      else count = (count + 1) / 2;
    end
    return count;
  endfunction

  for (genvar level = 0; level == 0 || operands_at_level(level - 1) > 1; level++) begin : g_level
    localparam int COUNT = operands_at_level(level);
    logic [SUM_W-1:0] terms[COUNT];
    if (level == 0) begin : g_input
      for (genvar i = 0; i < COUNT; i++) begin : g_extend
        assign terms[i] = SUM_W'($signed(term_flat_i[i*TERM_W+:TERM_W]));
      end
    end else begin : g_reduce
      localparam int PREV = operands_at_level(level - 1);
      if (CARRY_SAVE && PREV > 2) begin : g_compress
        for (genvar i = 0; i < PREV / 3; i++) begin : g_triple
          logic [SUM_W-1:0] a, b, c, ab;
          assign a = g_level[level-1].terms[3*i];
          assign b = g_level[level-1].terms[3*i+1];
          assign c = g_level[level-1].terms[3*i+2];
          assign ab = a ^ b;
          assign terms[2*i] = ab ^ c;
          assign terms[2*i+1] = ((a & b) | (ab & c)) << 1;
        end
        for (genvar i = 0; i < PREV % 3; i++) begin : g_pass
          assign terms[2*(PREV/3)+i] = g_level[level-1].terms[3*(PREV/3)+i];
        end
      end else begin : g_binary
        for (genvar i = 0; i < COUNT; i++) begin : g_pair
          if (2 * i + 1 < PREV)
            assign terms[i] = g_level[level-1].terms[2*i] + g_level[level-1].terms[2*i+1];
          else assign terms[i] = g_level[level-1].terms[2*i];
        end
      end
    end
    if (COUNT == 1) assign sum_o = terms[0];
  end
endmodule
