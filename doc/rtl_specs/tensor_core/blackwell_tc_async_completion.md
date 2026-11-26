# blackwell_tc_async_completion

## Description

One R_COMMIT converts a commit whose cutoff set is satisfied into one barrier arrival. After software consumes the result, the module returns the original slot to the tracker.

| Signal / channel | Direction | Type / width | Peer | Sampling condition |
|---|---|---|---|---|
| `ready_commit` | Input | [tc_ready_commit_t](blackwell_tc_completion_tracker.md#commit-contract) (93 bits) | TC tracker | Transfer on `ready_commit.fire`. pending=0 and issuer order eligible. |
| `tc_bar_req` | Output | [tc_bar_req_t](../mbarrier/blackwell_mbarrier_frontend.md#command) (90 bits) | barrier frontend | Transfer on `tc_bar_req.fire`. `{id:58,addr:32}`, fixed ARRIVE(1) |
| `tc_bar_rsp` | Input | [op_done_t](../top/blackwell_async_subsystem_top.md#identity) (62 bits) | barrier frontend | Transfer on `tc_bar_rsp.fire`. OK confirms atomic object update. An error raises fault. |
| `commit_done` | Output | op_done_t (62 bits) | Software front end | Transfer on `commit_done.fire`. Software-consumable commit result. |
| `commit_retire` | Output | [tc_commit_retire_t](blackwell_tc_completion_tracker.md#commit-contract) (61 bits) | TC tracker | Transfer on `commit_retire.fire`. `{slot:3,id:58}`, releases the tracker slot. |
| `epoch` | Input | 16 bits | Top level | Level identifying the active CTA lifetime. |
| `stop` | Input | 1 bit | Top level | Drain level. Continue accepting internal ready_commit work. |
| `drained` | Output | 1 bit | Top level | Level asserted when no transaction or result is held. |
| `fault` | Output | 1 bit | Top level | Sticky runtime fault level, cleared by isolated reset. |

## Functionality

R_COMMIT holds the 93-bit ready_commit and FSM. The barrier return, software done, and retire reuse this record. Reserve result space at acceptance so the barrier response is independent of software ready.

### Acceptance, arrival, response, and retirement

| State | Action | Transition |
|---|---|---|
| EMPTY | ready_commit_ready when fault is clear | On acceptance enter SEND |
| SEND | Present the sole tc_bar_req | After fire enter WAIT_BAR |
| WAIT_BAR | Check full ID and status of tc_bar_rsp | Matching OK enters DONE. An error raises runtime fault |
| DONE | Hold commit_done | After consumption enter RETIRE |
| RETIRE | Hold old commit_retire. On retire.fire a new ready_commit may be accepted on the same edge | Enter SEND on replacement or EMPTY otherwise |

Hold ID and address in SEND until fire, then wait only for the matching response. Each commit issues exactly one ARRIVE(1) in normal execution.

### Atomic update and visibility

Ordinary arrival has count 1 and leaves tx-count unchanged. Before ready_commit is presented, every covered MMA has retired all actual write ACKs. The tracker establishes this condition. The bridge cannot relax it.

A successful tc_bar_rsp indicates arrival committed atomically in the cache. It may flip phase and wake a wait. The cache owns the dirty object until writeback.

Software observes phase through `mbarrier.try_wait.parity`. A successful observation also needs an acquire ACK before returning true to software. [Wait and acquire](../mbarrier/blackwell_mbarrier_wait.md)

### Timing

For ready_commit accepted at g, the earliest tc_bar_req is g+1. With bar_rsp accepted at r, commit_done can deliver at r+1 and retire at r+2. On that edge the next eligible ready_commit may be sampled while old register contents supply the old retire.

While commit_done is stalled, retain the tracker slot so later commits from the same issuer cannot overtake the result. Accepted operations of different issuers can continue executing and completing. Backpressure new commands only when tracker capacity fills.

Hold R_COMMIT if retire is blocked. The tracker determines retire ready by matching the old slot/ID, independently of new ready_commit. A ready record from another issuer may replace it on the same edge. A commit from the same issuer remains gated by older commits in the tracker.

### Reset and acceptance

Continue accepting previously registered commits during normal stop. drained requires EMPTY and no held output. Only then may epoch change normally. Synchronous reset clears FSM/valid. Unknown or non-OK responses trigger [top-level fault handling](../top/blackwell_async_subsystem_top.md#common-protocol). Each successful commit produces one object request, software result, and retirement.
