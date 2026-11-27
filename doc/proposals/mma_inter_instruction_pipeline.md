# Cross-MMA pipeline design record

The two FA4 kernels share Allegro's operand buffers and memory ports. Their descriptors and instruction order come from offline PTX. The cycle counts assume the layout, permissions, and backpressure specified for each schedule. See the [Microarch Brief](microarch_brief.md) for resources and issue rules and the [Consecutive MMA cycle baseline](../rtl_specs/top/blackwell_async_subsystem_top.md#cycles) for cross-module acceptance criteria.

<a id="fa4-layout-audit"></a>
## QK and PV schedules for the two FA4 kernels

The table measures the interval between the first `dot_fire` of consecutive K16 instructions within one output tile. QK starts at the first dot after warmup. PV assigns V two slots every four cycles. It assumes timely pin, software P/O permission, and TMEM operands, acceptance on all four cores, and ACKs on their earliest edges. These are feasible traces for the project interfaces.

| Case and product | K16 steps per output tile | SMEM A / B reads per instruction (16 B atoms) | Dot cycles per core per instruction | First-issue interval between K steps |
|---|---:|---:|---:|---:|
| H32D64FullB2S128, QK, N128 | 4 | 256 / 256 | 64 | 64 |
| H16D128CausalB32S1024, QK, N128 | 8 | 256 / 256 | 64 | 64 |
| H32D64FullB2S128, PV, N64 | 8 | 0 / 128 | 32 | 32 |
| H16D128CausalB32S1024, PV, N128 | 8 | 0 / 256 | 64 | 64 |

### Instructions and addresses

Both kernels target PTX 8.8 and `sm_100a`. The instructions use ordinary `tcgen05.mma.cta_group::1.kind::f16` within the project's PTX 8.7 contract. Both QK instruction descriptors are `0x08200010`. The PV descriptors are `0x08110010` and `0x08210010` respectively. Q/K/V SMEM descriptors all have high word `0x40004040`, selecting 128 B swizzle and a 1,024 B SBO. Both cases reread B for every instruction. [Fixed cases](https://github.com/FlashGPU-Sim/FlashGPU-Sim/blob/7a48f7685d604d71da3692fb1b24825fdb7cc79c/tests/dsl/cutedsl/validation/configs/fa4_cases.csv) · [Upstream QK/PV definition](https://github.com/Dao-AILab/flash-attention/blob/d80a77103021c4e980f8cbbf85774f6a19e6474a/flash_attn/cute/flash_fwd_sm100.py#L1573-L1640) · [Project descriptor decode](../rtl_specs/tensor_core/blackwell_tc_mma_engine.md#matrix-descriptor)

The QK descriptor low word in the offline PTX expresses K16 offsets in 16 B units. D64 adds `0/2/4/6` in order. D128 continues with `0x400/0x402/0x404/0x406`. Each PV step increments the V descriptor low word by `0x80` and advances the P TMEM operand by eight 32-bit columns.

Let `s` denote the K16 step and `a` the byte base of the corresponding SMEM stage. The within-step element index is `k=0…15`. The formulas give the first byte of each FP16 element. Apply the swizzle before selecting the group. QK crosses a 16 KiB panel from the fourth to the fifth K16 step. Each PV step advances 2,048 B along V's sequence dimension.

```text
sw(x)        = x XOR (((x >> 7) & 7) << 4)
Q/K(row,s,k) = sw(a + 16384*(s//4) + 128*row + 32*(s%4) + 2*k)
V(n,s,k)     = sw(a + 16384*(n//64) + 128*(16*s+k) + 2*(n%64))
group(addr)  = (addr >> 4) & 7
```

For QK, `row` denotes Q's output row or K's output column. Only N128 PV accesses the second 64-column panel. TMEM uses 32-bit column indices. The S/P/O bases are 0/64/256 for D64 and 0/64/256 and 128/192/384 for the two D128 Q stages. PV reads two 16 B words per row at `P_base+8*s`, disjoint from this instruction's O. QK injects zero at the first step of each new S and reads the previous S thereafter. For each O, PV injects zero on the first step of the first KV tile and reads corrected O on the first step of later tiles. The other seven steps accumulate in place. [Upstream TMEM partitioning](https://github.com/Dao-AILab/flash-attention/blob/d80a77103021c4e980f8cbbf85774f6a19e6474a/flash_attn/cute/flash_fwd_sm100.py#L285-L298) · [O accumulation predicate](https://github.com/Dao-AILab/flash-attention/blob/d80a77103021c4e980f8cbbf85774f6a19e6474a/flash_attn/cute/flash_fwd_sm100.py#L1719-L1784)

### TMA input layout and byte addresses

The published Q/K example has logical dims=[64,128,2,1], stride[1:4]=[256,128,32768] B, and box=[64,128,1,1]. Relative to the same base, (0,0,1,0) maps to +128, (0,1,0,0) to +256, and (63,127,1,0) to +32766. The high byte of the last FP16 is at +32767. Successive heads begin 128 B apart, and successive sequence rows begin 256 B apart. [Captured Q/K example](https://github.com/FlashGPU-Sim/FlashGPU-Sim/blob/7a48f7685d604d71da3692fb1b24825fdb7cc79c/tests/src/unit/fa4_opaque_tensormap_test.cc#L107-L125)

Reference byte addresses follow the FP16 host layout, with logical dimensions ordered D/S/H/B. F1 has dims=[64,128,32,2] and byte stride[1…3]=[4096,128,524288]. F2 has dims=[128,1024,16,32] and byte stride[1…3]=[4096,256,4194304].

At rows=128, the D128 QK subblock byte offsets are `0/32/64/96/16384/16416/16448/16480`. The MN-major PV descriptor has LBO=16384 and SBO=1024. D64 QK subblock offsets are 0/32/64/96 B, and PV accesses one panel. [Upstream FA4 descriptor example](https://github.com/FlashGPU-Sim/FlashGPU-Sim/blob/7a48f7685d604d71da3692fb1b24825fdb7cc79c/tests/src/unit/fa4_opaque_tensormap_test.cc#L29-L51)

The additional wide-head case uses smem_base=0 and rows=128. For row0/b=128 the address is 16384, for row1/b=0 it is 144, and for row127/b=255 it is 32655 (32767 before swizzle). Neither panel aliases the next row. The original CUDA descriptor’s byte ABI is outside the scope of this address calculation. [Flash wide-head test](https://github.com/FlashGPU-Sim/FlashGPU-Sim/blob/7a48f7685d604d71da3692fb1b24825fdb7cc79c/tests/src/unit/fa4_opaque_tensormap_test.cc#L156-L165) · [CUDA tiled map API](https://docs.nvidia.com/cuda/archive/12.8.1/cuda-driver-api/group__CUDA__TENSOR__MEMORY.html)

### Repeating four-cycle QK window

For any eight rows and a fixed half, the formula gives a permutation of groups 0…7. Each cycle all eight groups grant one request and each of the 32 banks reads once. Two cycles out of four serve A and two serve B. In 64 cycles they cover the 512 requests of one MMA. Let F be the first dot of a K step and S=F+4j the first dot of its eight-column block j. The two halves of A row group r on core c receive grants at `F−64+16r+4c+h`, with h=0/1, and return two cycles later. The last group, r=3, is complete at F−1 and first used at F+2. B[j] receives grants at S−10/−9, returns at S−8/−7, distributes at S−6, and loads R_OP at S−1. Each of the eight B returns writes a distinct piece. Two alternating slots suffice. [SMEM arbitration](../rtl_specs/smem/blackwell_smem_fabric.md) · [Operands and writeback](../rtl_specs/tensor_core/blackwell_tc_mma_core.md)

With the previous step's first dot at 0, old D[0] receives its last successful ACK at 12. New C[0] reads at 58/59 and returns at 61/62. C[1] reads at 62/63 and returns at 65/66. Edge 63 issues the last old dot and loads the first new R_OP. Edge 64 issues the first new dot, ahead of the old final ACK at 72. Substituting the actual K-step addresses gives first issues at 0, 64, 128, and 192 for D64 and 0, 64, …, 448 for each D128 Q stage. All eight groups are occupied throughout the 64 cycles. Recompute the schedule from actual grants if another reader intervenes.

### PV V fills and same-address C

Read each of the 16 source atoms in an eight-column V block once. For fixed h, the group of within-row K index u=0…7 is `u XOR (j mod 8)`. For QK it is `c XOR (2*(s mod 4)+h)`, where c is the column index 0…7 within the block. These shortcuts assume the aligned stage bases in this example. For general addresses use group(sw(x)) above. Each batch of eight requests uses all eight groups. A PV return carries eight FP16 values for the same K and writes four 32-bit segments of one logical row. Transposing the two 8×8 halfword matrices at slot output presents the original values to the core in column order. [Loader assembly formulas and cycle table](../rtl_specs/tensor_core/blackwell_tc_b_loader.md#service)

Take the first V grant as 0 under the table's conditions. All four cores receive V blocks 0/1/2 at 4/8/12 respectively. R_OP can load one edge later and a dot can issue on the following edge. The four row groups of block b issue at `6+4b…9+4b`, where b counts blocks continuously across K steps. For D64 the last block of step 0 issues at 34…37 and the first block of step 1 at 38…41. The D128 windows are 66…69 and 70…73. If no A-class SMEM requests are present, the fabric may serve V sooner. The model tracks actual delivery separately from four-cycle consumption.

For in-place accumulation, step 0 D[0] receives its last ACK at 18. For D64, step 1 C[0] receives grants at 32/33 and returns at 35/36, in time for the first R_OP at 37. For D128 it receives grants at 64/65 and returns at 67/68, in time for 69. C[1] follows four cycles later. The two P read frames use TMEM read edges left free by C prefetch. D uses the separate write port.

The two layouts cover 384 eight-column blocks. With fixed B slots, the SMEM return contract yields four-core deliveries at 4, 8, 12, …. Allowing idle slots to be borrowed also delivers each block by its deadline. With one return group stalled, one core stalled, or both stalled, each destination must receive the original bits in column order exactly once.

<a id="fa4-handoffs"></a>
### Order of matrix products

QKₛ(t) and PVₛ(t) denote a complete product for Q stage s and physical KV tile t. Each D64 QK contains four K16 instructions and each D128 QK contains eight. PV contains eight in both cases. Expanding the MMA warp loops for the actual invocation shapes gives the following sequences.

- **D64, full attention.** One work tile executes `QK₀(0) → PV₀(0) → O_full`. QK reads Q and K from SMEM and writes S0. PV needs P0 produced from S0. The PTX loop body contains a PV→QK site, but KV length 128 gives zero loop iterations in this case. Execution takes the PV epilogue. The next work tile has its own producers and barrier phase.
- **D128, causal.** One work tile handles two consecutive 128-row Q stages. The four 256-row work ranges traverse L=2, 4, 6, and 8 KV tiles respectively, descending from H=L−1 to 0. Execute `QK₀(H) → QK₁(H)` first, then `PV₀(t) → QK₀(t−1) → PV₁(t) → QK₁(t−1)` for each t=H…1, and finally `PV₀(0) → PV₁(0)`. Each work tile has 2L−1 QK→PV transitions, all crossing Q stages, and 2(L−1) PV→QK transitions, all returning to the same Q stage. The causal mask changes the useful work. Each product that starts still executes its K16 sequence. [Upstream causal bounds](https://github.com/Dao-AILab/flash-attention/blob/d80a77103021c4e980f8cbbf85774f6a19e6474a/flash_attn/cute/block_info.py#L21-L39) · [MMA warp prologue, interleaved loop, and epilogue](https://github.com/Dao-AILab/flash-attention/blob/d80a77103021c4e980f8cbbf85774f6a19e6474a/flash_attn/cute/flash_fwd_sm100.py#L1683-L1824)

#### TMA and P readiness edges

The KV producer transfers K(H), V(H), K(H−1), V(H−1), … alongside computation. The MMA warp waits for the Q and K stages before its first QK. Its first PV waits for V and the P/O permission for its Q stage. TMA visibility requires the last destination SMEM write ACK, successful complete-tx for each copy, satisfaction of both arrival and byte counts for the phase, and finally a wait acquire ACK and true predicate for the consuming warp. A D64 K or V stage is 16 KiB. A D128 stage is 32 KiB. Its PTX issues two 16 KiB panel copies against one 32,768 B expect-tx. Completing the first panel cannot release the stage. A wait matching the phase at c can issue acquire at c+1 at the earliest. If the acquire ACK is accepted at a, the true predicate can be delivered at a+1 at the earliest. The warp must still execute its branch, prepare addresses, and submit the command. [Upstream prefetch order](https://github.com/Dao-AILab/flash-attention/blob/d80a77103021c4e980f8cbbf85774f6a19e6474a/flash_attn/cute/flash_fwd_sm100.py#L1471-L1513) · [TMA writes and completion](../rtl_specs/tma/blackwell_tma_completion_tracker.md) · [Wait and acquire](../rtl_specs/mbarrier/blackwell_mbarrier_wait.md)

Both kernels discard the arrival result (`_`), wait on parity, and use a nonzero PTX hint `10000000`. A four-column-aligned TMEM LD x32 reads eight 128-bit words per lane and delivers 32 RF beats, 4 KiB in total, for the warp. [LD data path](../rtl_specs/tmem/blackwell_tmem_ldst_engine.md#ld-word)

The softmax warp produces P. It waits for S_full from the corresponding QK, reads S into RF, computes probabilities, and writes P[0…95]. It uses PTX `tcgen05.wait::st` to confirm its writes before arriving at the P/O barrier. The correction warp must also arrive for the same phase. The first KV tile has no old O to rescale. For later tiles the actual scale determines whether O needs a read-modify-write. Confirmation of P[96…127] arrives separately at the lastsplit barrier. Both PTX versions place the MMA warp's second wait between PV K16 steps 5 and 6. With step 0's first dot at 0, uninterrupted step 6 starts at 192 (D64) or 384 (D128). To meet that edge F, step 6's first B block must arrive by F−2. With consecutive grant edges, the first request must enter R_BREQ by F−7 and receive grants at F−6 and F−5. If the wait blocks cmd.fire, computing the SMEM address early cannot claim that slot. [Split P writes in softmax](https://github.com/Dao-AILab/flash-attention/blob/d80a77103021c4e980f8cbbf85774f6a19e6474a/flash_attn/cute/flash_fwd_sm100.py#L2280-L2356) · [O correction and release](https://github.com/Dao-AILab/flash-attention/blob/d80a77103021c4e980f8cbbf85774f6a19e6474a/flash_attn/cute/flash_fwd_sm100.py#L2479-L2499)

#### QK → PV

Take the first dot of **the last K16 MMA of the immediately preceding product** as 0. Its ideal issue window is 0…63. The last D writes are accepted at 69/70, the last write commits at 71, and its ACK retires at 72. The tracker can accept engine done at 75 at the earliest. A commit may register early, but its S_full arrival waits for the operations it covers. Edge 72 therefore does not establish P readiness. [MMA writeback tail](../rtl_specs/top/blackwell_async_subsystem_top.md#cycles) · [Commit to arrival](../rtl_specs/tensor_core/blackwell_tc_async_completion.md)

| Edge | D64, same stage S0 → P0 | D128, cross-stage, e.g. S1 → P0 |
|---|---|---|
| 0…55 | TMA can transfer V to SMEM. P0 for this work tile still depends on the current S0. | An earlier QK₀(t) produced the input for P0. Softmax and O₀ correction can overlap the current QK₁. If the V and P/O waits release PV and the pin and slots are ready, the first V block can receive grants at 54/55. |
| 56…63 | Even if V is in SMEM, an unissued PV cannot request the loader. This stage's P also overlaps the second half of the old S address range. | The two P frames can read at 56/57 and return at 59/60. V returns at 56/57 and distributes at 58. If old O is required, C0 receives grants at 58/59 and returns at 61/62. The first tile injects zero. Load the new R_OP at 63. |
| 64 onward | Considering hardware aliasing alone, after the old ACK at 72, P can receive grants at 73/74 and return at 76/77. Edge 79 is a local lower bound. The actual path also passes through the tracker, S_full, softmax, P/O release, and successful acquire. | If the conditions hold, first issue is at 64 while the last old S1 ACK retires at 72. If P0, O₀, or V is late, reschedule preparation from its actual release edge. |

For D64, separate variable wait time from known preparation edges. Let R be an example edge when V and P can both start receiving grants after both waits succeed and PV is accepted and holds its TMEM pin. Both receive grants at R and R+1. SMEM returns V at R+2 and R+3 for four-core delivery at R+4. TMEM returns P at R+3 and R+4. R_OP can load at R+5 and the first dot can issue at R+6. Actual R depends on producer progress, wait acquire acknowledgments, and warp scheduling. D128 has a larger overlap window. In the prologue a complete QK₁ (512 active dot cycles) separates QK₀ and PV₀. In the interleaved loop two complete products can separate the corresponding QK and PV. Compare the permission for the particular stage against its first-block deadline.

#### PV → next QK

Each nonfinal D128 KV tile has two return paths. After PV₀(t), the MMA warp advances the KV ring, waits for successful acquire of K(t−1), then issues QK₀(t−1). After PV₁(t), the warp issues an asynchronous commit to release the V(t) SMEM slot. QK₁(t−1) reuses the same K whose wait already succeeded, without a second K wait. Commit registration and actual arrival occur on separate edges. The first new QK step uses `input_d=0` and injects zero. Old PV writes O and new QK writes a disjoint S. P partially overlaps the destination S, but the old P's final op_load precedes the new instruction's first issue. Operands already in R_OP can finish safely. [Core operand fetch and dependencies](../rtl_specs/tensor_core/blackwell_tc_mma_core.md)

Take the first dot of **the last K16 of the preceding PV** as edge 0. Assume the next QK has completed its wait and acquired its TMEM pin, its operands receive the normally scheduled grants, and both dot and writeback can accept. Core `c=0…3` owns 32 Q rows starting at `32c`. Each core issue uses eight local Q rows and eight common K vectors. One 16-term dot per row/column pair produces an 8×8 output microtile. Four consecutive issues use all four local Q row groups for the same eight output columns.

While the old PV runs, SMEM gives Q two read cycles in every four. The first reads the first 16 B of each of eight rows, the second the remaining 16 B. This supplies all 16 FP16 values per row, 256 B for eight rows. Four groups per core total 1 KiB and take eight read cycles. Row group `r=0…3` on core `c` receives grants at `16r+4c` and `16r+4c+1`, each returning two cycles later. B slots first read the old PV's V. The new QK's first K block receives grants at 54/55, returns at 56/57, and distributes to all four cores at 58.

| Q row group (core-local rows) | SMEM grant edges (cores 0, 1, 2, 3 in order) | Latest Q return across the four cores | R_OP load per core | Dot issue per core |
|---|---|---:|---:|---:|
| 0 (0…7) | 0/1, 4/5, 8/9, 12/13 | 15 | 63 | 64 |
| 1 (8…15) | 16/17, 20/21, 24/25, 28/29 | 31 | 64 | 65 |
| 2 (16…23) | 32/33, 36/37, 40/41, 44/45 | 47 | 65 | 66 |
| 3 (24…31) | 48/49, 52/53, 56/57, 60/61 | 63 | 66 | 67 |

The old PV loads its last microtile at 62 and issues it at 63. On that edge all four cores load the first new QK microtile. The engine releases the first microtile on all cores together. Each core then advances as its operands become ready. Every Q group in the table returns before its load, so each core issues one microtile per cycle at 64…67. Edge 68 moves to output columns 8…15 and reuses local Q starting with row group 0. The final old PV write ACK for O can retire at 72. [Four-core issue rules](../rtl_specs/tensor_core/blackwell_tc_mma_core.md) · [Repeating four-cycle QK window](#repeating-four-cycle-qk-window)

The new QK reads the S it wrote starting at K16 step 1. Renumbering from step 0's first dot at 0, D[0] receives its final successful ACK at 12. Step 1 C0 reads at 58/59 for first issue at 64. In-place PV accumulation on O also waits for successful ACKs block by block. Across KV tiles it additionally waits for the correction warp to publish O. A late ACK delays the read of the corresponding block. If only the final block ACK is late and writeback capacity suffices, the next instruction can still start on time.

#### Which waits can overlap other work?

- **Producer dependencies.** The D64 same-stage S→softmax→P chain, required O rescaling on later tiles, and late P for PV step 6 all require actual write acknowledgment and successful acquire. Independent TMA transfers or computation on another stage can overlap the wait. The current instruction must wait before reading unpublished data.
- **Preparation covered by existing prefetch.** After its wait succeeds, a command can load Q row groups, its first K/V block, P frames, and eligible C blocks before the preceding instruction's last dot. For D128, prioritize early publication of the next K stage and check the last Q row group's deadline. The B loader accepts only registered MMA commands.

<a id="tma-budget"></a>
### TMA service cycles and consumer deadlines

All copies share 128 B/cycle. For the two independent D128 16 KiB panels, the first copy's last segment and the second copy's first segment can enter the walker on adjacent edges. Ideal GMEM READ handoff is at cycles 129/130. Each copy waits for its own final destination write ACK and producer_rsp. Each panel registers its own complete-tx. The consumer deadline depends on successful wait for the entire stage. Command gaps, source returns, bank contention, ACKs, and barrier waits add time. The table counts only destination write service for aligned full segments. It assumes continuous source readiness, eight free groups, and timely reuse of the 64 transaction tags and 16 data slots. A load waiting on external memory occupies only a tag and takes RAM on a successful return. A store reserves RAM before its source read. Both release the row at final destination request acceptance. The actual write ACK retains the original tag. [Earliest read issue for two panels](../rtl_specs/tma/blackwell_tma_unit.md#copy-overlap)

| K/V data | Total | Minimum SMEM write service cycles | Computation available for overlap |
|---|---:|---:|---|
| D64, one K or V | 16 KiB | 128 | QK for the same work tile takes 256 cycles. If V writes at full rate from the start of this window, write service occupies half of it. Actual PV also waits for V and this stage's P/O. |
| D128, one K or V | 32 KiB | 256 | Two 16 KiB panel copies serve the same stage, 128 cycles each. Both must complete to satisfy the 32,768 B expect-tx. |
| D128, K+V for one KV tile | 64 KiB | 512 | The two Q stages together provide 2×(512 QK + 512 PV)=2,048 active dot cycles. |

The three-slot K/V ring allows reads to start early. Use the first actual grant, last destination ACK, and complete-tx of each copy to derive the earliest phase release. Stores also peak at 128 B/cycle. SMEM source reads of O compete with Q/K/V operand reads for the same group grants. GMEM write ACKs are tracked separately. A load write and an MMA read need separate edges only on a same-bank, same-word conflict. [TMA scheduling](../rtl_specs/tma/blackwell_tma_unit.md) · [Full-line cycle example](../rtl_specs/tma/blackwell_tma_data_path.md#peak)

## In-place accumulation and block dependencies

The [top-level N128 timing example](../rtl_specs/top/blackwell_async_subsystem_top.md#cycles) gives the aligned, uncontended schedule and the effect of delaying individual block ACKs and C returns.
