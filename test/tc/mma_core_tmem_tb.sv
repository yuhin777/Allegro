module mma_core_tmem_tb;
  import blackwell_async_pkg::*;
  import blackwell_tc_pkg::*;
  import blackwell_smem_pkg::*;
  import blackwell_tmem_pkg::*;
  bit clk;
  logic rst_n;
  wire halt_i = 0;
  logic [15:0] epoch_i;
  mma_live_t [2:0] live_i;
  logic [2:0][3:0] older_writes_clear;
  logic prepare_valid;
  logic prepare_ready;
  prepare_t prepare_payload;
  logic b_select_valid;
  logic b_select_ready;
  b_select_t b_select_payload;
  logic first_id_valid;
  async_id_t first_id;
  wire launch = 0;
  logic first_ready;
  logic [2:0] input_free;
  logic [2:0] writes_done;
  logic local_done_valid;
  logic local_done_ready;
  op_done_t local_done_payload;
  logic data_valid;
  logic data_ready;
  b_data_t data_payload;
  logic [7:0] sm_rd_req_valid;
  logic [7:0] sm_rd_req_ready;
  smem_rd_req_t sm_rd_req_payload[8];
  wire [7:0] sm_rd_rsp_valid = '0;
  logic [7:0] sm_rd_rsp_ready;
  smem_rd_rsp_t sm_rd_rsp_payload[8];
  logic [127:0] tm_rd_req_valid;
  logic [127:0] tm_rd_req_ready;
  tmem_rd_req_t tm_rd_req_payload[128];
  logic [127:0] tm_rd_rsp_valid;
  logic [127:0] tm_rd_rsp_ready;
  tmem_rd_rsp_t tm_rd_rsp_payload[128];
  logic [127:0] tm_wr_req_valid;
  logic [127:0] tm_wr_req_ready;
  tmem_wr_req_t tm_wr_req_payload[128];
  wire [127:0] tm_wr_ack_valid = '0;
  logic [127:0] tm_wr_ack_ready;
  tmem_wr_ack_t tm_wr_ack_payload[128];
  logic [71:0] sb_query;
  wire [256:0] sb_view = '0;
  logic drained_o;
  logic idle_o;
  logic fault_o;

  blackwell_tc_mma_core dut (.*);

  logic release_all, stall_lane0;
  for (genvar l = 0; l < 128; l++) begin : memory
    assign tm_rd_req_ready[l] = (!tm_rd_rsp_valid[l] || tm_rd_rsp_ready[l]) &&
        (tm_rd_req_payload[l].tag.token[9:8] == 0 || release_all) && !(l == 0 && stall_lane0);
    always_ff @(posedge clk) begin
      if (!rst_n) tm_rd_rsp_valid[l] <= 0;
      else begin
        if (tm_rd_rsp_ready[l]) tm_rd_rsp_valid[l] <= 0;
        if (tm_rd_req_valid[l] && tm_rd_req_ready[l]) begin
          tm_rd_rsp_valid[l] <= 1;
          tm_rd_rsp_payload[l] <= '{tm_rd_req_payload[l].tag, 128'd0, OK};
        end
      end
    end
  end

  always #5 clk = !clk;
  initial begin
    #100000;
    $fatal(1, "core TMEM test timed out");
  end
  task automatic tick;
    @(posedge clk);
    @(negedge clk);
    if (rst_n && fault_o) $fatal(1, "unexpected core fault");
  endtask
  task automatic reset_core;
    rst_n = 0;
    live_i = '0;
    prepare_valid = 0;
    b_select_valid = 0;
    data_valid = 0;
    release_all = 0;
    stall_lane0 = 0;
    tick();
    rst_n = 1;
  endtask

  // The first sixteen lanes fetch a transposed FP16 A from columns [0,64).
  task automatic prepare_fp16(input int unsigned dest);
    prepare_payload = '0;
    prepare_payload.cmd.id.epoch = epoch_i;
    prepare_payload.cmd.id.seq = 1;
    prepare_payload.cmd.a_from_tmem = 1;
    prepare_payload.cmd.transpose_a = 1;
    prepare_payload.cmd.d_tmem = dest;
    prepare_payload.cmd.b_desc[46] = 1;
    first_id = prepare_payload.cmd.id;
    live_i[0] = '{1'b1, 2'd0, first_id};
    prepare_valid = 1;
    #1;
    if (!prepare_ready) $fatal;
    tick();
    prepare_valid = 0;
  endtask

  task automatic check_footprint(input int unsigned dest, input bit expect_overlap);
    reset_core();
    prepare_fp16(dest);
    b_select_payload = '{first_id, 2'd0, 2'd0, 1'b0};
    b_select_valid = 1;
    #1;
    if (!b_select_ready) $fatal;
    tick();
    b_select_valid = 0;
    data_payload = '{first_id, 5'd0, 2048'd0};
    data_valid = 1;
    #1;
    if (!data_ready) $fatal;
    tick();
    data_valid = 0;
    // Service only the first row group. Full snapshot is required for overlap.
    while (dut.a_ready[0] != 4'b0001) tick();
    #1;
    if (first_ready != !expect_overlap)
      $fatal(1, "wrong first_ready for D column %0d with only row group 0", dest);
    release_all = 1;
    while (dut.a_ready[0] != 4'b1111) tick();
    #1;
    if (!first_ready) $fatal(1, "full snapshot did not enable first issue");
  endtask

  task automatic check_priority(input bit held);
    tmem_rd_req_t prior;
    reset_core();
    release_all = 1;
    stall_lane0 = held;
    prepare_fp16(128);
    prior = tm_rd_req_payload[0];
    prepare_payload = '0;
    prepare_payload.rec = 1;
    prepare_payload.bank = 1;
    prepare_payload.cmd.id.epoch = epoch_i;
    prepare_payload.cmd.id.seq = 2;
    prepare_payload.cmd.kind = 4;
    prepare_payload.cmd.a_type = 3;
    prepare_payload.cmd.b_type = 3;
    prepare_payload.cmd.scale_vec = 1;
    prepare_payload.cmd.scale_a = 256;
    prepare_payload.cmd.scale_b = 272;
    prepare_payload.cmd.d_tmem = 320;
    prepare_payload.cmd.a_ref[46] = 1;
    prepare_payload.cmd.b_desc[46] = 1;
    live_i[1] = '{1'b1, 2'd1, prepare_payload.cmd.id};
    prepare_valid = 1;
    stall_lane0 = 0;
    #1;
    if (!prepare_ready || !tm_rd_req_valid[0] || !tm_rd_req_ready[0]) $fatal;
    if (held) begin
      if (tm_rd_req_payload[0] != prior || prior.tag.id != first_id) $fatal(1, "held A changed");
      tick();
      prepare_valid = 0;
      #1;
    end
    if (!tm_rd_req_valid[0] || !tm_rd_req_ready[0] ||
        tm_rd_req_payload[0].tag.id != prepare_payload.cmd.id ||
        tm_rd_req_payload[0].tag.token[15:13] != 3'd3)
      $fatal(1, "young scale A did not win over old A");
    tick();
    prepare_valid = 0;
    #1;
    if (!tm_rd_req_valid[0] || tm_rd_req_payload[0].tag.id != first_id ||
        tm_rd_req_payload[0].tag.token[15:13] != 3'd1)
      $fatal(1, "ordinary A did not resume after scale A");
  endtask
  initial begin
    epoch_i = 1;
    older_writes_clear = '1;
    local_done_ready = 1;
    sm_rd_req_ready = '1;
    tm_wr_req_ready = '1;
    first_id_valid = 1;
    check_footprint(63, 1);
    check_footprint(64, 0);
    check_priority(0);
    check_priority(1);
    $display("PASS adjacent and overlapping A/D columns, held and competing TMEM requests");
    $finish;
  end
endmodule
