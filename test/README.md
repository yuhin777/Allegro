# Verification notes

## Wide dot arithmetic

Use `MMA_SIM_VECTORS` with [dot/run.sh](dot/run.sh) to prepend raw-bit reference transactions. For nonzero finite terms with matching decode, exponent selection and FP32 packing, compare accumulation against [MMA-Sim fused_sum at ac5b2a4](https://github.com/yuhin777/Allegro/blob/ac5b2a4/MMA-Sim/mmasim/simulator/arithmetic.py). Use the [wide arithmetic contract](../doc/rtl_specs/dot/blackwell_f16tf32_dot.md) for special values, zero terms and C prescale underflow.

- Compare S1 emax with a flat maximum over nonzero products and nonzero prescaled C. Exercise shift distances 0, 25, 26, 27, 31, 32 and 506 with both signs.
- Compare S2 pairs with individually truncated terms and S3 with their flat signed sum. Include same-sign maxima, near cancellation, a single nonzero TF32 lane, and BF16 zero times 2^127 with every other product zero and C=2^−40. The latter returns 0x2b800000.
- Cover all FP16/BF16 input combinations, extrema, subnormals, TF32 Inf and NaNs with payloads only in the low 13 bits, opposing infinities, and C prescale underflow. Stall continuous requests and check the pairing of result, tag, emax and special code across stalls.

## FA4 reference data and measurements

The address fixture derives byte strides from contiguous FP16 B/S/H/D host tensors permuted to logical D/S/H/B. Check the address deltas for a head switch, a sequence increment within one head, and a batch switch. [FA4 layout and schedule](../doc/proposals/mma_inter_instruction_pipeline.md)

A separate H20 independent-load experiment measured 95.3 B per SM cycle with one CTA, hot D128 data and two logical tiles in flight. Allegro’s specified 128 B/cycle peak follows from one full-width grant per cycle.

For measurements, align events by work tile, Q stage, KV index, barrier address/phase, and MMA ID. Record the final destination write ACK, complete-tx, phase flip, successful wait, cmd.fire/prepare, readiness of each row group and the first B block, relevant D block ACKs, and four-core op_load/dot_fire. Delay only the final K or V complete-tx, late P arrival, or the corresponding C block ACK in turn. Identify the first consumer edge that moves. If several conditions are outstanding, attribute the delay to the last one satisfied to avoid counting the same idle cycles against both TMA and P.

## Consecutive MMA accumulation

Eight N128 FP16 instructions accumulate in place. Command i, row m, column n, and K index k start at zero. A and B are exactly representable integer-valued FP16. C is the initial FP32 accumulator.

```text
A[i,m,k] = ((3*m + 2*k + i*(k+1)) mod 7) - 3
B[i,n,k] = ((n + 3*k + i*(n+2)) mod 9) - 4
C[m,n]   = m - 2*n
```

For each coordinate independently add the initial C to products over all k from all eight instructions. Compare all 65,536 FP32 result bytes. Record first dot, last write acceptance, actual write, final ACK, and tracker acceptance for each instruction. Compare timing with the [top-level N128 schedule](../doc/rtl_specs/top/blackwell_async_subsystem_top.md#cycles).

Reuse the same B range for two N256 commands and stall one core's final op_load. That core must retain unconsumed bytes and accept overwrite only on the edge after actual `op_load(j,3)`. Fill B blocks with distinct values and insert an idle cycle between first-group issue and second-group load. Check B and tag on all four issues and verify one local B read enable and one `R_OP.b` write enable per block. A complete N128 instruction issues 64 microtiles and reads 16 blocks per core, totaling 16 KiB of local B reads across the four cores. Backpressure R_OP, D slots, and write ports separately to check payload retention and actual writes per block. Also test TMEM A/scale self-overlap, offset overlap, and fully disabled writes. Delay one return or acknowledgment at a time. Separately delay acceptance of the last old D write and verify payload release and old ACK ownership.

## FA4 block writeback

For QK with nonuniform integer-valued FP16 inputs and blockwise writeback, all 65,536 B of FP32 output per stage match independent coordinate-wise accumulation.

For PV, compare each lane's read and write words edge by edge and verify the successful old D ACK precedes its C read. Independently accumulate eight steps of nonuniform P/V by output coordinate (m,n), covering both initial zero injection and corrected O. The eight-step nonuniform PV reference covers all 32,768 B of FP32 output for D64 and 65,536 B for each of the two D128 stages.

## TMA address coverage

Vary each dimension's stride and the panel independently. At the same coordinate check the GMEM byte and swizzled SMEM byte. See the [FA4 design record](../doc/proposals/mma_inter_instruction_pipeline.md) for actual descriptors, nonmonotonic strides, and individual addresses across panels.

Test nonzero swizzle base, partial/full OOB at edges, 128 B GMEM line crossings, illegal stride alignment, address addition overflow, the last legal SMEM byte, and rejection before bind for invalid fields. Check the [setup precheck and context](../doc/rtl_specs/tma/blackwell_tma_setup.md) against actual source and destination bytes.

## TMA transaction coverage

- **Descriptor cache and setup.** Issue three consecutive hits with distinct tickets, then a miss behind a stalled result. Check one GMEM request per miss, four-way replacement, demand after a prefetch hit or fill, simultaneous result consumption and lookup, address reuse across epochs, and MEMORY fault. Interleave two setup slots, stall result delivery, and check that late replies for three older tickets still reach their original owners after slot reuse.
- **Walker.** Stall S0, S1, and S2 independently. Check stable outputs, contiguous nonoverlapping ordinals, last-to-first command handoff, and recovery after all 64 tags fill. Exercise 16 B-aligned bases inside a sector, distinct GMEM and SMEM boundaries, FP16 row ends, transitions into and out of OOB, and addresses sharing a physical SMEM bank.
- **Data returns.** Issue 64 load reads before any return, hold the oldest return until last, and stall SMEM writes. Fill all 16 rows, check that the 17th successful return waits, then resume and check each selected destination byte exactly once. Return the eight groups out of order, ACK different tags on one edge, and hold the eighth group's ACK across slot reuse. Include short segments, OOB zero fill, all-OOB stores, wrong or duplicate tags, and competing descriptor returns.
- **Completion and faults.** Bind two independent loads to one phase. Delay the first load's last SMEM ACK and its producer response in separate runs. Check that the second can issue while the phase still waits for both contributions and arrivals. For a store spanning two nonadjacent GMEM lines, stall GMEM write acceptance and each ACK separately. Check that group read completion can precede full completion. Return MEMORY on the final write with all rows occupied. Check fault, preservation of committed writes, and no finish for the failed ticket.
- **Command overlap and groups.** Issue three 16 B linear loads to SMEM bases 0x000, 0x090, and 0x120 with a disjoint barrier. Hold the last ACKs of the first two and check that the third issues its read. For two successive barrier phases, register 16384 B per phase and check four 4096 B contributions before address reuse with new parity. Distinguish source progress, destination ACK, producer response, and software response edges. Exercise tiled loads and stores, groups from different issuers, and an empty commit that moves a group with outstanding reads from age 1 to age 2. Check group read waits with cutoffs 0 and 1 independently of full completion.

## B loader coverage

- Compare nonuniform raw 16-bit values element by element for both major orders and both FP16 and BF16. Check addresses, all 16 tokens, and column order across N64/128/256, swizzle phases, panel boundaries, and instruction boundaries. Interleave K-major, N-major, and generic blocks and verify that backpressure preserves the oldest slot's mode selection.
- Stall one return group and separately stall a core. Verify source credit return edges, held payload, exactly-once delivery to each destination, and slot reuse. Check errors on the final return, WS hit/miss, and shutdown drain.
- For generic formats cover low-bit packing, padding, multiple parts arriving for one destination row on one edge, and general-layout bank conflicts. Compare all four cores' data byte by byte.

## Dot array coverage

With the v1 shared array, check sustained wide/K32 issue with the sink ready, each family's isolated latency after drain, and synchronous reset at full blocked capacity.

Cover all 33 supported kind/mode/shape combinations. Issue six-stage low precision, three-stage integer, and five-stage FP16/TF32 consecutively. Stall the head result while the shorter family becomes ready first. Check that queued family IDs equal the number of valid microtiles in the pipelines, results deliver in original tag order, and lifting D backpressure causes no loss or duplication. Check native edges and payload capacity for each family. Verify broadcast wiring with an asymmetric INT8 microtile. Only k=0 is nonzero, A[r,0]=r+1, B[c,0]=c+9, and C[8r+c]=100r+c. Check `(r+1)×(c+9)+100r+c` in every cell.

Continuously vary input data and switch families. Check that unselected S0 row/column inputs stay zero and that issued microtiles deliver with their original tags. A blocked selected input holds its decoded values through the handshake edge.

## Barrier wait coverage

Run each acceptance case with an omitted hint, explicit zero, and nonzero hint 641. The initial QUERY sees the old phase without error in all three. Apply the [deadline cases](../doc/rtl_specs/mbarrier/blackwell_mbarrier_wait.md#wait-budget). Test 32 waiters across more than four cache lines, late old probes, acquire backpressure, two consecutive phase flips, and retention of an already presented result on fault.
