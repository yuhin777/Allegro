# Allegro

Allegro implements a single-CTA SM100a asynchronous subsystem in SystemVerilog. Four Tensor Cores share tensor memory (TMEM), shared memory (SMEM), the Tensor Memory Accelerator (TMA), and memory barriers. The surrounding system supplies warp scheduling, register-file access, global memory, and visibility services.

The subsystem accepts supported instructions through a ready/valid command interface. Its timing and completion guarantees assume legal operands, conforming handshakes, and successful external service responses. Simulation assertions check these assumptions.

## Design and RTL

| Start here | What it covers |
| --- | --- |
| [Supported PTX](doc/proposals/supported_ptx.md) | Instructions, operands, program-visible completion, and the three target kernels. |
| [Microarchitecture](doc/proposals/microarch_brief.md) | Command scheduling, [Tensor Core Buffer capacity and reuse](doc/proposals/microarch_brief.md#tc-buffer), and the [four-core data path](doc/images/tensor_core_tmem/tensor_core_tmem_pipeline.svg). |
| [Top-level specification](doc/rtl_specs/top/blackwell_async_subsystem_top.md) | Shared protocols, transaction identity, ordering, and the [index of module interfaces and timing](doc/rtl_specs/top/blackwell_async_subsystem_top.md#module-index). |
| [Subsystem RTL](rtl/top/blackwell_async_subsystem_top.sv) | Top-level ports and module connections. The [RTL file list](rtl/files.f) gives the compilation order. |
| [Cross-MMA pipeline](doc/proposals/mma_inter_instruction_pipeline.md) | Descriptors, address formulas, instruction order, and cycle-by-cycle scheduling for the two FA4 kernels. |

## Verification

Run from the repository root on the RTX 5080 verification host.

```sh
test/run.sh all        # Verilator lint, unit simulations, and workload replays
test/synth/check.sh    # Full-subsystem elaboration and selected synthesis checks
```

For a shorter run, select `lint`, `unit`, or `workloads` in place of `all`. The [verification guide](test/README.md) maps each module to its tests and describes the workload checks for arithmetic results, memory visibility, and handshake timing.
