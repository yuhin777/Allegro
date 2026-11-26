module b_loader_tb;
  import blackwell_async_pkg::*;
  import blackwell_tc_pkg::*;
  import blackwell_smem_pkg::*;
  bit clk;
  always #5 clk = ~clk;
  logic rst_n, halt_i, drained_o, fault_o, load_valid, load_ready, result_valid, result_ready;
  logic [15:0] epoch_i = 1;
  mma_live_t [2:0] live_i;
  b_load_t load_payload;
  op_done_t result_payload;
  logic [3:0] data_valid, data_ready;
  b_data_t data_payload;
  logic [7:0] sm_rd_req_valid, sm_rd_req_ready, sm_rd_rsp_valid, sm_rd_rsp_ready;
  smem_rd_req_t sm_rd_req_payload[8];
  smem_rd_rsp_t sm_rd_rsp_payload[8];
  smem_rd_rsp_t [7:0] driven_rsp;
  bit drive_edge;
  for (genvar g = 0; g < 8; g++) always @(drive_edge) sm_rd_rsp_payload[g] <= driven_rsp[g];
  blackwell_tc_b_loader dut (.*);

  localparam int MAX_COMMANDS = 96;
  b_load_t commands[MAX_COMMANDS];
  int nblocks[MAX_COMMANDS];
  logic [2047:0] blocks[MAX_COMMANDS][32];
  logic [15:0] required[MAX_COMMANDS][32][16], sent[MAX_COMMANDS][32][16];
  logic [31:0] atoms[MAX_COMMANDS][32][16][16];
  logic [15:0] masks[MAX_COMMANDS][32][16][16];
  typedef struct packed {
    smem_rd_rsp_t rsp;
    int available;
  } reply_t;
  reply_t replies[8][$];
  int next_block[4], next_id[4];
  bit inject_final_error;
  int nc, issued, retired, tick, anchor, total_requests, total_blocks;
  function automatic logic [7:0] memory(int addr);
    return 8'((addr * 'h9d + (addr >> 3) * 'h57 + (addr >> 9) * 'h37 + 'hab) ^ (addr >> 12));
  endfunction
  task automatic read_file;
    int fd, kind, dtype, tr, sz, parts;
    logic [  63:0] desc;
    logic [2047:0] expected;
    logic [  31:0] addr;
    logic [  15:0] mask;
    fd = $fopen("b_vectors.txt", "r");
    if ($fscanf(fd, "%d", nc) != 1 || nc > MAX_COMMANDS) $fatal(1, "b_vectors.txt");
    for (int i = 0; i < nc; i++) begin
      if ($fscanf(fd, "%d %d %d %d %h", kind, dtype, tr, sz, desc) != 5) $fatal;
      commands[i] = '{
          async_id_t'({16'd1, 10'd0, 32'(i)}),
          desc,
          4'(dtype),
          3'(kind),
          1'(tr),
          2'(sz)
      };
      nblocks[i] = 8 << sz;
      for (int j = 0; j < nblocks[i]; j++) begin
        if ($fscanf(fd, "%h", expected) != 1) $fatal;
        blocks[i][j] = expected;
        for (int p = 0; p < 16; p++) begin
          if ($fscanf(fd, "%d", parts) != 1 || parts > 16) $fatal;
          for (int a = 0; a < parts; a++) begin
            if ($fscanf(fd, "%h %h", addr, mask) != 2) $fatal;
            atoms[i][j][p][a] = addr;
            masks[i][j][p][a] = mask;
            required[i][j][p][a] = 1;
          end
        end
      end
    end
    $fclose(fd);
  endtask
  initial begin
    read_file();
    anchor = -1;
    inject_final_error = $test$plusargs("final_error");
    if (inject_final_error) nc = 1;
    rst_n = 0;
    halt_i = 0;
    load_valid = 0;
    result_ready = 0;
    data_ready = 0;
    sm_rd_rsp_valid = 0;
    sm_rd_req_ready = 0;
    @(negedge clk);
    rst_n = 1;
    while (retired < nc) begin
      load_valid = issued < nc;
      load_payload = (issued < nc) ? commands[issued] : '0;
      live_i = '0;
      live_i[0] = {load_valid, 2'd0, load_payload.id};
      result_ready = tick % 11 != 9;
      data_ready = retired == 0 ?
          4'hf : {tick % 7 != 0, tick % 5 != 0, tick % 9 != 0, tick % 19 >= 4};
      if (anchor < 0 && (|sm_rd_req_valid)) anchor = tick;
      for (int g = 0; g < 8; g++) begin
        reply_t head;
        sm_rd_req_ready[g] = retired == 0 ?
            (anchor >= 0 && (tick - anchor) % 4 < 2) : (tick + 3 * g) % 13 >= 2;
        sm_rd_rsp_valid[g] = 0;
        driven_rsp[g] = '0;
        if (replies[g].size() != 0) begin
          head = replies[g][0];
          sm_rd_rsp_valid[g] = tick >= head.available;
          driven_rsp[g] = head.rsp;
        end
      end
      drive_edge = !drive_edge;
      @(posedge clk);
      if (load_valid && load_ready) issued++;
      for (int g = 0; g < 8; g++) begin
        if (sm_rd_rsp_valid[g] && sm_rd_rsp_ready[g]) void'(replies[g].pop_front());
        if (sm_rd_req_valid[g] && sm_rd_req_ready[g]) begin
          int i, j, p, a, addr;
          reply_t ret;
          smem_rd_req_t req;
          req = sm_rd_req_payload[g];
          addr = int'(req.addr);
          i = int'(req.tag.id.seq);
          j = int'(req.tag.token[12:8]);
          p = int'(req.tag.token[7:4]);
          a = int'(req.tag.token[3:0]);
          if (i >= nc || req.tag.id != commands[i].id || req.tag.client != 6 || req.tag.token[15:13]
              != 0 || j >= nblocks[i] || !required[i][j][p][a] || sent[i][j][p][a] || (addr >> 4) %
              8 != g || req.addr != atoms[i][j][p][a] || req.byte_mask != masks[i][j][p][a])
            $fatal(
                1,
                "bad B request at tick %d id %d block %d piece %d part %d addr %h want %h mask %h want %h"
                    ,
                tick,
                i,
                j,
                p,
                a,
                req.addr,
                atoms[i][j][p][a],
                req.byte_mask,
                masks[i][j][p][a]
            );
          if (i == 0 && tick != anchor + 4 * j + p % 2)
            $fatal(1, "B ideal issue at %d want %d", tick, anchor + 4 * j + p % 2);
          sent[i][j][p][a] = 1;
          total_requests++;
          ret.rsp.tag = req.tag;
          ret.rsp.status = (inject_final_error && j == nblocks[i] - 1 && p == 15) ? MEMORY : OK;
          for (int b = 0; b < 16; b++) ret.rsp.data[8*b+:8] = memory(addr + b);
          ret.available = tick + 3 + (retired != 0 ? (g + tick) % 5 : 0);
          replies[g].push_back(ret);
        end
      end
      for (int c = 0; c < 4; c++)
      if (data_valid[c] && data_ready[c]) begin
        int i, j;
        i = next_id[c];
        j = next_block[c];
        if (data_payload.id !== commands[i].id || data_payload.block_idx !== 5'(j) ||
            data_payload.data !== blocks[i][j])
          $fatal(
              1,
              "bad core %d block expected %0d/%0d got %0d/%0d data diff %h",
              c,
              i,
              j,
              data_payload.id.seq,
              data_payload.block_idx,
              data_payload.data ^ blocks[i][j]
          );
        if (i == 0 && tick != anchor + 4 * j + 5)
          $fatal(1, "B ideal delivery at %d want %d", tick, anchor + 4 * j + 5);
        if (c == 0) total_blocks++;
        next_block[c]++;
        if (next_block[c] == nblocks[i]) begin
          next_block[c] = 0;
          next_id[c]++;
        end
      end
      if (result_valid && result_ready) begin
        if (result_payload.id !== commands[retired].id || result_payload.status != OK)
          $fatal(1, "incorrect result");
        for (int c = 0; c < 4; c++) if (next_id[c] <= retired) $fatal(1, "early result");
        retired++;
      end
      tick++;
      if (inject_final_error && fault_o) begin
        if (result_valid || retired != 0) $fatal(1, "failed B stream published success");
        for (int c = 0; c < 4; c++)
        if (next_block[c] != nblocks[0] - 1) $fatal(1, "failed B block reached core");
        repeat (3) begin
          @(posedge clk);
          if (!fault_o || result_valid || (|data_valid)) $fatal(1, "invalid B termination");
        end
        $display("PASS failed final B return suppresses all four deliveries and successful result");
        $finish;
      end else if (tick > 500000 || fault_o)
        $fatal(1, "B loader tick=%0d fault=%b retired=%0d/%0d issued=%0d blocks=%0d",
               tick, fault_o, retired, nc, issued, total_blocks);
      @(negedge clk);
    end
    for (int i = 0; i < nc; i++)
    for (int j = 0; j < nblocks[i]; j++)
    for (int p = 0; p < 16; p++)
    if (required[i][j][p] != sent[i][j][p]) $fatal(1, "missing request");
    if (!drained_o) $fatal(1, "not drained");
    $display("PASS %0d B streams, %0d blocks, %0d distinct request tags, four-core delivery", nc,
             total_blocks, total_requests);
    $finish;
  end
endmodule
