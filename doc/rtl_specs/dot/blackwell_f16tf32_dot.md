# blackwell_f16tf32_dot

## Description

Computes one complete FP16/BF16 dot16 or TF32 dot8 using `C_eff+ΣA*B`. Each core computes 64 wide dot products in parallel. TF32 enables only the first eight terms. The other terms do not participate in special-value handling or emax. The core unpacks in logical K order. [dot array](../tensor_core/blackwell_tc_dot_array.md) applies negate, decodes each row or column, and broadcasts the result. See [input formats](blackwell_f16tf32_dot.md#formats) for numerical formats.

| Signal / channel | Direction | Type / width | Peer | Handshake or sampling condition |
| --- | --- | --- | --- | --- |
| req | Input | a[16],b[16] each contain `{class2,sign1,sig11,e:s8}` elements, plus c32 and scale_input_d4, 740 bits total | TC dot array | req.fire captures S0. See [dot array](../tensor_core/blackwell_tc_dot_array.md) for class and element order |
| rsp | Output | result32, 32bit | TC dot array | rsp.fire delivers the FP32 result |

```mermaid
flowchart LR
  A["Decoded A/B rows and columns, C, shift"] --> S0["S0: exact products, four local exponent maxima, C prescale"]
  S0 --> S1["S1: global maximum and bounded shift distances"]
  S1 --> S2["S2: truncate each magnitude, apply signs, add adjacent pairs"]
  S2 --> S3["S3: reduce eight pair sums and C"]
  S3 --> S4["S4: normalize and pack FP32"]
```

## Functionality

clk/rst_n and valid/ready follow the [common conventions](../top/blackwell_async_subsystem_top.md#common-protocol). The upstream checks the type combination and excludes invalid values. FP16/BF16 use 16-bit elements and TF32 uses a 32-bit container.

<a id="formats"></a>

### Input formats and reference requirements

Represent finite values as `(-1)^sign × significand × 2^exponent`. For normals, significand=2^p+fraction and exponent=exp_field−bias−p. For subnormals, significand=fraction and exponent=1−bias−p. Zero has significand=0.

| Format | exponent/fraction bit | bias | Special values |
|---|---|---:|---|
| FP16 | 5/10 | 15 | All-one exponent: frac=0 gives Inf, otherwise NaN |
| BF16 | 8/7 | 127 | Same as above |
| TF32 container | FP32 container, retaining 10 fraction bits for arithmetic | 127 | Classify Inf and NaN using all 23 FP32 fraction bits |

The bit-exact reference uses integer significands and the truncation points specified for this pipeline. See [FP32 pack](blackwell_dot_fp32_pack.md#numeric-contract) for special-value resolution and FP32 packing.

### Pipeline registers

| Stage | Registered payload | Bits per dot |
|---|---|---:|
| S0 | 16 × (sign1, sig22, exp9), four group maxima × 9, C(sign1, sig24, exp9), special2 | 584 |
| S1 | 16 × (sign1, sig22, distance5), C(sign1, sig24, distance5), emax9, special2 | 489 |
| S2 | Eight signed29 pair sums, signed27 C, emax9, special2 | 270 |
| S3 | signed33 sum, emax9, special2 | 44 |
| S4 | result32 | 32 |

The native wide path stores 1,419 bits per dot. In the default array, wide and K32 share the S0…S3 registers and use separate tails. The independent configuration gives each path its own S0…S3 registers. See [array storage](../tensor_core/blackwell_tc_dot_array.md#floating-point-storage) for the physical widths.

### Decode, align, reduce, and pack

The row/column decoders represent finite values as `sign*sig11*2^(e−10)`. For FP16 normals, sig=1024+frac and e=exp−15. For subnormals, sig=frac and e=−14. BF16 uses sig=(128+frac)<<3 or subnormal frac<<3, with e=exp−127 or −126 respectively. TF32 takes the upper 10 bits of the FP32 fraction with the FP32 exponent. With an all-ones exponent, any set fraction bit in the original container selects NaN. Thus 0x7f800001 encodes NaN and 0x7f800000 encodes +Inf. A zero exponent and zero upper 10 fraction bits classify a finite TF32 as zero. Fill A and B terms 8…15 with +0 in TF32 mode.

1. First compute `C_eff=C*2^(-scale_input_d)` for C. Adjust the exponent for normals. When entering the subnormal range, shift the unsigned significand right and truncate. For an original subnormal, shift the fraction directly. Preserve Inf, NaN, and zero. Prescale C in an FP32 container.
2. An exact 11×11 multiplication produces sig22. Sign-extend both e values to 9 bits before adding. Decode C to sig24 and eC, with normal value sig24×2^(eC−23). For a finite result, select emax from the exponents of the nonzero products and nonzero prescaled C. An empty group contributes −256, below the smallest finite product exponent of −252. If all groups and C are zero, the integer sum is zero and the packed result is +0.
3. Use the unsigned product magnitude `sig22 << 5` (27 bits) and C magnitude `sig24 << 2` (26 bits). Both have 25 fractional bits at their term exponent. For each nonzero term compute `d = emax − e` with sign-extended exponents before narrowing. The full distance can reach 506. Encode `min(d,27)` in five unsigned bits for both paths. A logical right shift by 27 clears either magnitude. Apply each sign **after** this shift so that negative terms truncate toward zero. A zero significand contributes zero for every shift encoding. The special-result code takes priority at S4.
4. A signed aligned product fits in 28 bits and signed C in 27 bits. Each exact sum of two products fits in signed29. At S3 every partial sum is bounded in magnitude by `16 × (2047² << 5) + ((2²⁴−1) << 2)`, below 2³². Signed33 therefore suffices throughout the final reduction. Signed32 can overflow for legal FP16 inputs with every significand equal to 2047, product exponents zero, and C just below 2. Pairing occurs only after individual truncation. Cancellation and regrouping then have the same result as summing all 17 integers directly.
5. Use the signed33 sum with `base_exp = sext10(emax) − 25` for FP32 packing. Normalize and truncate toward zero to the representable FP32 significand. Exact cancellation and underflow to zero produce +0. A NaN operand, zero times infinity or opposing infinity signs select canonical NaN. A single infinity sign selects that infinity.

For nonzero finite terms, the global alignment and per-term truncation use the Blackwell accumulation precision in MMA-Sim’s `fused_sum`. A group maximum serves only as an intermediate comparison result. Rounding or aligning a group before the global maximum is known can change the final FP32 word. [MMA-Sim arithmetic at ac5b2a4](https://github.com/yuhin777/Allegro/blob/ac5b2a4/MMA-Sim/mmasim/simulator/arithmetic.py)

Put FP16 A=2 and B=3 only at k=1, with C=1 and scale_input_d=0. With the array applying negate_a, the request's A at that index must be −2 and the leaf result −5 (0xc0a00000).

### Result transfer and stalls

Input fire at l captures S0. Without stalls S4 is visible after l+4 and can transfer at l+5. P=5 and II=1. Backpressure propagates toward the input stage by stage. Each full stage holds its payload until it can advance. Synchronous reset clears the five stage-valid bits in the standalone wide leaf. In either array configuration it also invalidates the wide spill slot and clears the [issue-order FIFO](../tensor_core/blackwell_tc_dot_array.md#issue-order-result-selection-and-backpressure).

Verify all FP16/BF16 input combinations, TF32 Inf and NaNs whose only set fraction bits lie in the low 13 container bits, maximum/minimum normals, subnormals, exact cancellation, conflicting Inf signs, and C prescale underflow. The bit-exact reference must reproduce the specified fixed-point order. Per-term host floating-point addition is insufficient. Randomly stall continuous requests and check for loss, duplication, and correct edge-by-edge pairing of S4 results with input tags.

For stage-level acceptance, compare S1 emax with a flat maximum over nonzero products and nonzero prescaled C. Exercise distances 0, 25, 26, 27, 31, 32 and 506 with both signs. Compare S2 pair sums with separately truncated terms and S3 with their flat signed sum. Include same-sign maximum products, near cancellation, a single nonzero TF32 lane, and BF16 zero times 2^127 with all other products zero and C=2^−40. The latter must return C (0x2b800000). With nonzero products +1, −1 and 2^−26 and C=0, the small term truncates at the common exponent of ±1 and the result is +0. Stalls at any cut must preserve the pairing of data, emax and special code.

RTL: [blackwell_f16tf32_dot.sv](../../../rtl/dot/blackwell_f16tf32_dot.sv).

## Submodules

Instance counts are per dot unless specified otherwise.

| Submodule | Instances | Connections and control |
| --- | --- | --- |
| [dot_emax_tree](blackwell_dot_emax_tree.md) | 4 local + 1 global | Four 4-input signed9 maxima feed S0. A 5-input signed9 maximum including C feeds S1 distance generation. |
| [dot_signed_reduce_tree](blackwell_dot_signed_reduce_tree.md) | 8 pairs + 2 groups + 1 tail | S2 registers eight exact pair sums. Two four-input carry-save trees feed the three-input carry-save tail with C before S3. |
| [dot_fp32_pack](blackwell_dot_fp32_pack.md) | 1 | Encode with the extended base_exp and capture in S4. |
| [FP stage control](../../../rtl/dot/blackwell_fp_dot_control.sv) | 1 per wide-capable path per core | Drives stage enables and wide result retirement. |

The [wide front end](../../../rtl/dot/blackwell_fp_dot_front.sv) supplies the products and shift distances. The [configurable lane](../../../rtl/dot/blackwell_fp_dot_lane.sv) aligns the 16 products and C inline using the [RZ alignment rules](blackwell_dot_align_fixed_rz.md).
