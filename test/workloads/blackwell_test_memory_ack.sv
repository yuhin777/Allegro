// The test configures this route before issuing the owner. Its original
// payload and valid remain at the fabric head throughout a forced delay.
module blackwell_test_memory_ack
  import blackwell_async_pkg::*;
  import blackwell_tmem_pkg::*;
(
  input logic in_valid,
  output logic in_ready,
  input tmem_wr_ack_t in_payload,
  output logic out_valid,
  input logic out_ready,
  output tmem_wr_ack_t out_payload
);
  mem_tag_t target = '0;
  logic stall = 0, inject_memory = 0;
  wire matched = in_payload.tag == target;
  assign out_valid = in_valid && !(matched && stall);
  assign in_ready = out_ready && !(matched && stall);
  always_comb begin
    out_payload = in_payload;
    if (matched && inject_memory) out_payload.status = MEMORY;
  end
endmodule
