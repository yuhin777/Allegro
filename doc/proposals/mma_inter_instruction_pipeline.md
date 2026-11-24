# 跨 MMA 流水设计记录

这里记录两个 FA4 kernel 如何使用 Allegro 的操作数缓冲和共享端口。descriptor 与指令顺序取自离线 PTX，时序表按各段列出的布局、许可和背压条件推导。资源配置和发射规则见 [Microarch Brief](microarch_brief.md)，通用的跨模块验收见[连续 MMA 周期基准](../rtl_specs/top/blackwell_async_subsystem_top.md#cycles)。

<a id="fa4-layout-audit"></a>
## 两个 FA4 kernel 的实际 QK / PV 排程

下表以同一输出 tile 内相邻 K16 指令的首次 `dot_fire` 计间隔。QK 从预热后的首 dot 起算。PV 采用每四拍给 V 两个时隙的排程，假定 pin、P/O 软件许可、TMEM 操作数及时就绪，四核全接收、ACK 按最早沿返回。周期为项目接口的可行轨迹。

| 用例和乘法 | 每个输出 tile 的 K16 步数 | 每条 SMEM A / B 读请求（16 B atom） | 每条每核 dot 拍 | 相邻 K 步首发间隔 |
|---|---:|---:|---:|---:|
| H32D64FullB2S128，QK，N128 | 4 | 256 / 256 | 64 | 64 |
| H16D128CausalB32S1024，QK，N128 | 8 | 256 / 256 | 64 | 64 |
| H32D64FullB2S128，PV，N64 | 8 | 0 / 128 | 32 | 32 |
| H16D128CausalB32S1024，PV，N128 | 8 | 0 / 256 | 64 | 64 |

### 实际指令与地址

核对了两个用例的离线 PTX 及对应调用形状。导出件标记为 PTX 8.8、`sm_100a`，下列指令使用项目 PTX 8.7 合同内的普通 `tcgen05.mma.cta_group::1.kind::f16`。QK 的 instruction descriptor 都是 `0x08200010`，PV 分别为 `0x08110010` 和 `0x08210010`。Q/K/V 的 SMEM descriptor 高字均为 `0x40004040`，对应 128 B swizzle、SBO 1,024 B。两个用例均逐指令重读 B。[固定用例](https://github.com/FlashGPU-Sim/FlashGPU-Sim/blob/7a48f7685d604d71da3692fb1b24825fdb7cc79c/tests/dsl/cutedsl/validation/configs/fa4_cases.csv) · [上游 QK/PV 定义](https://github.com/Dao-AILab/flash-attention/blob/d80a77103021c4e980f8cbbf85774f6a19e6474a/flash_attn/cute/flash_fwd_sm100.py#L1573-L1640) · [项目描述符解码](../rtl_specs/tensor_core/blackwell_tc_mma_engine.md#matrix-descriptor)

离线 PTX 中 QK descriptor 低字的 K16 偏移以 16 B 为单位。D64 依次加 `0/2/4/6`，D128 接着用 `0x400/0x402/0x404/0x406`。PV 每步的 V descriptor 低字增加 `0x80`，P 的 TMEM 操作数则增加 8 个 32-bit column。

令 `s` 为 K16 步，`k=0…15`，`a` 为对应 SMEM stage 的字节基址。以下均为 FP16 元素首字节，地址先换位再取组。QK 第 4→5 个 K16 步跨 16 KiB panel，PV 的每一步沿 V 的序列维前进 2,048 B。

```text
sw(x)        = x XOR (((x >> 7) & 7) << 4)
Q/K(row,s,k) = sw(a + 16384*(s//4) + 128*row + 32*(s%4) + 2*k)
V(n,s,k)     = sw(a + 16384*(n//64) + 128*(16*s+k) + 2*(n%64))
group(addr)  = (addr >> 4) & 7
```

QK 的 `row` 分别是 Q 的输出行和 K 的输出列。PV 的第二个 64 列 panel 只在 N128 被访问。TMEM 用 32-bit column 编号：D64 用例的 S/P/O 基址依次为 0/64/256；D128 用例的两个 Q stage 分别为 0/64/256 与 128/192/384。PV 的 `P_base+8*s` 每行读两个 16 B word，与本条 O 地址分离。QK 每个新 S 的第一步注零，余步读旧 S。PV 每个 O 的首个 KV tile 首步注零，后续 KV tile 首步读取已校正的 O，其余七步均同址累加。[上游 TMEM 分区](https://github.com/Dao-AILab/flash-attention/blob/d80a77103021c4e980f8cbbf85774f6a19e6474a/flash_attn/cute/flash_fwd_sm100.py#L285-L298) · [O 累加谓词](https://github.com/Dao-AILab/flash-attention/blob/d80a77103021c4e980f8cbbf85774f6a19e6474a/flash_attn/cute/flash_fwd_sm100.py#L1719-L1784)

### TMA 输入布局与地址核对

公开样例的 Q/K 逻辑 dims=[64,128,2,1]，stride[1:4]=[256,128,32768] B，box=[64,128,1,1]。从相同 base 计算 (0,0,1,0) 得 +128，(0,1,0,0) 得 +256，(63,127,1,0) 得 +32766，最后一个 FP16 的高字节位于 +32767。将 stride[2] 错当作 stride[1]×128 会错读另一个 head。以两种 head 填不同数据，先比较编码/解码，再比较两条 tensor load 访问集合；头切换时清 cache 不是修正地址的手段。[实捕 Q/K 样例](https://github.com/FlashGPU-Sim/FlashGPU-Sim/blob/7a48f7685d604d71da3692fb1b24825fdb7cc79c/tests/src/unit/fa4_opaque_tensormap_test.cc#L107-L125)

地址回归采用 FP16 B/S/H/D host tensor 的连续输入布局，按逻辑 D/S/H/B 重排并将元素stride乘二。固定夹具为：F1 的 dims=[64,128,32,2]、byte stride[1…3]=[4096,128,524288]；F2 的 dims=[128,1024,16,32]、byte stride[1…3]=[4096,256,4194304]。这是按 host 输入推导的地址参考，不宣称已捕获这两个运行时 opaque 描述符。分别核对同一序列位置切换 head、同 head 推进序列、切换 batch 的地址差。

rows=128 时，D128 的 QK 子块字节偏移为 `0/32/64/96/16384/16416/16448/16480`，PV 的 MN-major descriptor 对应 LBO=16384、SBO=1024。D64 的 QK 子块偏移为 0/32/64/96 B，PV 只访问一个 panel。[上游 FA4 descriptor 样例](https://github.com/FlashGPU-Sim/FlashGPU-Sim/blob/7a48f7685d604d71da3692fb1b24825fdb7cc79c/tests/src/unit/fa4_opaque_tensormap_test.cc#L29-L51)

宽 head 附加用例取 smem_base=0、rows=128：row0/b=128 得 16384，row1/b=0 得 144，row127/b=255 得 32655（换位前为32767）；两个 panel 不与下一行别名。这是项目公开布局的验收，不据此推定原始 CUDA descriptor 的字节 ABI。[Flash 宽 head 测例](https://github.com/FlashGPU-Sim/FlashGPU-Sim/blob/7a48f7685d604d71da3692fb1b24825fdb7cc79c/tests/src/unit/fa4_opaque_tensormap_test.cc#L156-L165) · [CUDA tiled map API](https://docs.nvidia.com/cuda/archive/12.8.1/cuda-driver-api/group__CUDA__TENSOR__MEMORY.html)

### QK 的四拍重复窗口

对任意八行及同一 half，上式给出的八个组是 0…7 的排列。每拍八组各 grant 一笔，全部 32 个物理 bank 各读一次。每四拍两拍给 A、两拍给 B，64 拍刚好覆盖一条 MMA 的 512 笔请求。令 F 为某 K 步首 dot，S=F+4j 为其八列块 j 首 dot。核 c 的 A 行组 r 两半在 `F−64+16r+4c+h` grant，h=0/1，两拍后返回。最晚的 r=3 在 F−1 收齐，首用在 F+2。B[j] 在 S−10/−9 grant，S−8/−7 返回，S−6 分发，S−1 装 R_OP。八个 B 返回各写不同的 piece，两槽交替即可。[SMEM 仲裁](../rtl_specs/smem/blackwell_smem_fabric.md) · [操作数和写回](../rtl_specs/tensor_core/blackwell_tc_mma_core.md)

前步首 dot 为 0 时，旧 D[0] 在 12 收齐成功 ACK，新 C[0] 在 58/59 读、61/62 返回。C[1] 在 62/63 读、65/66 返回。63 发旧末 dot 并装新首 R_OP，64 发新首 dot，此时旧末 ACK 尚要等到 72。把实际的 K 子步地址代入上述排程，D64 得到首发 0、64、128、192；D128 两个 Q stage 各得 0、64、…、448。以非均匀整数 FP16 输入逐块写回，各 stage 的 65,536 B FP32 输出与按坐标独立累加一致。上述 64 拍内八组均已满载，有外围读插入时须按实际获准沿重算。

### PV 的 V 装填与同址 C

每个 V 八列块的 16 个源 atom 各读一次。固定 h，行内 K 编号 u=0…7 的组号为 `u XOR (j mod 8)`；QK 对应为 `c XOR (2*(s mod 4)+h)`，此处 c 是八列块内的列号 0…7。这两个简式取自本例对齐的 stage 基址，一般地址由上面的 group(sw(x)) 计算。两者在一批八笔中各占八组。PV 一个返回携带同一 K 的八个 FP16，写同一逻辑行的四个 32-bit 段。出槽的两个 8×8 半字方阵转置后，core 看到按列排列的原值。[loader 装配公式与逐拍表](../rtl_specs/tensor_core/blackwell_tc_b_loader.md#service)

以首笔 V grant 为 0，前提同表。V 块 0/1/2 分别在 4/8/12 完成四核交付，下一沿可装 R_OP，再下一沿可发 dot。块 b 的四个行组在 `6+4b…9+4b` 发射（b 为跨 K 步的连续块号）。D64 的步 0 末块在 34…37 发、步 1 首块在 38…41 发；D128 对应为 66…69 和 70…73。若 A 类 SMEM 请求缺席，fabric 可提前服务 V；模型按实际交付与四拍消费分别计时。

同址累加时，步 0 的 D[0] 在 18 收到末 ACK。D64 步 1 的 C[0] 在 32/33 grant、35/36 返回，赶上 37 的首 R_OP；D128 在 64/65 grant、67/68 返回，赶上 69。C[1] 相应推迟四拍。P 的两帧读使用 C 预取空出的 TMEM 读沿，D 使用独立写端口。逐沿比较每个 lane 的读写 word，检验旧 D 成功 ACK 先于对应 C 读。非均匀 P/V 的八步结果按输出 (m,n) 独立累加，包含首步注零和读取已校正 O 两种情形。

临时模型按上述真实布局检查了 384 个八列块。固定 B 时隙时，按现行 SMEM 返回合同推得四核交付沿为 4、8、12、…；允许借用空闲时隙时，各块也均在对应截止沿前或当沿交付。分别暂停一个返回组、一个 core 以及同时暂停两者，核对了列序原始位和每目的恰好一次。PV 八步非均匀累加对拍覆盖 D64 的 32,768 B，以及 D128 两个 stage 各 65,536 B 的 FP32 输出。

<a id="fa4-handoffs"></a>
### 真实的乘法顺序

下文记 QKₛ(t)、PVₛ(t) 为 Q stage s 对物理 KV tile t 的整次乘法。D64 每次 QK 有 4 条 K16，D128 有 8 条；两者每次 PV 都有 8 条。按调用形状解开 MMA warp 的循环后：

- **D64，全注意力。** 一个工作 tile 的序列为 `QK₀(0) → PV₀(0) → O_full`。QK 用 SMEM 的 Q、K 写 S0，PV 要读由 S0 生成的 P0。PTX 中循环体也有 PV→QK 站点，但此用例 KV 长度为 128，循环次数为零；实际走尾部 PV。下一工作 tile 另有自己的生产者与 barrier phase。
- **D128，causal。** 同一工作 tile 处理相邻两个 128 行的 Q stage。四个 256 行工作区间各遍历 L=2、4、6、8 个 KV tile，从 H=L−1 降到 0。开头执行 `QK₀(H) → QK₁(H)`；每个 t=H…1 依次执行 `PV₀(t) → QK₀(t−1) → PV₁(t) → QK₁(t−1)`；结尾执行 `PV₀(0) → PV₁(0)`。每个工作 tile 有 2L−1 次 QK→PV，全部跨 Q stage；有 2(L−1) 次 PV→QK，全部回到同一 Q stage。因果 mask 改变有效工作量，已进入的乘法仍执行其 K16 序列。[上游 causal 范围](https://github.com/Dao-AILab/flash-attention/blob/d80a77103021c4e980f8cbbf85774f6a19e6474a/flash_attn/cute/block_info.py#L21-L39) · [MMA warp 的序言、交错循环与尾段](https://github.com/Dao-AILab/flash-attention/blob/d80a77103021c4e980f8cbbf85774f6a19e6474a/flash_attn/cute/flash_fwd_sm100.py#L1683-L1824)

#### TMA 和 P 以哪个边沿为准

KV 生产者按 K(H)、V(H)、K(H−1)、V(H−1)… 搬运，与计算并行。MMA warp 首次 QK 等 Q stage 和 K stage，首次 PV 等 V stage 及本 Q stage 的 P/O 许可。每个 stage 的 TMA 可见链依次经过最后一次目标 SMEM 写 ACK、各 copy 的成功 complete-tx、该 phase 的 arrival 和 byte 条件同时满足，最后是消费 warp 的 wait acquire ACK 和成功谓词。D64 的一个 K 或 V stage 为 16 KiB；D128 为 32 KiB，实际 PTX 在同一 stage 的 32,768 B expect-tx 下发两笔 16 KiB panel copy。首个 panel 的完成无法放行整 stage。wait 在 c 沿匹配 phase，acquire 最早 c+1 发；若 a 沿接受 acquire ACK，成功谓词最早 a+1 交付。warp 还要执行分支、地址准备并提交命令。[上游预取顺序](https://github.com/Dao-AILab/flash-attention/blob/d80a77103021c4e980f8cbbf85774f6a19e6474a/flash_attn/cute/flash_fwd_sm100.py#L1471-L1513) · [TMA 实际写与完成](../rtl_specs/tma/blackwell_tma_completion_tracker.md) · [wait 与 acquire](../rtl_specs/mbarrier/blackwell_mbarrier_wait.md)

两个 kernel 的 arrival 都丢弃结果（`_`），wait 使用 parity，PTX 中出现非零提示 `10000000`。四列对齐的 TMEM LD x32 每 lane 取 8 个 128-bit word，整 warp 向 RF 交付 32 个 beat、共 4 KiB。[LD 数据通路](../rtl_specs/tmem/blackwell_tmem_ldst_engine.md#ld-word)

P 来自 softmax warp。它先等对应 QK 的 S_full，读 S 到 RF、计算概率、写 P[0…95]，用 PTX 的 `tcgen05.wait::st` 确认自己的写，再到达 P/O barrier。校正 warp 也要为同一 phase 到达；首个 KV tile 无旧 O 需重缩放，后续 tile 按实际 scale 决定是否读改写 O。P[96…127] 的写确认另行到达 lastsplit barrier。两份 PTX 的 MMA warp 都把第二次 wait 放在 PV 的 K16 步 5 与步 6 之间。若 PV 步 0 首 dot 为 0，无气泡的步 6 首 dot 应在 192（D64）或 384（D128）。要接上该沿 F，步 6 的第一块 B 最迟在 F−2 交付；按相邻两拍 grant 排程，首请求最迟在 F−7 进入 R_BREQ，F−6、F−5 两沿 grant。wait 若挡住 cmd.fire，提前计算 SMEM 地址也得不到这个时隙。[softmax 分段写 P](https://github.com/Dao-AILab/flash-attention/blob/d80a77103021c4e980f8cbbf85774f6a19e6474a/flash_attn/cute/flash_fwd_sm100.py#L2280-L2356) · [O 校正与 release](https://github.com/Dao-AILab/flash-attention/blob/d80a77103021c4e980f8cbbf85774f6a19e6474a/flash_attn/cute/flash_fwd_sm100.py#L2479-L2499)

#### QK → PV

以**紧邻前条乘法的最后一条 K16 MMA** 首 dot 为 0。其理想发射窗口为 0…63，末 D 写在 69/70 接受、71 实写、72 退休 ACK，tracker 最早在 75 接收 engine done。commit 可提前登记，实际 S_full arrival 要等其覆盖的操作完成；不能把 72 直接用作 P 就绪沿。[MMA 写尾](../rtl_specs/top/blackwell_async_subsystem_top.md#cycles) · [commit 到 arrival](../rtl_specs/tensor_core/blackwell_tc_async_completion.md)

| 边沿 | D64，同 stage S0 → P0 | D128，跨 stage，例如 S1 → P0 |
|---|---|---|
| 0…55 | V 可由 TMA 搬入 SMEM。此工作 tile 的 P0 仍等当前 S0。 | P0 的生产者是更早的 QK₀(t)。softmax 和 O₀ 校正可与当前 QK₁ 重叠。若 V 和 P/O 的 wait 已放行 PV、pin 和槽位及时，V 首块可在 54/55 grant。 |
| 56…63 | 即使 V 已写入，未发出的 PV 还不能请求 loader。本 stage 的 P 地址也与旧 S 后半部相交。 | 可在 56/57 读 P 的两帧，59/60 返回。V 在 56/57 返回、58 分发。如需旧 O，C0 在 58/59 grant、61/62 返回；首 tile 则注零。63 装新 R_OP。 |
| 64 及以后 | 只考虑硬件别名，旧 ACK=72 后 P 最早 73/74 grant、76/77 返回，79 是局部下界。真实顺序还要经过 tracker、S_full、softmax、P/O release 与成功 acquire。 | 条件满足时 64 即可首发，旧 S1 末 ACK 在 72 照常退休。若 P0、O₀ 或 V 有一项晚到，须按该项实际放行后的准备沿重排。 |

D64 可把未知等待和已知准备分开计算。令 R 为两个 wait 已成功、PV 已接受并完成预检和 pin 后，V 与 P 都能开始 grant 的示例沿。V/P 均在 R、R+1 获准。SMEM 的 V 在 R+2、R+3 返回，R+4 四核交付；TMEM 的 P 在 R+3、R+4 返回。最早 R+5 装 R_OP，R+6 首 dot。真实 R 取决于生产者、wait 的 acquire 确认和 warp 调度。D128 的重叠窗口则相当可观：序言中 QK₀ 与 PV₀ 之间有一整次 QK₁（512 个有效 dot 拍）；在交错循环中，对应的 QK 与 PV 之间可有两整次乘法。要比较的是本 stage 的许可和首块期限。

#### PV → 下一条 QK

D128 的每个非末 KV tile 有两种回切。PV₀(t) 后，MMA warp 推进 KV 环并等待 K(t−1) 的成功 acquire，再发 QK₀(t−1)。PV₁(t) 后，warp 为 V(t) 发出释放其 SMEM 槽的异步 commit，随后 QK₁(t−1) 复用已经通过 wait 的同一 K；此处没有第二个 K wait。commit 登记与其实际 arrival 是两个边沿。新 QK 的第一步 `input_d=0`，直接注零；旧 PV 写 O、新 QK 写 S，地址分离。P 与将写入的 S 共用部分地址，而旧 P 的最后一次 op_load 先于新指令首发，已在 R_OP 的操作数可安全完成。[core 取数与依赖](../rtl_specs/tensor_core/blackwell_tc_mma_core.md)

以前条 **PV 的最后一条 K16** 发出首个 dot 的沿为 0。下表假设下一条 QK 已提前通过 wait、预检和 pin，操作数端口按正常排程获准，dot 和写回均可接收。核 `c=0…3` 各负责从 `32c` 开始的 32 行 Q。每核一次发射用自己的八行 Q 和共用的八个 K 向量，对每个行列组合做一次 16 项点积，得到一个 8×8 输出微块。对同一组八个输出列，四次发射依次用完本核的四组 Q。

旧 PV 执行期间，SMEM 每四拍给 Q 两个读拍。第一拍从八行各取前 16 B，第二拍各取后 16 B。这样每行取齐 16 个 FP16，八行共 256 B。每核四组合计 1 KiB，占八个读拍。行组 `r=0…3` 在核 `c` 的两个 grant 沿为 `16r+4c` 和 `16r+4c+1`，各在两拍后返回。B 的时隙先读旧 PV 的 V。新 QK 的首个 K 块在 54/55 grant、56/57 返回，58 分发到四核。

| Q 行组（各核本地行号） | SMEM grant 沿（依次为核 0、1、2、3） | 四核中最晚的 Q 返回沿 | 各核装入 R_OP | 各核发射 dot |
|---|---|---:|---:|---:|
| 0（0…7） | 0/1、4/5、8/9、12/13 | 15 | 63 | 64 |
| 1（8…15） | 16/17、20/21、24/25、28/29 | 31 | 64 | 65 |
| 2（16…23） | 32/33、36/37、40/41、44/45 | 47 | 65 | 66 |
| 3（24…31） | 48/49、52/53、56/57、60/61 | 63 | 66 | 67 |

旧 PV 在 62 装入末个微块，63 发射，同沿四核装入新 QK 的首个微块。首个微块由 engine 统一放行，此后各核按自己的操作数就绪情况推进。表中每组 Q 都在装入前返回，所以 64…67 每核每拍发射一个微块。第 68 拍转到输出列 8…15，从同一份本地 Q 的第 0 行组开始复用。旧 PV 写 O 的末 ACK 可在 72 退休。[四核发射规则](../rtl_specs/tensor_core/blackwell_tc_mma_core.md) · [QK 的四拍重复窗口](#qk-的四拍重复窗口)

新 QK 从 K16 步 1 开始读取自己写的 S。以步 0 首 dot 重新记 0，D[0] 的末次成功 ACK 在 12，步 1 的 C0 在 58/59 读，64 首发。PV 对 O 的同址累加也按块等成功 ACK，跨 KV tile 另等校正 warp 发布 O。对应块的 ACK 晚到会推迟该块的读；若仅末块 ACK 晚到且写回容量足够，后条仍可按时首发。上述两个交接方向均用实际换位地址逐拍核对了八组 SMEM 的 grant、双槽释放及所列 TMEM 读写 word。

#### 哪些等待可以隐藏

- **生产者数据依赖。** D64 同 stage 的 S→softmax→P，后续 tile 必需的 O 重缩放，以及 PV 步 6 的末段 P，都要求真实写确认及成功 acquire。可让独立 TMA 搬运和另一 stage 的计算覆盖这些时间；当前指令无权越过 wait 读取未发布的数据。
- **现有预取能覆盖的准备。** 已通过 wait 的命令可在前条末次 dot 前装 Q 行组、首个 K/V 块、P 帧和合法 C 块。优先让 D128 的下一 K stage 提前发布，并检查最晚的 Q 行组。若想在整条 MMA 尚被 wait 挡住时，先把已发布的 V 或 Q 从 SMEM 搬入 TC buffer，需要另行定义独立预取及源 stage 生命周期；当前 loader 只接已登记的 MMA。

<a id="tma-budget"></a>
### TMA 服务拍与消费者期限

所有 copy 共用 128 B/拍。D128 两个独立 16 KiB panel 可在相邻沿将前条末段、后条首段送入 walker；理想 GMEM READ 在 129/130 拍交接。两条分别等待末次目标写 ACK 和 producer_rsp。每个 panel 单独登记 complete-tx，消费期限仍按整个 stage 的成功 wait。命令间隙、源返回、bank 争用、ACK 和 barrier 等待另算。下表只计对齐满段的目的写服务，假设源持续就绪、八组空闲、64 个事务 tag 和 16 个数据槽各自能及时周转。load 等外存时只占 tag，成功返回才占 RAM；store 在源读前先占 RAM。两向均在最后目标请求接受时释放行，实际写 ACK 仍归原 tag。[双 panel 的最早发读沿](../rtl_specs/tma/blackwell_tma_unit.md#copy-overlap)

| K/V 数据 | 总量 | 最少 SMEM 写服务拍 | 可用于重叠的计算 |
|---|---:|---:|---|
| D64，一份 K 或 V | 16 KiB | 128 | 同工作 tile 的 QK 为 256 拍；若 V 从窗口起点开始满速写，纯写服务占一半。实际 PV 仍等 V 和本 stage 的 P/O。 |
| D128，一份 K 或 V | 32 KiB | 256 | 同一 stage 两笔 16 KiB panel copy，各 128 拍，分别完成后才满足 32,768 B 的 expect-tx。 |
| D128，一个 KV tile 的 K+V | 64 KiB | 512 | 两个 Q stage 共 2×(512 QK + 512 PV)=2,048 个有效 dot 拍。 |

K/V 三槽环可将读入提前。用实际 copy 的首个 grant、末次目标 ACK 和 complete-tx 排出 phase 的最早放行沿。store 方向同样以 128 B/拍为峰值，O 的 SMEM 源读与 Q/K/V 操作数争同组的读 grant；其 GMEM 写 ACK 另行跟踪。比较两类争用时，load 写与 MMA 读只有同 bank 同 word 冲突才须错开。[TMA 调度](../rtl_specs/tma/blackwell_tma_unit.md) · [满行逐拍示例](../rtl_specs/tma/blackwell_tma_data_path.md#peak)

H20 单 CTA、D128 热数据、两个逻辑 tile 在途的独立 load 实验测得 95.3 B/SM 拍。上表的 128 B/拍来自项目端口宽度，store 方向取规格推导值。

实测归因时，用同一工作 tile、Q stage、KV 序号、barrier 地址/phase 和 MMA id 对齐：记录最后目标写 ACK、complete-tx、phase 翻转、wait 成功、cmd.fire/prepare、各行组与首 B 块就绪、相关 D 块 ACK、四核 op_load/dot_fire。分别只推迟 K 或 V 的最终 complete-tx、P 后段的 arrive 或对应 C 块的 ACK，比较第一个后移的消费沿。多个门限同时未满足时按最晚者归因，避免把同一段空拍重复计入 TMA 和 P。

## 设计时的模型对照

对[通用 N128 同址累加向量](../rtl_specs/top/blackwell_async_subsystem_top.md#mma-vectors)，临时边沿模型首发为 0、64、128、192、256、320、384、448，最终 65,536 个 FP32 结果字节与独立坐标求和一致。另以 64 组暂停序列检查 N256 原位覆盖及慢核部分交付。隔离换指令门控时，块 0 成功 ACK 延至 64 则 C0 最早 65 grant；只延迟末 ACK 到 80，后条仍在 64 首发；C1 于 70 收齐则后条块 1 首发延至 72。结果描述的是临时模型，正式实现需按各模块的验收用例复测。

分块设计的公开参考包括 [CUTLASS fragment 双缓冲](https://docs.nvidia.com/cutlass/4.3.1/media/docs/cpp/efficient_gemm.html#pipelining)、[NVDLA CDMA/CBUF 消费量跟踪](https://nvdla.org/hw/v1/ias/unit_description#convolution-buffer) 和 [CUDA SMEM bank 布局](https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/index.html#shared-memory-and-memory-banks)。
