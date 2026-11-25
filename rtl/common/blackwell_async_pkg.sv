package blackwell_async_pkg;
  typedef enum logic [3:0] {
    OK,
    UNSUPPORTED,
    INVALID,
    RANGE,
    MEMORY,
    STALE,
    PROTOCOL
  } status_t;
  typedef struct packed {
    logic [15:0] epoch;
    logic [9:0]  issuer;
    logic [31:0] seq;
  } async_id_t;
  typedef struct packed {
    async_id_t id;
    status_t   status;
  } op_done_t;
  typedef struct packed {
    async_id_t   id;
    logic [3:0]  client;
    logic [15:0] token;
  } mem_tag_t;
  typedef struct packed {
    async_id_t   id;
    logic [2:0]  kind;
    logic [1:0]  scope, from_proxy, to_proxy;
    logic [63:0] addr;
    logic [31:0] bytes;
  } order_req_t;
  typedef op_done_t order_rsp_t;
  typedef struct packed {
    logic valid;
    logic [1:0] rec;
    async_id_t id;
  } mma_live_t;
endpackage
