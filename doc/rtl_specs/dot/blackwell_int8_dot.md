# blackwell_int8_dot

## Description

32项S8/U8完整整数dot加S32 C；A/B signedness独立。64份组成每核整数阵列。逻辑K=32，全部项一次归约。

| 信号 / 通道 | 方向 | 类型 / 位宽 | 对端 | 握手或采样条件 |
| --- | --- | --- | --- | --- |
| req | 入 | a[32],b[32] 各项 signed9，c32,saturate1，共609bit | TC dot array | req.fire 捕获 S0；元素 k=0 占低 9bit |
| rsp | 出 | result32,overflow1；33bit | TC dot array | rsp.fire 交付结果 |

```mermaid
flowchart LR
  I[行列广播的 signed9] --> M[32个9x9乘法]
  M --> S0[S0: 32个signed18乘积]
  S0 --> T[平衡树归约至signed22]
  T --> S1[S1: psum / C / saturate]
  S1 --> A[扩展加C / overflow / clamp]
  A --> S2[S2: result / R_DOT]
```

## Functionality

遵循 [公共协议](../top/blackwell_async_subsystem_top.md#common-protocol)。overflow是最终无限精度整数结果超出S32范围的指示，不因saturate关闭而消失。

### 扩展操作数、归约与饱和

阵列按行、列各自的 dtype 将 S8 符号扩展、U8 零扩展至 signed9。叶模块将对应两项相乘，得到 signed18。32项先符号扩展到22bit再归约。C符号扩展为33bit，与psum相加；有效值范围保证33bit足够。饱和开启时限制到[−2^31,2^31−1]，关闭时取低32bit；只在最终结果处饱和。

| 级 | payload bit | 内容 |
|---|---:|---|
| S0 | 609 | 32×signed18,C32,saturate1 |
| S1 | 55 | psum22,C32,saturate1 |
| S2 | 33 | result32,overflow1 |

合计697bit/dot、5576B/核，valid另3bit/dot。S2 是结果寄存级。

取 A 的低两个 byte 为 0xff、0x01，B 为 0x02、0x03，其余项为零，C=4。A 为 S8、B 为 U8 时结果是 5；仅把 A 改为 U8 后结果是 517。

### 结果传输与停顿

输入fire l捕获S0，R_DOT在l+2后可见，最早l+3传输；P=3、II=1。三个独立弹性级，无额外R_DOT寄存；下游停顿不得覆盖任何级。复位清valid。

测试四种signedness组合、0xff在signed/unsigned解释上的差别、±极限C、正负overflow、饱和与wrap、抵消及随机背压。golden用至少64bit有符号整数求和，最终再施加S32规则；不能用逐项S32 wrap或逐项饱和。

审核起点：[现有实现](../../../rtl/dot/int8_dot_prod.sv)，周期以本规格的实际边沿为准。

## Submodules

| 子模块 | 每个 dot 的实例数 | 连接与控制 |
| --- | --- | --- |
| [pipeline_reg](../base/blackwell_pipeline_reg.md) | 3 | S0 捕获乘积，S1 捕获部分和，S2 捕获含 overflow 的结果。 |
