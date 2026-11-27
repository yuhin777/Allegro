module blackwell_tc_scale_b_snapshot
  import blackwell_async_pkg::*;
  import blackwell_tc_pkg::*;
  import blackwell_tmem_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic [15:0] epoch_i,
  input mma_live_t [2:0] live_i,
  input logic start_valid,
  output logic start_ready,
  input prepare_t start_payload,
  input logic release_valid,
  output logic release_ready,
  input async_id_t release_payload,
  output logic [127:0] rd_req_valid,
  input logic [127:0] rd_req_ready,
  output tmem_rd_req_t rd_req_payload[128],
  input logic [127:0] rd_rsp_valid,
  output logic [127:0] rd_rsp_ready,
  input tmem_rd_rsp_t rd_rsp_payload[128],
  input logic [3:0][71:0] query,
  output logic [3:0][256:0] view,
  output logic [2:0] ready,
  output logic [2:0] quiescent,
  output logic drained_o
);
  typedef struct packed {
    async_id_t  id;
    logic [1:0] rec;
    logic [8:0] base;
    logic [3:0] columns;
    logic [1:0] scale_id;
    logic [2:0] factors;
  } context_t;
  context_t ctx[2];
  logic [1:0] active, complete;
  logic [3:0][31:0][7:0][31:0] cells;
  logic [2:0] needed[2];
  logic [1:0][31:0][2:0] sent, received;
  logic req_found, req_bank, req_lock, held_bank;
  logic [4:0] req_lane, held_lane;
  logic [1:0] req_atom, held_atom;
  logic [1:0] release_match;
  logic [3:0] new_columns;
  assign new_columns = 4'd2 << start_payload.cmd.n_code;
`ifndef SYNTHESIS
  logic legal_start, start_live;
  always_comb begin
    start_live = 0;
    for (int i = 0; i < 3; i++)
    start_live |= live_i[i].valid && live_i[i].rec == start_payload.rec &&
        live_i[i].id == start_payload.cmd.id;
    legal_start = start_live && start_payload.cmd.id.epoch == epoch_i &&
        start_payload.cmd.n_code < 3 && start_payload.cmd.scale_b < 512 &&
        start_payload.cmd.scale_b + 32'(new_columns) <= 512 && start_payload.cmd.scale_vec != 0 &&
        int'(start_payload.cmd.scale_b_id) + (1 << (start_payload.cmd.scale_vec - 1)) <= 4;
  end
  always_ff @(posedge clk) if (rst_n) begin
    if (start_valid) assert (legal_start);
    if (release_valid) assert ($onehot(release_match));
  end
`endif
  always_comb begin
    ready = 0;
    quiescent = '1;
    for (int b = 0; b < 2; b++) begin
      needed[b] = 0;
      for (int c = 0; c < 8; c++)
      if (c < ctx[b].columns) needed[b][(int'(ctx[b].base[1:0])+c)/4] = 1;
      complete[b] = active[b];
      for (int r = 0; r < 32; r++) complete[b] &= (received[b][r] & needed[b]) == needed[b];
      if (active[b]) begin
        ready[ctx[b].rec] = complete[b];
        quiescent[ctx[b].rec] = complete[b];
      end
    end
  end
  assign start_ready = !active[start_payload.bank];
  for (genvar b = 0; b < 2; b++)
    assign release_match[b] = complete[b] && ctx[b].id == release_payload;
  assign release_ready = (|release_match);
  assign drained_o = active == 0;
  always_comb begin
    req_found = req_lock;
    req_bank = held_bank;
    req_lane = held_lane;
    req_atom = held_atom;
    for (int i = 0; i < 3; i++)
    for (int b = 0; b < 2; b++)
    for (int r = 0; r < 32; r++)
    for (int a = 0; a < 3; a++)
    if (!req_found && live_i[i].valid && active[b] && ctx[b].id == live_i[i].id &&
        needed[b][a] && !sent[b][r][a]) begin
      req_found = 1;
      req_bank = 1'(b);
      req_lane = 5'(r);
      req_atom = 2'(a);
    end
    rd_req_valid = 0;
    rd_rsp_ready = '1;
    for (int l = 0; l < 128; l++) rd_req_payload[l] = '0;
    if (req_found) begin
      rd_req_valid[7'(req_lane)] = 1;
      rd_req_payload[7'(req_lane)].tag = '{ctx[req_bank].id, 4'd4, {9'b0, req_lane, req_atom}};
      rd_req_payload[7'(req_lane)].lane = 7'(req_lane);
      rd_req_payload[7'(req_lane)].word = ctx[req_bank].base[8:2] + 7'(req_atom);
      for (int c = 0; c < 8; c++)
      for (int g = 0; g < 4; g++)
      if (c < ctx[req_bank].columns && g < ctx[req_bank].factors &&
          (c + int'(ctx[req_bank].base[1:0])) / 4 == int'(req_atom))
        rd_req_payload[7'(req_lane)].byte_mask[
            4*((c+int'(ctx[req_bank].base[1:0]))%4)+int'(ctx[req_bank].scale_id)+g] = 1;
    end
    view = '0;
    for (int q = 0; q < 4; q++)
    for (int b = 0; b < 2; b++)
    if (complete[b] && ctx[b].id == query[q][71:14] && int'(query[q][13:8]) * 8 ==
        int'(query[q][7:0]) && int'(query[q][7:0]) < int'(ctx[b].columns) * 32) begin
      view[q][256] = 1;
      for (int j = 0; j < 8; j++)
      view[q][32*j+:32] = cells[b][int'(query[q][4:0])+j][query[q][7:5]];
    end
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      active <= 0;
      req_lock <= 0;
    end else begin
      if (start_valid && start_ready) begin
        ctx[start_payload.bank] <= '{
            start_payload.cmd.id,
            start_payload.rec,
            start_payload.cmd.scale_b[8:0],
            new_columns,
            start_payload.cmd.scale_b_id,
            3'(1 << (start_payload.cmd.scale_vec - 1))
        };
        active[start_payload.bank] <= 1;
        sent[start_payload.bank] <= '0;
        received[start_payload.bank] <= '0;
      end
      if (release_valid && release_ready)
        for (int b = 0; b < 2; b++) if (release_match[b]) active[b] <= 0;
      req_lock <= req_found && !rd_req_ready[7'(req_lane)];
      if (req_found) begin
        held_bank <= req_bank;
        held_lane <= req_lane;
        held_atom <= req_atom;
        if (rd_req_ready[7'(req_lane)]) sent[req_bank][req_lane][req_atom] <= 1;
      end
      for (int l = 0; l < 128; l++) begin
        if (rd_rsp_valid[l]) begin
          logic b;
          logic [1:0] a;
          b = active[1] && rd_rsp_payload[l].tag.id == ctx[1].id;
          a = rd_rsp_payload[l].tag.token[1:0];
`ifndef SYNTHESIS
          assert (l < 32 && active[b] && ctx[b].id == rd_rsp_payload[l].tag.id &&
                  rd_rsp_payload[l].tag.client == 4 && rd_rsp_payload[l].tag.token[15:2] == 14'(l) &&
                  a < 3 && sent[b][l%32][a] && !received[b][l%32][a]);
`endif
          received[b][l%32][a] <= 1;
          for (int c = 0; c < 8; c++)
          if (c < ctx[b].columns && (int'(ctx[b].base[1:0]) + c) / 4 == int'(a))
            for (int g = 0; g < 4; g++)
            cells[{
              1'b0, b
            }][l%32][c][g*8+:8] <= g < ctx[b].factors ? rd_rsp_payload[l].data[
                8*(4*((int'(ctx[b].base[1:0])+c)%4)+int'(ctx[b].scale_id)+g)+:8] : 0;
        end
      end
    end
  end
endmodule
