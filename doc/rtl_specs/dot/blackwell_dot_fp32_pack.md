# blackwell_dot_fp32_pack

## Description

组合编码器将末级归约结果 `sum×2^base_exp` 或特殊值编码为 FP32。参数为 `SUM_W≥24, EXP_W≥2, CANONICAL_ZERO=1`。

| 信号 / 通道 | 方向 | 类型 / 位宽 | 对端 | 握手或采样条件 |
| --- | --- | --- | --- | --- |
| sum | 入 | signed[SUM_W] | 父级归约 | 组合，有限和 |
| base_exp | 入 | signed[EXP_W] | 父级对齐控制 | 组合，与 sum 同组 |
| special_valid | 入 | 1 bit | 父级特殊值逻辑 | 组合选择 special_result |
| special_result | 入 | bits[32] | 父级特殊值逻辑 | special_valid 为 1 时采用 |
| result | 出 | bits[32] | 父级结果级 | 组合输出，无时钟或握手 |

## Functionality

sum=0输出+0。其他有限数令s为符号、a为精确绝对值（临时SUM_W+1bit避免最负值溢出），h=floor(log2 a)，e=base_exp+h。当 h≥23 时 sig24=a>>(h−23)，当 h<23 时 sig24=a<<(23−h)。两种情况的最高有效位均在 bit 23。舍去的低位不进位。

- e>127：带符号Inf。
- −126≤e≤127：exp=e+127，fraction=sig24低23bit。
- −149≤e<−126：exp=0，fraction=(sig24>>(−126−e))低23bit。
- e<−149：带符号0；CANONICAL_ZERO=1时改为+0。
- special_valid=1：返回special_result，覆盖以上计算。

F16/低精度取 CANONICAL_ZERO=1，FP4 取 0；精确抵消均输出 +0。

无新增流水，结果由父模块末级捕获。验证 sum=3、base_exp=0 必须输出 0x40400000，及负2的幂、最负sum、normal/subnormal边界、e=−149/−150、e=127/128及special覆盖。

取 sum=2^24+3、base_exp=−24，保留的 24 位有效数应为 0x800001，FP32 输出 0x3f800001。被移出的 1 不进位。

<a id="numeric-contract"></a>

### 公共浮点最终结果规则

FP32 的 exponent/fraction 分别为 8/23 bit，bias=127。exp 全 1 时，frac=0 为 Inf，frac 非零为 NaN。有限值解码见各叶模块。

有限数按上文截断，上溢到 Inf 是项目规定的结果。

任一NaN、0×Inf、相反符号Inf参与求和产生canonical FP32 NaN `0x7fffffff`；仅单一符号Inf产生该Inf。先判所有特殊值，再选有限求和结果。scale NaN和scale为零与Inf的组合遵循同样规则。

完整整数归约后再编码。以 −5 的幅值右移一位并恢复符号为例，应得 −2。
