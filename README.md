# Allegro

Allegro models a single-CTA asynchronous subsystem for SM100a. It includes the Tensor Core, TMEM, shared SMEM, TMA, and mbarrier. The surrounding system provides warp scheduling, RF, GMEM, and visibility services.

- See [Supported PTX](doc/proposals/supported_ptx.md) for instructions, operands, completion semantics, and the three target kernels.
- The [Microarch Brief](doc/proposals/microarch_brief.md) describes the backend, the capacity and reuse rules of the [Tensor Core Buffer](doc/proposals/microarch_brief.md#tc-buffer), and scheduling for each asynchronous instruction class. [Four-core data path](doc/images/tensor_core_tmem/tensor_core_tmem_pipeline.svg)
- The 35 [RTL module specifications](doc/rtl_specs/top/blackwell_async_subsystem_top.md#module-index) define interfaces, state, timing, and acceptance criteria. The top level defines cross-module [handshakes and reset](doc/rtl_specs/top/blackwell_async_subsystem_top.md#common-protocol), [identity](doc/rtl_specs/top/blackwell_async_subsystem_top.md#identity), and [ordering](doc/rtl_specs/top/blackwell_async_subsystem_top.md#ordering).
- The [Cross-MMA pipeline design record](doc/proposals/mma_inter_instruction_pipeline.md) preserves the actual descriptors, instruction sequences, address formulas, and cycle-by-cycle derivations for both FA4 kernels.

The brief follows the organization of the [NVDLA v1 Convolution Pipeline](https://nvdla.org/hw/v1/ias/unit_description.html#convolution-pipeline). Module specifications follow the section structure of [CVA6 v5.3.0 ISSUE_STAGE](https://github.com/openhwgroup/cva6/blob/v5.3.0/docs/design/design-manual/source/cva6_issue_stage.adoc).

The implementation starts at the [RTL top level](rtl/top/blackwell_async_subsystem_top.sv). Acceptance covers the results and synchronization order of the three target kernels and the specified handshake edges under the stated service conditions. Total kernel cycles are recorded for observation. RTL lint, simulation, and kernel replay for this baseline are pending.
