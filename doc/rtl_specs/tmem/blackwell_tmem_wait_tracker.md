# blackwell_tmem_wait_tracker

## Description

32 条 live 记录从 LD/ST 登记跟踪到普通 done 消费后的 complete。一个 ST wait 快照只等待其截止前同 warp 尚未 complete 的 ST。

| 信号 / 通道 | 方向、类型 / 位宽 | 对端 | 握手或采样条件 |
| --- | --- | --- | --- |
| `alloc` | 入，[rf_track_alloc_t](#wait-types)，59bit | 顶层 R_RF_ISSUE | `{id:58,store:1}`，在引擎执行之前登记。 |
| `slot` | 出，[rf_track_slot_t](#wait-types)，63bit | 顶层 R_RF_ISSUE | 原id与5bit live槽号。 |
| `complete` | 入，[rf_track_done_t](#wait-types)，67bit | LD/ST engine | `{slot:5,id:58,status:4}`；普通done已消费后送入。 |
| `wait_cmd` | 入，[tmem_wait_cmd_t](#wait-types)，58bit | 软件前端 | 捕获本warp截止前的 ST。 |
| `wait_done` | 出，[op_done_t](../top/blackwell_async_subsystem_top.md#identity)，62bit | 软件前端 | pending 归零后发布 `{id,OK}`。 |
| `epoch_i` | 入，16bit，无握手 | 顶层 | 当前CTA生命周期。 |
| `stop_i` | 入，1bit | 顶层 | 停止接受新的 alloc/wait，已登记的 slot、complete 和结果继续。 |
| `drained_o` / `fault_o` | 出，各1bit | 顶层 | live/wait/slot 和 held 输出全空 / 运行故障。 |

## Functionality

RF/wait命令的issuer低5bit须0。warp由issuer[9:5]决定，不用warp%4代替身份；warp%4只用于TMEM物理RF分区。

<a id="wait-types"></a>

### Wait 与内部登记类型

| 类型 | 字段（从高到低） | 位数 |
|---|---|---:|
| `tmem_wait_cmd_t` | id58 | 58 |
| `rf_track_alloc_t` | id58, store1 | 59 |
| `rf_track_slot_t` | id58, slot5 | 63 |
| `rf_track_done_t` | slot5, id58, status4 | 67 |

软件 wait 的返回类型为 op_done_t。LD 与 ST 的实际数据完成沿由 [LDST engine](blackwell_tmem_ldst_engine.md) 定义。

### 登记与截止

32 条 live 行各含 valid1、id58、store1。alloc.fire 选择最低空槽，同时预留 slot 返回（索引5、valid1，id 来自原行）。slot 消费前暂停下一次 alloc。顶层收到 slot 后向引擎发令。表满时 complete 和 wait 仍能握手。

引擎在最后一次 LD RF 写回或 ST 实际写 ACK 完成后归还 pin，输出普通 done。普通 done 消费后才发送 complete；同一拍匹配 slot 和完整 id 的 OK complete 清对应 wait.pending 并释放 live 行，下一沿可复用。普通 done 的 ready 独立于 wait_done，避免二者互等。非 OK 或不匹配走[运行故障](../top/blackwell_async_subsystem_top.md#common-protocol)。

一条 wait 记录含 valid1、id58、pending32，共 91bit。wait_cmd.fire 捕获沿前同 epoch、同 warp 的 live ST，扣除同沿 complete 的旧槽；排除 LD 和同沿新 alloc。后续分配不能扩张该集合。pending 为零最早下一沿交付 OK（包括空集合）；背压保持 wait_done 至消费。一个 wait 忙时暂停新 wait，其他可用槽的 LD/ST 可继续登记与完成。

正常 stop 阻止新外部命令，旧 complete、slot 和结果继续。同步复位清 valid 和选择；正常换 epoch 要求 drained。验收覆盖已消费 64 条 ST 后的空 wait、同沿 alloc/complete/wait、不同 warp、LD 排除及两个返回口独立背压。
