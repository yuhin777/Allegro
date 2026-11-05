# Tensor Core / TMEM 微架构简报

> **方案解析推导。**面向当前 Allegro SM100a 单 CTA、`cta_group::1` 的[合法 MMA 组合](../specs/common/interfaces.md#mma-合法组合)。容量、流水和性能均为拟议实现指标，不代表现行 RTL 已验证性能。以下连续发射结论以第 4 节高性能布局、必要快照就绪、无外部争用和背压为前提；启动与排空单独计时。

## 1. 支持类型与算术流水

每核以 64 个完整 dot 形成一个 8×8 输出微块，所有路径目标为 **II=1，即每拍发射一个微块**。Sparse 保存压缩 A，按原逻辑 K 的 metadata 索引选择 B，实际乘法项数与 dense 相同。

| kind / 输入 | dense / sparse 逻辑 K | D 类型 | Ldot |
|---|---:|---|---:|
| f16：FP16/BF16 合法交叉组合 | 16 / 32 | FP32；仅 FP16×FP16 可选 FP16 | 5 拍 |
| tf32 | 8 / 16 | FP32 | 5 拍 |
| f8f6f4：E4M3/E5M2/E3M2/E2M3/E2M1 | 32 / 64 | FP16/FP32 | 6 拍 |
| i8：S8/U8 四种组合 | 32 / 64 | S32 | 4 拍 |
| mxf8f6f4，UE8M0 1X | 32 / 64 | FP32 | 6 拍 |
| mxf4，UE8M0 2X | 64 / 128 | FP32 | 5 拍 |
| mxf4nvf4，UE8M0 2X/4X 或 UE4M3 4X | 64 / 128 | FP32 | 5 拍 |

F16/TF32 共用阵列，block-scale 类型复用对应低精度/FP4 阵列。FP16 输出增加两级 64 路最终编码，**Lfmt=2、II=1**；FP32/S32 旁路，Lfmt=0。低精度、整数完整阵列及 FP16 编码器均是新增实现要求，数值与时序仍需验收。

非 WS 基础四类支持 M64/M128、合法 N8…256（步长 8，i8 的 N>32 时步长 16）；block-scale 仅 M128、非 WS。WS 基础四类支持 M32/64/128，dense N64/128/256、sparse N64/128。转置、selector、scale、mask 和 collector 等命令约束沿用[产品命令检查](../../rtl/tensor_core/blackwell_tc_mma_engine.sv)；原 RTL 合同文档已清理。

## 2. 架构图与 buffer

[完整寄存器图 SVG](../images/tensor_core_tmem/tensor_core_tmem_pipeline.svg) · [PNG](../images/tensor_core_tmem/tensor_core_tmem_pipeline.png) · [绘图脚本](../images/tensor_core_tmem/draw_pipeline.py)。图展开全部非 dot 内部寄存器。以下容量按每核列示，共享部分明确折算。

| TC 数据 | 容量/核 | 装填、复用与释放 |
|---|---:|---|
| A 驻留 | 1 KiB | 最多 32 行×32 B 原始/压缩容器，计算前从 TMEM 或 SMEM 装入，跨全部 N 复用；源读取及副作用结束后释放。 |
| B 双槽 | 2×512 B | 每槽八列完整逻辑 K；dense 有效量≤256 B，sparse≤512 B。分片装填，最后一个消费者载入 R_OP 后释放。 |
| C 双槽 | 2×1 KiB | 每槽 32×8 cell，供四次计算；非 WS M64 为 16×8、512 B，供两次。另一槽预取，最后消费者载入 R_OP 后释放。 |
| D 双槽 | 2×1 KiB | 每槽收四个 8×8 结果，非 WS M64 收两个；另一槽写回。最后 payload 被 R_W 接受后释放，旧 block/generation 的 ACK 独立跟踪。 |
| B scale 随槽 | 2×32 B | 每槽八列×最多四个 scale byte，与 B 身份一致，随最后消费者释放。 |
| **基础 TC 数据＋B scale** | **6208 B＝6.0625 KiB** | A/B/C/D 共 6 KiB，B scale 另占 64 B。 |
| E / scale A / scale B 快照 | 256 / 128 / 折合 1024 B | scale B 为四份各 1 KiB 的物理分区，保留独立布局；组合读每核 32 B/cycle 至 B scale 槽。读视图不重复计容。 |

各槽按分片 valid/consumed 管理，支持同拍消费旧值与重填。FP16 C/D 每 cell 仅使用低 16 bit，C 精确提升、D 带 byte mask 写入。A/E/scale 必须在连续窗口前就绪，且在任何重叠 D/ashift 覆盖写之前完成必要快照。

| 独立类别 | 容量/核或折算 | 计量边界 |
|---|---:|---|
| R_OP 操作数准备级 | 1152 B 上界 | A256＋完整 B512＋C256＋E64＋scale A32＋scale B32；解包在前，逐 dot sparse 选择与广播在后。 |
| TMEM 主返回＋backup | 2×512 B＝1 KiB | 每 32-bank 分区一组，逐 bank 独立交付。 |
| TMEM R_W | 512 B | 一份写 payload，ACK 仅存身份。 |
| SMEM 主返回＋backup | 共享 2×512 B，折合 256 B | 共享总量 1 KiB。 |
| **外部接口暂存小计** | **1.75 KiB/核** | 仅含上述 TMEM/SMEM 返回及 R_W，不含 R_OP。 |
| 宏内读输出 | 折合 640 B | TMEM SRAM_Q 512 B/分区＋共享 B_SRAM_Q 512 B 的每核折算 128 B。 |
| 原生算术流水 | F16 参考 14976 B | 按真实级间 payload×64 统计；F16 valid 另 40 B，tag 另计。R_DOT 属于末级，不重复计入 D；其他类型按自身 4/5/6 级统计。 |
| FP16 最终编码流水 | ≤864 B | R_FMT0≤608 B＋R_FMT1≤256 B；直接从 76 bit 最终状态编码，避免二次舍入。 |

控制另计：R_CMD、R_SCHED/R_FILL、R_BREQ、每 bank 三项读 tag、各级 valid/交付 mask、槽身份、两项 R_ACK 及 R_DONE。

## 3. 存储通路与背压

| 通路 | 阵列/映射 | 带宽 |
|---|---|---|
| TMEM | 128 bank×128 word×128 bit＝256 KiB，1R1W；`bank=lane, word=column//4, cell=column%4` | 每 32-bank 分区读、写各 512 B/cycle；全局各 2048 B/cycle |
| SMEM | 32 bank×456 word×128 bit＝228 KiB，1R1W | 共享物理读峰值 512 B/cycle |
| B 装填端口 | 分片 gather/解包至 B 槽 | 每核目的容器最多 256 B/cycle |
| B 槽至 dot | 同一 B 按行块复用 | dense 256、sparse 512 B/cycle/核 |

SMEM 采用 `a=byte_addr//16; bank=(a%32) XOR (16×parity((a>>5)&15)); word=a//32`。相同物理源只读一次并广播，按目的核分别记录交付；源读取量与解包后的目的容器装填量分别计数。

| 读通路边界（上升沿） | 时刻 |
|---|---:|
| bank 获准；SMEM 的 R_BREQ 路由提前一拍 | g |
| 同步 SRAM 输出 SRAM_Q | g+1 |
| 主返回 R_RESP / backup | g+2 |
| 写入 TC buffer 可见 | g+3 |
| 最早载入 R_OP / 发射 dot | g+4 / g+5 |

**每 bank 三项返回 credit**覆盖全部已获准、尚未交付的读；物理承接位置为 SRAM_Q、主返回和 backup。发读前预留容量，目的暂停时停止新 grant，已发读必须接住。SRAM_Q 按 bank 支持 read-enable 保持，未搬走的数据不得被覆盖；若宏不支持保持，须外置该寄存器并重新计容。

读写按 bank 合并无冲突请求，给 MMA 保证所需服务，空闲 bank/时隙可服务其他客户端。每 bank 每拍最多 1R＋1W，同 word 实际读写冲突先执行已获准写。**R_W 接受 → 下一拍 SRAM 写入并产生 ACK → 再下一拍 ACK 退休**；接受写时预留两项 ACK 身份帧之一，满足 `ACK 已占＋R_W 在途≤2`。

**D 反压水线由输出目标 block/generation 的槽是否可写决定。**不可写时 R_DOT/R_FMT1 保持并沿弹性算术流水反压至 R_OP；已在途结果留在各级寄存器，输入不必提前占用未来 D 槽。广播仅重试未交付目的，所有游标按握手推进。R_DONE 等全部实际写 ACK 退休、读与算术排空及副作用完成后通知，槽释放不代表指令完成。

## 4. 四核分工与连续发射条件

| 调度 / PTX 布局 | 核 i 的行、列范围 | 每列块发射数 U / 唯一 B 流数 | 最大共享 SMEM 需求 dense / sparse |
|---|---|---:|---:|
| M128（含合法 WS）/ D | 行 32i…32i+31，全部 N | 4 / 1 | 64 / 128 B/cycle |
| 非 WS M64 / F | 行 16i…16i+15，全部 N；lane=32i+行内偏移+alignment，alignment=0或16 | 2 / 1 | 128 / 256 B/cycle |
| M64 WS / E | 行 32(i%2)…+31，列 (i//2)N/2…+(N/2−1) | 4 / 2 | 128 / 256 B/cycle |
| M32 WS / G | 全部 32 行，列 iN/4…+(N/4−1) | 4 / 4 | 256 / 512 B/cycle |

先生成全局逻辑坐标，再应用 PTX 布局；WS 的 D 使用局部列、B 使用全局列。每核连续发射 `Q=MN/256` 个 8×8 微块，四核覆盖全部 MN 个输出。每核 B 平均装填需求上界为 dense `256/U`、sparse `512/U` B/cycle；共享流量按唯一 B 数据计，广播不重复收费。

**高性能布局前提：**D 基列按 4 个 cell 对齐；B 基址 4 KiB 对齐，K-major、无 swizzle，LBO=128 B，dense SBO=256 B、sparse SBO=512 B。设物理 K 字节坐标为 z：

`addr=Bbase+(n//8)*SBO+(n%8)*16+(z//16)*128+z%16`

4/6 bit 字段遵循 16 元素分组 padding，native FP4 按 nibble 紧凑存储。A 的来源及合法转置在前置装填中处理；E/scale 采用各自 PTX 布局快照。

令列块 j 首次 dot 发射为 `S_j=F+Uj`，无停顿供数安排如下：

| 阶段 | 时刻 |
|---|---|
| B 的 bank 服务窗口 → 入槽 | `S_j−U−4…S_j−5` → `S_j−U−1…S_j−2` |
| C 两笔 bank 服务 → 入槽 | `S_j−6、S_j−5` → `S_j−3、S_j−2` |
| R_OP 载入 → dot 发射 | `S_j−1…S_j+U−2` → `S_j…S_j+U−1` |

在上述布局、逐 bank 保证服务、每核装填端口及时和 ACK 正常退休条件下，**全部支持类型均可连续发射 Q 拍，无硬件固有供数气泡**。前提是完整 dot 阵列和 FP16 编码器实现 II=1；metadata/scale 已驻留，不额外占用逐 dot 外部供数。不同类型的算术延迟影响排空时间，不改变发射间隔。

## 5. 执行周期

以 `T_snap` 表示 A/E/全部必要 scale 快照可读、开始 B 源请求的边沿；前置装填耗时按实际来源计算。采用第 4 节布局和调度时，保守首发射为 `F=T_snap+U+5`，连续窗口为 Q 拍。令最后发射 `l=F+Q−1`，总算术延迟 `L=Ldot+Lfmt`：

| 排空事件 | 时刻 |
|---|---:|
| 原生 dot 输出 / 最终格式输出 | l+Ldot / l+L |
| 最后一片进入 D | l+L+1 |
| 两笔 R_W 写接受 | l+L+2、l+L+3 |
| 最后 SRAM 写入并产生 ACK | l+L+4 |
| 最后 ACK 退休、满足完成条件 | l+L+5 |

因此基础指令的完成时刻为 **`T_done=F+Q+Ldot+Lfmt+4`**。下表均为 N128、单位拍、从 T_snap 起算的方案解析推导；dense/sparse 的差别计入前置快照时间，不改变表内连续窗口。

| 项目 / 输入 → 输出 | M128 | 非 WS M64 | M64 WS | M32 WS |
|---|---:|---:|---:|---:|
| 首发射 F−T_snap | 9 | 7 | 9 | 9 |
| 连续发射 Q | 64 | 32 | 32 | 16 |
| f16/BF16/tf32 → FP32 完成 | 82 | 48 | 50 | 34 |
| FP16×FP16 → FP16 完成 | 84 | 50 | 52 | 36 |
| f8f6f4 → FP32 完成 | 83 | 49 | 51 | 35 |
| f8f6f4 → FP16 完成 | 85 | 51 | 53 | 37 |
| i8 → S32 完成 | 81 | 47 | 49 | 33 |
| mxf8f6f4 → FP32 完成 | 83 | — | — | — |
| mxf4/mxf4nvf4 → FP32 完成 | 82 | — | — | — |

D 槽 j 首次收集在 `S_j+L+1`，最后 payload 接受在 `S_j+U+L+2`；同槽 j+2 首次收集在 `S_j+2U+L+1`，两代边沿间隔为 **U−1 拍：M128/WS 为 3 拍，非 WS M64 为 1 拍**。写回错过复用期限时按第 3 节保持并反压；固定 II=1 的算术/编码延迟不缩短该间隔。

命令建立、A/E/scale 前置装填、软件同步和结果读回不在表内。collector 命中可减少前置装填；`.ashift` 等副作用须额外计入服务及 ACK，基础公式不包含这些尾部工作。
