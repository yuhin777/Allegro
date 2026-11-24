# blackwell_pipeline_reg

## Description

This module connects adjacent pipeline stages. A `WIDTH≥1`-bit data register and a valid bit form a one-entry elastic stage.

| Signal / channel | Direction | Type / width | Peer | Handshake or sampling condition |
| --- | --- | --- | --- | --- |
| in | Input | bits[WIDTH] | Upstream | in.fire captures input |
| out | Output | bits[WIDTH] | Downstream | out.fire consumes the registered output |

The [top-level common protocol](../top/blackwell_async_subsystem_top.md#common-protocol) defines clock, reset, and channel sampling.

## Functionality

Before the edge, out_valid=valid_q, out_payload=payload_q, and `in_ready=!valid_q || out_ready`. Synchronous reset takes priority on the rising edge and clears valid. Otherwise, only when in_ready is asserted, set valid_q=in_valid and load payload if in_valid is 1. On simultaneous out.fire and in.fire, the downstream stage consumes the old value and the register holds the new one after the edge.

An input accepted at t is visible after t and can transfer at t+1. Throughput is one item per cycle. There is no combinational fall-through data path or backup slot. Reset leaves payload untouched. Check empty, full and stalled, simultaneous input/output, and valid stability. The parent must avoid combinational ready loops.
