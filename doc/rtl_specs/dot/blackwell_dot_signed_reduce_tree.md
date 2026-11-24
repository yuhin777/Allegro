# blackwell_dot_signed_reduce_tree

## Description

This balanced combinational tree sums the signed fixed-point terms supplied by its parent. Parameters are `TERM_N≥1, TERM_W≥1, SUM_W≥TERM_W`.

| Signal / channel | Direction | Type / width | Peer | Handshake or sampling condition |
| --- | --- | --- | --- | --- |
| term[TERM_N] | Input | signed[TERM_W] per term | Parent fixed-point data path | Combinational, term 0 at the lowest index |
| sum | Output | signed[SUM_W] | Parent result stage | Combinational, no clock or handshake |

## Functionality

Sign-extend every term to SUM_W, then add in that width at each level. A general overflow-free choice is `SUM_W=TERM_W+ceil(log2 TERM_N)`. A dot parent may prove a narrower bound from valid magnitudes and must specify its proof and parameters. If the mathematical sum exceeds SUM_W, the output is its low SUM_W two's-complement bits. Assert that legal product inputs cannot reach this case. This wraparound does not implement saturation.

Pair adjacent terms starting at the low index. N=1 directly sign-extends. Pad an odd entry with zero. There are ceil(log2 TERM_N) levels, with no intermediate FP rounding or internal registers. Verify odd N, alternating signed extrema, zero sums, and the specified overflow behavior against an arbitrary-precision integer reference.
