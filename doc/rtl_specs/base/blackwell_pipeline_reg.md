# blackwell_pipeline_reg

## Description

本模块连接流水线相邻两级。一个 `WIDTH≥1` 位数据寄存器和一个有效位组成深度为一的弹性级。

| 信号 / 通道 | 方向 | 类型 / 位宽 | 对端 | 握手或采样条件 |
| --- | --- | --- | --- | --- |
| in | 入 | bits[WIDTH] | 上游 | in.fire 捕获输入 |
| out | 出 | bits[WIDTH] | 下游 | out.fire 消费已寄存的输出 |

时钟、复位及通道的采样约定见[顶层公共协议](../top/blackwell_async_subsystem_top.md#common-protocol)。

## Functionality

沿前 out_valid=valid_q，out_payload=payload_q，`in_ready=!valid_q || out_ready`。上升沿先判同步复位并清 valid；否则仅在 in_ready 时令 valid_q=in_valid，且 in_valid 为 1 时装入 payload。out.fire 与 in.fire 同沿时下游取旧值，沿后保存新值。

输入在t接受，t后输出可见，最早t+1传输；可持续每拍一项。无fall-through组合数据路径，不增加backup。复位不清payload。检查empty、满且暂停、同拍出入及valid稳定性；父模块须避免组合ready环。
