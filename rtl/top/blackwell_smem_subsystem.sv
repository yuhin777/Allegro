module blackwell_smem_subsystem
  import blackwell_async_pkg::*;
  import blackwell_smem_pkg::*;
  import blackwell_tma_pkg::*;
  import blackwell_mbarrier_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic stop,
  input logic [15:0] epoch,
  input mma_live_t live[3],
  output logic drained,
  input logic tma_cmd_valid,
  input logic tma_rsp_ready,
  input logic bar_cmd_valid,
  input logic bar_rsp_ready,
  input logic tc_req_valid,
  input logic tc_rsp_ready,
  output logic tma_cmd_ready,
  output logic tma_rsp_valid,
  output logic bar_cmd_ready,
  output logic bar_rsp_valid,
  output logic tc_req_ready,
  output logic tc_rsp_valid,
  input tma_cmd_t tma_cmd_payload,
  input bar_cmd_t bar_cmd_payload,
  input tc_bar_req_t tc_req_payload,
  output tma_rsp_t tma_rsp_payload,
  output bar_rsp_t bar_rsp_payload,
  output op_done_t tc_rsp_payload,
  input logic gmem_req_ready,
  input logic gmem_rsp_valid,
  output logic gmem_req_valid,
  output logic gmem_rsp_ready,
  output gmem_req_t gmem_req_payload,
  input gmem_rsp_t gmem_rsp_payload,
  input logic [2:0] order_req_ready,
  input logic [2:0] order_rsp_valid,
  output logic [2:0] order_req_valid,
  output logic [2:0] order_rsp_ready,
  output order_req_t order_req_payload[3],
  input op_done_t order_rsp_payload[3],
  input logic [31:0] commit_candidate_addr,
  output logic commit_blocked,
  output logic [31:0] commit_busy_addr,
  input logic commit_addr_busy,
  input logic flush_req_valid,
  input logic flush_rsp_ready,
  output logic flush_req_ready,
  output logic flush_rsp_valid,
  input logic [4:0][7:0] tc_smem_req_valid,
  input logic [4:0][7:0] tc_smem_rsp_ready,
  output logic [4:0][7:0] tc_smem_req_ready,
  output logic [4:0][7:0] tc_smem_rsp_valid,
  input smem_rd_req_t tc_smem_req_payload[5][8],
  output smem_rd_rsp_t tc_smem_rsp_payload[5][8],
  input logic [7:0] smem_rd_valid,
  input logic [7:0] smem_wr_valid,
  input logic [7:0] smem_rd_rsp_ready,
  input logic [7:0] smem_wr_ack_ready,
  output logic [7:0] smem_rd_ready,
  output logic [7:0] smem_wr_ready,
  output logic [7:0] smem_rd_rsp_valid,
  output logic [7:0] smem_wr_ack_valid,
  input smem_rd_req_t smem_rd_payload[8],
  input smem_wr_req_t smem_wr_payload[8],
  output smem_rd_rsp_t smem_rd_rsp_payload[8],
  output smem_wr_ack_t smem_wr_ack_payload[8]
);
  logic [5:0] local_drained;
  assign drained = &local_drained;
  logic [7:0] t_req_v, t_req_r, t_rsp_v, t_rsp_r;
  smem_atom_req_t t_req[8];
  smem_atom_rsp_t t_rsp[8];
  logic
      bind_req_valid,
      bind_req_ready,
      bind_rsp_valid,
      bind_rsp_ready,
      producer_done_valid,
      producer_done_ready,
      producer_rsp_valid,
      producer_rsp_ready;
  bar_bind_t bind_req_payload;
  op_done_t bind_rsp_payload, producer_rsp_payload;
  bar_producer_done_t producer_done_payload;
  logic [7:0] smem_read_blocked;
  blackwell_tma_unit tma (
    .clk,
    .rst_n,
    .stop,
    .epoch,
    .cmd_valid(tma_cmd_valid),
    .cmd_ready(tma_cmd_ready),
    .cmd_payload(tma_cmd_payload),
    .rsp_valid(tma_rsp_valid),
    .rsp_ready(tma_rsp_ready),
    .rsp_payload(tma_rsp_payload),
    .gmem_req_valid,
    .gmem_req_ready,
    .gmem_req_payload,
    .gmem_rsp_valid,
    .gmem_rsp_ready,
    .gmem_rsp_payload,
    .order_req_valid(order_req_valid[0]),
    .order_req_ready(order_req_ready[0]),
    .order_req_payload(order_req_payload[0]),
    .order_rsp_valid(order_rsp_valid[0]),
    .order_rsp_ready(order_rsp_ready[0]),
    .order_rsp_payload(order_rsp_payload[0]),
    .bar_bind_valid(bind_req_valid),
    .bar_bind_ready(bind_req_ready),
    .bar_bind_payload(bind_req_payload),
    .bar_bind_rsp_valid(bind_rsp_valid),
    .bar_bind_rsp_ready(bind_rsp_ready),
    .bar_bind_rsp_payload(bind_rsp_payload),
    .producer_done_valid,
    .producer_done_ready,
    .producer_done_payload,
    .producer_rsp_valid,
    .producer_rsp_ready,
    .producer_rsp_payload,
    .smem_req_valid(t_req_v),
    .smem_req_ready(t_req_r),
    .smem_req_payload(t_req),
    .smem_rsp_valid(t_rsp_v),
    .smem_rsp_ready(t_rsp_r),
    .smem_read_blocked,
    .smem_rsp_payload(t_rsp),
    .drained(local_drained[0])
  );
  logic
      wait_cmd_valid,
      wait_cmd_ready,
      wait_rsp_valid,
      wait_rsp_ready,
      service_req_valid,
      service_req_ready,
      service_rsp_valid,
      service_rsp_ready;
  logic
      wait_probe_req_valid,
      wait_probe_req_ready,
      wait_probe_rsp_valid,
      wait_probe_rsp_ready,
      wait_addr_busy,
      change_valid;
  logic [31:0] wait_busy_addr;
`ifndef SYNTHESIS
  logic wait_id_busy;
`endif
  bar_cmd_t wait_cmd_payload;
  bar_rsp_t wait_rsp_payload;
  bar_change_t change_payload;
  bar_service_req_t service_req_payload, wait_probe_req_payload;
  bar_service_rsp_t service_rsp_payload, wait_probe_rsp_payload;
  blackwell_mbarrier_frontend frontend (
    .clk,
    .rst_n,
    .stop,
    .epoch,
    .sw_cmd_valid(bar_cmd_valid),
    .sw_cmd_ready(bar_cmd_ready),
    .sw_cmd_payload(bar_cmd_payload),
    .sw_rsp_valid(bar_rsp_valid),
    .sw_rsp_ready(bar_rsp_ready),
    .sw_rsp_payload(bar_rsp_payload),
    .release_req_valid(order_req_valid[1]),
    .release_req_ready(order_req_ready[1]),
    .release_req_payload(order_req_payload[1]),
    .release_rsp_valid(order_rsp_valid[1]),
    .release_rsp_ready(order_rsp_ready[1]),
    .release_rsp_payload(order_rsp_payload[1]),
    .tc_req_valid,
    .tc_req_ready,
    .tc_rsp_valid,
    .tc_rsp_ready,
    .drained(local_drained[1]),
    .*
  );
  blackwell_mbarrier_wait waits (
    .clk,
    .rst_n,
    .stop(1'b0),
    .epoch,
    .wait_cmd_valid,
    .wait_cmd_ready,
    .wait_cmd_payload,
    .wait_rsp_valid,
    .wait_rsp_ready,
    .wait_rsp_payload,
    .probe_req_valid(wait_probe_req_valid),
    .probe_req_ready(wait_probe_req_ready),
    .probe_req_payload(wait_probe_req_payload),
    .probe_rsp_valid(wait_probe_rsp_valid),
    .probe_rsp_ready(wait_probe_rsp_ready),
    .probe_rsp_payload(wait_probe_rsp_payload),
    .acquire_req_valid(order_req_valid[2]),
    .acquire_req_ready(order_req_ready[2]),
    .acquire_req_payload(order_req_payload[2]),
    .acquire_rsp_valid(order_rsp_valid[2]),
    .acquire_rsp_ready(order_rsp_ready[2]),
    .acquire_rsp_payload(order_rsp_payload[2]),
    .change_valid,
    .change_payload,
    .busy_addr(wait_busy_addr),
`ifndef SYNTHESIS
    .ingress_id(bar_cmd_payload.id),
    .ingress_id_busy(wait_id_busy),
`endif
    .addr_busy(wait_addr_busy),
    .drained(local_drained[2])
  );
  logic back_req_valid, back_req_ready, back_rsp_valid, back_rsp_ready;
  bar_back_req_t back_req_payload;
  bar_back_rsp_t back_rsp_payload;
  blackwell_mbarrier_unit objects (
    .flush_req_valid,
    .flush_req_ready,
    .flush_rsp_valid,
    .flush_rsp_ready,
    .drained(local_drained[3]),
    .*
  );
  logic b_req_v, b_req_r, b_rsp_v, b_rsp_r;
  smem_atom_req_t b_req;
  smem_atom_rsp_t b_rsp;
  blackwell_mbarrier_backing backing (
    .clk,
    .rst_n,
    .epoch,
    .stop,
    .back_req_valid,
    .back_req_ready,
    .back_req_payload,
    .back_rsp_valid,
    .back_rsp_ready,
    .back_rsp_payload,
    .smem_req_valid(b_req_v),
    .smem_req_ready(b_req_r),
    .smem_req_payload(b_req),
    .smem_rsp_valid(b_rsp_v),
    .smem_rsp_ready(b_rsp_r),
    .smem_rsp_payload(b_rsp),
    .drained(local_drained[4])
  );
  logic [15:0][7:0]
      rd_req_valid,
      rd_req_ready,
      rd_rsp_valid,
      rd_rsp_ready,
      wr_req_valid,
      wr_req_ready,
      wr_ack_valid,
      wr_ack_ready;
  smem_rd_req_t rd_req_payload[16][8];
  smem_rd_rsp_t rd_rsp_payload[16][8];
  smem_wr_req_t wr_req_payload[16][8];
  smem_wr_ack_t wr_ack_payload[16][8];
  blackwell_smem_fabric fabric (
    .clk,
    .rst_n,
    .epoch_i(epoch),
    .live,
    .drained_o(local_drained[5]),
    .*
  );

  logic [7:0] prefer_ack, lock_ack, held_ack, select_ack;
  logic [2:0] backing_group, backing_cursor, backing_hold;
  logic backing_found;
  assign backing_group = b_req.addr[6:4];
  // Only one backing transaction may be outstanding in any group.
  always_comb begin
    backing_found = 0;
    backing_hold = '0;
    for (int g = 0; g < 8; g++) begin
      logic [2:0] n;
      n = backing_cursor + 3'(g);
      if (!backing_found && (rd_rsp_valid[11][n] || wr_ack_valid[11][n])) begin
        backing_found = 1;
        backing_hold = n;
      end
    end
    b_rsp_v = backing_found;
    b_rsp = '{
        write: wr_ack_valid[11][backing_hold],
        tag: rd_rsp_payload[11][backing_hold].tag,
        data: rd_rsp_payload[11][backing_hold].data
    };
    if (b_rsp.write) begin
      b_rsp.tag = wr_ack_payload[11][backing_hold].tag;
      b_rsp.data = 0;
    end
    b_req_r = b_req.write ? wr_req_ready[11][backing_group] : rd_req_ready[11][backing_group];
  end
  for (genvar c = 0; c < 16; c++)
  for (genvar g = 0; g < 8; g++) begin : routes
    if (c < 4 || c == 6) begin
      localparam int C = c == 6 ? 4 : c;
      assign rd_req_valid[c][g] = tc_smem_req_valid[C][g];
      assign rd_req_payload[c][g] = tc_smem_req_payload[C][g];
      assign tc_smem_req_ready[C][g] = rd_req_ready[c][g];
      assign tc_smem_rsp_valid[C][g] = rd_rsp_valid[c][g];
      assign tc_smem_rsp_payload[C][g] = rd_rsp_payload[c][g];
      assign rd_rsp_ready[c][g] = tc_smem_rsp_ready[C][g];
      assign wr_req_valid[c][g] = 0;
      assign wr_req_payload[c][g] = '0;
      assign wr_ack_ready[c][g] = 0;
    end else if (c == 12) begin
      assign rd_req_valid[c][g] = smem_rd_valid[g];
      assign rd_req_payload[c][g] = smem_rd_payload[g];
      assign smem_rd_ready[g] = rd_req_ready[c][g];
      assign rd_rsp_ready[c][g] = smem_rd_rsp_ready[g];
      assign smem_rd_rsp_valid[g] = rd_rsp_valid[c][g];
      assign smem_rd_rsp_payload[g] = rd_rsp_payload[c][g];
      assign wr_req_valid[c][g] = smem_wr_valid[g];
      assign wr_req_payload[c][g] = smem_wr_payload[g];
      assign smem_wr_ready[g] = wr_req_ready[c][g];
      assign wr_ack_ready[c][g] = smem_wr_ack_ready[g];
      assign smem_wr_ack_valid[g] = wr_ack_valid[c][g];
      assign smem_wr_ack_payload[g] = wr_ack_payload[c][g];
    end else if (c == 8 || c == 11) begin
      smem_atom_req_t req;
      logic v;
      if (c == 11) begin
        assign req = b_req;
        assign v = b_req_v && backing_group == 3'(g);
        assign rd_rsp_ready[c][g] = b_rsp_r && backing_hold == 3'(g) && !b_rsp.write;
        assign wr_ack_ready[c][g] = b_rsp_r && backing_hold == 3'(g) && b_rsp.write;
      end else begin
        assign req = t_req[g];
        assign v = t_req_v[g];
        assign t_req_r[g] = req.write ? wr_req_ready[c][g] : rd_req_ready[c][g];
        assign select_ack[g] = lock_ack[g] ? held_ack[g] :
            wr_ack_valid[c][g] && (!rd_rsp_valid[c][g] || prefer_ack[g] || smem_read_blocked[g]);
        assign t_rsp_v[g] = rd_rsp_valid[c][g] || wr_ack_valid[c][g];
        assign t_rsp[g] = select_ack[g] ? smem_atom_rsp_t
            '({1'b1, wr_ack_payload[c][g].tag, 128'b0}) :
            smem_atom_rsp_t'({1'b0, rd_rsp_payload[c][g]});
        assign rd_rsp_ready[c][g] = !select_ack[g] && t_rsp_r[g];
        assign wr_ack_ready[c][g] = select_ack[g] && t_rsp_r[g];
      end
      assign rd_req_valid[c][g] = v && !req.write;
      assign wr_req_valid[c][g] = v && req.write;
      assign rd_req_payload[c][g] = '{tag: req.tag, addr: req.addr, byte_mask: req.byte_mask};
      assign wr_req_payload[c][g] = '{
              tag: req.tag,
              addr: req.addr,
              byte_mask: req.byte_mask,
              data: req.data
          };
    end else begin
      assign rd_req_valid[c][g] = 0;
      assign rd_req_payload[c][g] = '0;
      assign rd_rsp_ready[c][g] = 0;
      assign wr_req_valid[c][g] = 0;
      assign wr_req_payload[c][g] = '0;
      assign wr_ack_ready[c][g] = 0;
    end
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      prefer_ack <= 0;
      lock_ack <= 0;
      held_ack <= 0;
      backing_cursor <= 0;
    end else begin
      if (b_rsp_v && b_rsp_r) backing_cursor <= backing_hold + 3'd1;
      for (int g = 0; g < 8; g++)
      if (t_rsp_v[g]) begin
        lock_ack[g] <= !t_rsp_r[g];
        held_ack[g] <= select_ack[g];
        if (t_rsp_r[g]) prefer_ack[g] <= !select_ack[g];
      end
    end
  end
endmodule
