# blackwell_mbarrier_backing

## Description

将对象cache的8B装入/写回转换为共享SMEM fabric上的16B masked事务。模块不保存另一套对象cache，不自行修改计数。接口规则见[common](../top/blackwell_async_subsystem_top.md#common-protocol)，对象见[mbarrier_object](blackwell_mbarrier_unit.md#object)，事务见[memory_transaction](../top/blackwell_async_subsystem_top.md#memory-routing)。

| 信号 / 通道 | 方向 | 类型 / 位宽 | 对端 | 握手或采样条件 |
| --- | --- | --- | --- | --- |
| `back_req` | 入 | [bar_back_req_t](#backing-types)，97 | 对象 unit | 单个对象读或写 |
| `back_rsp` | 出 | [bar_back_rsp_t](#backing-types)，68 | 对象 unit | 成功读返回8B，写返回value=0 |
| `smem_req` | 出 | [smem_atom_req_t](../smem/blackwell_smem_fabric.md#transactions)，255 | SMEM fabric | client=11，16B对齐 |
| `smem_rsp` | 入 | [smem_atom_rsp_t](../smem/blackwell_smem_fabric.md#transactions)，211 | SMEM fabric | 只接受当前live tag |
| `epoch` | 入 | 16bit静态配置 | 顶层 | 仅排空后改变 |
| `stop` | 入 | 1 | 顶层 | 排空指示，不gate内部back_req |
| `drained` | 出 | 1 | 顶层 | 无请求、外部在途或held返回 |
| `fault` | 出 | 1 sticky | 顶层 | 外部协议错误，复位清除 |

```mermaid
flowchart LR
  C[对象cache] --> R[R_REQ: addr/value/write]
  R --> A[16B地址与8B mask生成]
  A --> S[共享SMEM fabric]
  S --> V[tag与status检查]
  V --> O[R_RSP: 8B/status]
  O --> C
```

## Functionality

<a id="backing-types"></a>

### Backing 内部类型

`bar_back_req_t={write:1,addr:32,value:64}`，97bit；`bar_back_rsp_t={status:4,value:64}`，68bit。仅一笔在途，SMEM 请求仍带完整 token。

### 保留请求与结果位置

| 项目 | 容量 | 唯一用途 |
|---|---:|---|
| R_REQ | 97bit | 接受的对象操作，保持至外部完成 |
| R_RSP | 68bit | 回给unit的结果 |
| live tag | 78bit | 关联唯一外部事务 |
| token counter | 16bit | 当前client内递增token |
| 状态/valid/fault | 少量控制 | 不保存第二份128bit数据返回 |

只有一笔外部事务在途。读返回在握手边沿直接抽取需要的64bit进入R_RSP；不增加整行backup。接口支持输出背压，因此收到外部读返回前必须已预留R_RSP。

状态为 EMPTY、ISSUE、WAIT_MEM、RESP。EMPTY且无fault时可接back_req，包括stop期间为已接受操作和flush服务的请求。新请求检查范围/对齐后进入ISSUE；内部非法地址触发 fault。外部fire后WAIT_MEM；匹配返回后RESP；back_rsp消费后EMPTY。

### 地址、掩码与返回匹配

```text
line_addr = back_req.addr & ~0xf
half      = back_req.addr[3]
byte_mask = half ? 0xff00 : 0x00ff
write_data = zero_extend(value) << (half * 64)
read_value = smem_rsp.data[half*64 +: 64]
```

必须保留逻辑字节地址，SMEM fabric 以 4 B 字映射 bank，两个有效子字同沿提交。不能对邻接8B对象做read-modify-write。写ACK保证选中的8B实际提交；back_req接受本身不表示对象已保存。

`tag.client=11`，`tag.id={epoch,issuer=0,seq=0}`为此内部client的固定上下文；不代表已接受的外部命令，也不向op_done发布。token在back_rsp退休后模2^16递增，只有唯一live事务的tag不得复用。旧请求已收到最终ACK并退休后允许复用token，不能因计数器到界阻止必要flush；外部协议保证每笔请求只有一次返回。

读和写返回的write位必须与R_REQ一致，tag必须完全相等。其他client返回不能路由到本模块；若仍出现未知tag/write不符，消费并置fault，不将其误用为当前事务结果。错误恢复须按顶层合同隔离复位。

### 从请求到响应

设对象请求在边沿g接受，SMEM请求最早g+1被接受。SMEM服务延迟由fabric定义；匹配返回在边沿r接受，back_rsp最早r+1被消费。每笔最多一个外部请求和一个内部返回。

非 OK 读返回或写 ACK 直接触发 fault，禁止产生成功 back_rsp。只有实际成功的写 ACK 才可使 unit 清 dirty 或释放 victim。

INVAL和flush必须等此处成功写响应，不只等smem_req fire。普通dirty对象的本地计数更新不必等待此模块空闲，直到需要驱逐或显式flush时才保存。

### 仲裁与停顿

back_req及其收尾均不受stop影响；新的外部操作在frontend被阻止。WAIT_MEM始终给正确返回保留承接位置；back_rsp阻塞只阻止下一笔对象请求。

fabric的其他客户端可以同时使用无冲突bank。mbarrier无全SMEM独占权。其最终进展以fabric公平仲裁、外部返回最终到达及unit最终消费back_rsp为条件。

在unit flush期间，依次处理至多4个dirty项；各项写ACK分别确认。失败项及尚未保存项继续dirty，flush不得返回OK。

### 复位与异常

同步复位清状态、valid、fault和计数器，不修改SMEM。复位前保证外部事务取消或隔离，复位后旧tag不得重新进入。

内部请求地址不对齐或越界报 fault，不发外部事务。后端epoch变化而非EMPTY属于PROTOCOL；集成必须先观察drained。

正常epoch变更只在EMPTY、无held返回且无fault时清token counter并建立新上下文；不清SMEM。前一epoch的合法返回必须已退休，不能靠新epoch比较将其丢弃。

### 断言与验收

保持同一 16 B 行的两个 8 B 对象交错读写，暂停请求及返回，核对每个 back_req 只结算一次，未选半行保持。向返回注入错误 tag、方向或 MEMORY，检查 dirty victim 在成功写 ACK 前仍由 unit 持有。
