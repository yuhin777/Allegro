# blackwell_tmem_manager

## Description

Manages the full TMEM allocation exclusively owned by one CTA (128 lanes ×512 columns), this epoch's allocation permit, and references for five fixed users. The [fabric](blackwell_tmem_fabric.md#tmem-layout) defines data addressing.

| Signal / channel | Direction | Type / width | Peer | Sampling condition |
|---|---|---|---|---|
| `manage_cmd` | Input | [tmem_manage_cmd_t](#management-types) (102 bits) | Management front end | Transfer on `manage_cmd.fire`. ALLOC, DEALLOC, and relinquish allocation permit. |
| `alloc_credit_o` | Output | 1 bit | Management front end | `permit && !allocated`, sampled before selecting ALLOC. [Ingress arbitration](#alloc-admission) |
| `manage_rsp` | Output | [tmem_manage_rsp_t](#management-types) (90 bits) | Management front end | Transfer on `manage_rsp.fire`. Original ID and ALLOC base. Return base=0 for other operations. |
| `pin_req` | Input | 61 bits (58-bit ID and 3-bit user) | MMA engine, LD/ST | On `pin_req.fire`, acquire the fixed user reference. |
| `pin_rsp` | Output | op_done_t (58 bits) | MMA engine, LD/ST | On `pin_rsp.fire`, confirm the pin by ID. |
| `unpin` | Input | 61 bits | MMA engine, LD/ST | On `unpin.fire`, release the reference for the supplied 58-bit ID and 3-bit user. |
| `epoch_i` | Input | 16 bits | Top level | Level. Current CTA lifetime. |
| `stop_i` | Input | 1 bit | Top level | Level. Stop new external management commands. Continue pins, unpins, and responses for accepted work. |
| `epoch_end` | Input | Event without payload | Top level | Transfer on `epoch_end.fire`. The top has finished flush/ordering and all pins have returned. Atomically clear the old allocation and close the epoch. |
| `empty_o` | Output | 1 bit | Top level | Level. No allocation, references, or held responses. |
| `drained_o` | Output | 1 bit | Top level | Level. No references or outstanding responses. |

## Functionality

<a id="management-types"></a>

### Commands and state

`tmem_manage_cmd_t={id:58,op:2,base:32,columns:10}` (102 bits) encodes op 0/1/2 as ALLOC, DEALLOC, and RELINQUISH_ALLOC_PERMIT respectively. `tmem_manage_rsp_t={id:58,base:32}` is 90 bits. Management commands use a converged warp with issuer low five bits zero. ALLOC/DEALLOC support only base=0 and columns=512. RELINQUISH requires both fields zero. Use the [instruction scope](../../proposals/supported_ptx.md) for instruction preconditions.

`tmem_pin_req_t` and `tmem_unpin_t` both use `{id:58,user:3}`, `tmem_pin_rsp_t=op_done_t`. Users 0…2 correspond to the three physical MMA records, and 3 and 4 to LD and ST. Each user retains its full current ID for top-level response routing. The manager holds allocated, permit, and a five-bit in-use bitmap. From pin through matching unpin a user retains the same identity and must release before reuse. Provide a separate 90-bit management response slot, 58-bit pin response slot, arbitration cursor, and epoch/closed control.

<a id="alloc-admission"></a>

### Allocation and release

The front end fairly selects candidates eligible under each warp's program order. ALLOC participates only with valid credit. While occupied, other warps' DEALLOC and RELINQUISH can still acquire the shared ingress. Hold a selected command until fire. Select the next ALLOC from occupancy after the preceding commit. Software may relinquish the permit only after its last ALLOC in this epoch. Credit then stays 0 until the next epoch.

Round-robin among committable management, pin, and unpin candidates, committing at most one per edge. A response slot can replace an old result on its consumption edge. ALLOC handshake sets allocated and returns base=0. Before issuing ALLOC the front end reserves ID, SMEM [dst], and writeback space. It issues one actual 32-bit weak SMEM write and waits for successful acknowledgment to order subsequent same-address reads. RELINQUISH clears permit. Existing allocation remains usable. Software issues DEALLOC for a live allocation after old accesses finish and all five references have returned. DEALLOC clears allocated at management acceptance. Simulation asserts these preconditions, command encoding and current epoch.

### Reference acquisition, timing, and lifetime

Each engine pins the allocation covering its access. Simulation asserts that the lane/column range, layout and alignment are legal in widened arithmetic. On pin commit, set the free bit for that user and return the original ID. An engine issuing unpin drives the original ID and fixed user from its active record. The manager clears the user bit on unpin.fire. Simulation asserts the allocation and source/user identity at pin, and matches each unpin to that user’s live ID and epoch. Unpin ready is independent of management and pin responses. A request committed at edge a can deliver its response at a+1 at the earliest. unpin.fire returns the reference on its edge. Normal stop permits old commands to acquire and return references.

Synchronous reset clears allocation occupancy, references, and response valid and sets closed. Opening a legal new epoch sets permit. On normal shutdown the top issues epoch_end after flush and ordering finish. Accept only with no references, held responses, or same-edge control commit. Clear allocated/permit and close the old epoch. epoch_end may reclaim a static allocation.

A waiting ALLOC becomes eligible after successful DEALLOC when the allocation permit is available.
