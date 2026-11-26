module blackwell_tc_async_completion
  import blackwell_async_pkg::*;
  import blackwell_tc_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic halt_i,
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
  output logic drained_o,
  output logic fault_o
);
  typedef enum logic [2:0] {
    EMPTY,
    SEND,
    WAIT_BAR,
    DONE,
    RETIRE,
    FAILED
  } state_t;
  state_t state;
  tc_ready_commit_t record;
  assign drained_o = state == EMPTY;
  // stop_i closes external admission. Internal commits still drain.
  assign ready_commit_ready = !fault_o && !halt_i && (drained_o || (state == RETIRE && commit_retire_ready));
  assign tc_bar_req_valid = state == SEND;
  assign tc_bar_req_payload = record.commit;
  assign tc_bar_rsp_ready = state == WAIT_BAR;
  assign commit_done_valid = state == DONE;
  assign commit_done_payload = '{record.commit.id, OK};
  assign commit_retire_valid = state == RETIRE;
  assign commit_retire_payload = '{record.slot, record.commit.id};

`ifndef SYNTHESIS
  // A normal stop leaves the epoch live through the final retirement.
  assert property (@(posedge clk) disable iff (!rst_n || halt_i || fault_o)
                   stop_i && state != EMPTY |-> record.commit.id.epoch == epoch_i);
`endif

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= EMPTY;
      fault_o <= 0;
    end else begin
      case (state)
        SEND: if (tc_bar_req_ready) state <= halt_i ? FAILED : WAIT_BAR;
        WAIT_BAR:
        if (tc_bar_rsp_valid) begin
          if (tc_bar_rsp_payload.id != record.commit.id || tc_bar_rsp_payload.status != OK) begin
            fault_o <= 1;
            state <= FAILED;
          end else state <= halt_i ? FAILED : DONE;
        end
        DONE: if (commit_done_ready) state <= halt_i ? FAILED : RETIRE;
        RETIRE: if (commit_retire_ready) state <= EMPTY;
        default: ;
      endcase
      if (tc_bar_rsp_valid && state != WAIT_BAR) fault_o <= 1;
      if (ready_commit_valid && ready_commit_ready) begin
        record <= ready_commit_payload;
        state <= SEND;
      end
    end
  end
endmodule
