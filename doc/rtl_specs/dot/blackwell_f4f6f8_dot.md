# blackwell_f4f6f8_dot

## Description

Computes a complete 32-term low-precision dot with any A/B combination of E4M3/E5M2/E3M2/E2M3/E2M1 and optional UE8M0 1X scale. Each core computes 64 K32 dots per issued microtile. The core places raw elements in the low bits of each byte. The array decodes and broadcasts elements and scales by row or column.

| Signal / channel | Direction | Type / width | Peer | Handshake or sampling condition |
| --- | --- | --- | --- | --- |
| req | Input | a[32],b[32] each contain `{class2,sign1,sig4,e:s5}` elements, plus c32 and one `{nan1,e:s8}` each for scale_a/scale_b, 818 bits total | TC dot array | req.fire captures S0. See [dot array](../tensor_core/blackwell_tc_dot_array.md) for class and bit order |
| rsp | Output | result32, 32bit | TC dot array | rsp.fire delivers the result |

```mermaid
flowchart LR
  I["Low row/column decode"] --> S0["S0: products, four group maxima and scaled C exponent"]
  S0 --> S1["S1: global maximum and bounded distances"]
  S1 --> S2["S2: truncate, sign, add 16 pairs"]
  S2 --> S3["S3: four group sums and C"]
  S3 --> S4["S4: total sum"]
  S4 --> S5["S5: FP32 result"]
```

## Functionality

Command dtype values 3…7 select E4M3, E5M2, E3M2, E2M3, and E2M1 respectively. See the [interfaces](../top/blackwell_async_subsystem_top.md#common-protocol) for common protocol and [input formats](blackwell_f4f6f8_dot.md#formats) for numerical formats.

<a id="formats"></a>

### Input formats and reference requirements

Represent finite values as `(-1)^sign × significand × 2^exponent`. For normals, significand=2^p+fraction and exponent=exp_field−bias−p. For subnormals, significand=fraction and exponent=1−bias−p. Zero has significand=0.

| Format | exponent/fraction bit | bias | Special values |
|---|---|---:|---|
| E4M3 | 4/3 | 7 | exp=15 and frac=7 gives NaN. All other encodings are finite. No Inf |
| E5M2 | 5/2 | 15 | exp=31: frac=0 gives Inf, otherwise NaN |
| E3M2 | 3/2 | 3 | All encodings finite |
| E2M3 | 2/3 | 1 | All encodings finite |
| E2M1 | 2/1 | 1 | All encodings finite, including positive and negative zero |

UE8M0 has no sign or fraction. Values 0…254 represent 2^(byte−127). Value 255 is NaN.
The bit-exact reference uses integer significands and the truncation points specified for this pipeline. See [FP32 pack](blackwell_dot_fp32_pack.md#numeric-contract) for special-value resolution and FP32 packing.

### Pipeline registers

| Stage | Registered payload | Bits per dot |
|---|---|---:|
| S0 | 32 × (sign1, sig8, exp6), four (valid1, max9) records, C(sign1, valid1, sig24, relative_exp10), scale9, special2 | 567 |
| S1 | 32 × (sign1, sig8, distance5), C(sign1, sig24, distance5), base10, special2 | 490 |
| S2 | 16 × signed29 pair sums, signed27 C, base10, special2 | 503 |
| S3 | Four signed31 group sums, signed27 C, base10, special2 | 163 |
| S4 | signed33 sum, base10, special2 | 45 |
| S5 | FP32 result | 32 |

The native K32 path stores 1,800 bits per dot. The v1 array shares S0…S3 with wide requests and uses a dedicated K32 sum and pack tail. See [array storage](../tensor_core/blackwell_tc_dot_array.md#floating-point-storage) for the physical widths.

### Products, scaling, reduction, and packing

Decode all formats to `sign*sig4*2^(e−3)`. Let p be the source fraction width. For normals use sig4=((1<<p)+frac)<<(3−p), and for subnormals sig4=frac<<(3−p), adding zero low bits. For FP4 and FP6 subnormals, normalize sig4 until its high bit is set and decrease e by the same shift count. FP8 keeps the source subnormal exponent. The leaf multiplies the two unsigned sig4 values. Both S0 and S1 register the raw unsigned product8. Sign-extend both e values to 6 bits before adding them.

With MX disabled, each row and column decoder sends `{nan=0,e=0}`. When enabled, decode 0…254 to e=byte−127 and 0xff to `{nan=1,e=0}`. The leaf sums both scale exponents in signed9 to obtain E (−254…254). Either nan bit produces NaN. Convert the C exponent to `eC−E` and retain its unsigned 24-bit significand through S1. For every dtype pair and either MX setting, only nonzero finite products and nonzero finite C contribute to emax. A group containing only zero products has an invalid maximum. An all-zero sum returns +0.

S0 compares eligible exponent sums in four groups of eight. S1 compares valid groups with eligible C in the product exponent domain. Use a signed10 relative exponent for C. Subtract at full width before encoding each distance as min(distance,27) for a contributing magnitude. A zero magnitude contributes zero for every shift encoding. S1 also computes base_exp=emax−25+E.

S2 aligns product8 shifted left by 19 and C sig24 shifted left by two. Truncate each unsigned magnitude before applying its sign and adding adjacent products. A magnitude is bounded by 225 × 2^19. Signed29 holds two aligned products, signed31 holds eight, and signed33 holds 32 plus signed27 C. S3 adds four pairs per group using carry-save compression followed by one carry-propagating addition. S4 adds the four groups and C. S5 resolves the carried 2-bit special code and packs the sum toward zero.

For E2M1 0x3×0x2 with every other term and C zero, the result must be 0x3fc00000. For E4M3 0x3f×0x3f, both sig4 values are 15 and product8 must be 225 in S0/S1. Disable MX and set C=2^20 with all remaining products zero. The difference between emax and the product exponent is 20 and the aligned magnitude is 112. Flipping one input sign yields −112. Stalling and resuming S1 must preserve the term.

### Result transfer and stalls

P=6. Edge l captures S0. S5 is visible after l+5 and the earliest output transfer is l+6. II=1. Each occupied stage holds its payload during a stall. Synchronous reset invalidates in-flight microtiles. The [array protocol](../tensor_core/blackwell_tc_dot_array.md#issue-order-result-selection-and-backpressure) defines retirement across families. Adjacent inputs may change dtype and MX mode. S0 captures the microtile's products, special classifications, and scale exponent. Later stages use only the in-flight fields.

Verify all 25 dtype combinations, finite extrema/zero/subnormal/NaN as applicable, E5M2 Inf, UE8M0 0/254/255, and signed cancellation. Compare MX against a reference using exactly the same fixed-point alignment. With E5M2 A all zero, B[0]=0x7b, and FP32 C=0x00000001, verify that both unscaled and unit-scaled MX return C. Check truncation for large exponent differences between scaled finite products and C. Assert correct behavior under uniform backpressure across 64 lanes and fault injection with partial ready.

RTL: [blackwell_f4f6f8_dot.sv](../../../rtl/dot/blackwell_f4f6f8_dot.sv).

## Submodules

Instance counts are per dot unless specified otherwise.

| Submodule | Instances | Connections and control |
| --- | --- | --- |
| [dot_emax_tree](blackwell_dot_emax_tree.md) | 4 local + 1 global | S0 compares eight exponents per group. S1 combines groups and C. |
| [dot_signed_reduce_tree](blackwell_dot_signed_reduce_tree.md) | 16 pairs + 4 groups + 1 tail | S2 pairs aligned terms, S3 captures signed31 group sums, S4 includes C. |
| [dot_fp32_pack](blackwell_dot_fp32_pack.md) | 1 | S5 captures the result. |
| [FP stage control](../../../rtl/dot/blackwell_fp_dot_control.sv) | 1 per K32-capable path per core | Drives stage enables and K32 result retirement. |

The [low front end](../../../rtl/dot/blackwell_fp_dot_front.sv) and the [configurable lane](../../../rtl/dot/blackwell_fp_dot_lane.sv) implement these stages.
