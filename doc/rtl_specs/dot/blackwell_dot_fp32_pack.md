# blackwell_dot_fp32_pack

## Description

This combinational encoder converts the final reduction `sum×2^base_exp` or a special result to FP32. Parameters are `SUM_W≥24, EXP_W≥2, CANONICAL_ZERO=1`.

| Signal / channel | Direction | Type / width | Peer | Sampling condition |
|---|---|---|---|---|
| `sum` | Input | signed SUM_W bits | Parent reduction | Combinational finite sum. |
| `base_exp` | Input | signed EXP_W bits | Parent alignment control | Combinational, paired with sum. |
| `special_valid` | Input | 1 bit | Parent special-value logic | Combinational special_result select. |
| `special_result` | Input | 32 bits | Parent special-value logic | Used when special_valid is 1. |
| `result` | Output | 32 bits | Parent result stage | Combinational output without clock or handshake. |

## Functionality

sum=0 produces +0. For other finite values let s be the sign, a the exact absolute value (use a SUM_W+1-bit temporary for the most negative input), h=floor(log2 a), and e=base_exp+h. If h≥23, sig24=a>>(h−23). If h<23, sig24=a<<(23−h). In both cases the highest set bit is bit 23. Discard low bits without incrementing.

- e>127 gives signed Inf.
- For −126≤e≤127, exp=e+127 and fraction is the low 23 bits of sig24.
- For −149≤e<−126, exp=0 and fraction is the low 23 bits of (sig24>>(−126−e)).
- e<−149 gives signed zero, or +0 when CANONICAL_ZERO=1.
- When special_valid=1, return special_result in preference to the finite result.

The wide and K32 paths use CANONICAL_ZERO=1. The native K64 FP4 path uses CANONICAL_ZERO=0 and preserves the sign when a nonzero reduction sum underflows to zero. Exact cancellation produces +0 in every family.

The parent captures the result at its final stage without an extra pipeline stage.

For sum=2^24+3 and base_exp=−24 the retained 24-bit significand is 0x800001 and the FP32 result is 0x3f800001. The discarded 1 does not increment the result.

<a id="numeric-contract"></a>

### Common floating-point result rules

FP32 exponent and fraction widths are 8 and 23 bits respectively, with bias=127. When the exponent is all ones, frac=0 encodes Inf and a nonzero fraction encodes NaN. Each leaf specification defines finite decoding.

Truncate finite values as above. The project specifies overflow to Inf.

Any NaN, 0×Inf, or sum containing infinities of opposite signs produces canonical FP32 NaN `0x7fffffff`. Infinities of only one sign yield that infinity. Resolve all special values before selecting the finite sum. The same rules apply to a NaN scale and to zero scale combined with Inf.

Encode only after the complete integer reduction. Right-shifting the magnitude of −5 by one and restoring its sign must give −2.
