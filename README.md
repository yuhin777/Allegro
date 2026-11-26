# Allegro

Allegro models a single-CTA asynchronous subsystem for SM100a. It includes the Tensor Core, TMEM, shared SMEM, TMA, and mbarrier. The surrounding system provides warp scheduling, RF, GMEM, and visibility services.

- See [Supported PTX](doc/proposals/supported_ptx.md) for instructions, operands, completion semantics, and the three target kernels.
- The [Microarch Brief](doc/proposals/microarch_brief.md) describes the backend, the capacity and reuse rules of the [Tensor Core Buffer](doc/proposals/microarch_brief.md#tc-buffer), and scheduling for each asynchronous instruction class. [Four-core data path](doc/images/tensor_core_tmem/tensor_core_tmem_pipeline.svg)
- The 35 [RTL module specifications](doc/rtl_specs/top/blackwell_async_subsystem_top.md#module-index) define interfaces, state, timing, and acceptance criteria. The top level defines cross-module [handshakes and reset](doc/rtl_specs/top/blackwell_async_subsystem_top.md#common-protocol), [identity](doc/rtl_specs/top/blackwell_async_subsystem_top.md#identity), and [ordering](doc/rtl_specs/top/blackwell_async_subsystem_top.md#ordering).
- The [Cross-MMA pipeline design record](doc/proposals/mma_inter_instruction_pipeline.md) preserves the actual descriptors, instruction sequences, address formulas, and cycle-by-cycle derivations for both FA4 kernels.

The implementation starts at the [RTL top level](rtl/top/blackwell_async_subsystem_top.sv). Acceptance covers the results and synchronization order of the three target kernels and the specified handshake edges under the stated service conditions. Total kernel cycles are recorded for observation.

## Building and verifying the RTL

[rtl/files.f](rtl/files.f) lists the SystemVerilog packages and implementation sources in compilation order. Compile from the repository root with `blackwell_async_subsystem_top` as the top module. The external interface accepts normalized commands and uses independent ready/valid channels for GMEM, ordering, RF and the eight LSU atom ports.

Run the regressions on the RTX 5080 verification host. [test/run.sh](test/run.sh) accepts `lint`, `unit`, `workloads`, or `all`. The unit suite uses Verilator and a C++ compiler. The workload suite also uses Python, NumPy and cocotb. It drives the same top-level ports for linear bulk copies, independent issuer commits under a delayed or failing write acknowledgment, eight consecutive FP16 accumulations, a native FP4 MMA with independent TMEM scale operands, and the FA4 kernels. The FA4 timing fixture measures every core with operands published before the measured window. FA4 defaults to all distinct CTA row schedules at the last batch and head of each case, with uniform and coordinate-dependent inputs. Use `FA4_BATCH=all FA4_HEAD=all` for every grid coordinate. The [synthesis check](test/synth/check.sh) elaborates the complete top with Slang and synthesizes the base SRAM, FIFO, integer dot and TC completion logic with Yosys in the ORFS image.

[test/dot/run.sh](test/dot/run.sh) runs the v1 shared-array checks and an experimental independent-array comparison. The v1 acceptance criteria apply to the shared array. See the [verification notes](test/README.md) for numerical references, directed checks and FA4 measurement conditions.

## SystemVerilog formatting

Follow the [lowRISC Verilog Coding Style Guide](https://github.com/lowRISC/style-guides/blob/master/VerilogCodingStyle.md). Use two spaces per indentation level and four for wrapped expressions. Aim for 100 columns. Give each module port its own direction, type and line. Keep the valid, ready and payload signals of each channel together. Put one named instance connection or procedural statement on each line.

Use [Verible](https://github.com/chipsalliance/verible/releases/tag/v0.0-4302-gc6b29d62) version `v0.0-4302-gc6b29d62` with `verible-verilog-format` on the path. Run `tools/format-sv format` to format RTL and SystemVerilog testbenches, and `tools/format-sv check` to check them without writing files. The formatter preserves manual wrapping of long predicates. Break them at logical operators so reviewers can read each condition on its own.
