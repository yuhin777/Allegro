module blackwell_tmem_fabric
  import blackwell_async_pkg::*;
  import blackwell_tmem_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic halt_i,
  input logic [15:0] epoch_i,
  input logic [2:0][60:0] live_i,
  input logic [5:0][127:0] rd_req_valid,
  output logic [5:0][127:0] rd_req_ready,
  input tmem_rd_req_t rd_req_payload[6][128],
  output logic [5:0][127:0] rd_rsp_valid,
  input logic [5:0][127:0] rd_rsp_ready,
  output tmem_rd_rsp_t rd_rsp_payload[6][128],
  input logic [5:0][127:0] wr_req_valid,
  output logic [5:0][127:0] wr_req_ready,
  input tmem_wr_req_t wr_req_payload[6][128],
  output logic [5:0][127:0] wr_ack_valid,
  input logic [5:0][127:0] wr_ack_ready,
  output tmem_wr_ack_t wr_ack_payload[6][128],
  output logic drained_o,
  output logic fault_o
);
  logic [3:0] drained, fault;
  logic [127:0] held_request, bad_port;
  assign drained_o = &drained && held_request == 0;
  always_ff @(posedge clk)
    if (!rst_n) fault_o <= 0;
    else if (|fault || |bad_port) fault_o <= 1;

  // The valid bit precedes the index. The cursor points to the next client
  // after the previous successful grant. Priority never displaces a held grant.
  function automatic logic [3:0] select_client(input logic [5:0] choices, input logic [2:0] cursor,
                                               input logic [2:0] preferred);
    logic [3:0] pick;
    pick = 0;
    for (int k = 5; k >= 0; k--) begin
      int c;
      c = (int'(cursor) + k) % 6;
      if (choices[c]) pick = {1'b1, 3'(c)};
    end
    if (preferred < 6 && choices[preferred]) pick = {1'b1, preferred};
    return pick;
  endfunction

  for (genvar p = 0; p < 4; p++) begin : part
    logic [31:0] rv, rr, dv, dr, wv, wr, av, ar;
    tmem_rd_req_t r[32];
    tmem_rd_rsp_t d[32];
    tmem_wr_req_t w[32];
    tmem_wr_ack_t a[32];
    blackwell_tmem_partition #(
      .PARTITION_ID(p)
    ) partition (
      .clk,
      .rst_n,
      .halt_i,
      .rd_req_valid(rv),
      .rd_req_ready(rr),
      .rd_req_payload(r),
      .rd_rsp_valid(dv),
      .rd_rsp_ready(dr),
      .rd_rsp_payload(d),
      .wr_req_valid(wv),
      .wr_req_ready(wr),
      .wr_req_payload(w),
      .wr_ack_valid(av),
      .wr_ack_ready(ar),
      .wr_ack_payload(a),
      .read_credit_o(),
      .write_credit_o(),
      .drained_o(drained[p]),
      .fault_o(fault[p])
    );
    for (genvar b = 0; b < 32; b++) begin : bank
      localparam int LANE = p * 32 + b;
      logic [3:0] read_pick, write_pick, read_lock, write_lock;
      logic [2:0] read_cursor, write_cursor;
      logic [5:0] can_read, can_write, bad_read, bad_write;
      logic [5:0] take_return, take_ack;
      wire choose_new = !halt_i && !fault_o;
      wire [2:0] read_preference = rd_req_payload[p][LANE].tag.token[15:13] == 2 ? 3'(p) : 3'd7;
      wire [2:0] write_preference = wr_req_payload[p][LANE].tag.token[15:13] == 0 ? 3'(p) : 3'd7;
      assign write_pick = write_lock[3] ? write_lock : select_client(
          can_write, write_cursor, write_preference
      );
      assign read_pick = read_lock[3] ? read_lock : select_client(
          can_read, read_cursor, read_preference
      );
      assign rv[b] = read_pick[3];
      assign wv[b] = write_pick[3];
      assign r[b] = rd_req_payload[read_pick[2:0]][LANE];
      assign w[b] = wr_req_payload[write_pick[2:0]][LANE];
      assign dr[b] = |take_return;
      assign ar[b] = |take_ack;
      assign bad_port[LANE] = |bad_read || |bad_write;
      assign held_request[LANE] = read_lock[3] || write_lock[3];
      for (genvar c = 0; c < 6; c++) begin : client
        assign bad_read[c] = rd_req_valid[c][LANE] &&
            (rd_req_payload[c][LANE].lane != 7'(LANE) || rd_req_payload[c][LANE].tag.client !=
             4'(c) || rd_req_payload[c][LANE].tag.id.epoch != epoch_i);
        assign bad_write[c] = wr_req_valid[c][LANE] &&
            (wr_req_payload[c][LANE].lane != 7'(LANE) || wr_req_payload[c][LANE].tag.client !=
             4'(c) || wr_req_payload[c][LANE].tag.id.epoch != epoch_i || c == 4);
        assign can_write[c] = choose_new && wr_req_valid[c][LANE] && !bad_write[c];
        assign can_read[c] = choose_new && rd_req_valid[c][LANE] && !bad_read[c] &&
            !(wv[b] && wr[b] && w[b].word == rd_req_payload[c][LANE].word);
        assign wr_req_ready[c][LANE] = write_pick == {1'b1, 3'(c)} && wr[b];
        assign rd_req_ready[c][LANE] = read_pick == {1'b1, 3'(c)} && rr[b];
        assign rd_rsp_valid[c][LANE] = dv[b] && d[b].tag.client == 4'(c);
        assign rd_rsp_payload[c][LANE] = d[b];
        assign take_return[c] = rd_rsp_ready[c][LANE] && d[b].tag.client == 4'(c);
        assign wr_ack_valid[c][LANE] = av[b] && a[b].tag.client == 4'(c);
        assign wr_ack_payload[c][LANE] = a[b];
        assign take_ack[c] = wr_ack_ready[c][LANE] && a[b].tag.client == 4'(c);
      end
      always_ff @(posedge clk) begin
        if (!rst_n) begin
          read_lock <= 0;
          write_lock <= 0;
          read_cursor <= 0;
          write_cursor <= 0;
        end else begin
          read_lock <= rv[b] && !rr[b] ? read_pick : '0;
          write_lock <= wv[b] && !wr[b] ? write_pick : '0;
          if (rv[b] && rr[b]) read_cursor <= read_pick[2:0] == 5 ? 0 : read_pick[2:0] + 1'b1;
          if (wv[b] && wr[b]) write_cursor <= write_pick[2:0] == 5 ? 0 : write_pick[2:0] + 1'b1;
        end
      end
    end
  end
endmodule
