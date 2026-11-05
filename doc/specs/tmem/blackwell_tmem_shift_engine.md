# blackwell_tmem_shift_engine

> 规范版本 v1.0

## 1. 模块概述

执行单CTA `tcgen05.shift.down`，移动一个32-lane分区的8个column。无算术、无RF接口；通过RF subsystem访问唯一bank。一次执行一条命令，先保留32×8×32bit完整旧值，最后lane保持原值；规定new[r]=old[r+1]。

### 微架构与资源

```mermaid
flowchart LR
    N0[完整probe] --> N1[3读记录/1KiB源快照]
    N1[3读记录/1KiB源快照] --> N2[全读成功后切换]
    N2[全读成功后切换] --> N3[3写记录/complete]
```

使用1KiB=32lane*8column*32bit完整源快照，而非逐column覆盖源；data不复位、valid位复位。读取aligned word数G=ceil((column%4+8)/4)，G为2或3；3个read及3个write metadata credit，满足ceil(3-cycle RTT/1-cycle II)=3，数据仅提取目标8列并按[r,c]存快照。

完整probe先于读取；所有源读成功后按word写前31lane，最后lane mask0。Lshift=2+(G-1)+3+1+(G-1)+3，计一次probe、pipeline读写及确认和1拍snapshot→write切换；无背压11或13拍，命令II=Lshift+complete背压。读阶段与写阶段互斥，阶段内请求II=1。

所有资源与时序的默认值见[微架构配置](../common/interfaces.md#微架构配置与性能约束)。周期从接受边沿计至结果首次有效；延迟式另加实际背压和外部响应等待。payload 不复位，valid、credit 和身份有效性复位；clock enable 随实际推进，SRAM 仅启用有效 bank。

## 2. 接口定义

全部握手、身份、完成、错误和复位遵循[公共规则](../common/interfaces.md#握手身份与生命周期)；表内位宽单位为 bit，符号见[公用位宽配置](../common/interfaces.md#公用位宽配置)，参数项注明默认配置。无握手的组合输出随输入变化；有握手的流水输出按所属通道保持。

命令采用 `shift_cmd_a1_t`，内部完成采用 `async_event_a1_t`、domain=TC；普通 SHIFT DONE 由 parent 独立缓冲。bank 请求及响应按共享 word 接口执行。

base lane仅0/32/64/96，column<=504；先检查完整32×8读取和31×8写入权限。只写前31lane；不得以补零改变最后lane。完成在全部写确认后，纳入TC commit，不进入wait::ld/st。失败保留key，停止新请求并收完已发请求，不回滚已确认写。

内部complete只在本引擎保持一份，RF subsystem直接转发到TC tracker；普通DONE由RF subsystem独立保存。idle包含held complete，父层不复制引擎执行状态。

### Probe 与在途返回

完整源/目标地址检查先于任何目标写；probe响应身份由RF parent核对并顺序路由。bank read/write返回按各方向接受顺序匹配原命令tag和局部工作记录，未知或重复响应失败并排空，不能释放其他请求。

### 输入信号

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `clk` | 1 | 公共上升沿时钟。 |
| `rst_n` | 1 | 低有效异步复位，释放同步；控制状态与外部旧响应隔离见共享规则。 |
| `cmd_vld_i` | 1 | `cmd` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `cmd_i` | `SHIFT_CMD_A1_W` | SHIFT 命令；packed `shift_cmd_a1_t`，见[共享字段](../common/interfaces.md#shift-命令)。 |
| `complete_rdy_i` | 1 | `complete` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `rd_rdy_i` | 1 | `rd` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `rd_rsp_vld_i` | 1 | `rd_rsp` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `rd_rsp_data_i` | `TMEM_DATA_W` | 128 lane × 128 bit TMEM word 数据；低位为 lane0，word 内低位为低地址 byte。 |
| `rd_rsp_status_i` | `STATUS_W` | 模块诊断状态，0 成功、非 0 失败；错误完成不得伪装成功。 |
| `wr_rdy_i` | 1 | `wr` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `wr_rsp_vld_i` | 1 | `wr_rsp` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `wr_rsp_status_i` | `STATUS_W` | 模块诊断状态，0 成功、非 0 失败；错误完成不得伪装成功。 |
| `probe_rdy_i` | 1 | probe请求接受能力。 |
| `probe_rsp_vld_i` | 1 | 对应probe已完成；失败时不得执行目标写。 |
| `probe_rsp_status_i` | `STATUS_W` | 完整范围权限检查结果。 |

### 输出信号

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `cmd_rdy_o` | 1 | `cmd` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `complete_vld_o` | 1 | `complete` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `complete_o` | `ASYNC_EVENT_A1_W` | TC 内部完成，domain=TC；packed `async_event_a1_t`，见[共享字段](../common/interfaces.md#身份与事件字段)。 |
| `rd_vld_o` | 1 | `rd` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `rd_ctx_o` | `CTX_ID_W` | 物理 context 槽编号；与 epoch 共同检查权限。 |
| `rd_epoch_o` | `EPOCH_W` | context 生命周期编号；须与 live context 及 owner 记录匹配。 |
| `rd_column_o` | `TMEM_COLUMN_BUS_W` | 128 × 16 bit TMEM word 起始 column；低位对应 lane0，各有效 lane 按 4 column 对齐。 |
| `rd_tag_o` | `TAG_W`（默认 `ASYNC_TAG_W`） | 请求 tag；响应原样恢复，不能单独作为跨 epoch 唯一身份。 |
| `rd_lane_mask_o` | `TMEM_LANE_MASK_W` | 128 个 TMEM lane 的读使能；bit j 选择 lane j。 |
| `rd_rsp_rdy_o` | 1 | `rd_rsp` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `wr_vld_o` | 1 | `wr` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `wr_ctx_o` | `CTX_ID_W` | 物理 context 槽编号；与 epoch 共同检查权限。 |
| `wr_epoch_o` | `EPOCH_W` | context 生命周期编号；须与 live context 及 owner 记录匹配。 |
| `wr_column_o` | `TMEM_COLUMN_BUS_W` | 128 × 16 bit TMEM word 起始 column；低位对应 lane0，各有效 lane 按 4 column 对齐。 |
| `wr_data_o` | `TMEM_DATA_W` | 128 lane × 128 bit TMEM word 数据；低位为 lane0，word 内低位为低地址 byte。 |
| `wr_tag_o` | `TAG_W`（默认 `ASYNC_TAG_W`） | 请求 tag；响应原样恢复，不能单独作为跨 epoch 唯一身份。 |
| `wr_byte_mask_o` | `TMEM_BYTE_MASK_W` | 128 × 16 bit TMEM byte mask；bit 16*l+b 选择 lane l 的 word byte b，0 保持。 |
| `wr_rsp_rdy_o` | 1 | `wr_rsp` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `idle_o` | 1 | 无已接受命令、在途bank请求或held complete；普通DONE由RF subsystem统计。 |
| `probe_vld_o` | 1 | probe 请求有效。 |
| `probe_ctx_o` | `CTX_ID_W` | 对象context身份，随请求保存。 |
| `probe_epoch_o` | `EPOCH_W` | 对象生命周期，与bank live身份精确比较。 |
| `probe_lane_mask_o` | `TMEM_LANE_MASK_W` | 启用lane位图；禁用lane不访问也不报其地址错误。 |
| `probe_column_o` | `TMEM_COLUMN_BUS_W` | 各lane完整16bit起始column；probe允许非word对齐。 |
| `probe_columns_o` | `TMEM_COLUMNS_COUNT_W` | 每个enabled lane的连续column数量，1..512；先加宽检查末地址。 |
| `probe_tag_o` | `ASYNC_TAG_W` | 原命令tag，随probe响应运输。 |
| `probe_rsp_rdy_o` | 1 | 接收probe响应；身份由parent核对，顺序按已接受probe队列。 |


## 3. 伪代码

```text
on cmd_fire: capture key/base; check full-width range and entire 32x8 source /31x8 destination
submit one probe(span=8,lane_mask=32 source lanes); wait success
for each of G aligned words: issue ordered read with <=2 live metadata; extract only requested 8 columns
wait every source read; no target write before full 1KiB snapshot is valid
for each of G words: shift snapshot[r+1,c] into first31 lanes with exact column byte masks
    issue ordered masked write with <=2 live metadata; lastlane mask=0
on error: stop new requests; drain all accepted responses; preserve nonzero status
after last write confirmation: hold complete(key,TC,status)
```
