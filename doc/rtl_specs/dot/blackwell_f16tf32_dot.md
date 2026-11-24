# blackwell_f16tf32_dot

## Description

一个完整FP16/BF16 dot16或TF32 dot8，执行`C_eff+ΣA*B`。每核阵列实例化64份；TF32只启用前8项，其余项不参与special或emax。core 按逻辑 K 解包，[dot array](../tensor_core/blackwell_tc_dot_array.md) 施加 negate，按行或列解码后广播。数值格式见 [输入格式](blackwell_f16tf32_dot.md#formats)。

| 信号 / 通道 | 方向 | 类型 / 位宽 | 对端 | 握手或采样条件 |
| --- | --- | --- | --- | --- |
| req | 入 | a[16],b[16] 各项 `{class2,sign1,sig11,e:s8}`，c32,scale_input_d4，共740bit | TC dot array | req.fire 捕获 S0；class 与元素位序见 [dot array](../tensor_core/blackwell_tc_dot_array.md) |
| rsp | 出 | result32，32bit | TC dot array | rsp.fire 交付结果。FP32结果 |

```mermaid
flowchart LR
  A[输入] --> C[行列解码值 / C预缩放 / 16乘法 / emax]
  C --> S0[S0: product]
  S0 --> S1[S1: product]
  S1 --> AL[幅值RZ对齐]
  AL --> S2[S2: 17个对齐项]
  S2 --> RT[17项有符号归约]
  RT --> S3[S3: sum]
  S3 --> PK[FP32编码]
  PK --> S4[S4: R_DOT]
```

## Functionality

clk/rst_n和valid/ready按 [公共约定](../top/blackwell_async_subsystem_top.md#common-protocol)。type组合由上游检查，非法值不进入本模块。FP16/BF16用16bit元素，TF32用32bit容器。

<a id="formats"></a>

### 输入格式与参考要求

有限值统一为 `(-1)^sign × significand × 2^exponent`。normal 为 significand=2^p+fraction、exponent=exp_field−bias−p；subnormal 为 significand=fraction、exponent=1−bias−p；零的significand=0。

| 格式 | exponent/fraction bit | bias | 特殊值 |
|---|---|---:|---|
| FP16 | 5/10 | 15 | exp全1：frac0 Inf，否则NaN |
| BF16 | 8/7 | 127 | 同上 |
| TF32容器 | FP32容器，计算保留10 fraction bit | 127 | 先用完整FP32 fraction识别NaN，再截断低13bit |

逐位参考使用整数有效数及本流水指定的截断位置。特殊值归并与 FP32 编码见 [FP32 pack](blackwell_dot_fp32_pack.md#numeric-contract)。

### 流水寄存级

五个独立弹性寄存级，没有额外输出寄存。S1 寄存 S0 的乘积并隔开对齐级，透传也占一拍。

| 级 | 每dot payload | 字段 |
|---|---:|---|
| S0/S1，各 | 574bit | special2；16×(sign1,sig22,exp9,zero1)；emax9；C(sign1,sig24,exp9,zero1) |
| S2 | 572bit | special2；16×signed33 product；signed33 C；emax signed9 |
| S3 | 44bit | special2；sum signed33；emax signed9 |
| S4 | 32bit | result32 |

数据合计1796bit/dot，64份14368B；每份5个valid，共40B/核。微块tag只在阵列管理的同级tag链保存，不在64份叶模块复制。

### 解码、对齐、归约与编码

行列解码器输出的有限值为`sign*sig11*2^(e−10)`：FP16的normal sig=1024+frac、e=exp−15，subnormal sig=frac、e=−14；BF16的sig=(128+frac)<<3或subnormal frac<<3，e=exp−127或−126；TF32截取FP32 fraction高10bit，e同FP32，NaN判定仍看完整23bit fraction。TF32 指数字段和高 10 位 fraction 均为零时归入零类。TF32 的第 8…15 项在 A/B 两侧均填 +0。

1. C先计算`C_eff=C*2^(-scale_input_d)`：normal调整指数；进入subnormal时对无符号significand右移截断；原subnormal直接右移fraction；Inf/NaN/零保持。此预处理在FP32容器内执行，沿用现有算法。
2. 精确11×11乘法得到sig22，指数为两个 e 符号扩展至 9bit 后相加。C解码为sig24、eC，其中normal有效值为sig24×2^(eC−23)。emax只从非零有限乘积/C取最大指数；全部零时取−256，结果强制+0。
3. product幅值=`sig22<<5`，C幅值=`sig24<<2`，各按emax−e右移。大于等于32的移位得到0，再按sign转signed33；S2/S3继续保存emax，不在9bit内计算base_exp。
4. 17项在signed33内相加，乘积最多16项，不做中间FP32舍入；归约树奇数项补0。有效输入幅值上界保证该位宽不溢出。
5. S4前先将emax符号扩展至10bit，再计算`base_exp=sext10(emax)−25`，用于FP32编码。BF16最小normal乘积的emax=−252、base_exp=−277；先做9bit减法再扩展会溢出，这是现有算法实现中须纠正的位宽问题。S3→S4 仅捕获最终 32bit 编码。NaN/Inf优先规则按对象，不让special参与有限emax。

只在 k=1 放 FP16 的 A=2、B=3，C=1、scale_input_d=0。令阵列施加 negate_a，req 的该项 A 应为 −2，叶模块结果为 −5（0xc0a00000）。

### 结果传输与停顿

输入fire在l捕获S0，无停顿时S4在l+4后可见，最早l+5传输；P=5、II=1。下游阻塞逐级向前传播，各级满且不能前进时payload保持。复位只清5个valid。

验证所有FP16/BF16交叉、TF32低13bit含NaN信息、最大/最小normal、subnormal、精确抵消、Inf符号冲突和C预缩放下溢。逐位golden须按上述定点顺序实现，不使用逐项host浮点加法替代。随机暂停检查连续请求无丢失/重复，并核对S4结果与输入tag逐拍对应。

现有算术实现见 [f16tf32_dot_prod.sv](../../../rtl/dot/f16tf32_dot_prod.sv)。

## Submodules

| 子模块 | 每个 dot 的实例数 | 连接与控制 |
| --- | --- | --- |
| [dot_emax_tree](blackwell_dot_emax_tree.md) | 1 | S0 在有效乘积和 C 中选最大指数。 |
| [dot_align_fixed_rz](blackwell_dot_align_fixed_rz.md) | 17 | S2 对齐 16 个乘积和一个 C。 |
| [dot_signed_reduce_tree](blackwell_dot_signed_reduce_tree.md) | 1 | 17 项归约后在 S3 捕获 signed33。 |
| [dot_fp32_pack](blackwell_dot_fp32_pack.md) | 1 | 用扩展后的 base_exp 编码，在 S4 捕获。 |
| [pipeline_reg](../base/blackwell_pipeline_reg.md) | 5 | S0…S4 各一级，逐级传递背压。 |
