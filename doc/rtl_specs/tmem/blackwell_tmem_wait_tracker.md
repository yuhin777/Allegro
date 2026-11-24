# blackwell_tmem_wait_tracker

## Description

The 32 live records track LD/ST from registration through complete after ordinary done consumption. One ST wait snapshot waits only for unfinished stores of the same warp preceding its cutoff.

| Signal / channel | Direction, type / width | Peer | Handshake or sampling condition |
| --- | --- | --- | --- |
| `alloc` | Input, [rf_track_alloc_t](#wait-types), 59 bits | Top-level R_RF_ISSUE | `{id:58,store:1}`, register before engine execution. |
| `slot` | Output, [rf_track_slot_t](#wait-types), 63 bits | Top-level R_RF_ISSUE | Original ID and 5-bit live slot. |
| `complete` | Input, [rf_track_done_t](#wait-types), 67 bits | LD/ST engine | `{slot:5,id:58,status:4}`, sent after ordinary done consumption. |
| `wait_cmd` | Input, [tmem_wait_cmd_t](#wait-types), 58 bits | Software front end | Capture this warp's stores preceding the cutoff. |
| `wait_done` | Output, [op_done_t](../top/blackwell_async_subsystem_top.md#identity), 62 bits | Software front end | Publish `{id,OK}` once pending reaches zero. |
| `epoch_i` | Input, 16 bits, no handshake | Top level | Current CTA lifetime. |
| `stop_i` | Input, 1 bit | Top level | Stop new alloc/wait. Registered slots, completes, and results continue. |
| `drained_o` / `fault_o` | Output, 1 bit each | Top level | All live/wait/slot and held outputs empty / runtime fault. |

## Functionality

RF/wait commands require the low five issuer bits zero. issuer[9:5] identifies the warp. warp%4 selects only the physical RF partition in TMEM and cannot substitute for warp identity.

<a id="wait-types"></a>

### Wait and internal registration types

| Type | Fields (high to low) | Bits |
|---|---|---:|
| `tmem_wait_cmd_t` | id58 | 58 |
| `rf_track_alloc_t` | id58, store1 | 59 |
| `rf_track_slot_t` | id58, slot5 | 63 |
| `rf_track_done_t` | slot5, id58, status4 | 67 |

Software wait returns op_done_t. [LDST engine](blackwell_tmem_ldst_engine.md) defines actual LD/ST data completion edges.

### Registration and cutoff

Each of 32 live entries holds valid1, id58, and store1. alloc.fire selects the lowest free slot and reserves its slot response (5-bit index and valid1, with ID from the entry). Stall the next alloc until slot consumption. The top issues to the engine after receiving slot. complete and wait may still handshake when the table is full.

After final LD RF writeback or actual ST write ACK, the engine returns pin and outputs ordinary done. It sends complete only after done is consumed. A matching OK complete by slot and full ID clears the corresponding wait.pending bit and releases the live entry on that edge. Reuse can start on the next edge. Ordinary done ready is independent of wait_done to avoid mutual waiting. Non-OK or mismatched results follow [runtime fault handling](../top/blackwell_async_subsystem_top.md#common-protocol).

One wait entry holds valid1, id58, and pending32, totaling 91 bits. wait_cmd.fire captures pre-edge live stores of the same epoch and warp, subtracting old slots completing on this edge. Exclude LD and same-edge new alloc. Later allocations cannot enlarge the set. When pending is zero, OK can deliver at the next edge at the earliest, including for an empty set. Hold wait_done until consumed. A busy wait stalls new waits while LD/ST can register in other free slots and complete.

Normal stop prevents new external commands. Old complete, slot, and results continue. Synchronous reset clears valid and selections. Normal epoch change requires drained. Verify empty wait after consuming 64 stores, same-edge alloc/complete/wait, different warps, LD exclusion, and independent backpressure on both return ports.
