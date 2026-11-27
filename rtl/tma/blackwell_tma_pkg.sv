package blackwell_tma_pkg;
  import blackwell_async_pkg::*;
  typedef enum logic [2:0] {
    LOAD_TENSOR,
    STORE_TENSOR,
    LOAD_LINEAR,
    COMMIT_GROUP,
    WAIT_GROUP_READ,
    PROXY_FENCE,
    PREFETCH_MAP
  } tma_opcode_t;
  typedef struct packed {
    async_id_t id;
    tma_opcode_t opcode;
    logic [63:0] map_addr;
    logic [31:0] smem_addr;
    logic [63:0] global_addr;
    logic [31:0] bytes, barrier_addr;
    logic [3:0][31:0] coord;
    logic [63:0] cache_policy;
    logic wait_n;
  } tma_cmd_t;
  typedef struct packed {
    op_done_t done;
    logic [63:0] logical_bytes;
  } tma_rsp_t;
  typedef struct packed {
    logic [1:0] cls;
    logic [5:0] tag;
    logic phase;
  } gmem_id_t;
  typedef struct packed {
    gmem_id_t id;
    logic [2:0] op;
    logic [63:0] addr;
    logic [1023:0] data;
    logic [127:0] byte_mask;
    logic [63:0] cache_policy;
  } gmem_req_t;
  typedef struct packed {
    gmem_id_t id;
    logic [1023:0] data;
  } tma_gmem_return_t;
  typedef struct packed {
    gmem_id_t id;
    logic [1023:0] data;
    status_t status;
  } gmem_rsp_t;
  typedef logic [4:0] ticket_t;
  typedef struct packed {
    ticket_t  ticket;
    tma_cmd_t cmd;
  } tma_issue_t;
  typedef struct packed {
    ticket_t ticket;
    async_id_t id;
    logic [63:0] addr;
    logic prefetch;
  } tma_desc_req_t;
  typedef struct packed {
    ticket_t ticket;
    logic [1023:0] raw;
  } tma_desc_rsp_t;
  typedef struct packed {
    logic [63:0] base_addr;
    logic [3:0][32:0] dim;
    logic [2:0][39:0] stride;
    logic [3:0][8:0] box;
    logic [1:0] swizzle, l2promotion;
  } tensor_decoded_t;
  typedef struct packed {
    tma_cmd_t cmd;
    tensor_decoded_t map;
    ticket_t ticket;
    logic [63:0] total_bytes;
    logic [15:0] inner_bytes;
    logic [63:0] gmem_origin;
    logic [24:0] row_count;
  } tma_context_t;
  typedef struct packed {
    tma_issue_t issue;
    logic [1023:0] raw;
  } tma_setup_req_t;
  typedef struct packed {
    ticket_t ticket;
    logic context_slot;
    logic [63:0] total_bytes;
  } tma_setup_rsp_t;
  typedef struct packed {
    ticket_t ticket;
    logic context_slot;
  } tma_context_ref_t;
  typedef struct packed {
    logic smem_empty, gmem_empty;
    logic [10:0] smem_low, smem_high;
    logic [56:0] gmem_low, gmem_high;
  } tma_span_t;
  typedef enum logic [2:0] {
    SLOT_FREE,
    BUILD,
    READY,
    ARMED,
    WALK
  } setup_state_t;
  typedef struct packed {
    ticket_t ticket;
    logic [63:0] ordinal, gmem_line;
    logic [6:0] goff;
    logic [31:0] smem_sector;
    logic [6:0] soff;
    logic [2:0] xor_group;
    logic [7:0] logical_bytes;
    logic store, oob, last;
  } tma_segment_t;
  typedef struct packed {
    logic [5:0] tag;
    logic phase;
  } key_t;
  typedef struct packed {
    key_t key;
    tma_segment_t segment;
  } tma_start_t;
  typedef enum logic [2:0] {
    GMEM_REQ,
    GMEM_RSP,
    SMEM_REQ,
    SMEM_RSP,
    LOCAL_ZERO,
    NO_ACCESS
  } event_kind_t;
  typedef struct packed {
    key_t key;
    event_kind_t kind;
    logic [2:0] grp;
  } tma_xfer_event_t;
  typedef enum logic [2:0] {
    TAG_FREE,
    START,
    SOURCE,
    TARGET,
    RETIRE
  } tag_state_t;
  typedef struct packed {
    tag_state_t state;
    logic phase;
    ticket_t ticket;
    logic [10:0] sector;
    logic [6:0] soff, goff;
    logic [2:0] xor_group;
    logic [7:0] logical_bytes;
    logic oob;
    logic gmem_sent, gmem_done;
    logic [7:0] smem_sent, smem_done;
    logic source_done, target_done;
  } tma_tag_t;
  typedef struct packed {
    ticket_t ticket;
    logic [1:0] boundary;
  } tma_progress_t;
  typedef struct packed {
    logic live;
    async_id_t id;
    logic store;
    logic [63:0] cache_policy, total_bytes;
    logic bound;
  } tma_owner_view_t;

  function automatic logic [15:0] group_mask(input tma_tag_t t, input logic [2:0] g);
    logic [15:0] mask;
    for (int i = 0; i < 16; i++) begin
      logic [7:0] offset;
      offset = {1'b0, (g ^ t.xor_group), 4'(i)};
      mask[i] = (offset >= {1'b0, t.soff}) && (offset < {1'b0, t.soff} + t.logical_bytes);
    end
    return mask;
  endfunction
  function automatic logic [7:0] active_groups(input tma_tag_t t);
    logic [7:0] answer;
    for (int g = 0; g < 8; g++) answer[g] = |group_mask(t, 3'(g));
    return answer;
  endfunction
  function automatic logic [127:0] line_mask(input tma_tag_t t);
    logic [127:0] mask;
    for (int i = 0; i < 128; i++)
    mask[i] = (i >= int'(t.goff) && i < int'(t.goff) + int'(t.logical_bytes));
    return mask;
  endfunction
endpackage
