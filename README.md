# Allegro

Allegro 面向 SM100a 的单 CTA 异步子系统，覆盖 Tensor Core、TMEM、共享 SMEM、TMA 和 mbarrier。外围提供 warp 调度、RF、GMEM 和可见性服务。

- 支持的指令、操作数、完成语义及三个目标 kernel 见 [PTX 支持范围](doc/proposals/supported_ptx.md)。
- [Microarch Brief](doc/proposals/microarch_brief.md) 定义后端组成、[Tensor Core Buffer](doc/proposals/microarch_brief.md#tc-buffer) 的容量和复用条件，以及各类异步指令的调度规则。[四核数据通路图](doc/images/tensor_core_tmem/tensor_core_tmem_pipeline.svg)
- 35 份 [RTL 模块规格](doc/rtl_specs/top/blackwell_async_subsystem_top.md#module-index) 分别定义接口、状态、时序与验收边界。跨模块的 [握手与复位](doc/rtl_specs/top/blackwell_async_subsystem_top.md#common-protocol)、[身份](doc/rtl_specs/top/blackwell_async_subsystem_top.md#identity) 和 [ordering](doc/rtl_specs/top/blackwell_async_subsystem_top.md#ordering) 由顶层定义。
- [跨 MMA 流水设计记录](doc/proposals/mma_inter_instruction_pipeline.md) 保存两个 FA4 kernel 的实际 descriptor、指令顺序、地址公式和逐拍推导。

Brief 的组织参照 [NVDLA v1 Convolution Pipeline](https://nvdla.org/hw/v1/ias/unit_description.html#convolution-pipeline)，模块规格的章节参照 [CVA6 v5.3.0 ISSUE_STAGE](https://github.com/openhwgroup/cva6/blob/v5.3.0/docs/design/design-manual/source/cva6_issue_stage.adoc)。

现有实现从 [RTL 顶层](rtl/top/blackwell_async_subsystem_top.sv) 进入。当前规格以三个目标 kernel 的结果、同步顺序和指定服务条件下的关键边沿为验收基线，整 kernel 总周期作为观测值。该基线的 RTL lint、仿真及 kernel 重放待执行。
