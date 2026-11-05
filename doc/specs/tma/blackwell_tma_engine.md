# blackwell_tma_engine

> 规范版本 v1.0

## 1. 模块概述

TMA命令分发与per-issuer bulk-group跟踪层，包含copy engine。对子模块传递data queue8/cache4/MSHR16，仅data engine实例化这些资源；本层保存ticket及bulk-group状态，不增加data FIFO、descriptor cache或MSHR；ticket数`2*CMD_QUEUE_DEPTH+4`，默认20，其中至少2项保留给控制/等待而不被copy占尽。1024个issuer各有64bit open-group序号和sticky error。

子模块规范：[blackwell_tma_copy_engine](blackwell_tma_copy_engine.md)。

### 微架构与资源

```mermaid
flowchart LR
    N0[历史RAM读与ticket预留] --> N1[group/cutoff旁路]
    N1[group/cutoff旁路] --> N2[copy或control dispatch]
    N2[copy或control dispatch] --> N3[边界更新/held响应]
```

ticket20=2*FIFO8+4，至少2槽保留控制/等待；ticket仅保存用户身份、group编号、desc/source/full边界与结果，payload排队唯一在data FIFO。per-issuer RAM为1024×136bit（open_group64+first_failed_group64+error8）=17KiB，1R1W，独立seen/fault有效位；未seen读为初始值，不复位RAM内容。1级RAM读、1级seq/group检查与旁路、1级dispatch，正常命令准入II=1、Ldispatch=3；COMMIT/WAIT的cutoff在接受时形成，不受稍后RAM写入改写。

同issuer连续命令使用最新pending写旁路，read/write冲突按先前接受顺序；持久group水位在ticket退休后仍保留。copy响应进入ticket一次，软件held响应不阻塞desc/source/full边界推进。group等待每拍处理一个eligible ticket，前驱关系在接受时形成、退休清位。

ticket每条metadata预算384bit，保存用户身份、分组/desc/source/data边界、前驱mask及结果；完整778bit命令只在3级admission流水和data engine的唯一8项FIFO中保存，dispatch后ticket不保留副本。RAM读1拍；同issuer连续接受时以最近合法group历史写入旁路，64bit group/cutoff计算只在接受检查执行，cmd.seq由Flash保证单调且在live identity匹配时保持完整；live前驱仅按同issuer/已接受先后生成，不做持续64bit两两比较。历史RAM136bit=open_group64+first_failed_group64+status8，另seen/fault有效位各1024bit；健康namespace切换只清seen，fault有效位保持至全后端复位。

所有资源与时序的默认值见[微架构配置](../common/interfaces.md#微架构配置与性能约束)。周期从接受边沿计至结果首次有效；延迟式另加实际背压和外部响应等待。payload 不复位，valid、credit 和身份有效性复位；clock enable 随实际推进，SRAM 仅启用有效 bank。

## 2. 接口定义

全部握手、身份、完成、错误和复位遵循[公共规则](../common/interfaces.md#握手身份与生命周期)；表内位宽单位为 bit，符号见[公用位宽配置](../common/interfaces.md#公用位宽配置)，参数项注明默认配置。无握手的组合输出随输入变化；有握手的流水输出按所属通道保持。

命令及响应采用 `tma_cmd_t/tma_rsp_t`。stop 阻止新的外部命令，已接受工作继续推进。tma_rsp 恢复用户 tag/issuer，内部 copy.tag 为 ticket 索引；copy 完成先记录 ticket，响应反压不阻止 MSHR 退休。不同 ticket 响应允许乱序，payload 保持稳定。

load→mbarrier，store/global reduce→bulk group，prefetch→none；不合法completion或multi_cta返回UNSUPPORTED。tiled load的bulk-group仅跟踪descriptor读取；linear load不假设参与store bulk group。COMMIT_GROUP允许空组并推进open-group；WAIT_GROUP N捕获已提交group序号`g<max(open_group-N,0)`，不含未提交组；.read等待源读取，普通wait等待目标与ordering，tensor load仍只等descriptor。

copy失败在对应issuer的失败group水位保存，用户已消费copy错误响应后，覆盖它的后续wait仍失败。序号不回绕，耗尽前排空复位。group、cache/mode、dtype/op等合法条件沿用TMA字段定义（原文档已清理），范围外能力按共享目标拒绝。idle表示无执行中的copy，drained还要求没有等待ticket、copy待响应及held输出；已完成的group序号/error记录不妨碍drained。

ctx_i/epoch_i由TMA/bar parent传入当前唯一CTA namespace；只允许在engine.drained且旧响应已隔离时变化。切换后seen清0，不复位history RAM；unseen issuer逻辑open_group=0，若其sticky fault仍有效则first_failed_group=0且保留error，因此不能用epoch消除错误。新命令接受时捕获namespace，工作退休前不可切换。

### 输入信号

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `clk` | 1 | 公共上升沿时钟。 |
| `rst_n` | 1 | 低有效异步复位，释放同步；控制状态与外部旧响应隔离见共享规则。 |
| `ctx_i` | `CTX_ID_W` | 当前CTA namespace的context；变化前须drained。 |
| `epoch_i` | `EPOCH_W` | namespace生命周期；变化不清sticky fault。 |
| `tma_cmd_vld_i` | 1 | `tma_cmd` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `tma_cmd_i` | `TMA_CMD_W` | TMA/descriptor 控制命令；packed `tma_cmd_t`，见[共享字段](../common/interfaces.md#tma-命令与响应)。 |
| `tma_rsp_rdy_i` | 1 | `tma_rsp` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `gmem_req_rdy_i` | 1 | `gmem_req` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `smem_req_rdy_i` | 1 | `smem_req` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `tma_order_req_rdy_i` | 1 | `tma_order_req` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `tma_order_rsp_vld_i` | 1 | `tma_order_rsp` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `tma_order_rsp_i` | `BW_ORDER_RSP_W` | ordering 确认，ID 精确匹配；packed `bw_order_rsp_t`，见[共享字段](../common/interfaces.md#内存属性与-ordering)。 |
| `gmem_rsp_vld_i` | 1 | `gmem_rsp` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `gmem_rsp_data_i` | `GMEM_DATA_W` | memory 读返回行数据；data[8*j+:8] 对应请求 addr+j，未选读 byte 返回 0。 |
| `gmem_rsp_status_i` | `MEM_STATUS_W` | memory 状态，0 成功、非 0 失败。 |
| `gmem_rsp_id_i` | `GMEM_ID_W`（默认 `GMEM_ID_DEFAULT_W`） | 所属 memory 通道事务 ID；live ID 未退休前不复用，响应按 ID 匹配。 |
| `smem_rsp_vld_i` | 1 | `smem_rsp` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `smem_rsp_data_i` | `SMEM_DATA_W` | memory 读返回行数据；data[8*j+:8] 对应请求 addr+j，未选读 byte 返回 0。 |
| `smem_rsp_status_i` | `MEM_STATUS_W` | memory 状态，0 成功、非 0 失败。 |
| `smem_rsp_id_i` | `SMEM_ID_W`（默认 `TMA_SMEM_ID_DEFAULT_W`） | 所属 memory 通道事务 ID；live ID 未退休前不复用，响应按 ID 匹配。 |
| `tx_cpl_rdy_i` | 1 | `tx_cpl` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `tx_rsp_vld_i` | 1 | `tx_rsp` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `tx_rsp_tag_i` | `ASYNC_TAG_W` | 请求 tag；响应原样恢复，不能单独作为跨 epoch 唯一身份。 |
| `tx_rsp_status_i` | `STATUS_W` | 模块诊断状态，0 成功、非 0 失败；错误完成不得伪装成功。 |
| `tx_rsp_phase_i` | 1 | barrier phase；transaction 响应或诊断值，不代替 wait token。 |
| `stop_i` | 1 | 置 1 停止新的外部命令或登记；已接受工作、生产者完成和响应继续推进。 |

### 输出信号

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `tma_cmd_rdy_o` | 1 | `tma_cmd` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `tma_rsp_vld_o` | 1 | `tma_rsp` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `tma_rsp_o` | `TMA_RSP_W` | TMA 响应，bytes 为逻辑 payload 字节数；packed `tma_rsp_t`，见[共享字段](../common/interfaces.md#tma-命令与响应)。 |
| `gmem_req_vld_o` | 1 | `gmem_req` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `gmem_req_attr_o` | `BW_MEM_ATTR_W` | 内存访问属性，随请求保持；packed `bw_mem_attr_t`，见[共享字段](../common/interfaces.md#内存属性与-ordering)。 |
| `gmem_req_addr_o` | `ADDR_W`（默认 `GMEM_ADDR_W`） | GMEM byte 地址，128B 对齐；禁止截断 overflow。 |
| `gmem_req_data_o` | `GMEM_DATA_W` | memory 行数据；data[8*j+:8] 对应 addr+j，写 mask 为 0 的 byte 保持。 |
| `gmem_req_byte_mask_o` | `GMEM_MASK_W` | memory byte mask；bit j 选择 addr+j 的实际访问，未选读 byte 返回 0。 |
| `gmem_req_id_o` | `GMEM_ID_W`（默认 `GMEM_ID_DEFAULT_W`） | 所属 memory 通道事务 ID；live ID 未退休前不复用，响应按 ID 匹配。 |
| `gmem_req_write_o` | 1 | 1 为写请求，0 为读请求；访问语义同时受 attr.kind 约束。 |
| `smem_req_vld_o` | 1 | `smem_req` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `smem_req_attr_o` | `BW_MEM_ATTR_W` | 内存访问属性，随请求保持；packed `bw_mem_attr_t`，见[共享字段](../common/interfaces.md#内存属性与-ordering)。 |
| `smem_req_addr_o` | `SMEM_ADDR_W`（默认 `SMEM_BYTE_ADDR_W`） | SMEM/backing byte 地址，32B 行对齐；禁止截断 overflow。 |
| `smem_req_data_o` | `SMEM_DATA_W` | memory 行数据；data[8*j+:8] 对应 addr+j，写 mask 为 0 的 byte 保持。 |
| `smem_req_byte_mask_o` | `SMEM_MASK_W` | memory byte mask；bit j 选择 addr+j 的实际访问，未选读 byte 返回 0。 |
| `smem_req_id_o` | `SMEM_ID_W`（默认 `TMA_SMEM_ID_DEFAULT_W`） | 所属 memory 通道事务 ID；live ID 未退休前不复用，响应按 ID 匹配。 |
| `smem_req_write_o` | 1 | 1 为写请求，0 为读请求；访问语义同时受 attr.kind 约束。 |
| `tma_order_req_vld_o` | 1 | `tma_order_req` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `tma_order_req_o` | `BW_ORDER_REQ_W` | ordering 请求，确认须兑现对应 seq/proxy/scope 可见性；packed `bw_order_req_t`，见[共享字段](../common/interfaces.md#内存属性与-ordering)。 |
| `tma_order_rsp_rdy_o` | 1 | `tma_order_rsp` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `gmem_rsp_rdy_o` | 1 | `gmem_rsp` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `smem_rsp_rdy_o` | 1 | `smem_rsp` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `tx_cpl_vld_o` | 1 | `tx_cpl` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `tx_cpl_tag_o` | `ASYNC_TAG_W` | 请求 tag；响应原样恢复，不能单独作为跨 epoch 唯一身份。 |
| `tx_cpl_addr_o` | `SMEM_ADDR_W`（默认 `SMEM_BYTE_ADDR_W`） | barrier 对象 byte 地址，8B 对齐；SMEM 范围检查后访问。 |
| `tx_cpl_bytes_o` | `BARRIER_TX_BYTES_W` | unsigned32 transaction 增减量，单位 byte；从逻辑总量检查可表示性后生成，不含容器 padding，也不是 mask popcount。 |
| `tx_rsp_rdy_o` | 1 | `tx_rsp` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `idle_o` | 1 | 无本模块执行或在途访问；具体统计范围见本节规则。 |
| `drained_o` | 1 | 本模块已接受工作及请求、响应保持槽全部排空；具体范围见本节规则。 |

## 3. 伪代码

```text
on copy cmd_fire:
    allocate ticket with saved user tag/issuer/open_group
    mark store bulk member or tensor-load descriptor-only member
    atomically send command to copy engine using ticket index as internal tag
on COMMIT_GROUP_fire: acknowledge registration; open_group[issuer]++
on WAIT_GROUP_fire:
    capture cutoff=max(open_group[issuer]-N,0), wait_read and matching older groups
on desc_done/source_done: record corresponding successful boundary of matching live ticket immediately
on copy_response:
    mark full done/status/bytes; retain earliest sticky failed group
    if failed: mark unfinished desc/read boundaries terminated with error, so waits can retire
wait eligible when every covered member reached its required desc/read/full boundary
eligible response: restore user identity; propagate covered sticky error; hold until consumed
do not depend on copy-response consumption to retire internal data progress
```

### 流水、资源与排空

```text
on namespace change: require drained and old responses isolated; clear seen, retain fault flags
unseen history: group=0; sticky fault uses failed_group=0 and stored error until reset
on admission: reserve ticket; read issuer RAM; capture cutoff/group using latest same-issuer bypass
write issuer history with one indexed1R1W access; persist first failed group even after copy response consumed
build wait predecessor set once; desc/source/full events clear only their specific ticket boundaries
control/WAIT uses its reserved2-ticket capacity even when copy tickets full
```
