# blackwell_tmem_manager

## Description

Manages the full TMEM allocation exclusively owned by one CTA (128 lanes ×512 columns), this epoch's allocation permit, and references for five fixed users. The [fabric](blackwell_tmem_fabric.md#tmem-layout) defines data addressing.

| Signal / channel | Direction, type / width | Peer | Handshake or sampling condition |
| --- | --- | --- | --- |
| `manage_cmd` | Input, [tmem_manage_cmd_t](#management-types), 102 bits | Management front end | ALLOC, DEALLOC, and relinquish allocation permit. |
| `alloc_credit_o` | Output, 1 bit | Management front end | `permit && !allocated`, sampled before selecting ALLOC. [Ingress arbitration](#alloc-admission) |
| `manage_rsp` | Output, [tmem_manage_rsp_t](#management-types), 94 bits | Management front end | Original ID, status, and ALLOC base. Return base=0 for other operations. |
| `pin_req` / `pin_rsp` | Input 61 bits / output 62 bits | MMA engine, LD/ST | `{id58,user3}` acquires a reference and receives `op_done_t`. |
| `unpin` | Input 61 bits | MMA engine, LD/ST | `{id58,user3}`, fire releases the user's reference. |
| `epoch_i` | Input, 16 bits, no handshake | Top level | Current CTA lifetime. |
| `stop_i` | Input, 1 bit, no handshake | Top level | Stop new external management commands. Continue pins, unpins, and responses for accepted work. |
| `epoch_end` | Input event, no payload | Top level | The top has finished flush/ordering and all pins have returned. Atomically clear the old allocation and close the epoch. |
| `empty_o` | Output, 1 bit | Top level | No allocation, references, or held responses. |
| `drained_o` | Output, 1 bit | Top level | No references or outstanding responses. |
| `fault_o` | Output, 1 bit | Top level | Protocol fault such as unknown/duplicate unpin. |

## Functionality

<a id="management-types"></a>

### Commands and state

`tmem_manage_cmd_t={id:58,op:2,base:32,columns:10}` (102 bits) encodes op 0/1/2 as ALLOC, DEALLOC, and RELINQUISH_ALLOC_PERMIT respectively. `tmem_manage_rsp_t={id:58,status:4,base:32}` is 94 bits. Management commands use a converged warp with issuer low five bits zero. ALLOC/DEALLOC support only base=0 and columns=512. RELINQUISH requires both fields zero. Use the [instruction scope](../../proposals/supported_ptx.md) for ingress precheck.

`tmem_pin_req_t` and `tmem_unpin_t` both use `{id:58,user:3}`, `tmem_pin_rsp_t=op_done_t`. Users 0…2 correspond to the three physical MMA records, and 3 and 4 to LD and ST. Each user retains its full current ID and top-level routing checks the response. The manager holds allocated, permit, and a five-bit in-use bitmap. From pin through matching unpin a user retains the same identity and must release before reuse. Provide a separate 94-bit management response slot, 62-bit pin response slot, arbitration cursor, and epoch/closed control.

<a id="alloc-admission"></a>

### Allocation and release

The front end fairly selects candidates eligible under each warp's program order. ALLOC participates only with valid credit. While occupied, other warps' DEALLOC and RELINQUISH can still acquire the shared ingress. Hold a selected command until fire. Select the next ALLOC from occupancy after the preceding commit. Software may relinquish the permit only after its last ALLOC in this epoch. Credit then stays 0 until the next epoch.

Round-robin among committable management, pin, and unpin candidates, committing at most one per edge. A response slot can replace an old result on its consumption edge. ALLOC handshake sets allocated and returns base=0. Before issuing ALLOC the front end reserves ID, SMEM [dst], and writeback space. It issues one actual 32-bit weak SMEM write and waits for successful acknowledgment to order subsequent same-address reads. RELINQUISH clears permit. Existing allocation remains usable. Software issues DEALLOC after old accesses finish. At management acceptance the manager checks allocated and all five reference bits clear. On success clear allocated. If references remain, return INVALID in the reserved response slot and preserve allocation and use bits. No active allocation, double release, wrong epoch, or illegal internal user follows the [fault contract](../top/blackwell_async_subsystem_top.md#common-protocol).

### Reference acquisition, timing, and lifetime

Before pin, each engine validates actual lane/column ranges, layout, and alignment in widened arithmetic. Pin commit requires allocation, matching source/user, and a free bit. Set that bit and return the original ID with OK. An engine issuing unpin drives the original ID and fixed user from its active record. The manager checks the permitted user encoding for the source, epoch, and use bit and clears the bit on fire. Unpin ready is independent of management and pin responses. For a request committed at a the earliest response consumption is a+1. unpin.fire returns the reference on its edge. Normal stop permits old commands to acquire and return references.

Synchronous reset clears allocation occupancy, references, and response valid and sets closed. Opening a legal new epoch sets permit. On normal shutdown the top issues epoch_end after flush and ordering finish. Accept only with no references, held responses, or same-edge control commit. Clear allocated/permit and close the old epoch. epoch_end may reclaim a static allocation.

Use the F1/F2 512-column allocation and check a same-address SMEM read obtains base=0. Retain allocation while an old reference returns late. A subsequent DEALLOC allows another warp's waiting ALLOC to take the full block. Verify independent reference return from all five users and continued unpin progress under management or pin response backpressure.
