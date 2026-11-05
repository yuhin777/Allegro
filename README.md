# Allegro

Allegro aims to reproduce a **single-CTA Blackwell Tensor Core asynchronous subsystem** in SystemVerilog. The project targets the SM100a execution model with `cta_group::1`, bringing together matrix computation, tensor memory, asynchronous data movement, and completion synchronization.

The goal is to build an executable RTL subsystem around the PTX-visible behavior of these operations, with an explicitly designed microarchitecture for operand delivery, computation, writeback, and completion.

## Scope

| Component | Role |
| --- | --- |
| **Tensor Core** | Execute dense and sparse MMA operations using dot-product arrays, operand buffers, and hardware scheduling. |
| **Tensor Memory (TMEM)** | Provide 256 KiB of storage for matrix operands and results, with allocation, ownership, and access control. |
| **Tensor Memory Accelerator (TMA)** | Handle asynchronous tensor data movement, address generation, and tensor-map processing. |
| **mbarrier** | Track arrivals and transaction completion to synchronize asynchronous work. |
| **Completion and data interfaces** | Connect MMA commit/wait, TMEM transfers, and register-file handshakes into a complete execution flow. |

The initial scope is one cooperative thread array (CTA). Warp scheduling, the register file, and the global-memory system connect through external interfaces. Multi-CTA and `cta_group::2` execution are outside this scope.

## Microarchitecture

The latest [Tensor Core/TMEM brief](doc/proposals/tensor_core_tmem_mma_brief.md) proposes four Tensor Cores, each producing an 8×8 output microtile with 64 complete dot products. Resident A data, double-buffered B/C/D storage, and bank-aware memory service support continuous issue under the stated layout and bandwidth conditions.

The design covers operand preparation, sparse metadata and scale delivery, SRAM response buffering, backpressure, and write acknowledgements. Instruction completion waits for all required writes and side effects to finish.

See the [pipeline diagram](doc/images/tensor_core_tmem/tensor_core_tmem_pipeline.svg) for the register boundaries and data paths. Capacities and cycle counts in the proposal are analytical design targets.

## Repository Layout

| Path | Contents |
| --- | --- |
| [rtl/](rtl/) | SystemVerilog arithmetic units, execution engines, memory/control modules, and subsystem tops. |
| [doc/specs/](doc/specs/) | Version v1.0 module specifications, shared interfaces, and the specification manifest. |
| [doc/proposals/](doc/proposals/) | Microarchitecture proposals and research designs. |
| [doc/dot/](doc/dot/) | Detailed designs for FP16/TF32, F4/F6/F8, FP4, and INT8 dot products. |
| [doc/images/](doc/images/) | Architecture diagrams, drawing scripts, and supporting figures. |
| [test/](test/) | Reserved for future tests. |

The main RTL integration point is [`blackwell_async_subsystem_top.sv`](rtl/top/blackwell_async_subsystem_top.sv).

## Development Status

Allegro is under development. Existing RTL, the v1.0 specifications, and newer proposals represent distinct stages of the design; the RTL does not yet implement the complete proposed microarchitecture. FP16 result encoding remains an outstanding numerical implementation dependency.

The repository currently contains RTL and design documentation. Build infrastructure and verification will be established in subsequent work; there are no runnable repository build, test, or cycle-model targets at present.

RTL lint and simulation should run on the configured remote host in an isolated workspace. Local work is limited to editing and static checks.
