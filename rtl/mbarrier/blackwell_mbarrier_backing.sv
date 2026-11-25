module blackwell_mbarrier_backing
  import blackwell_async_pkg::*;
  import blackwell_mbarrier_pkg::*;
  import blackwell_smem_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic halt_i,
  input logic stop,
  input logic [15:0] epoch,
  input logic back_req_valid,
  input logic back_rsp_ready,
  input logic smem_req_ready,
  input logic smem_rsp_valid,
  output logic back_req_ready,
  output logic back_rsp_valid,
  output logic smem_req_valid,
  output logic smem_rsp_ready,
  input bar_back_req_t back_req_payload,
  output bar_back_rsp_t back_rsp_payload,
  output smem_atom_req_t smem_req_payload,
  input smem_atom_rsp_t smem_rsp_payload,
  output logic drained,
  output logic fault
);
  typedef enum logic [1:0] {
    EMPTY,
    ISSUE,
    WAIT_MEM,
    RESP
  } state_t;
  state_t state;
  bar_back_req_t req;
  logic [15:0] token, epoch_q;
  assign drained = state == EMPTY;
  assign back_req_ready = rst_n && drained && !fault;
  assign smem_req_valid = state == ISSUE;
  assign smem_rsp_ready = rst_n && !fault;
  assign back_rsp_valid = state == RESP;
  always_comb begin
    smem_req_payload = '0;
    smem_req_payload.tag = '{
        id: '{epoch: epoch_q, issuer: '0, seq: '0},
        client: 4'd11,
        token: token
    };
    smem_req_payload.addr = {req.addr[31:4], 4'b0};
    smem_req_payload.byte_mask = req.addr[3] ? 16'hff00 : 16'h00ff;
    smem_req_payload.write = req.write;
    smem_req_payload.data[req.addr[3]*64+:64] = req.value;
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= EMPTY;
      fault <= 0;
      token <= 0;
      epoch_q <= 0;
    end else if (!halt_i) begin
      if (epoch != epoch_q) begin
        if (!drained) fault <= 1;
        else begin
          epoch_q <= epoch;
          token <= 0;
        end
      end
      if (back_req_valid && back_req_ready) begin
        if (back_req_payload.addr[2:0] != 0 || back_req_payload.addr >= 233472) fault <= 1;
        else begin
          req <= back_req_payload;
          state <= ISSUE;
        end
      end
      if (smem_req_valid && smem_req_ready) state <= WAIT_MEM;
      if (smem_rsp_valid && smem_rsp_ready) begin
        if (state != WAIT_MEM || smem_rsp_payload.tag != smem_req_payload.tag ||
            smem_rsp_payload.write != req.write || smem_rsp_payload.status != OK)
          fault <= 1;
        else begin
          back_rsp_payload.status <= OK;
          back_rsp_payload.value <= req.write ? '0 : smem_rsp_payload.data[req.addr[3]*64+:64];
          state <= RESP;
        end
      end
      if (back_rsp_valid && back_rsp_ready) begin
        token <= token + 16'd1;
        state <= EMPTY;
      end
    end
  end
endmodule
