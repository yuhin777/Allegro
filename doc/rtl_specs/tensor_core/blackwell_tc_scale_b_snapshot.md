# blackwell_tc_scale_b_snapshot

## Description

One instance per backend stores scale B snapshots for two active input contexts and provides eight columns of factors by ID to all four cores through combinational views. Of the 4×1 KiB physical storage, banks 0/1 correspond to engine-assigned input banks. The other two are reserved. Each bank has 32 rows ×8 cells ×4 B. Selecting a physical snapshot bank does not change the TMEM source.

| Signal / channel | Direction | Type / width | Peer | Sampling condition |
|---|---|---|---|---|
| `start` | Input | prepare_t (449 bits) | MMA engine | On `start.fire`, accept the command after the engine has obtained the pin and granted scale B read permission. |
| `release` | Input | async_id_t (58 bits) | MMA engine | On `release.fire`, release the snapshot by ID. |
| `rd_req[128]` | Output | tmem_rd_req_t (108 bits) | TMEM fabric | On `rd_req.fire`, issue for client 4 on source lane x modulo 32. |
| `rd_rsp[128]` | Input | tmem_rd_rsp_t (206 bits) | TMEM fabric | On `rd_rsp.fire`, accept the matching read return. |
| `query[4]` | Input | 72 bits per core | Four cores | Level. Look up a READY snapshot by ID and column. |
| `view[4]` | Output | 257 bits per core | Four cores | Level. Return the matching column independently to each core. |
| `ready[3]` | Output | 1 bit per record | MMA engine | Level. Assert after all required returns transfer. |
| `quiescent[3]` | Output | 1 bit per record | MMA engine | Level. No held or pending requests for the ID and no further reads to issue. |
| `live[3]` | Input | 61 bits per entry | MMA engine | Level. Match command ID and record. |
| `clk` | Input | 1 bit | MMA engine / top level | Rising edge samples synchronous state. |
| `rst_n` | Input | 1 bit | MMA engine / top level | Sample low on a rising edge to reset control. |
| `epoch_i` | Input | 16 bits | MMA engine / top level | Level identifying the active CTA lifetime. |
| `drained_o` | Output | 1 bit | MMA engine / top level | Level covering active snapshots and held requests. |

The [top-level common protocol](../top/blackwell_async_subsystem_top.md#common-protocol) defines clock, reset, and channel sampling.

```mermaid
flowchart LR
 S[start / id / input bank] --> F["Enumerate source words / hold requests"]
 F --> M[TMEM client4] --> G["Collect by ID and token"]
 G --> B["Two independently valid snapshots"] --> V["Four combinational queries"]
```

## Functionality

### Fill and release by ID

Each started bank holds ID/rec, base/id/V, needed/valid (up to 256 cells each), and sent/pending for 32 rows ×3 source words. One enumerator prioritizes the oldest waiting request and locks a presented candidate until fire. sb_token={reserved7=0,partition2=0,row5,atom2}, atom=0…2. column=base+n//32, source_word=base//4+atom. Combine needed bytes in the same word. Match return ID and token, then write only selected cells in snapshot[bank][n%32][n//32]. N256 with base%4=0 takes at most 64 requests, otherwise at most 96.

EMPTY → FILL → READY. Set ready for the rec after the last required return transfers. SB can be sampled into R_OP on the next edge. The other snapshot can fill concurrently. After every core finishes using this ID's inputs and quiescent is true, the engine issues release and reclaims the bank. A simulation assertion checks that each return identifies an issued, outstanding word of the live snapshot on the selected lane. Quiescent becomes true only after the edge retiring the final obligation. Do not unpin early. Reset clears valid bits and preserves snapshot data.

<a id="scale-layout"></a>

### Scale layout and query types

Applies to M128 ordinary mxf8f6f4, mxf4, and mxf4nvf4. See [MMA command](blackwell_tc_mma_engine.md#mma-command) for legal types and vec by kind. The factor count V is 1, 2, or 4. For k∈[0,K), g=floor(kV/K) and the product uses `SA(m,g)×A(m,k)×SB(n,g)×B(k,n)`.

#### TMEM layout

Use x=m for A or x=n for B and s equal to the respective scale ID. The upper 16 taddr bits are zero and the lower 16 give the base column. For each valid (x,g), extract a byte from a 32-bit cell using the formula below. Use extended-width addition. Legal commands address allocated cells within the TMEM column range.

```text
lane   = x % 32
column = base + x//32 + (s+g)//4
byte   = (s+g)%4
value  = TMEM[lane][column][8*byte +: 8]
```

Legal selections satisfy s+V≤4. A uses lanes0…31 and four columns. B uses the same lanes and N/32 columns. For 2X, id=2 starts at byte2. For 4X start at byte0. A/B have independent addresses and IDs. See [low-precision scales](../dot/blackwell_f4f6f8_dot.md#formats) and [FP4 scale](../dot/blackwell_fp4_dot.md#formats) for UE8M0/UE4M3 arithmetic.

#### Combinational scale B query

`tc_sb_query_t={id:58,block:6,n_base:8}` is 72 bits, with n_base=8×block. `tc_sb_view_t={valid:1,data:256}` is 257 bits. For j=0…7 and g=0…V−1, `data[32*j+8*g+:8]=SB(n_base+j,g)`. Zero unused factor bytes. Assert valid only for a matching ID, range, and valid bits. The core samples the densely packed data directly on the R_OP load edge.

When D overlaps the source, all 64 dot lanes use the scale values captured during PREP. [Scale A diagram](https://docs.nvidia.com/cuda/archive/12.8.2/parallel-thread-execution/_images/tcgen05-mma-scale-factor-a-1x-dig.png) · [Scale B diagram](https://docs.nvidia.com/cuda/archive/12.8.2/parallel-thread-execution/_images/tcgen05-mma-scale-factor-b-1x-dig.png)
