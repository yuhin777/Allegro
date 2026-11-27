# blackwell_int8_dot

## Description

Computes one complete 32-term S8/U8 integer dot plus S32 C, with independent A/B signedness. Each core's integer array has 64 copies. Logical K=32 and all terms participate in a single reduction.

| Signal / channel | Direction | Type / width | Peer | Sampling condition |
|---|---|---|---|---|
| `req` | Input | 609 bits (32 A and 32 B signed 9-bit elements, 32-bit C and 1-bit saturate) | TC dot array | `req.fire` captures S0. Element k=0 occupies the low 9 bits. |
| `rsp` | Output | 33 bits (32-bit result and 1-bit overflow) | TC dot array | `rsp.fire` delivers the result. |

```mermaid
flowchart LR
  I["Row/column broadcast of signed9"] --> M["32 multipliers, 9×9"]
  M --> S0["S0: 16 signed18 pair sums"]
  S0 --> T["Four-level reduction to signed22"]
  T --> S1[S1: psum / C / saturate]
  S1 --> A["Widen, add C, detect overflow, clamp"]
  A --> S2[S2: result / R_DOT]
```

## Functionality

Follow the [common protocol](../top/blackwell_async_subsystem_top.md#common-protocol). overflow indicates that the infinite-precision final integer result exceeds the S32 range. It is reported even when saturation is disabled.

### Operand extension, reduction, and saturation

The array uses each row and column dtype to sign-extend S8 or zero-extend U8 to signed9. Legal signed9 inputs represent S8 or U8 values in [−128,255]. Each signed17 product is in [−32640,65025]. Add adjacent products exactly in signed18 before S0. Sign-extend the 16 pair sums to signed22 and reduce through four addition levels before S1. The 32-term sum lies in [−1044480,2080800]. Extend C to signed33 and add psum. Valid ranges guarantee 33 bits suffice. When saturation is enabled, clamp to [−2^31,2^31−1]. Otherwise return the low 32 bits. Saturate only the final result.

| Stage | Registered payload | Bits per dot |
|---|---|---:|
| S0 | 16×signed18,C32,saturate1 | 321 |
| S1 | psum22,C32,saturate1 | 55 |
| S2 | result32,overflow1 | 33 |

The pipeline stores 409 data bits and three valid bits per dot. S2 is the result register.

Set the two low bytes of A to 0xff, 0x01, and of B to 0x02, 0x03. Set all other terms to zero and C=4. With S8 A and U8 B the result is 5. Changing only A to U8 gives 517.

### Result transfer and stalls

Input fire at l captures S0. R_DOT is visible after l+2 and first transfers at l+3. P=3 and II=1. Three independent elastic stages include R_DOT. A downstream stall must not overwrite any stage. Reset clears valid.

Apply S32 wrap or saturation only to the final sum.

RTL: [blackwell_int8_dot.sv](../../../rtl/dot/blackwell_int8_dot.sv).

## Submodules

Instance counts are per dot unless specified otherwise.

| Submodule | Instances | Connections and control |
| --- | --- | --- |
| [dot_signed_reduce_tree](blackwell_dot_signed_reduce_tree.md) | 1 | Reduces 16 signed18 pair sums to the signed22 partial sum before S1. |
| [pipeline_reg](../base/blackwell_pipeline_reg.md) | 3 | S0 captures pair sums, S1 the partial sum, and S2 the result including overflow. |
