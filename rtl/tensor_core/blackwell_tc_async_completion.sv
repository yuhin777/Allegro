// Implements frozen A1: doc/specs/blackwell_tc_async_completion.md
module blackwell_tc_async_completion
  import blackwell_async_pkg::*;
#(
  parameter int unsigned OPERATIONS = 32,
  parameter int unsigned COMMITS = 8
) (
  input logic clk,
  input logic rst_n,
  input logic register_vld_i,
  input blackwell_async_pkg::async_key_a1_t register_i,
  input logic complete_vld_i,
  input blackwell_async_pkg::async_event_a1_t complete_i,
  input logic commit_vld_i,
  input blackwell_async_pkg::tc_commit_a1_t commit_i,
  input logic bar_rdy_i,
  input logic bar_rsp_vld_i,
  input tma_mbarrier_pkg::bar_rsp_t bar_rsp_i,
  input logic event_rdy_i,
  input logic stop_i,
  output logic register_rdy_o,
  output logic complete_rdy_o,
  output logic commit_rdy_o,
  output logic bar_vld_o,
  output tma_mbarrier_pkg::bar_cmd_t bar_o,
  output logic bar_rsp_rdy_o,
  output logic event_vld_o,
  output blackwell_async_pkg::async_event_a1_t event_o,
  output logic protocol_error_o,
  output logic idle_o,
  output logic drained_o
);

  import tma_mbarrier_pkg::*;
  typedef enum logic [1:0] {Idle, Send, WaitAck, Event} state_t;
  state_t state_q, state_d;
  // One complete commit identity shared by request generation and event output.
  tc_commit_a1_t record_q, record_d;
  logic [STATUS_W-1:0] status_q, status_d;
  logic phase_q, phase_d;
  logic tracker_register_rdy, tracker_commit_rdy, tracker_drained;
  logic arrival_vld, arrival_rdy;
  tc_commit_a1_t arrival;
  logic [STATUS_W-1:0] arrival_status;

  blackwell_tc_completion_tracker #(.OPERATIONS(OPERATIONS), .COMMITS(COMMITS)) u_tracker (
    .clk(clk), .rst_n(rst_n),
    .register_vld_i(register_vld_i && !stop_i), .register_rdy_o(tracker_register_rdy),
    .register_i(register_i), .complete_vld_i(complete_vld_i),
    .complete_rdy_o(complete_rdy_o), .complete_i(complete_i),
    .commit_vld_i(commit_vld_i && !stop_i), .commit_rdy_o(tracker_commit_rdy),
    .commit_i(commit_i), .arrival_vld_o(arrival_vld), .arrival_rdy_i(arrival_rdy),
    .arrival_o(arrival), .arrival_status_o(arrival_status),
    .protocol_error_o(protocol_error_o), .idle_o(idle_o), .drained_o(tracker_drained)
  );
  assign register_rdy_o = tracker_register_rdy && !stop_i;
  assign commit_rdy_o = tracker_commit_rdy && !stop_i;
  assign arrival_rdy = state_q == Idle;
  assign drained_o = tracker_drained && state_q == Idle;
  assign bar_vld_o = state_q == Send;
  assign bar_rsp_rdy_o = state_q == WaitAck;
  assign event_vld_o = state_q == Event;

  always_comb begin
    bar_o = '0;
    bar_o.opcode = (status_q == ASYNC_OK) ? MBAR_OP_ARRIVE : MBAR_OP_FAULT;
    bar_o.tag = record_q.commit.id.tag;
    bar_o.issuer = record_q.commit.id.issuer;
    bar_o.seq = record_q.commit.id.seq;
    bar_o.addr = record_q.commit.barrier;
    bar_o.arrive_count = BARRIER_COUNT_W'(1);
    event_o = '0;
    event_o.ctx = record_q.ctx;
    event_o.\event .id = record_q.commit.id;
    event_o.\event .domain = CPL_TC;
    event_o.\event .status = status_q;
    event_o.\event .value = phase_q;

    state_d = state_q;
    record_d = record_q;
    status_d = status_q;
    phase_d = phase_q;
    case (state_q)
      Idle: if (arrival_vld && arrival_rdy) begin
        record_d = arrival;
        status_d = arrival_status;
        phase_d = 1'b0;
        state_d = Send;
      end
      Send: if (bar_vld_o && bar_rdy_i) state_d = WaitAck;
      WaitAck: if (bar_rsp_vld_i && bar_rsp_rdy_o) begin
        if (status_q == ASYNC_OK) begin
          status_d = (bar_rsp_i.tag != record_q.commit.id.tag ||
                      bar_rsp_i.issuer != record_q.commit.id.issuer) ?
                     ASYNC_BAD_COMPLETION : bar_rsp_i.status;
        end
        phase_d = bar_rsp_i.phase;
        state_d = Event;
      end
      Event: if (event_vld_o && event_rdy_i) state_d = Idle;
      default: begin
        status_d = ASYNC_BAD_COMPLETION;
        state_d = Event;
      end
    endcase
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q <= Idle;
      record_q <= '0;
      status_q <= ASYNC_OK;
      phase_q <= 1'b0;
    end else begin
      state_q <= state_d;
      record_q <= record_d;
      status_q <= status_d;
      phase_q <= phase_d;
    end
  end
`ifndef SYNTHESIS
  assert property (@(posedge clk) disable iff (!rst_n)
      bar_vld_o && !bar_rdy_i |=> bar_vld_o && $stable(bar_o));
  assert property (@(posedge clk) disable iff (!rst_n)
      event_vld_o && !event_rdy_i |=> event_vld_o && $stable(event_o));

`endif
endmodule
