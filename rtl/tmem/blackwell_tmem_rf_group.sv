// Implements frozen A1: doc/specs/blackwell_tmem_rf_group.md
module blackwell_tmem_rf_group
  import blackwell_async_pkg::*;
(
  input logic [RF_THREADS-1:0] pending_i,
  input logic [RF_THREADS-1:0] valid_i,
  input logic [RF_THREADS * TMEM_ADDR_W-1:0] cell0_i,
  input logic [RF_THREADS * TMEM_ADDR_W-1:0] cell1_i,
  input logic second_i,
  input logic pack16_i,
  input logic writing_i,
  input logic [RF_BEAT_W-1:0] rf_data_i,
  output logic all_valid_o,
  output logic [RF_THREADS-1:0] selected_o,
  output logic [TMEM_LANE_MASK_W-1:0] rd_lane_mask_o,
  output logic [TMEM_COLUMN_BUS_W-1:0] rd_column_o,
  output logic [TMEM_COLUMN_BUS_W-1:0] wr_column_o,
  output logic [TMEM_DATA_W-1:0] wr_data_o,
  output logic [TMEM_BYTE_MASK_W-1:0] wr_byte_mask_o
);
    logic [127:0] bank_used;
    logic [31:0] a;
    logic [6:0] lane;
    logic [15:0] word_col;
    logic [1:0] slot;
    logic [3:0] byte_mask;
    logic fits;
    always_comb begin
      int t;
      t = 0;
        all_valid_o=1'b1; selected_o='0; bank_used='0;
        rd_lane_mask_o='0; rd_column_o='0;
        wr_column_o='0; wr_byte_mask_o='0; wr_data_o='0;
        a='0; lane='0; word_col='0; slot='0; byte_mask='0; fits=1'b0;
        for (t=0;t<32;t++) begin
            a=second_i ? cell1_i[t*32+:32] : cell0_i[t*32+:32];
            lane=a[22:16]; word_col={a[15:2],2'b00}; slot=a[1:0];
            byte_mask=pack16_i ? 4'b0011 : 4'b1111;
            if (pending_i[t] && !valid_i[t]) all_valid_o=1'b0;
            fits=pending_i[t] && valid_i[t] &&
                (!bank_used[lane] ||
                 (rd_column_o[lane*16+:16] == word_col &&
                  (!writing_i ||
                   (wr_byte_mask_o[lane*16+slot*4+:4] & byte_mask) == 0)));
            if (fits) begin
                selected_o[t]=1'b1;
                bank_used[lane]=1'b1;
                rd_lane_mask_o[lane]=1'b1;
                rd_column_o[lane*16+:16]=word_col;
                wr_column_o[lane*16+:16]=word_col;
                wr_byte_mask_o[lane*16+slot*4+:4]=byte_mask;
                if (pack16_i)
                    wr_data_o[lane*128+slot*32+:32]=second_i ?
                        {16'b0,rf_data_i[t*32+16+:16]} :
                        {16'b0,rf_data_i[t*32+:16]};
                else wr_data_o[lane*128+slot*32+:32]=rf_data_i[t*32+:32];
            end
        end
    end
endmodule
