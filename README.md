# Allegro

Allegro implements a single-CTA asynchronous subsystem for NVIDIA Blackwell SM100a in SystemVerilog. Four Tensor Cores share tensor memory (TMEM), shared memory (SMEM), the Tensor Memory Accelerator (TMA), and memory barriers. The surrounding system provides warp scheduling, register-file access, global memory, and visibility services.

| Repository content | Description |
| --- | --- |
| [Supported PTX](doc/proposals/supported_ptx.md) | Instructions, operands, completion semantics, and the three target kernels. |
| [Microarchitecture](doc/proposals/microarch_brief.md) | How commands move through the subsystem, which resources limit throughput, and how the four Tensor Cores share data. |
| [Subsystem RTL](rtl/top/blackwell_async_subsystem_top.sv) and [module specifications](doc/rtl_specs/top/blackwell_async_subsystem_top.md#module-index) | The hardware implementation and its contracts for handshakes, ordering, capacity, and timing. |
| [Cross-MMA design record](doc/proposals/mma_inter_instruction_pipeline.md) | Instruction sequences, descriptor addresses, and cycle-by-cycle schedules for two FA4 kernels. |
| [Verification](test/README.md) | Module testbenches and workload replays that check arithmetic results, memory visibility, and handshake timing. |
