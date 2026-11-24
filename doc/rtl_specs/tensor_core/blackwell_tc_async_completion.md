# blackwell_tc_async_completion

## Description

一条 R_COMMIT 将已满足截止集合的 commit 转为一次 barrier arrival。软件消费结果后向 tracker 归还原槽。

| 信号 / 通道 | 方向 | 类型 / 位宽 | 对端 | 握手或采样条件 |
| --- | --- | --- | --- | --- |
| `ready_commit` | 入 | [tc_ready_commit_t](blackwell_tc_completion_tracker.md#commit-contract)，93 | TC tracker | pending=0 且 issuer 顺序允许 |
| `tc_bar_req` | 出 | [tc_bar_req_t](../mbarrier/blackwell_mbarrier_frontend.md#command)，90 | barrier frontend | `{id:58,addr:32}`，固定 ARRIVE(1) |
| `tc_bar_rsp` | 入 | [op_done_t](../top/blackwell_async_subsystem_top.md#identity)，62 | barrier frontend | OK 表示对象已原子更新，异常触发 fault |
| `commit_done` | 出 | op_done_t，62 | 软件前端 | 软件可消费的commit结果 |
| `commit_retire` | 出 | [tc_commit_retire_t](blackwell_tc_completion_tracker.md#commit-contract)，61 | TC tracker | `{slot:3,id:58}`，释放tracker槽 |
| `epoch/stop` | 入 | 16/1 | 顶层 | 当前CTA/排空指示，内部ready_commit继续接受 |
| `drained/fault` | 出 | 各1 | 顶层 | 无持有事务或结果/响应协议故障 |

## Functionality

R_COMMIT 保存 ready_commit 的 93bit 与 FSM，barrier 返回、软件 done 和 retire 复用该记录。接受时预留结果，barrier 响应独立于软件 ready。

### 接收、arrival、响应与退休

| 状态 | 动作 | 转移条件 |
|---|---|---|
| EMPTY | ready_commit_ready=无fault | 接受后SEND |
| SEND | 输出唯一tc_bar_req | fire后WAIT_BAR |
| WAIT_BAR | 核对 tc_bar_rsp 的完整 id 和状态 | 匹配 OK 进入 DONE，异常触发运行故障 |
| DONE | 保持commit_done | 消费后RETIRE |
| RETIRE | 保持旧 commit_retire；若本沿 retire.fire，可同时接收新 ready_commit | 替换则 SEND，否则 EMPTY |

SEND 的 id 和地址保持到 fire，随后只等匹配响应。每个 commit 在正常执行中仅发一次 ARRIVE(1)。

### 原子更新与可见性

普通arrival count固定1，tx-count不变。ready_commit出现之前，覆盖MMA已经完成全部实际写ACK退休；该条件来自tracker，不能由bridge自行放松。

成功的 tc_bar_rsp 表示 cache 内 arrival 已原子提交，可能翻转 phase 并唤醒 wait。dirty 对象由 cache 持有到写回。

软件通过 `mbarrier.try_wait.parity` 观察 phase。成功观察还须取得 acquire ACK，随后才向软件返回 true。[wait 与 acquire](../mbarrier/blackwell_mbarrier_wait.md)

### 时序

ready_commit 在 g 接受，tc_bar_req 最早 g+1。bar_rsp 在 r 接受，commit_done 最早 r+1 交付，retire 最早 r+2 交付；该沿可采样下一个已合格的 ready_commit，用旧寄存器值输出旧 retire。

若commit_done背压，tracker槽仍保留，保证同issuer后续commit不越过此结果。不同issuer的已接受操作可以继续执行/完成；tracker最终容量满时才反压新命令。

retire 被阻时保持 R_COMMIT；其 ready 由 tracker 对旧 slot/id 的匹配决定，独立于新 ready_commit。不同 issuer 的已就绪记录可同沿接替；同 issuer 仍受 tracker 中较老 commit 的顺序门控。

### 复位与验收

正常 stop 继续接收已登记的 commit。EMPTY 且无 held 输出时 drained；仅在该条件下正常换 epoch。同步复位清 FSM/valid。未知或非 OK 响应触发[顶层故障](../top/blackwell_async_subsystem_top.md#common-protocol)。检查每个成功 commit 恰好产生一次对象请求、软件 done 和 retire，结果背压期间同 issuer 保序。
