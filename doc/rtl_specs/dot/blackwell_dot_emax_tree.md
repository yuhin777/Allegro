# blackwell_dot_emax_tree

## Description

This combinational tree finds the maximum valid exponent. Parameters are `TERM_N≥1, EXP_W≥2, DEFAULT_EXP`. All exponents are signed. There is no clock, reset, or registered valid/ready channel.

| Signal / channel | Direction | Type / width | Peer | Sampling condition |
|---|---|---|---|---|
| `term_valid` | Input | TERM_N bits | Dot exponent selection stage | Combinational valid bit per term. |
| `term_exp` | Input | TERM_N × EXP_W bits (signed exponents) | Dot exponent selection stage | Combinational signed exponents, one per valid-mask position. |
| `result_valid` | Output | 1 bit | Dot exponent selection stage | Combinational output, at least one term valid. |
| `result_exp` | Output | signed EXP_W bits | Dot exponent selection stage | Combinational output, DEFAULT_EXP when all terms are invalid. |

## Functionality

### Pairwise comparison of valid terms

Each leaf is `(v,e)`. Ignore invalid inputs when merging two nodes. With two valid inputs, take the larger signed exponent, choosing the left on a tie. Two invalid inputs produce invalid/DEFAULT_EXP. Recursively pair adjacent indices and pair an odd trailing entry with invalid. The tree has ceil(log2 TERM_N) levels. Result valid is the OR of all input valid bits.

There is no internal state or added latency. The parent captures the output at its specified pipeline stage. Verify N=1, odd N, all invalid, the minimum negative exponent, and equal exponents. Check that comparisons use signed arithmetic.
