# blackwell_fifo

## Description

This synchronous FIFO delivers data from producer to consumer in acceptance order. Its parameters are `WIDTH≥1, DEPTH≥1`. A combinational read of the register array supplies the head.

| Signal / channel | Direction | Type / width | Peer | Sampling condition |
|---|---|---|---|---|
| `push` | Input | WIDTH bits | Upstream | `push.fire` writes the tail. |
| `pop` | Output | WIDTH bits | Downstream | `pop.fire` consumes the pre-edge head. |
| `occupancy` | Output | ceil(log2(DEPTH+1)) bits | Parent module | Combinational count of occupied entries. |

The [top-level common protocol](../top/blackwell_async_subsystem_top.md#common-protocol) defines clock, reset, and channel sampling.

## Functionality

State comprises DEPTH×WIDTH payload bits, two `max(1,ceil(log2 DEPTH))` pointers, and an occupancy count. push.fire advances the write pointer and pop.fire the read pointer. Each wraps from DEPTH−1 to 0, including for non-power-of-two depths.

`pop_valid=count!=0` and `push_ready=count<DEPTH || pop_fire`. An empty FIFO has no push-to-pop bypass. When a full FIFO pops and pushes on one edge, deliver the old head before storing the new tail. `count_next=count+push_fire−pop_fire`. Reset clears pointers and count and leaves the payload untouched.

An item enqueued at t can dequeue at t+1 at the earliest, even from an initially empty FIFO. Continuous handshakes give II=1. The head holds while pop stalls. Occupancy stays within 0…DEPTH and entries retire in insertion order. Charge each large-payload instance its actual DEPTH×WIDTH storage.
