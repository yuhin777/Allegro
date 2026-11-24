# blackwell_tc_scale_b_snapshot

## Description

每后端一份，保存两条活跃输入上下文的 scale B 快照，向四核组合提供指定 id 的八列因子。4×1 KiB 物理存储中 bank 0/1 对应 engine 分配的输入 bank，另外两份保留。每份按 32 行×8 cell×4 B 组织。物理快照选择不改变 TMEM 来源。

| 信号 / 通道 | 方向、类型 / 位宽 | 对端 | 握手或采样条件 |
| --- | --- | --- | --- |
| start / release | 入 prepare_t 449 bit / 入 async_id_t 58 bit | MMA engine | [engine](blackwell_tc_mma_engine.md) 在 pin 与跨指令地址依赖满足后启动。按 id 释放。 |
| rd_req[128] / rd_rsp[128] | 出 tmem_rd_req_t (108 bit) / 入 tmem_rd_rsp_t (210 bit) | TMEM fabric | client4，源 lane=x%32。 |
| query[4] / view[4] | 入 / 出，查询72 bit / 视图257 bit | 四个 core | 按 id 找到 READY 快照，可同沿读不同列。 |
| ready[3] / quiescent[3] | 出，每 rec 各 1 bit | MMA engine | quiescent 表示该 id 的 held/pending 均空且不再创建新读。 |
| live[3]；clk、rst_n、epoch_i / drained_o、fault_o | 入，每项 live 61 bit，clk/rst_n/epoch 为 1/1/16 bit；状态出，各 1 bit | engine、顶层 | 按 id/rec 匹配，drained 包含活动快照与 held 请求。 |

时钟、复位及通道的采样约定见[顶层公共协议](../top/blackwell_async_subsystem_top.md#common-protocol)。

```mermaid
flowchart LR
 S[start / id / input bank] --> F[枚举源 word / held]
 F --> M[TMEM client4] --> G[按 id,token 收集]
 G --> B[两份独立有效快照] --> V[四个组合查询]
```

## Functionality

### 按 id 装填和释放快照

每个被启动的 bank 保存 id/rec、base/id/V、needed/valid（各最多 256 个 cell）、32 行×3 源 word 的 sent/pending。单一枚举器优先较老待发请求，已展示候选锁到 fire。sb_token={reserved7=0,partition2=0,row5,atom2}，atom=0…2。column=base+n//32，source_word=base//4+atom；按 needed 合并同 word 的有效 byte。返回匹配 id 与 token 后写 snapshot[bank][n%32][n//32]，只覆盖所选 cell。N256 且 base%4=0 时至多 64 笔，否则至多 96 笔。

EMPTY → FILL → READY。最后一笔必需返回成功后置本 rec 的 ready，下一沿允许采 SB 入 R_OP；另一个快照可同时装填。在所有核已结束该 id 的输入使用且 quiescent 后，engine 发 release 并回收 bank。非 OK、未知或重复返回置 fault，不能使快照 ready。quiescent 在最后责任退休沿后才为真，unpin 不得提前。复位清有效位，不清快照数据。

验收在非零 bank 装入下一条，检查 n=31/32 的源 lane 回绕、四核独立查询和两 id 互不污染。分别延迟源返回、release 和 manager.unpin，检查各自的握手沿。测试 1X/2X/4X 及所有合法 s/V。

<a id="scale-layout"></a>

### Scale 布局与查询类型

适用 M128 普通 mxf8f6f4、mxf4、mxf4nvf4。各 kind 的合法类型和 vec 见 [MMA 命令](blackwell_tc_mma_engine.md#mma-command)。因子数 V=1、2、4。对 k∈[0,K)，g=floor(kV/K)，乘积使用 `SA(m,g)×A(m,k)×SB(n,g)×B(k,n)`。

#### TMEM 布局

x=m（A）或 n（B），s 为各自的 scale id。源 taddr 高16位为0，低16位是基 column。每个有效 (x,g) 按下面公式从 32-bit cell 取一个字节，加法扩展后检查范围和分配权限。

```text
lane   = x % 32
column = base + x//32 + (s+g)//4
byte   = (s+g)%4
value  = TMEM[lane][column][8*byte +: 8]
```

合法 s+V≤4。A 使用 lane0…31 和四个 column，B 用同一组 lane 和 N/32 个 column。2X 的 id=2 从 byte2 开始；4X 从 byte0 开始。A/B 拥有独立的地址和 id。UE8M0/UE4M3 的数值规则见[低精度scale](../dot/blackwell_f4f6f8_dot.md#formats)与[FP4 scale](../dot/blackwell_fp4_dot.md#formats)。

#### Scale B 组合查询

`tc_sb_query_t={id:58,block:6,n_base:8}`，72bit，n_base=8×block。`tc_sb_view_t={valid:1,data:256}`，257bit。对 j=0…7、g=0…V−1，`data[32*j+8*g+:8]=SB(n_base+j,g)`；未用因子的字节为0。查询只在 id、范围与有效位匹配时给出 valid。core 在 R_OP 装入沿直接采样紧凑排列的数据。

验收用各 lane/column/byte 独立编码的数据覆盖 x=31/32、末行/列、所有 N 和各 s/V，检查 D 与源重叠时全部 64 路 dot 仍使用 PREP 的采样值。[scale A 图](https://docs.nvidia.com/cuda/archive/12.8.2/parallel-thread-execution/_images/tcgen05-mma-scale-factor-a-1x-dig.png) · [scale B 图](https://docs.nvidia.com/cuda/archive/12.8.2/parallel-thread-execution/_images/tcgen05-mma-scale-factor-b-1x-dig.png)
