module blackwell_tmem_manager
  import blackwell_async_pkg::*;
  import blackwell_tmem_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic stop_i,
  input logic [15:0] epoch_i,
  input logic epoch_end_valid,
  output logic epoch_end_ready,
  input logic manage_cmd_valid,
  output logic manage_cmd_ready,
  input tmem_manage_cmd_t manage_cmd_payload,
  output logic manage_rsp_valid,
  input logic manage_rsp_ready,
  output tmem_manage_rsp_t manage_rsp_payload,
  input logic pin_req_valid,
  output logic pin_req_ready,
  input tmem_pin_req_t pin_req_payload,
  output logic pin_rsp_valid,
  input logic pin_rsp_ready,
  output tmem_pin_rsp_t pin_rsp_payload,
  input logic unpin_valid,
  output logic unpin_ready,
  input tmem_unpin_t unpin_payload,
  output logic alloc_credit_o,
  output logic empty_o,
  output logic drained_o
);
  logic allocated, permit, opened;
  logic [15:0] epoch;
  logic [4:0] in_use;
  logic [1:0] cursor;
  logic [2:0] candidates, grant;
  assign alloc_credit_o = permit && !allocated;
  assign drained_o = in_use == 0 && !manage_rsp_valid && !pin_rsp_valid;
  assign empty_o = drained_o && !allocated;

  always_comb begin
    candidates[0] = manage_cmd_valid && !stop_i && (!manage_rsp_valid || manage_rsp_ready) &&
        (manage_cmd_payload.op != 0 || alloc_credit_o);
    candidates[1] = pin_req_valid && (!pin_rsp_valid || pin_rsp_ready);
    candidates[2] = unpin_valid;
    grant = '0;
    for (int k = 2; k >= 0; k--) begin
      int c;
      c = (int'(cursor) + k) % 3;
      if (candidates[c] && opened) grant = 3'b001 << c;
    end
  end
  assign {unpin_ready, pin_req_ready, manage_cmd_ready} = grant;
  assign epoch_end_ready = opened && drained_o && grant == 0;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      allocated <= 0;
      permit <= 0;
      opened <= 0;
      epoch <= 0;
      cursor <= 0;
      in_use <= '0;
      manage_rsp_valid <= 0;
      pin_rsp_valid <= 0;
    end else begin
      if (manage_rsp_ready) manage_rsp_valid <= 0;
      if (pin_rsp_ready) pin_rsp_valid <= 0;
      if (epoch != epoch_i) begin
        opened <= 1;
        epoch <= epoch_i;
        permit <= 1;
      end
      if (epoch_end_valid && epoch_end_ready) begin
        allocated <= 0;
        permit <= 0;
        opened <= 0;
      end
      if (grant[0]) begin
        cursor <= 1;
        manage_rsp_valid <= 1;
        manage_rsp_payload <= '{id: manage_cmd_payload.id, base: '0};
        case (manage_cmd_payload.op)
          0: allocated <= 1;
          1: allocated <= 0;
          2: permit <= 0;
          default: ;
        endcase
      end
      if (grant[1]) begin
        cursor <= 2;
        pin_rsp_valid <= 1;
        pin_rsp_payload <= '{id: pin_req_payload.id};
        in_use[pin_req_payload.user] <= 1;
      end
      if (grant[2]) begin
        cursor <= 0;
        in_use[unpin_payload.user] <= 0;
      end
    end
  end
`ifndef SYNTHESIS
  async_id_t owner[5];
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (epoch != epoch_i) assert (!opened && drained_o);
      if (manage_cmd_valid && !stop_i) begin
        assert (manage_cmd_payload.id.epoch == epoch_i && manage_cmd_payload.id.issuer[4:0] == 0 &&
                manage_cmd_payload.id.seq != '1);
        assert (manage_cmd_payload.op <= 2 && manage_cmd_payload.base == 0);
        assert (manage_cmd_payload.columns == (manage_cmd_payload.op == 2 ? 10'd0 : 10'd512));
        if (manage_cmd_payload.op == 1)
          assert (allocated && in_use == 0) else $error("TMEM_DEALLOC_LIFETIME");
      end
      if (grant[1]) begin
        assert (allocated && pin_req_payload.user < 5 && !in_use[pin_req_payload.user] &&
                pin_req_payload.id.epoch == epoch);
        owner[pin_req_payload.user] <= pin_req_payload.id;
      end
      if (grant[2]) begin
        assert (unpin_payload.user < 5 && in_use[unpin_payload.user] &&
                unpin_payload.id.epoch == epoch && owner[unpin_payload.user] == unpin_payload.id);
      end
    end
  end
`endif
endmodule
