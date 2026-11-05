# blackwell_tc_completion_tracker

> 规范版本 v1.0

## 1. 模块概述

跟踪已接受的MMA/CP/SHIFT及commit快照。OPERATIONS=1、COMMITS=8；每commit记录此前同ctx/epoch/issuer的live op集合和同issuer先前commit顺序。无需知道矩阵形状，也不跟踪TMA bytes或LD/ST方向wait。

### 微架构与资源

```mermaid
flowchart LR
    N0[accept/complete] --> N1[单live身份与failure]
    N1[单live身份与failure] --> N2[8个commit快照]
    N2[8个commit快照] --> N3[公平held arrival]
```

默认OPERATIONS=1、COMMITS=8。数据命令独占权直到内部complete_fire才释放，因此live TC操作最大1；普通DONE背压及barrier arrival不延长已退休operation。8个commit每项保存1bit pending与8bit predecessor；slot复用前清所有旧snapshot位，防止新操作继承旧依赖。

issuer fault为1024bit控制位图，operation身份只存1份；commit payload8×TC_COMMIT_A1_W在使能寄存器。register/complete组合接受L=0、II=1，commit接受到最早arrival有效L=1；一个held arrival槽背压只阻塞发布，complete一直可退休。

所有资源与时序的默认值见[微架构配置](../common/interfaces.md#微架构配置与性能约束)。周期从接受边沿计至结果首次有效；延迟式另加实际背压和外部响应等待。payload 不复位，valid、credit 和身份有效性复位；clock enable 随实际推进，SRAM 仅启用有效 bank。

按M启用1/2/4个core协作的一条MMA只占一个live operation；局部core退休不进入本tracker，父MMA汇总后提交一次complete。

## 2. 接口定义

全部握手、身份、完成、错误和复位遵循[公共规则](../common/interfaces.md#握手身份与生命周期)；表内位宽单位为 bit，符号见[公用位宽配置](../common/interfaces.md#公用位宽配置)，参数项注明默认配置。无握手的组合输出随输入变化；有握手的流水输出按所属通道保持。

register、complete、commit、arrival 分别采用 `async_key_a1_t`、`async_event_a1_t`、`tc_commit_a1_t`、`tc_commit_a1_t`。arrival_status 表示快照及生产者失败；protocol_error 表示无法匹配的协议事件。

登记必须与外部命令实际接受同拍，并先于任何执行请求；表满反压，重复live key不接受。complete入口独立于登记/commit/arrival credit，domain必须TC，精确key匹配；未知/重复完成报protocol_error并不释放其他操作。失败保持issuer fault到排空后全后端复位，仅换epoch不能恢复。

commit仅纳入接受边沿前的前驱，同拍有效完成从集合清除；同拍失败及旧sticky failure仍传播。后来的操作不扩展快照；slot释放前从所有snapshot清位。同issuer的arrival按commit接受顺序发布，其他issuer轮询。arrival_vld反压时payload稳定。

idle/drained由本模块的权威表及held arrival直接计算并输出，不由父层重复登记或另建计数表。

### 输入信号

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `clk` | 1 | 公共上升沿时钟。 |
| `rst_n` | 1 | 低有效异步复位，释放同步；控制状态与外部旧响应隔离见共享规则。 |
| `register_vld_i` | 1 | `register` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `register_i` | `ASYNC_KEY_A1_W` | TC 操作登记，必须与外部命令接受同拍；packed `async_key_a1_t`，见[共享字段](../common/interfaces.md#身份与事件字段)。 |
| `complete_vld_i` | 1 | `complete` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `complete_i` | `ASYNC_EVENT_A1_W` | TC 内部完成；packed `async_event_a1_t`，见[共享字段](../common/interfaces.md#身份与事件字段)。 |
| `commit_vld_i` | 1 | `commit` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `commit_i` | `TC_COMMIT_A1_W` | TC commit；packed `tc_commit_a1_t`，见[共享字段](../common/interfaces.md#身份与事件字段)。 |
| `arrival_rdy_i` | 1 | `arrival` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |

### 输出信号

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `register_rdy_o` | 1 | `register` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `complete_rdy_o` | 1 | `complete` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `commit_rdy_o` | 1 | `commit` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `arrival_vld_o` | 1 | `arrival` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `arrival_o` | `TC_COMMIT_A1_W` | 满足前驱快照的 commit；packed `tc_commit_a1_t`，见[共享字段](../common/interfaces.md#身份与事件字段)。 |
| `arrival_status_o` | `STATUS_W` | 模块诊断状态，0 成功、非 0 失败；错误完成不得伪装成功。 |
| `protocol_error_o` | 1 | 协议错误指示：未知/重复完成、身份或域不匹配；不得退休其他操作。 |
| `idle_o` | 1 | 无live TC数据操作；待发布commit不计入idle。 |
| `drained_o` | 1 | 数据操作表、commit表及held arrival均空；sticky fault不计作在途工作。 |


## 3. 伪代码

```text
on register_fire: allocate slot; store exact ctx/id
on complete_fire:
    if key not live or domain!=TC: protocol_error=1
    else:
        clear slot bit in every commit snapshot; propagate failure
        sticky_fault[issuer] |= failed; free operation slot
on commit_fire:
    pending=matching pre-edge live operations minus valid same-edge completion
    status=sticky_fault[issuer] OR same-edge matching failure
    predecessors=earlier live commits with same ctx/epoch/issuer
when pending=0 && predecessors=0 && arrival_slot_available:
    publish eligible commit by round-robin; clear its predecessor bits
on quiescent reset: clear tables, held arrival and sticky faults
idle=operation_table_empty
drained=idle && commit_table_empty && no held arrival
```
