// All 64 cells and the tag path capture on the same enables.
// Enables 0 through 3 follow issue order. Enables 4, 5 and 6 capture the tails.
module blackwell_fp_dot_control #(
  parameter bit HAS_WIDE = 1,
  parameter bit HAS_LOW = 1,
  parameter bit WIDE_SPILL = HAS_LOW && HAS_WIDE
) (
  input logic clk,
  input logic rst_n,
  input logic req_valid,
  input logic req_low,
  input logic allow_spill,
  output logic req_ready,
  input logic wide_ready,
  input logic low_ready,
  output logic wide_valid,
  output logic low_valid,
  output logic [6:0] advance,
  output logic [3:0] low_mode,
  output logic spill_write,
  output logic spill_valid
);
  logic [3:0] valid;
  logic [3:0] ready;
  logic tail_ready;
  logic wide_full, low_sum_full, low_pack_full;
  logic wide_space, low_sum_space, low_pack_space;
  assign wide_valid = wide_full || spill_valid;
  assign low_valid = low_pack_full;
  assign wide_space = !wide_full || wide_ready || (WIDE_SPILL && !spill_valid && allow_spill);
  assign low_pack_space = !low_pack_full || low_ready;
  assign low_sum_space = !low_sum_full || low_pack_space;
  assign tail_ready = low_mode[3] ? low_sum_space : wide_space;
  assign req_ready = ready[0];
  for (genvar s = 0; s < 4; s++) begin : g_stage
    logic incoming, incoming_low;
    if (s == 0) begin
      assign incoming = req_valid, incoming_low = req_low;
    end else begin
      assign incoming = valid[s-1], incoming_low = low_mode[s-1];
    end
    assign ready[s] = !(&valid[3:s]) || tail_ready;
    assign advance[s] = rst_n && ready[s] && incoming;
    if (HAS_LOW && HAS_WIDE) begin
      always_ff @(posedge clk) if (advance[s]) low_mode[s] <= incoming_low;
    end else assign low_mode[s] = HAS_LOW;
    always_ff @(posedge clk) begin
      if (!rst_n) valid[s] <= 0;
      else if (ready[s]) valid[s] <= incoming;
    end
  end
  assign advance[4] = rst_n && HAS_WIDE && wide_space && valid[3] && !low_mode[3];
  assign advance[5] = rst_n && HAS_LOW && low_sum_space && valid[3] && low_mode[3];
  assign advance[6] = rst_n && HAS_LOW && low_pack_space && low_sum_full;
  assign spill_write = rst_n && WIDE_SPILL && wide_full && wide_space && (!wide_ready || spill_valid);
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      wide_full <= 0;
      spill_valid <= 0;
      low_sum_full <= 0;
      low_pack_full <= 0;
    end else begin
      if (wide_space) wide_full <= advance[4];
      spill_valid <= spill_write || (spill_valid && !wide_ready);
      if (low_sum_space) low_sum_full <= advance[5];
      if (low_pack_space) low_pack_full <= advance[6];
    end
  end
endmodule
