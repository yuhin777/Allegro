# blackwell_dot_signed_reduce_tree

## Description

This combinational tree sums the signed fixed-point terms supplied by its parent. Parameters are `TERM_N≥1, TERM_W≥1, SUM_W≥TERM_W`.

| Signal / channel | Direction | Type / width | Peer | Sampling condition |
|---|---|---|---|---|
| `term[TERM_N]` | Input | TERM_N × TERM_W bits (signed terms) | Parent fixed-point data path | Combinational. Term 0 occupies the low TERM_W bits. |
| `sum` | Output | signed SUM_W bits | Parent result stage | Combinational, no clock or handshake. |

## Functionality

Sign-extend every term to SUM_W, then add in that width at each level. A general overflow-free choice is `SUM_W=TERM_W+ceil(log2 TERM_N)`. A dot parent may prove a narrower bound from valid magnitudes and must specify its proof and parameters. If the mathematical sum exceeds SUM_W, the output is its low SUM_W two's-complement bits. The parent bounds legal products so their sum fits SUM_W. This wraparound does not implement saturation.

With the default `CARRY_SAVE=0`, pair adjacent terms at each level and pass any unpaired term forward. The binary tree has ceil(log2 TERM_N) levels. With `CARRY_SAVE=1`, each group of three operands emits two SUM_W-bit rows (bitwise sum and left-shifted majority carry). Pass remaining rows forward. Repeat until two rows remain and add them once with carry propagation. Both implementations sign-extend a single input directly and have no intermediate FP rounding or internal registers.
