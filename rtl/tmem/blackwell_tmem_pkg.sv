package blackwell_tmem_pkg;
  import blackwell_async_pkg::*;
  typedef struct packed {
    async_id_t   id;
    logic [1:0]  op;
    logic [31:0] base;
    logic [9:0]  columns;
  } tmem_manage_cmd_t;
  typedef struct packed {
    async_id_t id;
    status_t status;
    logic [31:0] base;
  } tmem_manage_rsp_t;
  typedef struct packed {
    async_id_t  id;
    logic [2:0] user;
  } tmem_pin_req_t;
  typedef tmem_pin_req_t tmem_unpin_t;
  typedef op_done_t tmem_pin_rsp_t;
  typedef struct packed {
    async_id_t id;
    logic store, x32;
    logic [31:0] base;
  } tmem_ldst_cmd_t;
  typedef struct packed {
    tmem_ldst_cmd_t cmd;
    logic [4:0] slot;
  } ldst_issue_t;
  typedef struct packed {
    async_id_t id;
    logic [6:0] index;
    logic last;
    logic [1023:0] data;
  } rf_beat_t;
  typedef struct packed {
    async_id_t id;
    logic store;
  } rf_track_alloc_t;
  typedef struct packed {
    async_id_t  id;
    logic [4:0] slot;
  } rf_track_slot_t;
  typedef struct packed {
    logic [4:0] slot;
    async_id_t id;
    status_t status;
  } rf_track_done_t;
  typedef struct packed {async_id_t id;} tmem_wait_cmd_t;
  typedef struct packed {
    mem_tag_t tag;
    logic [6:0] lane, word;
    logic [15:0] byte_mask;
  } tmem_rd_req_t;
  typedef struct packed {
    mem_tag_t tag;
    logic [6:0] lane, word;
    logic [15:0] byte_mask;
    logic [127:0] data;
  } tmem_wr_req_t;
  typedef struct packed {
    mem_tag_t tag;
    logic [127:0] data;
    status_t status;
  } tmem_rd_rsp_t;
  typedef struct packed {
    mem_tag_t tag;
    status_t  status;
  } tmem_wr_ack_t;
endpackage
