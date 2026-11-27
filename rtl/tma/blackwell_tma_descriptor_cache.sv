module blackwell_tma_descriptor_cache
  import blackwell_async_pkg::*;
  import blackwell_tma_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic [15:0] epoch,
  input logic lookup_valid,
  input logic result_ready,
  input logic gmem_req_ready,
  input logic gmem_rsp_valid,
  output logic lookup_ready,
  output logic result_valid,
  output logic gmem_req_valid,
  output logic gmem_rsp_ready,
  input tma_desc_req_t lookup_payload,
  output tma_desc_rsp_t result_payload,
  output gmem_req_t gmem_req_payload,
  input tma_gmem_return_t gmem_rsp_payload,
  output logic drained
);
  typedef enum logic [1:0] {
    IDLE,
    COMPARE,
    ISSUE,
    WAIT_RSP
  } state_t;
  state_t state;
  logic [1023:0] data[4];
  logic [56:0] addr[4];
  logic [3:0] valid;
  logic [1:0] cursor, victim, choice, hit_slot;
  logic [15:0] epoch_q;
  logic phase, hit;
  tma_desc_req_t owner;
  assign drained = state == IDLE && !result_valid;
  always_comb begin
    hit = 0;
    choice = cursor;
    hit_slot = 0;
    for (int i = 3; i >= 0; i--) begin
      if (!valid[i]) choice = 2'(i);
      if (valid[i] && addr[i] == owner.addr[63:7]) begin
        hit = 1;
        hit_slot = 2'(i);
      end
    end
    lookup_ready = rst_n &&
        (state == IDLE || (state == COMPARE && hit && (!result_valid || result_ready)));
    gmem_req_valid = state == ISSUE;
    gmem_req_payload = '0;
    gmem_req_payload.id = '{cls: 2'd1, tag: '0, phase: phase};
    gmem_req_payload.addr = owner.addr;
    gmem_req_payload.byte_mask = '1;
  end
  // COMPARE reserves the sole result register before launching a miss.
  // No other lookup can fill it before this response.
  assign gmem_rsp_ready = rst_n;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= IDLE;
      valid <= 0;
      result_valid <= 0;
      cursor <= 0;
      phase <= 0;
      epoch_q <= 0;
    end else begin
      if (epoch_q != epoch) begin
        valid <= 0;
        epoch_q <= epoch;
        cursor <= 0;
      end
      if (result_valid && result_ready) result_valid <= 0;
      if (state == COMPARE && (!result_valid || result_ready)) begin
        if (hit) begin
          result_valid <= 1;
          result_payload <= '{ticket: owner.ticket, raw: data[hit_slot]};
          state <= IDLE;
        end else begin
          victim <= choice;
          state <= ISSUE;
        end
      end
      if (lookup_valid && lookup_ready) begin
        owner <= lookup_payload;
        state <= COMPARE;
      end
      if (gmem_req_valid && gmem_req_ready) state <= WAIT_RSP;
      if (gmem_rsp_valid && gmem_rsp_ready) begin
        phase <= !phase;
        valid[victim] <= 1;
        addr[victim] <= owner.addr[63:7];
        data[victim] <= gmem_rsp_payload.data;
        cursor <= victim + 2'd1;
        result_valid <= 1;
        result_payload <= '{ticket: owner.ticket, raw: gmem_rsp_payload.data};
        state <= IDLE;
      end
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (epoch_q != epoch) assert (drained);
      if (lookup_valid) assert (lookup_payload.id.epoch == epoch && lookup_payload.addr[6:0] == 0);
      if (gmem_rsp_valid)
        assert (state == WAIT_RSP && gmem_rsp_payload.id == gmem_req_payload.id)
            else $fatal(1, "TMA_DESC_RETURN");
    end
  end
`endif
endmodule
