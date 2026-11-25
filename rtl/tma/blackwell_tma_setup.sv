module blackwell_tma_setup
  import blackwell_async_pkg::*;
  import blackwell_tma_pkg::*;
(
  input logic clk,
  input logic rst_n,
  input logic halt_i,
  input logic request_valid,
  input logic result_ready,
  input logic arm_valid,
  input logic walk_start_valid,
  input logic slot_release_valid,
  output logic request_ready,
  output logic result_valid,
  output logic arm_ready,
  output logic walk_start_ready,
  output logic slot_release_ready,
  input tma_setup_req_t request_payload,
  output tma_setup_rsp_t result_payload,
  input tma_context_ref_t arm_payload,
  input tma_context_ref_t walk_start_payload,
  input tma_context_ref_t slot_release_payload,
  output tma_context_t ctx[2],
  output setup_state_t slot_state[2],
  output ticket_t slot_ticket[2],
  output tma_span_t span[2],
  output logic drained,
  output logic fault
);
  typedef enum logic [2:0] {
    DECODE,
    CALC,
    CLIP_STORE,
    CHECK,
    PUBLISH
  } build_t;
  build_t stage[2];
  logic [1:0] map_legal, mult_busy;
  logic [3:0] product_step[2];
  logic [1:0] clipped_store;
  logic [3:0][7:0] last_local[2];
  logic [1:0] clip_dim[2];
  logic [25:0] last_sector[2];  // Up to 4 panels of 256^3 rows.
  localparam logic [3:0] ClipSectorProduct = 4'd10;
  logic [5:0] launched[2], completed[2];
  logic [2:0][32:0] lows[2], highs[2];
  logic [63:0] rows[2], elements[2];
  logic [75:0] low_addr[2], high_addr[2];
  logic compute_rr, found, chosen, publication, publication_slot, free_slot;
  logic [ 3:0] task_id;
  logic [63:0] mul_a;
  logic [39:0] mul_b;
  typedef struct packed {
    logic valid, slot;
    logic [3:0] task_id;
    logic [75:0] value;
  } product_t;
  product_t pipe[4];
  function automatic tensor_decoded_t decode(input logic [1023:0] raw);
    tensor_decoded_t m;
    m = '0;
    m.base_addr = raw[32+:64];
    m.swizzle = raw[24+:2];
    m.l2promotion = raw[28+:2];
    for (int i = 0; i < 4; i++) begin
      m.dim[i] = {1'b0, raw[(12+i*4)*8+:32]} + 33'd1;
      m.box[i] = raw[(72+i*2)*8+:9];
      if (i > 0) m.stride[i-1] = raw[(32+i*8)*8+:40];
    end
    return m;
  endfunction
  function automatic logic valid_map(input logic [1023:0] raw);
    logic legal;
    legal = raw[23:0] == 24'h060310 && (raw[31:24] & 8'hcf) == 8'h03 && raw[35:32] == 0 &&
        raw[32*8+:64] == 0 && raw[28*8+:32] == 0 && raw[64*8+:64] == 0 && raw[80*8+:16] == 0 &&
        raw[1023:86*8] == 0;
    for (int i = 0; i < 4; i++) begin
      legal &= raw[(72+i*2)*8+:16] inside {[1 : 256]};
      legal &= raw[(82+i)*8+:8] == 1;
      if (i != 0)
        legal &= raw[(32+i*8)*8+:64] != 0 && raw[(32+i*8)*8+:4] == 0 && raw[(32+i*8)*8+40+:24] == 0;
    end
    return legal && raw[72*8+:3] == 0;
  endfunction
  always_comb begin
    logic free_any;
    free_any = 0;
    free_slot = 0;
    found = 0;
    chosen = 0;
    task_id = 0;
    mul_a = 0;
    mul_b = 0;
    publication = 0;
    publication_slot = 0;
    for (int j = 0; j < 2; j++) begin
      logic s;
      s = compute_rr ^ 1'(j);
      slot_ticket[j] = ctx[j].ticket;
      if (!free_any && (slot_state[j] == SLOT_FREE ||
                        (slot_release_valid && slot_release_payload.context_slot == 1'(j)))) begin
        free_any = 1;
        free_slot = 1'(j);
      end
      if (!publication && slot_state[s] == BUILD && stage[s] == PUBLISH) begin
        publication = 1;
        publication_slot = s;
      end
      if (!found && slot_state[s] == BUILD && stage[s] == CLIP_STORE && !mult_busy[s]) begin
        found = 1;
        chosen = s;
        task_id = ClipSectorProduct;
        mul_a = 64'(last_sector[s]);
        mul_b = 40'(ctx[s].map.box[clip_dim[s]]);
      end
      if (!found && slot_state[s] == BUILD && stage[s] == CALC) begin
        if (!mult_busy[s] && product_step[s] < 4) begin
          found = 1;
          chosen = s;
          task_id = product_step[s];
          mul_a = product_step[s] == 0 ? 64'd1 : rows[s];
          mul_b = 40'(ctx[s].map.box[2'(product_step[s]+4'd1)]);
        end else begin
          for (int n = 0; n < 6; n++)
          if (!found && !launched[s][n]) begin
            found = 1;
            chosen = s;
            task_id = 4'(4 + n);
            mul_a = n % 2 == 0 ? 64'(lows[s][n/2]) : 64'(highs[s][n/2]);
            mul_b = ctx[s].map.stride[n/2];
          end
        end
      end
    end
    drained = slot_state[0] == SLOT_FREE && slot_state[1] == SLOT_FREE && !result_valid;
    request_ready = rst_n && !fault && free_any;
    arm_ready = slot_state[arm_payload.context_slot] == READY &&
        slot_ticket[arm_payload.context_slot] == arm_payload.ticket;
    walk_start_ready = slot_state[walk_start_payload.context_slot] == ARMED &&
        slot_ticket[walk_start_payload.context_slot] == walk_start_payload.ticket;
    slot_release_ready = slot_state[slot_release_payload.context_slot] inside {ARMED, WALK} &&
        slot_ticket[slot_release_payload.context_slot] == slot_release_payload.ticket;
  end
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      fault <= 0;
      result_valid <= 0;
      compute_rr <= 0;
      for (int i = 0; i < 2; i++) slot_state[i] <= SLOT_FREE;
      for (int i = 0; i < 4; i++) pipe[i].valid <= 0;
    end else if (!halt_i && !fault) begin
      if (arm_valid && !arm_ready || walk_start_valid && !walk_start_ready ||
          slot_release_valid && !slot_release_ready)
        fault <= 1;
      if (result_valid && result_ready) result_valid <= 0;
      if (arm_valid && arm_ready) slot_state[arm_payload.context_slot] <= ARMED;
      if (walk_start_valid && walk_start_ready) slot_state[walk_start_payload.context_slot] <= WALK;
      if (slot_release_valid && slot_release_ready)
        slot_state[slot_release_payload.context_slot] <= SLOT_FREE;
      if (request_valid && request_ready) begin
        slot_state[free_slot] <= BUILD;
        stage[free_slot] <= DECODE;
        ctx[free_slot].cmd <= request_payload.issue.cmd;
        ctx[free_slot].ticket <= request_payload.issue.ticket;
        ctx[free_slot].map <= request_payload.issue.cmd.opcode == LOAD_LINEAR ? '0 : decode(
            request_payload.raw
        );
        map_legal[free_slot] <= valid_map(request_payload.raw);
      end
      for (int i = 0; i < 2; i++)
      if (slot_state[i] == BUILD) begin
        if (stage[i] == DECODE) begin
          if (ctx[i].cmd.opcode == LOAD_LINEAR) stage[i] <= CHECK;
          else begin
            logic empty_tile, clipped;
            logic [75:0] addr_lo, addr_hi;
            empty_tile = 0;
            clipped = 0;
            addr_lo = 76'(ctx[i].map.base_addr);
            addr_hi = addr_lo + 1;
            for (int d = 0; d < 4; d++) begin
              logic signed [34:0] first, last, high_limit;
              first = 35'($signed(ctx[i].cmd.coord[d]));
              last = first + 35'({1'b0, ctx[i].map.box[d]}) - 1;
              high_limit = $signed({2'b0, ctx[i].map.dim[d]}) - 1;
              if (first < 0) first = 0;
              if (last > high_limit) begin
                clipped = 1;
                last = high_limit;
              end
              last_local[i][d] <= 8'(last - first);
              if (first > last) empty_tile = 1;
              if (d == 0) begin
                addr_lo += 76'(first[32:0]) << 1;
                addr_hi += 76'(last[32:0]) << 1;
              end else begin
                lows[i][d-1] <= first[32:0];
                highs[i][d-1] <= last[32:0];
              end
              if (ctx[i].cmd.opcode == STORE_TENSOR && $signed(ctx[i].cmd.coord[d]) < 0) fault <= 1;
            end
            clipped_store[i] <= ctx[i].cmd.opcode == STORE_TENSOR && clipped && !empty_tile;
            low_addr[i] <= addr_lo;
            high_addr[i] <= addr_hi;
            span[i].gmem_empty <= empty_tile;
            product_step[i] <= 0;
            mult_busy[i] <= 0;
            launched[i] <= 0;
            completed[i] <= 0;
            if (!map_legal[i] || ctx[i].cmd.smem_addr[3:0] != 0) fault <= 1;
            stage[i] <= CALC;
          end
        end
        if (stage[i] == CALC && product_step[i] == 4 && (&completed[i])) begin
          if (clipped_store[i]) begin
            // Linearize the last accessed (panel, z, y, x-row) using full box pitches.
            last_sector[i] <= 26'(last_local[i][0][7:6]);
            clip_dim[i] <= 3;
            stage[i] <= CLIP_STORE;
          end else stage[i] <= CHECK;
        end
        if (stage[i] == CHECK) begin
          logic [64:0] glast, slast;
          logic [63:0] total, inner, final_panel, final_within;
          logic linear, empty_g, empty_s, valid_geometry;
          linear = ctx[i].cmd.opcode == LOAD_LINEAR;
          total = linear ? 64'(ctx[i].cmd.bytes) : elements[i] << 1;
          inner = 64'(ctx[i].map.box[0]) << 1;
          final_panel = (inner - 1) >> 7;
          final_within = (inner - 1) & 127;
          empty_g = linear ? total == 0 : span[i].gmem_empty;
          empty_s = total == 0 || (ctx[i].cmd.opcode == STORE_TENSOR && empty_g);
          slast = 65'(ctx[i].cmd.smem_addr) +
              (linear ? 65'(total) -
               1 : ((65'(final_panel) * 65'(rows[i]) + 65'(rows[i]) - 1) << 7) + 65'(final_within));
          if (!linear && clipped_store[i])
            slast = 65'(ctx[i].cmd.smem_addr) + (65'(last_sector[i]) << 7) +
                65'({last_local[i][0][5:0], 1'b1});
          glast = 65'(ctx[i].cmd.global_addr) + 65'(total) - 1;
          valid_geometry = ctx[i].cmd.smem_addr[3:0] == 0 && (empty_s || slast < 233472);
          if (linear)
            valid_geometry &= ctx[i].cmd.global_addr[3:0] == 0 && ctx[i].cmd.bytes[3:0] == 0 &&
                (empty_g || !glast[64]);
          else valid_geometry &= empty_g || high_addr[i][75:64] == 0;
          if (ctx[i].cmd.opcode != STORE_TENSOR) valid_geometry &= total <= 1048575;
          if (!valid_geometry) fault <= 1;
          ctx[i].total_bytes <= total;
          ctx[i].inner_bytes <= linear ? '0 : inner[15:0];
          ctx[i].iteration_count <= linear ? total : elements[i];
          span[i].smem_empty <= empty_s;
          span[i].gmem_empty <= empty_g;
          span[i].smem_low <= ctx[i].cmd.smem_addr[17:7];
          span[i].smem_high <= slast[17:7];
          span[i].gmem_low <= linear ? ctx[i].cmd.global_addr[63:7] : low_addr[i][63:7];
          span[i].gmem_high <= linear ? glast[63:7] : high_addr[i][63:7];
          stage[i] <= PUBLISH;
        end
      end
      for (int i = 1; i < 4; i++) pipe[i] <= pipe[i-1];
      pipe[0] <= '{
          valid: found,
          slot: chosen,
          task_id: task_id,
          value: 76'(mul_a) * 76'(mul_b)
      };
      if (found) begin
        compute_rr <= !chosen;
        if (task_id < 4 || task_id == ClipSectorProduct) mult_busy[chosen] <= 1;
        else launched[chosen][3'(task_id-4'd4)] <= 1;
      end
      if (pipe[3].valid) begin
        logic s;
        logic [3:0] n;
        s = pipe[3].slot;
        n = pipe[3].task_id;
        if (n == ClipSectorProduct) begin
          last_sector[s] <= pipe[3].value[25:0] + 26'(last_local[s][clip_dim[s]]);
          mult_busy[s] <= 0;
          if (clip_dim[s] == 1) stage[s] <= CHECK;
          else clip_dim[s] <= clip_dim[s] - 1'b1;
        end else if (n < 4) begin
          if (n == 3) elements[s] <= pipe[3].value[63:0];
          else rows[s] <= pipe[3].value[63:0];
          mult_busy[s] <= 0;
          product_step[s] <= n + 4'd1;
        end else begin
          if (n[0]) high_addr[s] <= high_addr[s] + pipe[3].value;
          else low_addr[s] <= low_addr[s] + pipe[3].value;
          completed[s][3'(n-4'd4)] <= 1;
        end
      end
      if (publication && (!result_valid || result_ready)) begin
        result_valid <= 1;
        slot_state[publication_slot] <= READY;
        result_payload <= '{
            ticket: ctx[publication_slot].ticket,
            context_slot: publication_slot,
            total_bytes: ctx[publication_slot].total_bytes,
            status: OK
        };
      end
    end
  end
endmodule
