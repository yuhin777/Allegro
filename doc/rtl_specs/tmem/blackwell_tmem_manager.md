# blackwell_tmem_manager

## Description

本模块管理单 CTA 独占的整块 TMEM（128 lane × 512 列）、本 epoch 的分配许可和五个固定使用者的引用。数据寻址由 [fabric](blackwell_tmem_fabric.md#tmem-layout) 定义。

| 信号 / 通道 | 方向、类型 / 位宽 | 对端 | 握手或采样条件 |
| --- | --- | --- | --- |
| `manage_cmd` | 入，[tmem_manage_cmd_t](#management-types)，102bit | 管理前端 | ALLOC、DEALLOC、释放分配许可。 |
| `alloc_credit_o` | 出，1 bit | 管理前端 | `permit && !allocated`，在选择 ALLOC 前采样。[入口仲裁](#alloc-admission) |
| `manage_rsp` | 出，[tmem_manage_rsp_t](#management-types)，94bit | 管理前端 | 原id、status和ALLOC所得base；非ALLOC的base=0。 |
| `pin_req` / `pin_rsp` | 入 61bit / 出 62bit | MMA engine、LD/ST | `{id58,user3}` 取得引用，响应为 `op_done_t`。 |
| `unpin` | 入 61bit | MMA engine、LD/ST | `{id58,user3}`，fire 释放该使用者的引用。 |
| `epoch_i` | 入，16bit，无握手 | 顶层 | 当前CTA生命周期。 |
| `stop_i` | 入，1bit，无握手 | 顶层 | 停止新外部管理命令；已接受工作的 pin、unpin 和响应继续。 |
| `epoch_end` | 入事件，无payload | 顶层 | 顶层已完成flush/ordering且全部pin归还，原子清旧allocation并封闭epoch。 |
| `empty_o` | 出，1bit | 顶层 | 无 allocation、引用或 held 响应。 |
| `drained_o` | 出，1bit | 顶层 | 无引用及在途响应。 |
| `fault_o` | 出，1bit | 顶层 | 未知/重复unpin等协议故障。 |

## Functionality

<a id="management-types"></a>

### 命令和状态

`tmem_manage_cmd_t={id:58,op:2,base:32,columns:10}`（102bit），op 0/1/2 分别为 ALLOC、DEALLOC、RELINQUISH_ALLOC_PERMIT。`tmem_manage_rsp_t={id:58,status:4,base:32}`（94bit）。管理命令为收敛 warp，issuer 低 5 bit 为零。ALLOC/DEALLOC 仅支持 base=0、columns=512，RELINQUISH 两字段均为零。入口预检按[指令范围](../../proposals/supported_ptx.md)处理。

`tmem_pin_req_t` 和 `tmem_unpin_t` 均为 `{id:58,user:3}`，`tmem_pin_rsp_t=op_done_t`。user 0…2 对应三条物理 MMA 命令记录，3、4 分别对应 LD 和 ST。使用者保留当前完整 id，顶层路由核对响应；manager 保存 allocated、permit 和五位使用中位图。每个使用者从一次 pin 到对应 unpin 持有同一身份，复用前必须归还。保留独立管理响应槽 94bit、pin 响应槽 62bit、仲裁游标及 epoch/closed 控制。

<a id="alloc-admission"></a>

### 分配和释放

前端在各 warp 程序序允许的候选间公平选择。ALLOC 仅在 credit 有效时参加选择；占用期间，其他 warp 的 DEALLOC 和 RELINQUISH 仍能取得同一入口。单入口已有 held 命令时保持至 fire。下一条 ALLOC 的选择使用前一条提交后的占用状态。软件在本 epoch 的最后一次 ALLOC 后才可释放 permit，此后 credit 保持 0 至下一 epoch。

管理、pin 与 unpin 在可提交的候选间轮询，每沿最多提交一笔。响应槽可在旧结果被消费的沿接替。ALLOC 握手置 allocated，返回 base=0。前端在发 ALLOC 前预留 id、SMEM [dst] 和写回位置，实际发出一次 32bit SMEM 弱写并等待成功确认，保证后继同址读的顺序。RELINQUISH 清 permit，已有分配继续可用。软件在旧访问结束后发 DEALLOC。manager 在管理接受沿检查已分配且五个引用位全零，成功则清 allocated。若仍有引用，在预留的管理响应槽返回 INVALID，保留分配和使用位。无活动分配、重复释放、错 epoch 或非法内部使用者按[故障合同](../top/blackwell_async_subsystem_top.md#common-protocol)处理。

### 取得引用、时序与生命周期

各引擎在 pin 前以扩展位宽检查本命令实际访问的 lane/column 范围、布局及对齐。pin 提交要求已分配、来源与 user 匹配且该位空闲，置位并返回原 id、OK。发出 unpin 的引擎用本条活动记录驱动原 id 和固定 user；manager 检查该来源可用的 user 编码、epoch 和使用位，在 fire 沿清位；其 ready 独立于管理及 pin 响应。请求在 a 沿提交后最早 a+1 消费响应，unpin.fire 本沿归还。正常 stop 允许旧命令取得和归还引用。

同步复位清占用位、引用和响应 valid，置 closed。合法新 epoch 开放时置 permit。顶层正常关闭在 flush 和 ordering 完成后发 epoch_end；本模块仅在无引用、held 响应和同沿控制提交时接受，清 allocated/permit 并封闭旧 epoch。静态分配可以由 epoch_end 收回。

验收以 F1/F2 的 512 列申请检查同址 SMEM 读取得 base=0；在旧引用晚归还时保持分配，随后 DEALLOC 允许等待的另一 warp ALLOC 取得整块。核对五个使用者独立归还，管理或 pin 响应背压期间 unpin 仍能前进。
