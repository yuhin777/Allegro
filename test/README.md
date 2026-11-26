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
