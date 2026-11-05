# blackwell_tmem_wait_tracker

> 规范版本 v1.0

## 1. 模块概述

管理LD/ST方向wait。OPERATIONS=1、WAITS=16、TAG_W=16；key为ctx/epoch/warp/store/tag/seq。wait只覆盖同ctx/epoch/warp/方向的此前已接受操作；CP/SHIFT/MMA不登记到本模块。

### 微架构与资源

```mermaid
flowchart LR
    N0[LD/ST登记与finish] --> N1[单live身份]
    N1[单live身份] --> N2[16个wait快照]
    N2[16个wait快照] --> N3[方向held response]
```

默认OPERATIONS=1、WAITS=16。命令级互斥保证全LD/ST live命令最大1；方向/warp仍在完整key中检查，16个wait各保存1bit pending和16bit predecessor。每context/warp/方向的poison按身份namespace存控制位图，epoch有效性单独保存；不按wait条目复制方向状态。

op/finish与wait接受均II=1；满足依赖且响应槽空时，下一拍最早返回，Lmin=1。held响应1槽，选择使用16项优先树/有界轮询；同拍finish先清旧依赖及传播failure，再形成不包含新op的快照。

所有资源与时序的默认值见[微架构配置](../common/interfaces.md#微架构配置与性能约束)。周期从接受边沿计至结果首次有效；延迟式另加实际背压和外部响应等待。payload 不复位，valid、credit 和身份有效性复位；clock enable 随实际推进，SRAM 仅启用有效 bank。

## 2. 接口定义

全部握手、身份、完成、错误和复位遵循[公共规则](../common/interfaces.md#握手身份与生命周期)；表内位宽单位为 bit，符号见[公用位宽配置](../common/interfaces.md#公用位宽配置)，参数项注明默认配置。无握手的组合输出随输入变化；有握手的流水输出按所属通道保持。

`op_*`登记接受的LD/ST；`finish_*`报告真实数据完成和status8；`wait_*`建立快照；`rsp_*`回传原wait身份和status。`clear_ctx_vld_i/clear_ctx_i`为成功重建后的单拍通知，仅在该context无live op、wait、held rsp时允许。

op/wait表满分别反压；finish入口不受两表或wait response credit制约。重复登记不接受并由集成层报告协议错误；未知/重复完成置protocol_error。失败poison同ctx/epoch/warp/方向，后续同类wait失败；安全context重建后可清RF poison。同类wait按接受顺序发布，其他类可轮询发布。held response仍计入生命周期排空。

idle/drained直接由本模块操作、wait及响应记录计算；父RF subsystem引用输出，不维护镜像表。clear_ctx仍逐context检查相关记录为空。

### 输入信号

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `clk` | 1 | 公共上升沿时钟。 |
| `rst_n` | 1 | 低有效异步复位，释放同步；控制状态与外部旧响应隔离见共享规则。 |
| `op_vld_i` | 1 | `op` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `op_ctx_i` | `CTX_ID_W` | 物理 context 槽编号；与 epoch 共同检查权限。 |
| `op_epoch_i` | `EPOCH_W` | context 生命周期编号；须与 live context 及 owner 记录匹配。 |
| `op_warp_i` | `WARP_ID_W` | warp 编号；RF 方向 wait 按 warp 匹配，数据路径低 2 bit 选 TMEM 分区。 |
| `op_store_i` | 1 | 1 为 ST 方向，0 为 LD 方向；wait/finish/DONE 按此匹配。 |
| `op_tag_i` | `TAG_W`（默认 `ASYNC_TAG_W`） | 请求 tag；响应原样恢复，不能单独作为跨 epoch 唯一身份。 |
| `op_seq_i` | `SEQ_W` | 64 bit 操作序号；按所属身份/完成域递增，不回绕。 |
| `finish_vld_i` | 1 | `finish` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `finish_ctx_i` | `CTX_ID_W` | 物理 context 槽编号；与 epoch 共同检查权限。 |
| `finish_epoch_i` | `EPOCH_W` | context 生命周期编号；须与 live context 及 owner 记录匹配。 |
| `finish_warp_i` | `WARP_ID_W` | warp 编号；RF 方向 wait 按 warp 匹配，数据路径低 2 bit 选 TMEM 分区。 |
| `finish_store_i` | 1 | 1 为 ST 方向，0 为 LD 方向；wait/finish/DONE 按此匹配。 |
| `finish_tag_i` | `TAG_W`（默认 `ASYNC_TAG_W`） | 请求 tag；响应原样恢复，不能单独作为跨 epoch 唯一身份。 |
| `finish_seq_i` | `SEQ_W` | 64 bit 操作序号；按所属身份/完成域递增，不回绕。 |
| `finish_status_i` | `STATUS_W` | 模块诊断状态，0 成功、非 0 失败；错误完成不得伪装成功。 |
| `wait_vld_i` | 1 | `wait` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `wait_ctx_i` | `CTX_ID_W` | 物理 context 槽编号；与 epoch 共同检查权限。 |
| `wait_epoch_i` | `EPOCH_W` | context 生命周期编号；须与 live context 及 owner 记录匹配。 |
| `wait_warp_i` | `WARP_ID_W` | warp 编号；RF 方向 wait 按 warp 匹配，数据路径低 2 bit 选 TMEM 分区。 |
| `wait_store_i` | 1 | 1 为 ST 方向，0 为 LD 方向；wait/finish/DONE 按此匹配。 |
| `wait_tag_i` | `TAG_W`（默认 `ASYNC_TAG_W`） | 请求 tag；响应原样恢复，不能单独作为跨 epoch 唯一身份。 |
| `clear_ctx_vld_i` | 1 | 成功 context 重建后的单拍清理通知；该 context 的 op/wait/held rsp 必须为空。 |
| `clear_ctx_i` | `CTX_ID_W` | 物理 context 槽编号；与 epoch 共同检查权限。 |
| `rsp_rdy_i` | 1 | `rsp` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |

### 输出信号

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `op_rdy_o` | 1 | `op` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `finish_rdy_o` | 1 | `finish` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `wait_rdy_o` | 1 | `wait` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `rsp_vld_o` | 1 | `rsp` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `rsp_ctx_o` | `CTX_ID_W` | 物理 context 槽编号；与 epoch 共同检查权限。 |
| `rsp_epoch_o` | `EPOCH_W` | context 生命周期编号；须与 live context 及 owner 记录匹配。 |
| `rsp_warp_o` | `WARP_ID_W` | warp 编号；RF 方向 wait 按 warp 匹配，数据路径低 2 bit 选 TMEM 分区。 |
| `rsp_store_o` | 1 | 1 为 ST 方向，0 为 LD 方向；wait/finish/DONE 按此匹配。 |
| `rsp_tag_o` | `TAG_W`（默认 `ASYNC_TAG_W`） | 请求 tag；响应原样恢复，不能单独作为跨 epoch 唯一身份。 |
| `rsp_status_o` | `STATUS_W` | 模块诊断状态，0 成功、非 0 失败；错误完成不得伪装成功。 |
| `protocol_error_o` | 1 | 协议错误指示：未知/重复完成、身份或域不匹配；不得退休其他操作。 |
| `idle_o` | 1 | 无live LD/ST操作；wait及held response由drained统计。 |
| `drained_o` | 1 | 操作表、wait表及held response均空；class poison不计作在途工作。 |


## 3. 伪代码

```text
on op_fire: allocate free slot; record exact key
on wait_fire:
    pending = matching pre-edge live ops minus same-edge valid finish
    predecessors = prior live waits of same ctx/epoch/warp/direction
    status = existing poison OR same-edge matching failure
on finish_fire:
    if no matching key: protocol_error=1
    else:
        clear its bit from every pending snapshot; propagate failure
        mark class poisoned on failure; free op slot
when pending=0 && predecessors=0 && response_slot_available:
    publish next eligible wait using round-robin; clear its predecessor bits
on clear_ctx_pulse: require drained(ctx); clear class poison and remembered epoch
idle=operation_table_empty
drained=idle && wait_table_empty && no held response
```
