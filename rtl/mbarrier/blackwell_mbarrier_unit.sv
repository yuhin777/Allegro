module blackwell_mbarrier_unit
  import blackwell_async_pkg::*;
  import blackwell_mbarrier_pkg::*;
(
  input logic clk,
  input logic rst_n,
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
  output logic drained
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
  logic hit, found_empty, flushing, modifying;
  logic [15:0] epoch_q;
  bar_service_req_t req;
  assign drained = state == IDLE;
  assign flush_req_ready = rst_n && drained;
  assign service_req_ready = flush_req_ready && !flush_req_valid;
  assign service_rsp_valid = state == RESP;
  assign flush_rsp_valid = state == FLUSH_RESP;
  assign back_req_valid = state inside {SAVE, FILL, INVALIDATE};
  assign back_rsp_ready = rst_n;
  assign back_req_payload.write = state != FILL;
  assign back_req_payload.addr = state == SAVE ? {tags[slot], 3'b0} : req.cmd.addr;
  assign back_req_payload.value = state == SAVE ? objects[slot] : '0;
  assign modifying = req.cmd.op != BAR_QUERY;
  assign change_valid = (state == COMMIT && modifying && req.cmd.op != BAR_INVAL) ||
      (state == INVAL_WAIT && back_rsp_valid);
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
    candidate = old_obj;
    case (req.cmd.op)
      BAR_INIT: candidate = '{
          reserved: 0, initialized: 1, phase: 0, tx: '0,
          expected: req.cmd.count[19:0], pending: req.cmd.count[19:0]
      };
      BAR_INVAL: candidate = '0;
      BAR_ARRIVE, BAR_EXPECT, BAR_COMPLETE: begin
        case (req.cmd.op)
          BAR_ARRIVE: candidate.pending = old_obj.pending - req.cmd.count[19:0];
          BAR_EXPECT: begin
            candidate.pending = old_obj.pending - 20'd1;
            candidate.tx = old_obj.tx + $signed({1'b0, req.cmd.bytes[19:0]});
          end
          BAR_COMPLETE: candidate.tx = old_obj.tx - $signed({1'b0, req.cmd.bytes[19:0]});
          default: ;
        endcase
        if (candidate.pending == 0 && candidate.tx == 0) begin
          candidate.phase = !old_obj.phase;
          candidate.pending = old_obj.expected;
        end
      end
      default: ;
    endcase
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      valid <= 0;
      dirty <= 0;
      cursor <= 0;
      epoch_q <= 0;
      state <= IDLE;
      flushing <= 0;
    end else begin
      if (epoch != epoch_q) begin
        valid <= 0;
        dirty <= 0;
        cursor <= 0;
        epoch_q <= epoch;
      end
      case (state)
        IDLE: begin
          if (flush_req_valid && flush_req_ready) begin
            flushing <= 1;
            flush_index <= 0;
            state <= FLUSH_SCAN;
          end else if (service_req_valid && service_req_ready) begin
            req <= service_req_payload;
            state <= LOOKUP;
          end
        end
        LOOKUP: begin
          slot <= hit ? hit_slot : victim;
          if (hit) begin
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
          next_obj <= candidate;
          state <= COMMIT;
        end
        COMMIT: begin
          service_rsp_payload <= '{
              route: req.route,
              slot: req.slot,
              rsp: '{id: req.cmd.id, completed: 1'b0},
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
          dirty[slot] <= 0;
          if (flushing) state <= FLUSH_SCAN;
          else if (req.cmd.op == BAR_INIT) begin
            old_obj <= '0;
            state <= UPDATE;
          end else state <= FILL;
        end
        FILL: if (back_req_ready) state <= FILL_WAIT;
        FILL_WAIT:
        if (back_rsp_valid) begin
          old_obj <= back_rsp_payload.value;
          state <= UPDATE;
        end
        INVALIDATE: if (back_req_ready) state <= INVAL_WAIT;
        INVAL_WAIT:
        if (back_rsp_valid) begin
          valid[slot] <= 0;
          dirty[slot] <= 0;
          state <= RESP;
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
        default: ;
      endcase
    end
  end
`ifndef SYNTHESIS
  function automatic logic valid_object(input bar_object_t obj);
    return !obj.reserved && obj.initialized && obj.expected != 0 &&
        obj.pending <= obj.expected && obj.tx != 21'sh100000;
  endfunction
  always_ff @(posedge clk) begin
    if (rst_n) begin
      if (epoch != epoch_q) assert (drained && dirty == 0);
      if (service_req_valid && service_req_ready) begin
        assert (service_req_payload.cmd.id.epoch == epoch);
        assert (service_req_payload.cmd.addr[2:0] == 0 && service_req_payload.cmd.addr < 233472);
        assert (service_req_payload.cmd.op inside
                {BAR_INIT, BAR_INVAL, BAR_QUERY, BAR_ARRIVE, BAR_EXPECT, BAR_COMPLETE});
      end
      if (back_rsp_valid) begin
        assert (state inside {SAVE_WAIT, FILL_WAIT, INVAL_WAIT});
        if (state == FILL_WAIT) assert (valid_object(bar_object_t'(back_rsp_payload.value)));
      end
      if (state == LOOKUP && req.cmd.op == BAR_INIT) assert (!hit);
      if (state == UPDATE) begin
        logic signed [33:0] pending, tx, byte_count;
        pending = $signed({14'b0, old_obj.pending});
        tx = 34'($signed(old_obj.tx));
        byte_count = $signed({2'b0, req.cmd.bytes});
        if (req.cmd.op != BAR_INIT) assert (valid_object(old_obj));
        case (req.cmd.op)
          BAR_INIT: assert (req.cmd.count inside {[1 : 1048575]});
          BAR_ARRIVE: begin
            assert (req.cmd.count inside {[1 : 1048575]});
            pending -= $signed({2'b0, req.cmd.count});
          end
          BAR_EXPECT: begin
            assert (req.cmd.bytes <= 1048575);
            pending -= 34'sd1;
            tx += byte_count;
          end
          BAR_COMPLETE: begin
            assert (req.cmd.bytes <= 1048575 && req.route == 3 && req.cmd.parity == old_obj.phase);
            tx -= byte_count;
          end
          default: ;
        endcase
        assert (pending >= 0 && pending <= 1048575 && tx >= -1048575 && tx <= 1048575);
      end
    end
  end
`endif
endmodule
