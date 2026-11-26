# blackwell_dot_align_fixed_rz

## Description

This combinational aligner implements rounding toward zero by shifting the unsigned magnitude right before applying the sign. Parameters are `MAG_W≥1, TERM_W=MAG_W+1, EXP_W≥2`.

| Signal / channel | Direction | Type / width | Peer | Sampling condition |
|---|---|---|---|---|
| `term_valid`, `term_sign` | Input | 1 bit each | Dot alignment stage | Combinational valid and sign. |
| `term_mag` | Input | unsigned MAG_W bits | Dot alignment stage | Combinational unsigned magnitude. |
| `term_exp`, `emax` | Input | signed EXP_W bits each | Dot alignment stage | Combinational signed exponents. |
| `term` | Output | signed TERM_W bits | Dot alignment stage | Combinational aligned term. |

## Functionality

Compute `d=emax−term_exp` in EXP_W+1 bits. Valid inputs require d≥0. If d≥MAG_W, use zero. Otherwise q=term_mag>>d. The output is `term_sign ? -signed({0,q}) : signed({0,q})`. An invalid input produces zero. A negative d is an internal upstream protocol error.

The aligner has no registers and adds zero cycles. The parent defines the binary point when left-shifting the input magnitude. `signed_negative >>> d` rounds toward negative infinity and is not equivalent.
