# blackwell_fifo

## Description

本模块在生产者与消费者之间按接受顺序交付数据。同步 FIFO 的参数为 `WIDTH≥1, DEPTH≥1`，队首由寄存器阵列组合读出。

| 信号 / 通道 | 方向 | 类型 / 位宽 | 对端 | 握手或采样条件 |
| --- | --- | --- | --- | --- |
| push | 入 | bits[WIDTH] | 上游 | push.fire 写入队尾 |
| pop | 出 | bits[WIDTH] | 下游 | pop.fire 取沿前队首 |
| occupancy | 出 | ceil(log2(DEPTH+1)) bit | 父模块 | 当前已占项数 |

时钟、复位及通道的采样约定见[顶层公共协议](../top/blackwell_async_subsystem_top.md#common-protocol)。

## Functionality

状态为DEPTH×WIDTH payload、两个`max(1,ceil(log2 DEPTH))`指针及占用计数。push.fire 推进写指针，pop.fire 推进读指针，各自在 DEPTH−1 后回到 0，包含非 2 次幂深度。

`pop_valid=count!=0`，`push_ready=count<DEPTH || pop_fire`。空FIFO没有push→pop旁路；同拍满队列pop与push必须先读出旧head语义，再写新tail。`count_next=count+push_fire−pop_fire`。复位清指针/count，不清payload。

沿 t 入队时，即使 FIFO 原为空，也最早在 t+1 出队。连续握手时 II=1。pop暂停期间head不变。断言0≤count≤DEPTH、push/pop顺序一致、满时无覆盖；测试DEPTH=1和非2次幂。用于大payload的实例必须按实际DEPTH×WIDTH计容，不能当零成本控制FIFO。
