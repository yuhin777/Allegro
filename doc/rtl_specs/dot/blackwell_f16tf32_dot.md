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
| TF32 container | FP32 container, retaining 10 fraction bits for arithmetic | 127 | Classify Inf and NaN after discarding the low 13 fraction bits |

The bit-exact reference uses integer significands and the truncation points specified for this pipeline. See [FP32 pack](blackwell_dot_fp32_pack.md#numeric-contract) for special-value resolution and FP32 packing.

### Pipeline registers

Each row describes the combinational work ending at that register. Each stage can accept a new transaction as its previous transaction advances. The 2-bit special-result code travels with the same transaction through S0…S3.

| Stage | Work before the register | Registered payload per dot | Bits |
|---|---|---|---:|
| S0 | Multiply 16 pairs of 11-bit significands. In parallel, add operand exponents and find the maximum within each consecutive group of four products (two comparison levels). Prescale C and resolve special classes. | 16 × (sign1, sig22, exp9), four group maxima × 9, C(sign1, sig24, exp9), special2 | 584 |
| S1 | Find the maximum of the four group maxima and the C exponent. Subtract each term exponent from this global maximum and saturate the distance. | 16 × (sign1, sig22, distance5), C(sign1, sig24, distance5), emax9, special2 | 489 |
| S2 | Align each unsigned magnitude independently, truncate toward zero, apply its sign, then add adjacent product pairs. Align and sign C in parallel. | Eight signed29 pair sums, signed27 C, emax9, special2 | 270 |
| S3 | Sign-extend eight pair sums and C and reduce nine terms to one exact integer. | signed33 sum, emax9, special2 | 44 |
| S4 | Normalize the sum, apply FP32 truncation, select the special result when required and capture the encoding. | result32 | 32 |

Independent native pipeline data storage is 1,419 bits/dot or 11,352 B for 64 dots. The array shares stage control across its 64 cells. See [array storage](../tensor_core/blackwell_tc_dot_array.md#floating-point-storage) for the output collision buffer and configuration totals. The array keeps a stage-matched microtile tag chain shared by all 64 leaves. The cut divides exponent selection between S0 and S1 and divides integer addition between S2 and S3. These are combinational work assignments. Their propagation delays depend on the implementation.

### Decode, align, reduce, and pack

The row/column decoders represent finite values as `sign*sig11*2^(e−10)`. For FP16 normals, sig=1024+frac and e=exp−15. For subnormals, sig=frac and e=−14. BF16 uses sig=(128+frac)<<3 or subnormal frac<<3, with e=exp−127 or −126 respectively. TF32 takes the upper 10 bits of the FP32 fraction with the FP32 exponent. NaN detection uses the retained 10 fraction bits. A zero exponent and zero upper 10 fraction bits classify a finite TF32 as zero. Fill A and B terms 8…15 with +0 in TF32 mode.

1. First compute `C_eff=C*2^(-scale_input_d)` for C. Adjust the exponent for normals. When entering the subnormal range, shift the unsigned significand right and truncate. For an original subnormal, shift the fraction directly. Preserve Inf, NaN, and zero. Prescale C in an FP32 container.
2. An exact 11×11 multiplication produces sig22. Sign-extend both e values to 9 bits before adding. Decode C to sig24 and eC, with normal value sig24×2^(eC−23). Select emax from C and all product exponents, including products with zero magnitude. Each zero operand and zero C contributes an operand exponent of −126. For example, a zero multiplied by 2^127 contributes product exponent 1.
3. Use the unsigned product magnitude `sig22 << 5` (27 bits) and C magnitude `sig24 << 2` (26 bits). Both have 25 fractional bits at their term exponent. Compute `d = emax − e` with sign-extended exponents before narrowing. The full distance can reach 506. Encode `min(d,27)` in five unsigned bits for both paths. A logical right shift by 27 clears either magnitude. Apply each sign **after** this shift so that negative terms truncate toward zero. The decoded zero significand already produces a zero contribution. Its exponent still participates in S0/S1. The special-result code takes priority at S4.
4. A signed aligned product fits in 28 bits and signed C in 27 bits. Each exact sum of two products fits in signed29. At S3 every partial sum is bounded in magnitude by `16 × (2047² << 5) + ((2²⁴−1) << 2)`, below 2³². Signed33 therefore suffices throughout the final reduction. Signed32 can overflow for legal FP16 inputs with every significand equal to 2047, product exponents zero, and C just below 2. Pairing occurs only after individual truncation. Cancellation and regrouping then have the same result as summing all 17 integers directly.
5. Use the signed33 sum with `base_exp = sext10(emax) − 25` for FP32 packing. Normalize and truncate toward zero to the representable FP32 significand. Exact cancellation and underflow to zero produce +0. A NaN operand, zero times infinity or opposing infinity signs select canonical NaN. A single infinity sign selects that infinity.

The arithmetic contract follows Blackwell `fused_dot_add`, `fused_sum` and the FP32 branch of `nv_fused_dot_add`. Each term truncates at the global exponent. A group maximum serves only as an intermediate comparison result. Rounding or aligning a group before the global maximum is known can change the final FP32 word. [MMA-Sim arithmetic at ac5b2a4](https://github.com/yuhin777/Allegro/blob/ac5b2a4/MMA-Sim/mmasim/simulator/arithmetic.py)

Put FP16 A=2 and B=3 only at k=1, with C=1 and scale_input_d=0. With the array applying negate_a, the request's A at that index must be −2 and the leaf result −5 (0xc0a00000).

### Result transfer and stalls

Input fire at l captures S0. Without stalls S4 is visible after l+4 and can transfer at l+5. P=5 and II=1. Backpressure propagates toward the input stage by stage. Each full stage holds its payload until it can advance. Reset clears only the five valid bits.

Verify all FP16/BF16 input combinations, TF32 Inf and NaN after truncation, maximum/minimum normals, subnormals, exact cancellation, conflicting Inf signs, and C prescale underflow. The bit-exact reference must reproduce the specified fixed-point order. Per-term host floating-point addition is insufficient. Randomly stall continuous requests and check for loss, duplication, and correct edge-by-edge pairing of S4 results with input tags.

For stage-level acceptance, compare S1 emax with a flat maximum over the active K products and C, including zero terms. Exercise distances 0, 25, 26, 27, 31, 32 and 506 with both signs. Compare S2 pair sums with separately truncated terms and S3 with their flat signed sum. Include same-sign maximum products, near cancellation, a single nonzero TF32 lane, and a zero times 2^127 alongside a small finite product. Stalls at any cut must preserve the pairing of data, emax and special code.

RTL: [blackwell_f16tf32_dot.sv](../../../rtl/dot/blackwell_f16tf32_dot.sv).

## Submodules

| Submodule | Instances per dot | Connections and control |
| --- | --- | --- |
| [dot_emax_tree](blackwell_dot_emax_tree.md) | 4 local + 1 global | Four 4-input signed9 maxima feed S0. A 5-input signed9 maximum including C feeds S1 distance generation. |
| Magnitude alignment | 17 | S2 consumes the bounded S1 distances directly and applies the [RZ aligner](blackwell_dot_align_fixed_rz.md) magnitude and sign semantics. |
| [dot_signed_reduce_tree](blackwell_dot_signed_reduce_tree.md) | 8 pairs + 2 groups + 1 tail | S2 registers eight exact pair sums. Two four-input carry-save group trees feed a dedicated three-input carry-save tree with C before S3. Each tree ends in one carry-propagating addition. Shared mode uses the lower half of the K32 pair and group trees. |
| [dot_fp32_pack](blackwell_dot_fp32_pack.md) | 1 | Encode with the extended base_exp and capture in S4. |
| [FP stage control](../../../rtl/dot/blackwell_fp_dot_control.sv) | Shared across cells | S0…S3 capture on their common enables. The wide tail captures the packed result and holds it until retirement or transfer into the spill slot. |
