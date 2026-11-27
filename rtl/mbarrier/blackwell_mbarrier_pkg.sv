package blackwell_mbarrier_pkg;
  import blackwell_async_pkg::*;
  typedef enum logic [3:0] {
    BAR_INIT,
    BAR_INVAL,
    BAR_ARRIVE,
    BAR_EXPECT,
    BAR_TRY,
    BAR_FENCE_INIT,
    BAR_QUERY,
    BAR_COMPLETE
  } bar_op_t;
  typedef struct packed {
    async_id_t id;
    bar_op_t op;
    logic [31:0] addr, count, bytes;
    logic parity;
    logic [31:0] time_hint;
  } bar_cmd_t;
  typedef struct packed {
    async_id_t id;
    logic completed;
  } bar_rsp_t;
  typedef struct packed {
    logic [1:0] route;
    logic [4:0] slot;
    bar_cmd_t   cmd;
  } bar_service_req_t;
  typedef struct packed {
    logic [1:0] route;
    logic [4:0] slot;
    bar_rsp_t rsp;
    logic phase, initialized;
  } bar_service_rsp_t;
  typedef struct packed {
    logic [31:0] addr;
    logic phase, initialized;
  } bar_change_t;
  typedef struct packed {
    logic write;
    logic [31:0] addr;
    logic [63:0] value;
  } bar_back_req_t;
  typedef struct packed {
    logic [63:0] value;
  } bar_back_rsp_t;
  typedef struct packed {
    async_id_t   id;
    logic [31:0] addr;
  } bar_bind_t;
  typedef bar_bind_t tc_bar_req_t;
  typedef struct packed {
    async_id_t id;
    logic [31:0] bytes;
  } bar_producer_done_t;
  typedef struct packed {
    logic reserved, initialized, phase;
    logic signed [20:0] tx;
    logic [19:0] expected, pending;
  } bar_object_t;
endpackage
