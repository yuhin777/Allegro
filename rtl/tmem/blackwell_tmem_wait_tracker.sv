module blackwell_tmem_wait_tracker
  import blackwell_async_pkg::*;
  import blackwell_tmem_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic halt_i,
  input logic stop_i,
  input logic [15:0] epoch_i,
  input logic alloc_valid,
  output logic alloc_ready,
  input rf_track_alloc_t alloc_payload,
  output logic slot_valid,
  input logic slot_ready,
  output rf_track_slot_t slot_payload,
  input logic complete_valid,
  output logic complete_ready,
  input rf_track_done_t complete_payload,
  input logic wait_cmd_valid,
  output logic wait_cmd_ready,
  input tmem_wait_cmd_t wait_cmd_payload,
  output logic wait_done_valid,
  input logic wait_done_ready,
  output op_done_t wait_done_payload,
  output logic drained_o,
  output logic fault_o
);
  logic [31:0] live, store, pending, snapshot;
  async_id_t ids[32], wait_id;
  logic waiting;
  logic [4:0] free_slot, return_slot;
  logic alloc_bad, wait_bad, complete_ok;
  always_comb begin
    free_slot = 0;
    alloc_bad = alloc_payload.id.issuer[4:0] != 0 || alloc_payload.id.epoch != epoch_i ||
        alloc_payload.id.seq == '1;
    wait_bad = wait_cmd_payload.id.issuer[4:0] != 0 || wait_cmd_payload.id.epoch != epoch_i ||
        wait_cmd_payload.id.seq == '1;
    for (int i = 31; i >= 0; i--) begin
      if (!live[i]) free_slot = 5'(i);
      if (live[i] && ids[i] == alloc_payload.id) alloc_bad = 1;
      snapshot[i] = live[i] && store[i] && ids[i].epoch == wait_cmd_payload.id.epoch &&
          ids[i].issuer == wait_cmd_payload.id.issuer;
    end
    if (complete_ok) snapshot[complete_payload.slot] = 0;
  end
  assign complete_ready = !halt_i && !fault_o;
  assign complete_ok = complete_valid && complete_ready && live[complete_payload.slot] &&
      ids[complete_payload.slot] == complete_payload.id && complete_payload.status == OK &&
      !(slot_valid && return_slot == complete_payload.slot);
  assign alloc_ready = !stop_i && !halt_i && !fault_o && !(&live) && (!slot_valid || slot_ready);
  assign slot_payload = '{id: ids[return_slot], slot: return_slot};
  assign wait_cmd_ready = !waiting && !stop_i && !halt_i && !fault_o;
  assign wait_done_valid = waiting && pending == 0;
  assign wait_done_payload = '{id: wait_id, status: OK};
  assign drained_o = !waiting && live == 0 && !slot_valid;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      live <= 0;
      pending <= 0;
      waiting <= 0;
      slot_valid <= 0;
      fault_o <= 0;
    end else begin
      if (slot_valid && slot_ready) slot_valid <= 0;
      if (wait_done_valid && wait_done_ready) waiting <= 0;
      if (complete_valid && complete_ready) begin
        if (!complete_ok) fault_o <= 1;
        else begin
          live[complete_payload.slot] <= 0;
          pending[complete_payload.slot] <= 0;
        end
      end
      if (alloc_valid && alloc_ready) begin
        if (alloc_bad) fault_o <= 1;
        else begin
          slot_valid <= 1;
          return_slot <= free_slot;
          live[free_slot] <= 1;
          ids[free_slot] <= alloc_payload.id;
          store[free_slot] <= alloc_payload.store;
        end
      end
      if (wait_cmd_valid && wait_cmd_ready) begin
        if (wait_bad) fault_o <= 1;
        else begin
          waiting <= 1;
          wait_id <= wait_cmd_payload.id;
          pending <= snapshot;
        end
      end
    end
  end
endmodule
