module blackwell_tc_async_completion
  import blackwell_async_pkg::*;
  import blackwell_tc_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic stop_i,
  input logic [15:0] epoch_i,
  input logic ready_commit_valid,
  output logic ready_commit_ready,
  input tc_ready_commit_t ready_commit_payload,
  output logic tc_bar_req_valid,
  input logic tc_bar_req_ready,
  output tc_commit_t tc_bar_req_payload,
  input logic tc_bar_rsp_valid,
  output logic tc_bar_rsp_ready,
  input op_done_t tc_bar_rsp_payload,
  output logic commit_done_valid,
  input logic commit_done_ready,
  output op_done_t commit_done_payload,
  output logic commit_retire_valid,
  input logic commit_retire_ready,
  output tc_commit_retire_t commit_retire_payload,
  output logic drained_o
);
  typedef enum logic [2:0] {
    EMPTY,
    SEND,
    WAIT_BAR,
    DONE,
    RETIRE
  } state_t;
  state_t state;
  tc_ready_commit_t record;
  assign drained_o = state == EMPTY;
  // stop_i closes external admission. Internal commits still drain.
  assign ready_commit_ready = drained_o || (state == RETIRE && commit_retire_ready);
  assign tc_bar_req_valid = state == SEND;
  assign tc_bar_req_payload = record.commit;
  assign tc_bar_rsp_ready = state == WAIT_BAR;
  assign commit_done_valid = state == DONE;
  assign commit_done_payload.id = record.commit.id;
  assign commit_retire_valid = state == RETIRE;
  assign commit_retire_payload = '{record.slot, record.commit.id};

`ifndef SYNTHESIS
  // A normal stop leaves the epoch live through the final retirement.
  assert property (@(posedge clk) disable iff (!rst_n)
                   stop_i && state != EMPTY |-> record.commit.id.epoch == epoch_i);
  assert property (@(posedge clk) disable iff (!rst_n)
                   tc_bar_rsp_valid |-> state == WAIT_BAR && tc_bar_rsp_payload.id == record.commit.id)
    else $fatal(1, "TC_BRIDGE_RSP: unexpected barrier acknowledgment");
`endif

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= EMPTY;
    end else begin
      case (state)
        SEND: if (tc_bar_req_ready) state <= WAIT_BAR;
        WAIT_BAR: if (tc_bar_rsp_valid) state <= DONE;
        DONE: if (commit_done_ready) state <= RETIRE;
        RETIRE: if (commit_retire_ready) state <= EMPTY;
        default: ;
      endcase
      if (ready_commit_valid && ready_commit_ready) begin
        record <= ready_commit_payload;
        state <= SEND;
      end
    end
  end
endmodule
