# blackwell_fp4_dot

## Description

64项E2M1完整dot，先形成四个16项组，再应用组scale并与FP32 C累加。每核64份；输出32bit FP32。

| 信号 / 通道 | 方向 | 类型 / 位宽 | 对端 | 握手或采样条件 |
| --- | --- | --- | --- | --- |
| req | 入 | a[64],b[64] 各项 `{sign1,q4}`，c32，scale_a[4],scale_b[4] 各项 `{nan1,sig4,e:s9}`，共784bit | TC dot array | req.fire 捕获 S0；各侧元素按 k、scale 按 16 项组 h 从低位起排 |
| rsp | 出 | result32 | TC dot array | rsp.fire 交付结果 |

时钟、复位及通道的采样约定见[顶层公共协议](../top/blackwell_async_subsystem_top.md#common-protocol)。

```mermaid
flowchart LR
  I[64个FP4乘积 / 四组归约 / 两侧scale相乘] --> S0[S0: sigma与scale]
  S0 --> G[组scale乘法 / emax]
  G --> S1[S1: gamma]
  S1 --> S2[S2: 4组与C对齐]
  S2 --> S3[S3: signed sum]
  S3 --> S4[S4: FP32 / R_DOT]
```

## Functionality

阵列对 NVFP4/UE4M3 每 16 项解码一个 scale，对 MXFP4/UE8M0 每 32 项解码一个 scale。组内公共 scale 的放置由 [scale布局](../tensor_core/blackwell_tc_scale_b_snapshot.md#scale-layout) 定义。

<a id="formats"></a>

### FP4 与 scale 特殊值

E2M1 与 UE8M0 的编码见[低精度输入格式](blackwell_f4f6f8_dot.md#formats)。UE4M3 忽略最高位，按正 E4M3 解码，低七位 0x7f 为 NaN。special归并见 [FP32 pack](blackwell_dot_fp32_pack.md#numeric-contract)。

### 流水寄存级

| 级 | bit/dot | payload |
|---|---:|---|
| S0 | 192 | special33；4×sigma13；4×scale product8；4×scale exponent10；C sign1/sig24/relative_exp10 |
| S1 | 202 | special33；4×sign1/mag20/exp10；C sign1/sig24/exp10；emax10 |
| S2 | 278 | special33；4×signed47 gamma；signed47 C；base_exp10 |
| S3 | 93 | special33；sign1、abs_sum49、base_exp10 |
| S4 | 32 | result32 |

合计797bit/dot、6376B/核；valid另5bit/dot。S4直接是R_DOT。

### 组内乘积、组间缩放与归约

阵列输出的 E2M1 幅值的二倍 q 按编码0…7取`{0,1,2,3,4,6,8,12}`，符号另取。每组sigma为16个signed(qA*qB)之和，13bit；该值代表真实未scale和的4倍。

Scale解释为`sig4*2^e`：UE8M0的sig=8,e=byte−130；UE4M3忽略最高bit，normal sig=8+frac,e=exp−10，subnormal sig=frac,e=−9，零sig=0且e=−129。NaN见 [输入格式](blackwell_fp4_dot.md#formats)。

原始因子按逻辑 g 紧凑排列。对每行或列，阵列将 UE4M3 的第 h 个解码结果送 req 的第 h 组；UE8M0 的第 g 个解码结果同时送第 2g 和 2g+1 组。叶模块逐组取 A、B 的 scale，相乘前将两侧 e 符号扩展至 10bit 再求和。任一所用 scale 的 nan 置位即产生 NaN。

每组`gamma_mag=abs(sigma)*sigA*sigB`（20bit），`gamma_exp=eA+eB`；符号为sigma符号。C解码成sign、sig24及真实整数有效数指数eC（normal exp_field−150，subnormal−149）；C相对指数为`eC+17`。

emax取非零gamma的gamma_exp及非零C的相对指数最大值；全部零使用0。对gamma先左移27、C有效数左移12，再按emax减各相对指数做幅值RZ对齐，形成signed47。四组与C以signed49求和，`base_exp=emax−29`。最后按FP32 pack规则编码，不在组间做FP32舍入。

令 A=B 全 1，SA=(1,2,4,8)、SB 全 1、C=−1，UE4M3 4X 应产生 239（0x436f0000）。

### 结果传输与停顿

P=5；输入l捕获S0，R_DOT在l+4后可见，下一沿可输出；II=1。每级独立弹性保持，复位清valid。验证全部FP4输入编码、两个有效mode、UE4M3 zero/subnormal/NaN、高位忽略、UE8M0边界、组抵消与C极大指数差。每组sigma与gamma都要与整数golden比较以定位舍入阶段。

审核起点：[现有实现](../../../rtl/dot/fp4_dot_prod.sv)。

## Submodules

| 子模块 | 每个 dot 的实例数 | 连接与控制 |
| --- | --- | --- |
| [pipeline_reg](../base/blackwell_pipeline_reg.md) | 5 | 按上表位宽连接 S0…S4；分组乘加、缩放和 FP32 编码位于级间组合逻辑。 |
