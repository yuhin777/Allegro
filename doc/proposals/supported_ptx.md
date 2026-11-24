# Allegro 首版 PTX 支持范围

首版以 PTX 8.7、SM100a、单 CTA 和 `cta_group::1` 为语义基线。一个后端服务一个活跃 CTA，一次 launch 可以包含多个 CTA。外围保证发起粒度、warp 收敛、线程身份及同步依赖。资源预算与性能目标见 [Microarch Brief](microarch_brief.md)。

## 1. 目标用例

| 标识 | kernel / case | 覆盖目标 |
|---|---|---|
| L | `linear_bulk_two_phase_kernel` | 两轮线性 G2S；每轮四笔 4096 B，复用同一 mbarrier |
| F1 | `H32D64FullB2S128` | FP16 FA4，QK 为 SMEM A/B、N128；PV 为 TMEM A、SMEM B、N64 |
| F2 | `H16D128CausalB32S1024` | FP16 causal FA4，QK 为 SMEM A/B、N128；PV 为 TMEM A、SMEM B、N128 |

固定 FlashGPU-Sim `7a48f7685d604d71da3692fb1b24825fdb7cc79c`、flash-attention `d80a77103021c4e980f8cbbf85774f6a19e6474a`、CuTe DSL 4.5.2。范围仅为这三个用例及下表明确增加的精度与 WS，不扩展为 FlashGPU-Sim 全部 SM100 测试。[线性 kernel](https://github.com/FlashGPU-Sim/FlashGPU-Sim/blob/7a48f7685d604d71da3692fb1b24825fdb7cc79c/tests/src/tma/tma_test.cu#L380-L446) · [mbarrier helper](https://github.com/FlashGPU-Sim/FlashGPU-Sim/blob/7a48f7685d604d71da3692fb1b24825fdb7cc79c/tests/src/include/ptx/mbarrier.cuh) · [FA4 用例](https://github.com/FlashGPU-Sim/FlashGPU-Sim/blob/7a48f7685d604d71da3692fb1b24825fdb7cc79c/tests/dsl/cutedsl/validation/fa4_forward.py) · [QK/PV 定义](https://github.com/Dao-AILab/flash-attention/blob/d80a77103021c4e980f8cbbf85774f6a19e6474a/flash_attn/cute/flash_fwd_sm100.py#L474-L498)

<a id="dense-mma"></a>
## 2. Dense MMA

M=128，N∈{64,128,256}，K 由 kind 决定。普通形式为 `tcgen05.mma.cta_group::1.kind::*`，scaled kind 带 `.block_scale` 及其合法 scale-vector 修饰符；WS 为 `tcgen05.mma.ws.cta_group::1.kind::*`。下表共 33 个 kind／模式／形状组合，dtype 交叉和 scale 组合另行覆盖。

| kind | A/B 格式 | K | D | 普通 | WS |
|---|---|---:|---|---|---|
| f16 | FP16、BF16 两种输入独立选择 | 16 | FP32 | 是 | 是 |
| tf32 | TF32 × TF32 | 8 | FP32 | 是 | 是 |
| f8f6f4 | E4M3、E5M2、E3M2、E2M3、E2M1，各侧独立选择 | 32 | FP32 | 是 | 是 |
| i8 | S8、U8，各侧独立选择 | 32 | S32 | 是 | 是 |
| mxf8f6f4 | 上述五种低精度；UE8M0 1X | 32 | FP32 | 是 | 否 |
| mxf4 | E2M1 × E2M1；UE8M0 2X | 64 | FP32 | 是 | 否 |
| mxf4nvf4 | E2M1 × E2M1；UE8M0 2X 或 UE4M3 4X | 64 | FP32 | 是 | 否 |

MMA 由单线程发起。A 来自 SMEM descriptor 或 TMEM 地址，B 来自 SMEM descriptor；布局按[矩阵描述符](../rtl_specs/tensor_core/blackwell_tc_mma_engine.md#matrix-descriptor)、[TMEM 布局](../rtl_specs/tmem/blackwell_tmem_fabric.md#tmem-layout)和[scale 布局](../rtl_specs/tensor_core/blackwell_tc_scale_b_snapshot.md#scale-layout)解释。F1/F2 需要 K-major QK、MN-major V 及相应 swizzle，不能用仅限连续布局代替。数值按[各算术模块的数值规则](../rtl_specs/tensor_core/blackwell_tc_dot_array.md#numeric-routing)执行。

- `enable-input-d` 选择旧 D 或零作为 C；同 issuer、同累加器的连续 MMA 必须读到前一结果。全部实际 D 写 ACK 与资源归还后才完成，commit 不得提前 arrival。
- 浮点 negate 按 kind 支持。i8 独立选择 A/B signedness，仅 i8 可启用最终饱和，其 negate 位均为零。普通 f16/tf32 允许 `scale-input-d`；其他形式取零。两个 native FP4 kind 不允许 transpose。
- 普通基础四类允许 disable-output-lane；WS 和 block-scale 要求无禁写 lane。scale 的 type、vector size、地址和 ID 必须满足对应布局的合法组合，不增加 UE8M0 4X 项目扩展。
- 普通与 WS 的源数据在 PTX 规定的生命周期内保持有效，包括 collector 命中的情形。

[PTX 形状表](https://docs.nvidia.com/cuda/archive/12.8.2/parallel-thread-execution/index.html#tcgen05-kind-shapes) · [block-scale 组合](https://docs.nvidia.com/cuda/archive/12.8.2/parallel-thread-execution/index.html#valid-combinations-of-scale-vec-size-with-types-and-mma-kind)

## 3. Collector

普通 MMA 支持 `a::{fill,use,lastuse,discard}`，默认 a::discard；WS 支持 `b0…b3::{fill,use,lastuse,discard}`，默认 b0::discard。名称范围为当前 CTA/epoch，软件协调跨线程的同名使用，TC commit 仍按完整 issuer 隔离。

fill 从源装填。合法 use 在完整驻留身份匹配时复用，物理 miss 可从源重读。lastuse 使用后可丢弃，discard 可直接从源装填。普通 A 的跨指令命中由实现决定。软件负责有效 fill 等序列前提，物理 miss 本身不触发硬件错误。[PTX collector 规则](https://docs.nvidia.com/cuda/archive/12.8.2/parallel-thread-execution/index.html#tensorcore-5th-generation-matrix-multiply-and-accumulate-operations) · [WS 指令](https://docs.nvidia.com/cuda/archive/12.8.2/parallel-thread-execution/index.html#tensorcore-5th-generation-instructions-tcgen05-mma-ws)

WS 的名字可映射到不同大小的驻留区。跨指令复用要求四核整份安装成功。分区分配、LRU 和重装时序见 [MMA engine](../rtl_specs/tensor_core/blackwell_tc_mma_engine.md#b-residency)。

## 4. 异步数据与同步指令

下表只开放所列形式。L/F1/F2 表示使用它们的目标用例。省略的默认 scope 按 PTX 正规化；`shared::cluster` 只接受可证明指向本 CTA 的地址，远端或 multicast 不在范围内。

| 指令或指令族 | 合法操作数、粒度与完成边界 | 用例 / 负责模块 |
|---|---|---|
| `tcgen05.alloc.cta_group::1.sync.aligned.shared::cta.b32`；`tcgen05.dealloc.cta_group::1.sync.aligned.b32`；`tcgen05.relinquish_alloc_permit.cta_group::1.sync.aligned` | 收敛且操作数一致的 warp。F1/F2 独占 512 列，base=0。ALLOC 结果实际写入 SMEM [dst]，已占用时在入口等待；使用结束后才释放。仍有引用时 DEALLOC 返回 INVALID。较小列数属于范围外。[TMEM 管理命令](../rtl_specs/tmem/blackwell_tmem_manager.md#management-types) | F1/F2 / manager、外围 SMEM 写入 |
| `tcgen05.ld.sync.aligned.32x32b.x16.b32`；`tcgen05.ld.sync.aligned.32x32b.x32.b32`；`tcgen05.st.sync.aligned.32x32b.x16.b32`；`tcgen05.wait::st.sync.aligned` | 收敛 warp；普通 b32，无 pack。LD 等最后 RF 写回，ST 等最后实际写 ACK；wait::st 等该 warp 的旧 ST 集合 | F1/F2 / LDST、RF tracker |
| `tcgen05.commit.cta_group::1.mbarrier::arrive::one.b64`，含本地 `shared::cluster` 形式 | 单线程捕获当前 CTA/epoch、同 issuer 的旧前驱；同拍新接受操作不进入集合。成功完成后只提交一次 arrival，错误不得成功唤醒 | F1/F2 / TC tracker、completion bridge |
| `cp.async.bulk.shared::cta.global.mbarrier::complete_tx::bytes` | 单线程，首址 16 B 对齐、长度为 16 B 倍数；实际目标 SMEM 写 ACK 全部结清后 complete-tx 一次 | L / TMA、mbarrier |
| `cp.async.bulk.tensor.4d.shared::cluster.global.tile.mbarrier::complete_tx::bytes.L2::cache_hint`；`cp.async.bulk.tensor.4d.global.shared::cta.tile.bulk_group.L2::cache_hint` | 单线程，rank-4 FP16 项目[Tensor Map](../rtl_specs/tma/blackwell_tma_setup.md#tensor-map)，4 个 s32 坐标。Q/K/V 读入、O 写回；load 等目标写入与 complete-tx，store 保留源读取及目标写 ACK 两个完成边界 | F1/F2 / TMA |
| `cp.async.bulk.commit_group`；`cp.async.bulk.wait_group.read` | 单线程、同 issuer 截止组；wait 只支持立即数 0/1。`.read` 等源读责任，目标写 ACK 仍须单独退休 | F1/F2 / TMA unit |
| `mbarrier.init.shared::cta.b64`；`mbarrier.inval.shared::cta.b64` | 单线程、本地 8 B 对齐对象；init 原子初始化，inval 等引用退出和 backing 确认；包括默认 `.shared` 拼写 | L/F1/F2 / barrier frontend、unit、backing |
| `mbarrier.arrive.expect_tx.shared::cta.b64` 及 `.arrive.expect_tx.release.cta.shared::cta.b64`；`mbarrier.arrive.release.cta.shared::cta.b64` | 单线程；expect_tx 在同一提交点登记 bytes 并 arrive。L 每 phase 登记 16384 B；release 须满足真实 ordering | L/F1/F2 / barrier frontend、unit |
| `mbarrier.try_wait.parity.shared::cta.b64`，含默认 `.shared` 与默认 acquire 语义 | 单线程、目标 parity；允许 time hint，但不得绕过 phase 和 acquire 可见性条件 | L/F1/F2 / barrier wait、ordering |
| `fence.proxy.async.shared::cta`；`fence.mbarrier_init.release.cluster` | 单线程；分别发布此前相关 generic shared 写和 barrier 初始化。cluster 限本 CTA，真实 ordering 确认后完成 | L/F1/F2 / TMA 或 barrier frontend、外围 ordering |
| `prefetch.tensormap` | 描述符预取提示；不产生 tile 数据效果或替代 copy 完成 | F1/F2 / descriptor cache |

外围负责地址算术、分支、softmax、RF、普通 LSU、`bar.sync`／`bar.arrive`／`bar.warp.sync`、`elect.sync` 和 `setmaxnreg`。必须提供真实 RF 接受、存储 ACK、可见性确认和线程到达事件，不能在夹具中提前完成。Tensor Map 使用公开的项目编码，外围负责从宿主描述符正规化，不承诺 NVIDIA opaque 二进制兼容。

## 5. 范围外与验收

不支持 sparse、M32/M64 或其他 M、FP16 MMA 结果、跨 CTA、`.ashift`、独立 SHIFT、`tcgen05.cp`、有效 zero-column mask、非零 column shift、UE8M0 4X。未列出的 TMEM shape/repeat、pack/unpack、`tcgen05.wait::ld`、`tcgen05.fence`、TMA 维数/类型、linear store、map replace、reduction、multicast、普通 cp.async 到 barrier 的登记均不自动开放。

外围在异步登记前拒绝可识别的范围外 PTX（UNSUPPORTED）、非法编码（INVALID）和地址越界（RANGE）。活动事务发生存储、ordering 或协议错误时，本次运行以 sticky fault 终止。[顶层恢复合同](../rtl_specs/top/blackwell_async_subsystem_top.md#common-protocol)

L/F1/F2 验收数据和程序可见的完成顺序；在各规格给定的对齐、输入就绪和端口服务条件下验收关键边沿。整 kernel 总周期作为运行观测值。

- L 检查两轮各四笔 4 KiB 搬运、校验和、phase 复用及最后写 ACK 到唤醒的顺序。
- F1/F2 覆盖 QK→TMEM/RF 中间值→PV→O 写回；保留 Q=K=0、V=1、O=1 连通性用例，并增加按坐标变化的非均匀输入，分别核对地址、数值和完成顺序。在记录给定的供数和 ACK 条件下，同一乘法内相邻 K16 的稳态首 dot 间隔为 QK 64 拍、PV 32 拍（F1）或 64 拍（F2）。F2 同一 stage 的两笔 16 KiB copy 分别提交，32,768 B 全部结清且 acquire 成功后才可消费。[FA4 地址与时序](mma_inter_instruction_pipeline.md)
- 33 个 MMA 组合及合法 dtype、scale、control 与独立数值参考逐项核对。WS 覆盖四个名字、全部 collector 操作、命中与淘汰后重装。
