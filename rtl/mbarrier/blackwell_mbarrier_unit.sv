module blackwell_mbarrier_unit
  import blackwell_async_pkg::*;
  import blackwell_mbarrier_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic halt_i,
  input logic stop,
  input logic [15:0] epoch,
  input logic service_req_valid,
  input logic service_rsp_ready,
  input logic back_req_ready,
  input logic back_rsp_valid,
  output logic service_req_ready,
  output logic service_rsp_valid,
  output logic back_req_valid,
  output logic back_rsp_ready,
  input bar_service_req_t service_req_payload,
  output bar_service_rsp_t service_rsp_payload,
  output bar_back_req_t back_req_payload,
  input bar_back_rsp_t back_rsp_payload,
  output logic change_valid,
  output bar_change_t change_payload,
  input logic flush_req_valid,
  input logic flush_rsp_ready,
  output logic flush_req_ready,
  output logic flush_rsp_valid,
  output status_t flush_rsp_payload,
  output logic drained,
  output logic fault
);
  typedef enum logic [3:0] {
    IDLE,
    LOOKUP,
    UPDATE,
    COMMIT,
    RESP,
    SAVE,
    SAVE_WAIT,
    FILL,
    FILL_WAIT,
    INVALIDATE,
    INVAL_WAIT,
    FLUSH_SCAN,
    FLUSH_RESP
  } state_t;
  state_t state;
  logic [3:0] valid, dirty;
  logic [28:0] tags[4];
  bar_object_t objects[4], old_obj, next_obj, candidate;
  logic [1:0] cursor, slot, hit_slot, victim;
  logic [2:0] flush_index;
  logic hit, found_empty, flushing, legal, modifying;
  logic [15:0] epoch_q;
  bar_service_req_t req;
  assign drained = state == IDLE;
  assign flush_req_ready = rst_n && drained && !fault;
  assign service_req_ready = flush_req_ready && !flush_req_valid;
  assign service_rsp_valid = state == RESP;
  assign flush_rsp_valid = state == FLUSH_RESP;
  assign flush_rsp_payload = OK;
  assign back_req_valid = state inside {SAVE, FILL, INVALIDATE};
  assign back_rsp_ready = rst_n && !fault;
  assign back_req_payload.write = state != FILL;
  assign back_req_payload.addr = state == SAVE ? {tags[slot], 3'b0} : req.cmd.addr;
  assign back_req_payload.value = state == SAVE ? objects[slot] : '0;
  assign modifying = req.cmd.op != BAR_QUERY;
  assign change_valid = !fault &&
      ((state == COMMIT && modifying && req.cmd.op != BAR_INVAL) ||
       (state == INVAL_WAIT && back_rsp_valid && back_rsp_payload.status == OK));
  assign change_payload = '{
          addr: req.cmd.addr,
          phase: next_obj.phase,
          initialized: next_obj.initialized
      };
  always_comb begin
    hit = 0;
    hit_slot = 0;
    found_empty = 0;
    victim = cursor;
    for (int n = 0; n < 4; n++) begin
      if (valid[n] && tags[n] == req.cmd.addr[31:3]) begin
        hit = 1;
        hit_slot = 2'(n);
      end
      if (!found_empty && !valid[n]) begin
        found_empty = 1;
        victim = 2'(n);
      end
    end
  end
  always_comb begin
    logic signed [33:0] pending, tx;
    candidate = old_obj;
    pending = $signed({14'b0, old_obj.pending});
    tx = 34'($signed(old_obj.tx));
    legal = !old_obj.reserved && old_obj.initialized && old_obj.expected != 0 &&
        old_obj.pending <= old_obj.expected && old_obj.tx != 21'sh100000;
    case (req.cmd.op)
      BAR_INIT: begin
        legal = req.cmd.count inside {[1 : 1048575]};
        candidate = '{
            reserved: 0,
            initialized: 1,
            phase: 0,
            tx: '0,
            expected: req.cmd.count[19:0],
            pending: req.cmd.count[19:0]
        };
      end
      BAR_INVAL: candidate = '0;
      BAR_QUERY: ;
      BAR_ARRIVE, BAR_EXPECT, BAR_COMPLETE: begin
        case (req.cmd.op)
          BAR_ARRIVE: begin
            pending -= $signed({2'b0, req.cmd.count});
            legal &= req.cmd.count inside {[1 : 1048575]};
          end
          BAR_EXPECT: begin
            pending -= 1;
            tx += $signed({2'b0, req.cmd.bytes});
            legal &= req.cmd.bytes <= 1048575;
          end
          BAR_COMPLETE: begin
            tx -= $signed({2'b0, req.cmd.bytes});
            legal &= req.cmd.bytes <= 1048575 && req.cmd.guard && req.cmd.parity == old_obj.phase &&
                req.route == 3;
          end
          default: ;
        endcase
        legal &= pending >= 0 && pending <= 1048575 && tx >= -1048575 && tx <= 1048575;
        candidate.pending = pending[19:0];
        candidate.tx = tx[20:0];
        if (pending == 0 && tx == 0) begin
          candidate.phase = !old_obj.phase;
          candidate.pending = old_obj.expected;
        end
      end
      default:   legal = 0;
    endcase
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid <= 0;
      dirty <= 0;
      cursor <= 0;
      fault <= 0;
      epoch_q <= 0;
      state <= IDLE;
      flushing <= 0;
    end else if (!halt_i) begin
      if (epoch != epoch_q) begin
        if (!drained || dirty != 0) fault <= 1;
        else begin
          valid <= 0;
          cursor <= 0;
          epoch_q <= epoch;
        end
      end
      if (back_rsp_valid && back_rsp_ready && !(state inside {SAVE_WAIT, FILL_WAIT, INVAL_WAIT}))
        fault <= 1;
      if (!fault)
        case (state)
          IDLE: begin
            if (flush_req_valid && flush_req_ready) begin
              flushing <= 1;
              flush_index <= 0;
              state <= FLUSH_SCAN;
            end else if (service_req_valid && service_req_ready) begin
              req <= service_req_payload;
              if (service_req_payload.cmd.id.epoch != epoch ||
                  service_req_payload.cmd.addr[2:0] != 0 || service_req_payload.cmd.addr >= 233472)
                fault <= 1;
              else state <= LOOKUP;
            end
          end
          LOOKUP: begin
            slot <= hit ? hit_slot : victim;
            if (hit && req.cmd.op == BAR_INIT) fault <= 1;
            else if (hit) begin
              old_obj <= objects[hit_slot];
              state <= UPDATE;
            end else begin
              cursor <= victim + 2'd1;
              if (valid[victim] && dirty[victim]) state <= SAVE;
              else if (req.cmd.op == BAR_INIT) begin
                old_obj <= '0;
                state <= UPDATE;
              end else state <= FILL;
            end
          end
          UPDATE: begin
            if (!legal) fault <= 1;
            else begin
              next_obj <= candidate;
              state <= COMMIT;
            end
          end
          COMMIT: begin
            service_rsp_payload <= '{
                route: req.route,
                slot: req.slot,
                rsp: '{id: req.cmd.id, status: OK, completed: 1'b0},
                phase: next_obj.phase,
                initialized: next_obj.initialized
            };
            if (req.cmd.op == BAR_INVAL) state <= INVALIDATE;
            else begin
              objects[slot] <= next_obj;
              valid[slot] <= 1;
              tags[slot] <= req.cmd.addr[31:3];
              if (modifying) dirty[slot] <= 1;
              state <= RESP;
            end
          end
          SAVE: if (back_req_ready) state <= SAVE_WAIT;
          SAVE_WAIT:
          if (back_rsp_valid) begin
            if (back_rsp_payload.status != OK) fault <= 1;
            else begin
              dirty[slot] <= 0;
              if (flushing) state <= FLUSH_SCAN;
              else if (req.cmd.op == BAR_INIT) begin
                old_obj <= '0;
                state <= UPDATE;
              end else state <= FILL;
            end
          end
          FILL: if (back_req_ready) state <= FILL_WAIT;
          FILL_WAIT:
          if (back_rsp_valid) begin
            if (back_rsp_payload.status != OK) fault <= 1;
            else begin
              old_obj <= back_rsp_payload.value;
              state <= UPDATE;
            end
          end
          INVALIDATE: if (back_req_ready) state <= INVAL_WAIT;
          INVAL_WAIT:
          if (back_rsp_valid) begin
            if (back_rsp_payload.status != OK) fault <= 1;
            else begin
              valid[slot] <= 0;
              dirty[slot] <= 0;
              state <= RESP;
            end
          end
          RESP: if (service_rsp_ready) state <= IDLE;
          FLUSH_SCAN: begin
            if (flush_index == 4) state <= FLUSH_RESP;
            else begin
              if (dirty[flush_index[1:0]]) begin
                slot <= flush_index[1:0];
                state <= SAVE;
              end
              flush_index <= flush_index + 3'd1;
            end
          end
          FLUSH_RESP:
          if (flush_rsp_ready) begin
            flushing <= 0;
            state <= IDLE;
          end
          default: fault <= 1;
        endcase
    end
  end
endmodule
