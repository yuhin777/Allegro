// Elastic FIFO with explicit wrap for non-power-of-two capacities. Payload
// storage is not reset; valid/count is the only authority for reading it.
`default_nettype none
module blackwell_fifo #(
    parameter int unsigned WIDTH = 32,
    parameter int unsigned DEPTH = 4,
    parameter int unsigned COUNT_W = $clog2(DEPTH+1)
) (
    input wire clk, rst_n,
    input wire in_vld_i,
    output wire in_rdy_o,
    input wire [WIDTH-1:0] in_data_i,
    output wire out_vld_o,
    input wire out_rdy_i,
    output wire [WIDTH-1:0] out_data_o,
    output wire [COUNT_W-1:0] count_o
);
    localparam int unsigned PTR_W = DEPTH < 2 ? 1 : $clog2(DEPTH);
    logic [WIDTH-1:0] data_q [DEPTH];
    logic [PTR_W-1:0] read_q, read_d, write_q, write_d;
    logic [COUNT_W-1:0] count_q, count_d;
    wire pop = out_vld_o && out_rdy_i;
    wire push = in_vld_i && in_rdy_o;
    assign in_rdy_o = int'(count_q) < DEPTH || pop;
    assign out_vld_o = count_q != 0;
    assign out_data_o = data_q[read_q];
    assign count_o = count_q;
    always_comb begin
        read_d = read_q;
        write_d = write_q;
        count_d = count_q;
        if (push) write_d = int'(write_q) == DEPTH-1 ? '0 : write_q + 1'b1;
        if (pop) read_d = int'(read_q) == DEPTH-1 ? '0 : read_q + 1'b1;
        case ({push,pop})
            2'b10: count_d = count_q + 1'b1;
            2'b01: count_d = count_q - 1'b1;
            default: ;
        endcase
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin read_q <= '0; write_q <= '0; count_q <= '0; end
        else begin
            read_q <= read_d;
            write_q <= write_d;
            count_q <= count_d;
        end
    end
    always_ff @(posedge clk) if (push) data_q[write_q] <= in_data_i;
    initial if (WIDTH < 1 || DEPTH < 1 || COUNT_W < $clog2(DEPTH+1))
        $error("Invalid FIFO geometry");
`ifndef SYNTHESIS
    assert property (@(posedge clk) disable iff (!rst_n)
        out_vld_o && !out_rdy_i |=> out_vld_o && $stable(out_data_o));
    assert property (@(posedge clk) disable iff (!rst_n)
        int'(count_q) <= DEPTH && int'(read_q) < DEPTH && int'(write_q) < DEPTH);
`endif
endmodule
`default_nettype wire
