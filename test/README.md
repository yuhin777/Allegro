# Blackwell subsystem verification

Each module below links to its specification and describes the stimulus, observations and expected results. For ready/valid channels, record transfers on the rising edge where both signals are asserted. Match responses to the original transaction identity and compare payload and valid across stalled edges. For numerical checks compare result bits. For timing checks record the service conditions and count from the handshake named in the specification.

Use the v1 shared wide/K32 configuration for acceptance. The independent configuration is experimental. The subsystem chapter covers interactions that span module boundaries.

## Storage and pipeline primitives

### [`blackwell_banked_sram`](../doc/rtl_specs/base/blackwell_banked_sram.md)

- Check independent bank enables, Q retention during stalls, preservation of adjacent bytes under masking, addresses DEPTH−1 and DEPTH, concurrent different-word reads and writes, and controller suppression of same-word conflicts.

### [`blackwell_fifo`](../doc/rtl_specs/base/blackwell_fifo.md)

- Assert 0≤count≤DEPTH, ordered delivery, and protection against overwriting a full FIFO. Test DEPTH=1 and non-power-of-two depths.

### [`blackwell_pipeline_reg`](../doc/rtl_specs/base/blackwell_pipeline_reg.md)

- Start empty, accept A, and stall the output while offering B. Check that valid and A hold. Release the stall and accept B on the edge that delivers A. Expect B on the next edge. Reset a full stage and check that valid clears.

## Dot arithmetic

### [`blackwell_dot_align_fixed_rz`](../doc/rtl_specs/dot/blackwell_dot_align_fixed_rz.md)

- Drive both signs of an odd magnitude at d=0, MAG_W−1, and MAG_W. Compare with a magnitude shift followed by sign restoration. Invalid inputs produce zero. Assert that a valid input with negative d violates the upstream contract.

### [`blackwell_dot_emax_tree`](../doc/rtl_specs/dot/blackwell_dot_emax_tree.md)

- For N=1 and an odd N, compare the tree with a signed maximum over valid inputs. Include the minimum exponent, equal exponents, and an invalid leaf with the largest exponent. With no valid leaves expect valid=0 and DEFAULT_EXP.

### [`blackwell_dot_fp32_pack`](../doc/rtl_specs/dot/blackwell_dot_fp32_pack.md)

- Verify that sum=3 and base_exp=0 give 0x40400000. Also check negative powers of two, the most negative sum, normal/subnormal boundaries, e=−149/−150, e=127/128, and special-result priority.

### [`blackwell_dot_signed_reduce_tree`](../doc/rtl_specs/dot/blackwell_dot_signed_reduce_tree.md)

- Verify odd N, alternating signed extrema, zero sums, and the specified overflow behavior against an arbitrary-precision integer reference.

### [`blackwell_f16tf32_dot`](../doc/rtl_specs/dot/blackwell_f16tf32_dot.md)

- Use `MMA_SIM_VECTORS` with [dot/run.sh](dot/run.sh) to prepend raw-bit reference transactions. For nonzero finite terms with matching decode, exponent selection and FP32 packing, compare accumulation against [MMA-Sim fused_sum at ac5b2a4](https://github.com/yuhin777/Allegro/blob/ac5b2a4/MMA-Sim/mmasim/simulator/arithmetic.py). Use the [wide arithmetic contract](../doc/rtl_specs/dot/blackwell_f16tf32_dot.md) for special values, zero terms and C prescale underflow.
- Compare S1 emax with a flat maximum over nonzero products and nonzero prescaled C. Exercise shift distances 0, 25, 26, 27, 31, 32 and 506 with both signs.
- Compare S2 pairs with individually truncated terms and S3 with their flat signed sum. Include same-sign maxima, near cancellation, a single nonzero TF32 lane, and BF16 zero times 2^127 with every other product zero and C=2^−40. The latter returns 0x2b800000.
- Cover all FP16/BF16 input combinations, extrema, subnormals, TF32 Inf and NaNs with payloads only in the low 13 bits, opposing infinities, and C prescale underflow. Stall continuous requests and check the pairing of result, tag, emax and special code across stalls.

### [`blackwell_f4f6f8_dot`](../doc/rtl_specs/dot/blackwell_f4f6f8_dot.md)

- Verify all 25 dtype combinations, finite extrema/zero/subnormal/NaN as applicable, E5M2 Inf, UE8M0 0/254/255, and signed cancellation. Compare MX against a reference using exactly the same fixed-point alignment. With E5M2 A all zero, B[0]=0x7b, and FP32 C=0x00000001, verify that both unscaled and unit-scaled MX return C. Check truncation for large exponent differences between scaled finite products and C. Assert correct behavior under uniform backpressure across 64 lanes and fault injection with partial ready.

### [`blackwell_fp4_dot`](../doc/rtl_specs/dot/blackwell_fp4_dot.md)

- Verify every FP4 input encoding, both valid modes, UE4M3 zero/subnormal/NaN and ignored high bit, UE8M0 boundaries, group cancellation, and large exponent differences with C. Compare each sigma and gamma with an integer reference to locate rounding differences.

### [`blackwell_int8_dot`](../doc/rtl_specs/dot/blackwell_int8_dot.md)

- Test all four signedness combinations, signed/unsigned interpretations of 0xff, both extreme C values, positive/negative overflow, saturation and wrap, cancellation, and random backpressure. The reference sums in at least 64 signed bits and applies S32 rules only at the end. Per-term S32 wrap or saturation is incorrect.

## Tensor Core

### [`blackwell_tc_async_completion`](../doc/rtl_specs/tensor_core/blackwell_tc_async_completion.md)

- Verify one object request, software done, and retire per successful commit and same-issuer order under result backpressure.

### [`blackwell_tc_b_loader`](../doc/rtl_specs/tensor_core/blackwell_tc_b_loader.md)

- Compare nonuniform raw 16-bit values element by element for both major orders and both FP16 and BF16. Check addresses, all 16 tokens, and column order across N64/128/256, swizzle phases, panel boundaries, and instruction boundaries. Interleave K-major, N-major, and generic blocks and verify that backpressure preserves the oldest slot's mode selection.
- Stall one return group and separately stall a core. Verify source credit return edges, held payload, exactly-once delivery to each destination, and slot reuse. Check errors on the final return, WS hit/miss, and shutdown drain.
- For generic formats cover low-bit packing, padding, multiple parts arriving for one destination row on one edge, and general-layout bank conflicts. Compare all four cores' data byte by byte.

### [`blackwell_tc_completion_tracker`](../doc/rtl_specs/tensor_core/blackwell_tc_completion_tracker.md)

- Cover coincident registration/completion/commit, an empty snapshot after consuming more than 32 consecutive done results, and [nonempty commits from different issuers](../doc/rtl_specs/top/blackwell_async_subsystem_top.md#mma-nonempty-commit).

### [`blackwell_tc_dot_array`](../doc/rtl_specs/tensor_core/blackwell_tc_dot_array.md)

- With the v1 shared array, check sustained wide/K32 issue with the sink ready, each family's isolated latency after drain, and synchronous reset at full blocked capacity.
- Cover all 33 supported kind/mode/shape combinations. Issue six-stage low precision, three-stage integer, and five-stage FP16/TF32 consecutively. Stall the head result while the shorter family becomes ready first. Check that queued family IDs equal the number of valid microtiles in the pipelines, results deliver in original tag order, and lifting D backpressure causes no loss or duplication. Check native edges and payload capacity for each family. Verify broadcast wiring with an asymmetric INT8 microtile. Only k=0 is nonzero, A[r,0]=r+1, B[c,0]=c+9, and C[8r+c]=100r+c. Check `(r+1)×(c+9)+100r+c` in every cell.
- Continuously vary input data and switch families. Check that unselected S0 row/column inputs stay zero and that issued microtiles deliver with their original tags. A blocked selected input holds its decoded values through the handshake edge.

### [`blackwell_tc_mma_core`](../doc/rtl_specs/tensor_core/blackwell_tc_mma_core.md)

- Reuse the same B range for two N256 commands and stall one core's final op_load. That core must retain unconsumed bytes and accept overwrite only on the edge after actual `op_load(j,3)`. Fill B blocks with distinct values and insert an idle cycle between first-group issue and second-group load. Check B and tag on all four issues and verify one local B read enable and one `R_OP.b` write enable per block. A complete N128 instruction issues 64 microtiles and reads 16 blocks per core, totaling 16 KiB of local B reads across the four cores. Backpressure R_OP, D slots, and write ports separately to check payload retention and actual writes per block. Also test TMEM A/scale self-overlap, offset overlap, and fully disabled writes. Delay one return or acknowledgment at a time. Separately delay acceptance of the last old D write and verify payload release and old ACK ownership.

### [`blackwell_tc_mma_engine`](../doc/rtl_specs/tensor_core/blackwell_tc_mma_engine.md)

- Use distinct byte signatures by (n,k) to verify both major orders, each permitted swizzle, FP6 cross-byte fields, adjacent FP4 nibbles, and padding masks. Check layout before physical bank mapping.
- For simultaneous eligible entries, entries becoming eligible while done is held, and interleaved completions, verify exactly one notification per ID.
- For steady-state handoff observe launch, local_done, unpin, and tracker handshakes separately.
- Check ingress backpressure with all three slots full. Each cmd.fire registers with the tracker on the same edge. Three consecutive normal commands each launch once. Exercise a late final ACK, stalled partial distribution, same-name fill→use→lastuse, late completion by an old owner, and stop. WS coverage includes four N64 entries, two N128 entries, one N256 entry, and mixed sizes. Check the lowest contiguous free run, fragmentation, and LRU. Each core reads only blocks it has installed and has permission to use. Each accepted command finishes exactly once.

### [`blackwell_tc_scale_b_snapshot`](../doc/rtl_specs/tensor_core/blackwell_tc_scale_b_snapshot.md)

- Load the next instruction into a nonzero bank. Check source lane wrap at n=31/32, independent queries from four cores, and isolation of the two IDs. Delay source return, release, and manager.unpin separately and check their handshake edges. Cover 1X/2X/4X and all legal s/V.
- Use distinct values for each lane/column/byte to cover x=31/32, the final row/column, all N, and each s/V. When D overlaps the source, verify that all 64 dot lanes use the values sampled during PREP.

## Shared memory

### [`blackwell_smem_fabric`](../doc/rtl_specs/smem/blackwell_smem_fabric.md)

- Stall one broadcast destination and check that served destinations see no duplicate. For successive accesses to one word, verify that a winning read gets the old value, a read after a winning write gets the new value, and the waiting party advances.
- Verify unselected bytes, half-line barrier writes, requests and ACKs in seven groups while one TMA group stalls, TMA store/MMA read contention, LSU contention, partial broadcast delivery, and exhaustion of three credits.

## Tensor memory

### [`blackwell_tmem_fabric`](../doc/rtl_specs/tmem/blackwell_tmem_fabric.md)

- Let two clients write different banks on one edge and stall their ACKs independently. Check partial retirement, original client/token, and held stability. Mismatch the client, lane or epoch and check that the illegal request cannot reach SRAM.

### [`blackwell_tmem_ldst_engine`](../doc/rtl_specs/tmem/blackwell_tmem_ldst_engine.md)

- Verify the 32 cells of each beat independently and preserve unaccessed cells.
- Fill LD with distinct values by lane and column. Sweep x16/x32 and all four b%4 values. Verify one read per `(id,lane,w)`, first/last byte_mask, and each thread/register value with index/last. Cover e=511 and out-of-range precheck.
- Separately delay grants/returns for the current and next word and stall the current final RF beat. Check same-edge old sampling and new capture on word handoff and correct ownership of late prefetches. Hold an old ST ACK. Verify the next RF beat can replace the old one at final actual write acceptance. Filling both partition ACK frames then applies real credit backpressure.
- Cover all four warp partitions and stall the two completion outputs independently. Late MEMORY raises fault without successful ACK settlement. The surrounding system reads an RF register only after actual beat writeback.

### [`blackwell_tmem_manager`](../doc/rtl_specs/tmem/blackwell_tmem_manager.md)

- Use the F1/F2 512-column allocation and check a same-address SMEM read obtains base=0. Retain allocation while an old reference returns late. A subsequent DEALLOC allows another warp's waiting ALLOC to take the full block. Verify independent reference return from all five users and continued unpin progress under management or pin response backpressure.

### [`blackwell_tmem_partition`](../doc/rtl_specs/tmem/blackwell_tmem_partition.md)

- Assert that illegal lane, word or tag values are detected before issue. Drop ready on each successive edge after grant and check outstanding per bank equals the number of Q, return, and reserved read identities and is ≤3. A full bank can reuse credit on the edge an old entry retires. After two consecutive write frames stall a single bank ACK and observe write acceptance, actual write, and per-bank ACK separately. Across D generation changes, mixed clients, and all byte masks, an old ACK retires only its old identity.

### [`blackwell_tmem_wait_tracker`](../doc/rtl_specs/tmem/blackwell_tmem_wait_tracker.md)

- Verify empty wait after consuming 64 stores, same-edge alloc/complete/wait, different warps, LD exclusion, and independent backpressure on both return ports.

## Tensor Memory Accelerator

### [`blackwell_tma_completion_tracker`](../doc/rtl_specs/tma/blackwell_tma_completion_tracker.md)

- Bind two independent loads to one phase. Delay the first load's last SMEM ACK and its producer response in separate runs. Check that the second can issue while the phase still waits for both contributions and arrivals. For a store spanning two nonadjacent GMEM lines, stall GMEM write acceptance and each ACK separately. Check that group read completion can precede full completion. Return MEMORY on the final write with all rows occupied. Check fault, preservation of committed writes, and no finish for the failed ticket.

### [`blackwell_tma_data_path`](../doc/rtl_specs/tma/blackwell_tma_data_path.md)

- Issue 64 load reads before any return, hold the oldest return until last, and stall SMEM writes. Fill all 16 rows, check that the 17th successful return waits, then resume and check each selected destination byte exactly once. Return the eight groups out of order, ACK different tags on one edge, and hold the eighth group's ACK across slot reuse. Include short segments, OOB zero fill, all-OOB stores, wrong or duplicate tags, and competing descriptor returns.

### [`blackwell_tma_descriptor_cache`](../doc/rtl_specs/tma/blackwell_tma_descriptor_cache.md)

- Issue three consecutive hits with distinct tickets, then a miss behind a stalled result. Check one GMEM request per miss, four-way replacement, demand after a prefetch hit or fill, simultaneous result consumption and lookup, address reuse across epochs, and MEMORY fault.

### [`blackwell_tma_request_generator`](../doc/rtl_specs/tma/blackwell_tma_request_generator.md)

- Stall S0, S1, and S2 independently. Check stable outputs, contiguous nonoverlapping ordinals, last-to-first command handoff, and recovery after all 64 tags fill. Exercise 16 B-aligned bases inside a sector, distinct GMEM and SMEM boundaries, FP16 row ends, transitions into and out of OOB, and addresses sharing a physical SMEM bank.

### [`blackwell_tma_setup`](../doc/rtl_specs/tma/blackwell_tma_setup.md)

- Vary each dimension's stride and the panel independently. At the same coordinate check the GMEM byte and swizzled SMEM byte. See the [FA4 design record](../doc/proposals/mma_inter_instruction_pipeline.md) for actual descriptors, nonmonotonic strides, and individual addresses across panels.
- Test nonzero swizzle base, partial/full OOB at edges, 128 B GMEM line crossings, illegal stride alignment, address addition overflow, the last legal SMEM byte, and rejection before bind for invalid fields. Check the [setup precheck and context](../doc/rtl_specs/tma/blackwell_tma_setup.md) against actual source and destination bytes.
- Interleave two setup slots, stall result delivery, and check that late replies for three older tickets still reach their original owners after slot reuse.

### [`blackwell_tma_unit`](../doc/rtl_specs/tma/blackwell_tma_unit.md)

- Issue three 16 B linear loads to SMEM bases 0x000, 0x090, and 0x120 with a disjoint barrier. Hold the last ACKs of the first two and check that the third issues its read. For two successive barrier phases, register 16384 B per phase and check four 4096 B contributions before address reuse with new parity. Distinguish source progress, destination ACK, producer response, and software response edges. Exercise tiled loads and stores, groups from different issuers, and an empty commit that moves a group with outstanding reads from age 1 to age 2. Check group read waits with cutoffs 0 and 1 independently of full completion.

## Memory barriers

### [`blackwell_mbarrier_backing`](../doc/rtl_specs/mbarrier/blackwell_mbarrier_backing.md)

- Interleave reads and writes to both 8 B objects in one 16 B line while stalling requests and returns. Check that each back_req settles exactly once and the unselected half stays intact. Inject a wrong tag, wrong direction, or MEMORY return and verify that the unit retains the dirty victim until a successful write ACK.

### [`blackwell_mbarrier_frontend`](../doc/rtl_specs/mbarrier/blackwell_mbarrier_frontend.md)

- Offer a new commit and an eligible INIT at the same address on one edge. INIT must block the new commit while an older commit can still retire. Use separate addresses for independent issuers. Fill the software response slot, then complete a bound producer and check that the reserved response can progress. Supply a mismatched phase and check fault without a byte deduction.

### [`blackwell_mbarrier_unit`](../doc/rtl_specs/mbarrier/blackwell_mbarrier_unit.md)

- Test four 4096 B transactions per round over two rounds with one flip each, negative T, consecutive same-address COMPLETE_TX and arrival, count limits, failure without false success, 8 B writes preserving the adjacent object, busy throughout dirty eviction, and phase completion coinciding with timeout.
- Cycle through five objects with waits, updates, and dirty misses. Check progress with a four-entry cache, agreement of commit change with the new object, preservation of the adjacent half-line, and retention of the victim until writeback succeeds.

### [`blackwell_mbarrier_wait`](../doc/rtl_specs/mbarrier/blackwell_mbarrier_wait.md)

- Run the deadline cases with an omitted hint, explicit zero, and nonzero hint 641. The initial QUERY sees the old phase without error in all three. Apply the [deadline cases](../doc/rtl_specs/mbarrier/blackwell_mbarrier_wait.md#wait-budget). Test 32 waiters across more than four cache lines, late old probes, acquire backpressure, two consecutive phase flips, and retention of an already presented result on fault.

## Subsystem integration

### [`blackwell_async_subsystem_top`](../doc/rtl_specs/top/blackwell_async_subsystem_top.md)

- In the same CTA, epoch, and warp, thread 5 (A) first issues an ordinary FP16 MMA writing X. Thread 6 (B) next issues an MMA writing Y. After B's register_op.fire and before its engine_done.fire, B commits to a separate initialized barrier one arrival short of completion. Verify the pending snapshot contains only B's operation. Use disjoint X/Y column ranges, input_d=0, and no cross-instruction source/destination aliases. Use the legal ordinary MMA disable_lane_mask so A writes only TMEM partition 0 and B only partition 1. Holding an ACK for A then occupies no bank or ACK frame needed by B.
- Hold only the matching ACK for A's last actual write and keep other interfaces ready. Observe all actual B write ACKs and unpin, then engine_done(B).fire and B's atomic barrier arrival. A is still unfinished and both engine records still occupy slots. Release A's ACK and observe engine_done(A).fire. Reclaim A then B. B must notify and arrive exactly once each. If B is terminal yet cannot notify until A is released, the test fails. Also return MEMORY for A's final ACK. B's previously committed success and arrival must remain, top-level fault must assert, and A must not generate a successful arrival.
- Trace the first three N128 instructions under the [specified steady-state conditions](../doc/rtl_specs/top/blackwell_async_subsystem_top.md#cycles). Check that prefetch, execution, and trailing writes can advance concurrently. For N256 in-place B replacement, stall one core and check deliveries already made, that core's consumption watermark, and the identity of old ACKs.
- In addition to the nonempty commit above, cover independent empty commits, same-address INIT/INVAL exclusion of new commits, and backpressure on software responses and acquire.
- Align transfers, RF writeback, and mbarrier by ID. When two independent loads bind the same phase, acknowledge each byte contribution separately. The consuming warp waits for all expect-tx and arrival obligations and successful acquire. Test recovery after data slots fill, consecutive reads across commands, and progress of a third independent short copy. [TMA data path](../doc/rtl_specs/tma/blackwell_tma_data_path.md#peak) · [Walker handoff example](../doc/rtl_specs/tma/blackwell_tma_unit.md#copy-overlap)
- In the ordering fixture, check visibility at each OK acknowledgment against the operation’s scope and kind. Apply normal backpressure separately during the second phase, descriptor access, final destination ACK, dirty flush, and final ordering. On release check that the original transaction continues. Separately inject MEMORY at the final ACK and check fault and isolated reset.

#### Consecutive N128 accumulation

Eight N128 FP16 instructions accumulate in place. Command i, row m, column n, and K index k start at zero. A and B are exactly representable integer-valued FP16. C is the initial FP32 accumulator.

```text
A[i,m,k] = ((3*m + 2*k + i*(k+1)) mod 7) - 3
B[i,n,k] = ((n + 3*k + i*(n+2)) mod 9) - 4
C[m,n]   = m - 2*n
```

For each coordinate independently add the initial C to products over all k from all eight instructions. Compare all 65,536 FP32 result bytes. Record first dot, last write acceptance, actual write, final ACK, and tracker acceptance for each instruction. Compare timing with the [top-level N128 schedule](../doc/rtl_specs/top/blackwell_async_subsystem_top.md#cycles).

#### Workload replay

- For L/F1/F2 check data and program-visible completion order. Check key edges under the alignment, input readiness, and port service conditions in each specification. Record whole-kernel cycles as observations.
- For L check four 4 KiB copies in each of two rounds, the checksum, phase reuse, and the ordering from final write ACK to wakeup.
- Run the Q=K=0, V=1, O=1 connectivity case and use coordinate-dependent nonuniform inputs to check addresses, values, and completion order separately.
- Compare all 33 MMA combinations and legal dtype, scale, and control settings against an independent numerical reference. WS coverage includes four names, every collector operation, hits, and reload after eviction.

The address fixture derives byte strides from contiguous FP16 B/S/H/D host tensors permuted to logical D/S/H/B. Check the address deltas for a head switch, a sequence increment within one head, and a batch switch. [FA4 layout and schedule](../doc/proposals/mma_inter_instruction_pipeline.md)

A separate H20 independent-load experiment measured 95.3 B per SM cycle with one CTA, hot D128 data and two logical tiles in flight. Allegro’s specified 128 B/cycle peak follows from one full-width grant per cycle.

For measurements, align events by work tile, Q stage, KV index, barrier address/phase, and MMA ID. Record the final destination write ACK, complete-tx, phase flip, successful wait, cmd.fire/prepare, readiness of each row group and the first B block, relevant D block ACKs, and four-core op_load/dot_fire. Delay only the final K or V complete-tx, late P arrival, or the corresponding C block ACK in turn. Identify the first consumer edge that moves. If several conditions are outstanding, attribute the delay to the last one satisfied to avoid counting the same idle cycles against both TMA and P.

For QK with nonuniform integer-valued FP16 inputs and blockwise writeback, all 65,536 B of FP32 output per stage match independent coordinate-wise accumulation.

For PV, compare each lane's read and write words edge by edge and verify the successful old D ACK precedes its C read. Independently accumulate eight steps of nonuniform P/V by output coordinate (m,n), covering both initial zero injection and corrected O. The eight-step nonuniform PV reference covers all 32,768 B of FP32 output for D64 and 65,536 B for each of the two D128 stages.
