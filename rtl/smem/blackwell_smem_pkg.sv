package blackwell_smem_pkg;
  import blackwell_async_pkg::*;
  typedef struct packed {
    mem_tag_t tag;
    logic [31:0] addr;
    logic [15:0] byte_mask;
  } smem_rd_req_t;
  typedef struct packed {
    mem_tag_t tag;
    logic [31:0] addr;
    logic [15:0] byte_mask;
    logic [127:0] data;
  } smem_wr_req_t;
  typedef struct packed {
    mem_tag_t tag;
    logic [127:0] data;
    status_t status;
  } smem_rd_rsp_t;
  typedef struct packed {
    mem_tag_t tag;
    status_t  status;
  } smem_wr_ack_t;
  typedef struct packed {
    logic write;
    mem_tag_t tag;
    logic [31:0] addr;
    logic [15:0] byte_mask;
    logic [127:0] data;
  } smem_atom_req_t;
  typedef struct packed {
    logic write;
    mem_tag_t tag;
    logic [127:0] data;
    status_t status;
  } smem_atom_rsp_t;
endpackage
