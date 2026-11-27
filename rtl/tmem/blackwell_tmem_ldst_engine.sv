module blackwell_tmem_ldst_engine
  import blackwell_async_pkg::*;
  import blackwell_tmem_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic stop_i,
  input logic issue_valid,
  output logic issue_ready,
  input ldst_issue_t issue_payload,
  input logic rf_store_valid,
  output logic rf_store_ready,
  input rf_beat_t rf_store_payload,
  output logic rf_load_valid,
  input logic rf_load_ready,
  output rf_beat_t rf_load_payload,
  output logic [127:0] rd_req_valid,
  input logic [127:0] rd_req_ready,
  output tmem_rd_req_t rd_req_payload[128],
  input logic [127:0] rd_rsp_valid,
  output logic [127:0] rd_rsp_ready,
  input tmem_rd_rsp_t rd_rsp_payload[128],
  output logic [127:0] wr_req_valid,
  input logic [127:0] wr_req_ready,
  output tmem_wr_req_t wr_req_payload[128],
  input logic [127:0] wr_ack_valid,
  output logic [127:0] wr_ack_ready,
  input tmem_wr_ack_t wr_ack_payload[128],
  output logic pin_req_valid,
  input logic pin_req_ready,
  output tmem_pin_req_t pin_req_payload,
  input logic pin_rsp_valid,
  output logic pin_rsp_ready,
  input tmem_pin_rsp_t pin_rsp_payload,
  output logic unpin_valid,
  input logic unpin_ready,
  output tmem_unpin_t unpin_payload,
  output logic done_valid,
  input logic done_ready,
  output op_done_t done_payload,
  output logic track_done_valid,
  input logic track_done_ready,
  output rf_track_done_t track_done_payload,
  output logic drained_o
);
  typedef enum logic [2:0] {
    IDLE,
    PIN,
    PIN_WAIT,
    DATA,
    RELEASE,
    REPORT,
    TRACK
  } stage_t;
  stage_t stage[2];
  ldst_issue_t record_q[2];
  logic [1:0] pin_match;
  logic [3:0] selected, active, cursor, locked, locked_source, output_ready;
  localparam int PIN_PORT = 0, RELEASE_PORT = 1, DONE_PORT = 2, TRACK_PORT = 3;
  wire direction = issue_payload.cmd.store;
  assign issue_ready = rst_n && stage[direction] == IDLE;
  assign drained_o = stage[0] == IDLE && stage[1] == IDLE;
  assign output_ready = {track_done_ready, done_ready, unpin_ready, pin_req_ready};
  for (genvar k = 0; k < 4; k++) begin : control_port
    localparam stage_t SOURCE = k == PIN_PORT ? PIN :
        k == RELEASE_PORT ? RELEASE : k == DONE_PORT ? REPORT : TRACK;
    assign selected[k] = locked[k] ? locked_source[k] :
        stage[cursor[k]] == SOURCE ? cursor[k] : !cursor[k];
    assign active[k] = stage[selected[k]] == SOURCE;
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        locked[k] <= 0;
        cursor[k] <= 0;
      end else begin
        locked[k] <= active[k] && !output_ready[k];
        if (active[k]) locked_source[k] <= selected[k];
        if (active[k] && output_ready[k]) cursor[k] <= !selected[k];
      end
    end
  end
  assign {track_done_valid, done_valid, unpin_valid, pin_req_valid} = active;
  assign pin_req_payload = '{id: record_q[selected[0]].cmd.id, user: selected[0] ? 3'd4 : 3'd3};
  assign unpin_payload = '{id: record_q[selected[1]].cmd.id, user: selected[1] ? 3'd4 : 3'd3};
  assign done_payload = '{id: record_q[selected[2]].cmd.id};
  assign track_done_payload = '{
          slot: record_q[selected[3]].slot,
          id: record_q[selected[3]].cmd.id
      };
  assign pin_rsp_ready = rst_n;
  for (genvar dir = 0; dir < 2; dir++)
    assign pin_match[dir] = stage[dir] == PIN_WAIT && pin_rsp_payload.id == record_q[dir].cmd.id;
  // LD has one 16 B buffer per lane. The next word may issue while this word
  // owns its buffer; its return can fire exactly when the last old cell leaves.
  logic [31:0] sent, prefetched, returned, send_current, send_next, receive_current, receive_next;
  logic [31:0][127:0] word_buffer, returned_data;
  logic [6:0] word_index, beat_index;
  logic [1:0] cell_index;
  wire [8:0] ld_base = record_q[0].cmd.base[8:0];
  wire [8:0] ld_end = ld_base + (record_q[0].cmd.x32 ? 9'd31 : 9'd15);
  wire [6:0] last_word = ld_end[8:2];
  wire last_cell = cell_index == 3 || (word_index == last_word && cell_index == ld_end[1:0]);
  assign rf_load_valid = stage[0] == DATA && (&returned);
  assign rf_load_payload.id = record_q[0].cmd.id;
  assign rf_load_payload.index = beat_index;
  assign rf_load_payload.last = beat_index == (record_q[0].cmd.x32 ? 31 : 15);
  wire ld_fire = rf_load_valid && rf_load_ready;
  wire rotate = ld_fire && last_cell && !rf_load_payload.last;

  // ST retains a single 128-byte RF beat, one issued and one retired prefix
  // per lane. ACKs may lag several RF beats behind write acceptance.
  logic [1023:0] store_buffer;
  logic store_full;
  logic [4:0] store_beats;
  logic [31:0][4:0] sent_count, ack_count;
  logic [31:0] write_fire, ack_fire, all_sent, all_acked;
  wire [4:0] write_index = store_beats - 1'b1;
  wire [8:0] column = record_q[1].cmd.base[8:0] + 9'(write_index);
  wire store_replace = store_full && (&all_sent);
  assign rf_store_ready = stage[1] == DATA && store_beats < 16 &&
      (!store_full || store_replace);
  wire st_fire = rf_store_valid && rf_store_ready;
  function automatic logic [15:0] read_mask(input logic [6:0] word_number, input logic [8:0] first,
                                            last);
    logic [15:0] mask;
    for (int c = 0; c < 4; c++)
    mask[c*4+:4] = {4{({word_number, 2'(c)} >= first) && ({word_number, 2'(c)} <= last)}};
    return mask;
  endfunction
  for (genvar lane = 0; lane < 128; lane++) begin : port
    localparam int T = lane % 32;
    wire in_load = record_q[0].cmd.base[22:21] == 2'(lane / 32) && stage[0] == DATA;
    wire in_store = record_q[1].cmd.base[22:21] == 2'(lane / 32) && stage[1] == DATA;
    wire [6:0] requested_word = sent[T] ? word_index + 1'b1 : word_index;
    assign rd_req_valid[lane] = in_load &&
        (!sent[T] || (word_index != last_word && !prefetched[T]));
    assign rd_req_payload[lane] = '{
            tag: '{
                id: record_q[0].cmd.id,
                client: 4'd5,
                token: {1'b0, requested_word, 6'(T), 2'b00}
            },
            lane: 7'(lane),
            word: requested_word,
            byte_mask: read_mask(requested_word, ld_base, ld_end)
        };
    assign rd_rsp_ready[lane] = !returned[T] || rotate;
    assign wr_req_valid[lane] = in_store && store_full &&
        sent_count[T] == write_index;
    assign wr_req_payload[lane] = '{
            tag: '{
                id: record_q[1].cmd.id,
                client: 4'd5,
                token: {1'b1, 7'(write_index), 6'(T), 2'b00}
            },
            lane: 7'(lane),
            word: column[8:2],
            byte_mask: 16'h000f << (4 * column[1:0]),
            data: 128'(store_buffer[T*32+:32]) << (32 * column[1:0])
        };
    assign wr_ack_ready[lane] = rst_n;
`ifndef SYNTHESIS
    wire [15:0] rd_token = rd_rsp_payload[lane].tag.token;
    wire match_base = in_load && rd_rsp_payload[lane].tag.id == record_q[0].cmd.id &&
        rd_rsp_payload[lane].tag.client == 5 && !rd_token[15] && rd_token[7:0] == {6'(T), 2'b00};
    wire current_match = match_base && rd_token[14:8] == word_index && sent[T] && !returned[T];
    wire next_match = match_base && word_index != last_word &&
        rd_token[14:8] == word_index + 1'b1 && prefetched[T];
    always_ff @(posedge clk) begin
      if (rst_n && rd_rsp_valid[lane]) assert (current_match || next_match);
      if (rst_n && wr_ack_valid[lane]) begin
        assert (in_store && wr_ack_payload[lane].tag.id == record_q[1].cmd.id &&
                wr_ack_payload[lane].tag.client == 5 && ack_count[T] < sent_count[T] &&
                wr_ack_payload[lane].tag.token == {1'b1, 7'(ack_count[T]), 6'(T), 2'b00})
          else $error("TMEM_STORE_ACK");
      end
    end
`endif
  end
  for (genvar t = 0; t < 32; t++) begin : thread_route
    wire [6:0] ld_lane = {record_q[0].cmd.base[22:21], 5'(t)};
    wire [6:0] st_lane = {record_q[1].cmd.base[22:21], 5'(t)};
    wire req_fire = rd_req_valid[ld_lane] && rd_req_ready[ld_lane];
    wire ret_fire = rd_rsp_valid[ld_lane] && rd_rsp_ready[ld_lane];
    assign send_current[t] = req_fire && !sent[t];
    assign send_next[t] = req_fire && sent[t];
    assign receive_current[t] = ret_fire && rd_rsp_payload[ld_lane].tag.token[14:8] == word_index;
    assign receive_next[t] = ret_fire && !receive_current[t];
    assign returned_data[t] = rd_rsp_payload[ld_lane].data;
    assign rf_load_payload.data[t*32+:32] = word_buffer[t][int'(cell_index)*32+:32];
    assign write_fire[t] = wr_req_valid[st_lane] && wr_req_ready[st_lane];
    assign ack_fire[t] = wr_ack_valid[st_lane] && wr_ack_ready[st_lane];
    assign all_sent[t] = sent_count[t] == store_beats || write_fire[t];
    assign all_acked[t] = ack_count[t] == 16 || (ack_count[t] == 15 && ack_fire[t]);
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      stage[0] <= IDLE;
      stage[1] <= IDLE;
      store_full <= 0;
    end else begin
      if (issue_valid && issue_ready) begin
        stage[direction] <= PIN;
        record_q[direction] <= issue_payload;
        if (direction) begin
          sent_count <= '0;
          ack_count <= '0;
          store_beats <= 0;
          store_full <= 0;
        end else begin
          sent <= 0;
          returned <= 0;
          prefetched <= 0;
          beat_index <= 0;
          word_index <= issue_payload.cmd.base[8:2];
          cell_index <= issue_payload.cmd.base[1:0];
        end
      end
      if (pin_req_valid && pin_req_ready) stage[selected[0]] <= PIN_WAIT;
      if (pin_rsp_valid && pin_rsp_ready) stage[pin_match[1]] <= DATA;
      if (unpin_valid && unpin_ready) stage[selected[1]] <= REPORT;
      if (done_valid && done_ready) stage[selected[2]] <= TRACK;
      if (track_done_valid && track_done_ready) stage[selected[3]] <= IDLE;
      if (stage[0] == DATA) begin
        sent <= rotate ? prefetched | send_next : sent | send_current;
        prefetched <= rotate ? '0 : prefetched | send_next;
        returned <= rotate ? receive_next : returned | receive_current;
        for (int t = 0; t < 32; t++)
        if (receive_current[t] || receive_next[t]) word_buffer[t] <= returned_data[t];
        if (ld_fire) begin
          beat_index <= beat_index + 1'b1;
          cell_index <= cell_index + 1'b1;
          if (rotate) word_index <= word_index + 1'b1;
          if (rf_load_payload.last) stage[0] <= RELEASE;
        end
      end
      if (stage[1] == DATA) begin
        if (store_replace) store_full <= 0;
        if (st_fire) begin
          store_buffer <= rf_store_payload.data;
          store_full <= 1;
          store_beats <= store_beats + 1'b1;
        end
        for (int t = 0; t < 32; t++) begin
          if (write_fire[t]) sent_count[t] <= sent_count[t] + 1'b1;
          if (ack_fire[t]) ack_count[t] <= ack_count[t] + 1'b1;
        end
        if (&all_acked) stage[1] <= RELEASE;
      end
    end
  end
`ifndef SYNTHESIS
  wire [16:0] issue_limit = {1'b0, issue_payload.cmd.base[15:0]} +
      (issue_payload.cmd.x32 ? 17'd32 : 17'd16);
  wire bad_issue = issue_payload.cmd.id.issuer[4:0] != 0 || issue_payload.cmd.id.seq == '1 ||
      issue_payload.cmd.base[31:16] != {9'd0, issue_payload.cmd.id.issuer[6:5], 5'd0} ||
      issue_limit > 512 || (direction && issue_payload.cmd.x32);
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (issue_valid) assert (!bad_issue) else $error("TMEM_RF_ISSUE");
      if (pin_rsp_valid) assert ($onehot(pin_match));
      if (rf_store_valid && store_beats < 16 && stage[1] inside {PIN, PIN_WAIT, DATA})
        assert (rf_store_payload.id == record_q[1].cmd.id &&
                rf_store_payload.index == 7'(store_beats) &&
                rf_store_payload.last == (store_beats == 15));
    end
  end
`endif
endmodule
