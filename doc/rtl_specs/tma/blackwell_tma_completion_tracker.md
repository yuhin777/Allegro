# blackwell_tma_completion_tracker

## Description

Track data commands by the general-purpose ticket already allocated by the unit. All unfinished commands share 64 segment tags. Match each segment return by {tag,phase}. Long-lived state is independent of setup slots.

| Channel and direction | Type / width | Peer | Handshake or sampling condition |
| --- | --- | --- | --- |
| begin / owner_view[18] inputs | ticket5 / [tma_owner_view_t](blackwell_tma_unit.md#owner-view)[18] | TMA unit | begin initializes progress once for the specified ticket and may coincide with another command's allocate/retire. Read identity, direction, successful binding, and logical byte count combinationally by ticket. |
| allocate / generated inputs | [tma_segment_t](blackwell_tma_request_generator.md#segment) / [tma_finish_t](#transfer-types) | walker | The final segment allocates and sets generated for its ticket on the same allocate.fire edge. A close-only marker handshakes separately. After closure, allocate no further segments for that ticket. |
| start / tag_view[64] outputs | [tma_start_t](#transfer-types) / [tma_tag_t](#transfer-types) combinational view | data path | start delivers the segment and key. The view reflects pre-edge state. Address each event by key. |
| event[20] / data_ref[64] inputs | [tma_xfer_event_t](#transfer-types) / 1-bit level per entry | data path | Register one event on the edge of each bus fire. data_ref indicates that the data path still references the tag. |
| ticket_busy / target_visible outputs | One bit per general-purpose ticket on each output | TMA unit | busy spans begin to finish.fire. Set target_visible when generated and all segments' targets have received their required ACKs. Source progress, target visibility, and object acknowledgment release their respective dependencies separately. |
| progress / finish outputs | [tma_progress_t](#transfer-types) / tma_finish_t | TMA unit | Deliver source progress once, full progress once, and the final result to the unit. Hold when stalled. |
| producer_done output / producer_rsp input | [bar_producer_done_t](../mbarrier/blackwell_mbarrier_frontend.md#command) / op_done_t | Barrier front end (via unit) | One notification and one matching acknowledgment per bound load. |
| drained / fault outputs | 1 bit each | TMA unit | No remaining transactions, held selections, or command obligations / sticky protocol error. |

```mermaid
flowchart LR
 W["Walker segment"] --> A["Allocate / 64-entry tag table"]
 A -->|start| D["Data path / 16 data rows"]
 D -->|Port request and return events| A
 W -->|generated| C["Command source progress and destination completion"]
 A -->|Actual write ACK / retire| C
 C --> B["Load notifies mbarrier and waits for acknowledgment"]
 C --> S["Store reports full"]
```

## Functionality

<a id="transfer-types"></a>

### Ticket and segment identity

- `key={tag:u6,phase:u1}`, with tag indexing this table. GMEM class0 carries the key. Descriptors use separate class1. [unit](blackwell_tma_unit.md#gmem-types) defines the bus encoding. For SMEM client8, `token={6'b0,tag6,group3,phase1}` is 16 bits. Full mem_tag also contains command ID and client. Group must match the physical port. The 4-bit data slot index stays inside the data path.
- `tma_start_t={key7,segment193}` is 200 bits and `tma_xfer_event_t={key7,kind3,group3}` is 13 bits. Kinds 0…5 are GMEM_REQ, GMEM_RSP, SMEM_REQ, SMEM_RSP, LOCAL_ZERO, and NO_ACCESS. Lanes 0/1 carry GMEM requests/successful replies, 2+g / 10+g carry requests/successful replies for group g, and 18/19 carry local events. Non-SMEM events use group=0.
- `tma_progress_t={ticket5,boundary2}` is 7 bits. Values 0/1/2 mean descriptor/source/full. Cache/setup reports descriptor progress. `tma_finish_t={ticket5}` is 5 bits and closes an empty enumeration or hands off the final command.

### Allocation, acknowledgment, and retirement

Each `tma_tag_t` entry is defined below. Compact table fields reconstruct destination addresses and masks while waiting for L2. The GMEM line address transfers only once with start. The data path stores a store's destination line address beside its data slot.

| Control fields | bit | Purpose |
|---|---:|---|
| state / phase / ticket | 3 / 1 / 5 | FREE, START, SOURCE, TARGET, RETIRE. Toggle phase on each retirement. ticket directly indexes owner_view and the ticket's progress state. |
| smem_sector[17:7] / soff / goff / xor_group / logical_bytes / oob | 11 / 7 / 7 / 3 / 8 / 1 | Sector index inside the CTA. Append seven zero low bits to recover the base. Use the [segment byte formula](blackwell_tma_request_generator.md#segment) to generate active groups, masks, and GMEM byte positions. |
| gmem_sent / gmem_done / smem_sent / smem_done | 1 / 1 / 8 / 8 | Set bits separately on requests and their terminal responses. Direction-specific lifetimes are defined below. |
| source_done / target_done | 1 / 1 | Settle source and destination once each per segment. |

The segment table occupies 64×66 bits. Index long-lived state directly by general-purpose ticket. Each entry uses 7-bit pending_source, pending_target, and live_tags for outstanding sources, destinations, and unretired segments respectively (up to 64 each). Retain generated, source/full/finish, and producer handshake state. Only the tracker updates them. unit.ticket latches delivered progress/final results and its owner_view supplies total_bytes, policy, and full ID. Allocation increments all three counts. First source settlement, target settlement, and tag retirement decrement their respective counts. Combine same-edge changes by ticket. Free table capacity does not imply command completion.

1. **Allocation.** allocate.fire writes START, occupies a tag, and takes the shared elastic start port. start can send old and accept new on one edge. The last segment also sets generated. A close-only marker consumes no tag and can handshake on generated even when the table is full. Settle LOCAL_ZERO/NO_ACCESS using the actually dispatched key.
2. **Source completion.** A normal load finishes its source read when RAM accepts the GMEM return. An OOB load finishes it when LOCAL_ZERO establishes the zero row. A store finishes source reads after all active group returns write the reserved row. NO_ACCESS closes both sides of an OOB store together. First source_done per segment decrements its ticket's pending_source and enables destination issue. Publish source progress once generated and all segment sources have finished.
3. **Group acknowledgments.** Look up tag.ticket by live key and read command ID/direction from the matching owner. Accept replies only for its sent, unfinished requests. For a load reconstruct the required group mask from the tag's routing fields and mark each successful group ACK done independently. A store marks done on its one successful GMEM write ACK. Eight groups can acknowledge different tags on one edge. Groups already submitted may acknowledge while one group of a row still awaits submission. Combine same-edge events by tag first, then sum and update each ticket's counters. Settle by original key even after data slot reuse. A store's GMEM WRITE.fire proves all source groups have delivered. Afterward its source address, offset, xor, and source group bitmaps are invalid. Waiting for the write ACK needs only key/owner, state, segment length, and GMEM sent/done. Old source bits may retain physical values. Check only still-valid obligations for validation and drain.
4. **Retirement.** A normal segment needs both sides finished and all required destinations submitted and acknowledged. In RETIRE, require start to have no reference to the key, data_ref[tag]=0, and done for all sent requests. Round-robin selects at most one eligible entry per edge, toggles phase, and clears it to FREE. The tag can be reused on the next edge. Destination write acceptance can release the data slot earlier. data_ref is a pre-edge level covering held rows, requests, and RD/Q/R_OUT references.
5. **Command completion.** A store can report full when the ticket is closed, source is reported, live_tags=0, and no held reference remains. Each actual destination write ACK establishes visibility for its write as specified in [SMEM client8](../smem/blackwell_smem_fabric.md#transactions) and [GMEM WRITE](blackwell_tma_unit.md#gmem-types). An all-OOB store has no destination writes. Zero-filled OOB loads still require all actual SMEM write ACKs. A bound load sends one producer_done with total_bytes and OK and reports full only after producer_rsp. The producer port handles one transaction at a time, fairly selects eligible tickets, and holds ID/payload under backpressure. The front end serializes producers for the same address and phase. The unit checks real aliasing and explicit fences. finish.fire hands final status to the unit. Reuse the ticket only after child references release and the software response finishes.

### Errors, drain, and acceptance

Bind two independent loads to one phase. Delay A's final SMEM ACK or producer_rsp in separate tests. B can still issue its first read when resources are ready. The phase waits for both actual byte contributions and arrivals to settle. See [unit](blackwell_tma_unit.md#copy-overlap) for handoff between two 16 KiB panels.

Check non-OK, unknown, duplicate, wrong-generation, wrong-direction, and wrong-group replies at the data interface and trigger [top-level fault handling](../top/blackwell_async_subsystem_top.md#common-protocol). Faults do not count as normal segment progress. Normal stop completes accepted tickets. Synchronous reset clears tag valid, phase, counters, and held state. Normal epoch change requires drained.

Let seven groups of an old segment ACK early and delay the last. Reuse its data slot while retaining its tag until the final ACK. For a store to two nonadjacent GMEM lines, delay each line's ACK in turn and verify .read can complete earlier while full needs both ACKs. Cover a full 64-tag table, simultaneous multigroup ACKs, all-OOB, and delayed producer_rsp. A MEMORY status on the final write raises only fault. Already committed successful writes remain.
