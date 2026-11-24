# blackwell_f4f6f8_dot

## Description

32项完整低精度dot，支持E4M3/E5M2/E3M2/E2M3/E2M1交叉及UE8M0 1X scale；64份组成一个核的低精度阵列。core 将原始元素放在各 byte 低位，阵列按行或列解码元素与 scale 后广播。

| 信号 / 通道 | 方向 | 类型 / 位宽 | 对端 | 握手或采样条件 |
| --- | --- | --- | --- | --- |
| req | 入 | a[32],b[32] 各项 `{class2,sign1,sig4,e:s5}`，c32，scale_a/scale_b 各 `{nan1,e:s8}`，共818bit | TC dot array | req.fire 捕获 S0；class 与位序见 [dot array](../tensor_core/blackwell_tc_dot_array.md) |
| rsp | 出 | result32；32bit | TC dot array | rsp.fire 交付结果 |

```mermaid
flowchart LR
  I[行列解码值 / 32乘法] --> S0[S0: product与scale]
  S0 --> E[C映射到乘积指数域 / emax]
  E --> S1[S1]
  S1 --> AL[RZ对齐]
  AL --> S2[S2: 33项]
  S2 --> R[四组8项归约]
  R --> S3[S3: 四部分和与C]
  S3 --> S4[S4: 总和]
  S4 --> S5[S5: FP32 / R_DOT]
```

## Functionality

阵列按命令 dtype 3…7 分别解码 E4M3、E5M2、E3M2、E2M3、E2M1。共同协议见 [interfaces](../top/blackwell_async_subsystem_top.md#common-protocol)，数值格式见 [输入格式](blackwell_f4f6f8_dot.md#formats)。

<a id="formats"></a>

### 输入格式与参考要求

有限值统一为 `(-1)^sign × significand × 2^exponent`。normal 为 significand=2^p+fraction、exponent=exp_field−bias−p；subnormal 为 significand=fraction、exponent=1−bias−p；零的significand=0。

| 格式 | exponent/fraction bit | bias | 特殊值 |
|---|---|---:|---|
| E4M3 | 4/3 | 7 | exp15且frac7为NaN，无Inf，其余有限 |
| E5M2 | 5/2 | 15 | exp31：frac0 Inf，否则NaN |
| E3M2 | 3/2 | 3 | 所有编码有限 |
| E2M3 | 2/3 | 1 | 所有编码有限 |
| E2M1 | 2/1 | 1 | 所有编码有限；含正负零 |

UE8M0 无 sign/fraction；0…254 表示 2^(byte−127)，255 为 NaN。
逐位参考使用整数有效数及本流水指定的截断位置。特殊值归并与 FP32 编码见 [FP32 pack](blackwell_dot_fp32_pack.md#numeric-contract)。

### 流水寄存级

| 级 | bit/dot | 内容 |
|---|---:|---|
| S0 | 605 | special33；32组sign1/product8/exp6/zero1；product emax valid1+exp10；C sign1/mag27/exp10/zero1；scale exponent10 |
| S1 | 605 | special33；32组sign1/product8/exp6/zero1；C sign1/mag27/domain_exp10/zero1；scale_exp10；emax10+valid1 |
| S2 | 967 | special33；32×signed28；C signed28；base_exp10 |
| S3 | 208 | special33；5×signed33部分和；base_exp10 |
| S4 | 76 | special33；sum33；base_exp10 |
| S5 | 32 | result32 |

合计2493bit/dot、19944B/64dot，valid另6bit/dot；tag由阵列保存。S5即R_DOT，没有额外结果缓存。

### 乘积、缩放、归约与编码

全部格式解码为`sign*sig4*2^(e−3)`；令 p 为原 fraction 位数，normal 取 sig4=((1<<p)+frac)<<(3−p)，subnormal 取 sig4=frac<<(3−p)，新添的低位为0。subnormal保持其有效幅值，不FTZ。叶模块将两个无符号 sig4 相乘，S0、S1 各寄存原始无符号 product8。乘积指数为两侧 e 符号扩展至 6bit 后相加。

MX 关闭时行列解码器各送 `{nan=0,e=0}`。开启时各解码器将 0…254 转为 e=byte−127，0xff 转为 `{nan=1,e=0}`。叶模块将两侧 e 扩展至 signed10 相加得 E，任一 nan 置位即产生 NaN。将C的指数变成`eC−E`，C mag27=`sig24<<2`；emax取乘积非零指数与该C指数的最大值。全部零时valid=0并输出+0。

S1→S2 的组合连线用 `{product8,19'b0}` 构成无符号 mag27，连同 S1 的 C mag27 送入对齐器。所有 mag 对齐到 emax，先幅值右移截断再加符号。base_exp=`emax−25+E`。32个signed28项分四组8项得到signed33部分和，第五部分是符号扩展后的C；下一拍归约五项。所有加法先在足够宽位计算并证明无有效输入溢出，不能在28bit内积累32项。

验收用 E2M1 0x3×0x2，其余项及 C 为零，唯一结果为 0x3fc00000。对齐级另取 E4M3 的 0x3f×0x3f，sig4 均为 15，S0/S1 的 product8 应为 225。关闭 MX、令 C=2^20 且其余乘积为零，emax 与乘积指数之差为 20，对齐后幅值为 112；翻转一侧符号得到 −112。暂停 S1 后恢复应得到相同的项。

### 结果传输与停顿

P=6；输入l捕获S0，S5在l+5后可见，最早l+6输出传输；II=1。六级独立弹性保持，复位清valid。相邻输入可切换 dtype 和 MX 模式，S0 捕获本片的乘积、特殊值和 scale 指数，后级只使用在途字段。

验证25种dtype交叉、每种有限极值/零/subnormal/NaN、E5M2 Inf、UE8M0 0/254/255及正负抵消。MX测试以完全相同定点对齐golden比较，并检查scale在有限乘积和C之间相差很大时的截断。对64lane统一阻塞和部分ready错误注入做断言。

审核起点：[现有实现](../../../rtl/dot/f4f6f8_dot_prod.sv)。

## Submodules

| 子模块 | 每个 dot 的实例数 | 连接与控制 |
| --- | --- | --- |
| [dot_emax_tree](blackwell_dot_emax_tree.md) | 2 | S0 先比较 32 个乘积，S1 合入换算到乘积域的 C。 |
| [dot_align_fixed_rz](blackwell_dot_align_fixed_rz.md) | 33 | 32 个乘积与一个 C 分别对齐，在 S2 捕获。 |
| [dot_signed_reduce_tree](blackwell_dot_signed_reduce_tree.md) | 5 | 四棵八项树形成部分和，末树归约四个部分和及 C。 |
| [dot_fp32_pack](blackwell_dot_fp32_pack.md) | 1 | S4 的和与指数生成 S5 结果。 |
| [pipeline_reg](../base/blackwell_pipeline_reg.md) | 6 | S0…S5 各一级，各级保持表中已捕获的字段。 |
