module blackwell_tmem_partition
  import blackwell_async_pkg::*;
  import blackwell_tmem_pkg::*;
#(
  parameter int unsigned PARTITION_ID = 0
) (
  input logic clk,
  input logic rst_n,
  input logic halt_i,
  input logic [31:0] rd_req_valid,
  output logic [31:0] rd_req_ready,
  input tmem_rd_req_t rd_req_payload[32],
  output logic [31:0] rd_rsp_valid,
  input logic [31:0] rd_rsp_ready,
  output tmem_rd_rsp_t rd_rsp_payload[32],
  input logic [31:0] wr_req_valid,
  output logic [31:0] wr_req_ready,
  input tmem_wr_req_t wr_req_payload[32],
  output logic [31:0] wr_ack_valid,
  input logic [31:0] wr_ack_ready,
  output tmem_wr_ack_t wr_ack_payload[32],
  output logic [31:0][1:0] read_credit_o,
  output logic [1:0] write_credit_o,
  output logic drained_o,
  output logic fault_o
);
  logic [31:0] sampling, writing, read_busy, rd_fault, wr_fault;
  logic [31:0][6:0] read_addr, write_addr;
  logic [31:0][15:0] write_mask;
  logic [31:0][127:0] read_q, write_data;

  // A frame is occupied from request acceptance through the last bank ACK.
  // During its first cycle it also owns the single R_W data register.
  logic [1:0][31:0] outstanding, after_ack, retire;
  mem_tag_t ack_tag[2][32];
  logic oldest, writing_slot, free_slot;
  logic [ 1:0] free_frame;
  wire  [31:0] write_fire = wr_req_valid & wr_req_ready;
  assign after_ack = outstanding & ~retire;
  assign free_frame = {after_ack[1] == 0, after_ack[0] == 0};
  assign write_credit_o = 2'(free_frame[0]) + 2'(free_frame[1]);
  assign free_slot = !free_frame[0];
  assign drained_o = read_busy == 0 && outstanding == 0;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      outstanding <= '0;
      writing <= '0;
      oldest <= 0;
      writing_slot <= 0;
      fault_o <= 0;
    end else begin
      writing <= write_fire;
      outstanding <= after_ack;
      if (|write_fire) begin
        writing_slot <= free_slot;
        outstanding[free_slot] <= write_fire;
        oldest <= after_ack[!free_slot] != 0 ? !free_slot : free_slot;
      end else if (after_ack[oldest] == 0) oldest <= !oldest;
      if (|rd_fault || |wr_fault) fault_o <= 1;
    end
  end

  for (genvar b = 0; b < 32; b++) begin : bank
    localparam logic [6:0] LANE = 7'(32 * PARTITION_ID + b);
    logic [1:0] ack_available;
    logic selected, ack_held, response_held;
    for (genvar f = 0; f < 2; f++) begin : ack
      assign ack_available[f] = outstanding[f][b] && !(writing[b] && writing_slot == 1'(f));
      assign retire[f][b] = wr_ack_valid[b] && wr_ack_ready[b] && selected == 1'(f);
    end
    assign selected = ack_available[oldest] ? oldest : !oldest;
    assign wr_ack_valid[b] = (|ack_available) && (!halt_i || ack_held);
    assign wr_ack_payload[b] = '{tag: ack_tag[selected][b], status: OK};
    logic duplicate_wr;
    assign duplicate_wr = (after_ack[0][b] && ack_tag[0][b] == wr_req_payload[b].tag) ||
        (after_ack[1][b] && ack_tag[1][b] == wr_req_payload[b].tag);
    assign wr_fault[b] = wr_req_valid[b] && (wr_req_payload[b].lane != LANE || duplicate_wr);
    assign wr_req_ready[b] = !halt_i && !fault_o && |free_frame && !wr_fault[b];
    always_ff @(posedge clk) begin
      if (write_fire[b]) begin
        write_addr[b] <= wr_req_payload[b].word;
        write_mask[b] <= wr_req_payload[b].byte_mask;
        write_data[b] <= wr_req_payload[b].data;
        ack_tag[free_slot][b] <= wr_req_payload[b].tag;
      end
    end

    // The synchronous macro output is the third physical return slot.
    // Its contents move only when the two-entry response queue can accept.
    logic q_valid, deliver, move_q;
    logic [1:0] count;
    logic head, tail;
    mem_tag_t sample_tag, q_tag;
    logic [15:0] sample_mask, q_mask;
    tmem_rd_rsp_t response[2];
    logic [127:0] masked_data;
    for (genvar i = 0; i < 16; i++) assign masked_data[8*i+:8] = read_q[b][8*i+:8] & {8{q_mask[i]}};
    assign rd_rsp_valid[b] = count != 0 && (!halt_i || response_held);
    assign rd_rsp_payload[b] = response[head];
    assign deliver = rd_rsp_valid[b] && rd_rsp_ready[b];
    assign move_q = q_valid && (count < 2 || deliver) && (!halt_i || sampling[b]);
    wire [2:0] reservations = 3'(count) + 3'(q_valid) + 3'(sampling[b]);
    assign read_credit_o[b] = 2'(3'd3 - reservations + 3'(deliver));
    assign read_busy[b] = reservations != 0;
    logic duplicate_rd;
    assign duplicate_rd = (sampling[b] && sample_tag == rd_req_payload[b].tag) ||
        (q_valid && q_tag == rd_req_payload[b].tag) ||
        (count != 0 && !deliver && response[head].tag == rd_req_payload[b].tag) ||
        (count == 2 && response[!head].tag == rd_req_payload[b].tag);
    assign rd_fault[b] = (rd_req_valid[b] && (rd_req_payload[b].lane != LANE || duplicate_rd)) ||
        reservations > 3 || (sampling[b] && q_valid && !move_q && !halt_i);
    assign rd_req_ready[b] = !halt_i && !fault_o && !rd_fault[b] && read_credit_o[b] != 0 &&
        !(write_fire[b] && wr_req_payload[b].word == rd_req_payload[b].word);
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        ack_held <= 0;
        response_held <= 0;
        sampling[b] <= 0;
        q_valid <= 0;
        count <= 0;
        head <= 0;
        tail <= 0;
      end else begin
        ack_held <= wr_ack_valid[b] && !wr_ack_ready[b];
        response_held <= rd_rsp_valid[b] && !rd_rsp_ready[b];
        sampling[b] <= rd_req_valid[b] && rd_req_ready[b];
        if (rd_req_valid[b] && rd_req_ready[b]) begin
          read_addr[b] <= rd_req_payload[b].word;
          sample_tag <= rd_req_payload[b].tag;
          sample_mask <= rd_req_payload[b].byte_mask;
        end
        if (move_q) begin
          response[tail] <= '{tag: q_tag, data: masked_data, status: OK};
          tail <= !tail;
          q_valid <= 0;
        end
        if (sampling[b]) begin
          q_valid <= 1;
          q_tag <= sample_tag;
          q_mask <= sample_mask;
        end
        if (deliver) head <= !head;
        count <= count + 2'(move_q) - 2'(deliver);
      end
    end
  end

  blackwell_banked_sram #(
    .BANKS (32),
    .DEPTH (128),
    .WORD_W(128)
  ) storage (
    .clk,
    .read_enable(sampling & {32{rst_n}}),
    .read_addr,
    .read_q,
    .write_enable(writing & {32{rst_n}}),
    .write_addr,
    .write_data,
    .write_byte_mask(write_mask)
  );
endmodule
