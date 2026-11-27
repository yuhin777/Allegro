module blackwell_banked_sram #(
  parameter int BANKS = 1,
  DEPTH = 128,
  WORD_W = 128,
  localparam int ADDR_W = DEPTH > 1 ? $clog2(DEPTH) : 1
) (
  input logic clk,
  input logic [BANKS-1:0] read_enable,
  input logic [BANKS-1:0] write_enable,
  input logic [BANKS-1:0][ADDR_W-1:0] read_addr,
  input logic [BANKS-1:0][ADDR_W-1:0] write_addr,
  output logic [BANKS-1:0][WORD_W-1:0] read_q,
  input logic [BANKS-1:0][WORD_W-1:0] write_data,
  input logic [BANKS-1:0][WORD_W/8-1:0] write_byte_mask
);
  for (genvar b = 0; b < BANKS; b++) begin : bank
    logic [WORD_W-1:0] mem[DEPTH];
    always_ff @(posedge clk) begin
      if (read_enable[b]) read_q[b] <= mem[read_addr[b]];
      if (write_enable[b])
        for (int k = 0; k < WORD_W / 8; k++)
        if (write_byte_mask[b][k]) mem[write_addr[b]][8*k+:8] <= write_data[b][8*k+:8];
    end
`ifndef SYNTHESIS
    assert property (@(posedge clk) read_enable[b] |-> int'(read_addr[b]) < DEPTH);
    assert property (@(posedge clk) write_enable[b] |-> int'(write_addr[b]) < DEPTH);
    assert property (
        @(posedge clk) read_enable[b] && write_enable[b] |-> read_addr[b] != write_addr[b]);
`endif
  end
endmodule
