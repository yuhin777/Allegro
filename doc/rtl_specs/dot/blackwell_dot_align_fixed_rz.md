# blackwell_dot_align_fixed_rz

## Description

组合幅值对齐器，先右移无符号幅值再施加符号，实现toward-zero。参数`MAG_W≥1, TERM_W=MAG_W+1, EXP_W≥2`。

| 信号 / 通道 | 方向 | 类型 / 位宽 | 对端 | 握手或采样条件 |
| --- | --- | --- | --- | --- |
| term_valid, term_sign | 入 | 各1bit | dot 对齐级 | 组合有效及符号 |
| term_mag | 入 | unsigned MAG_W | dot 对齐级 | 组合无符号幅值 |
| term_exp, emax | 入 | 各signed EXP_W | dot 对齐级 | 组合有符号指数 |
| term | 出 | signed TERM_W | dot 对齐级 | 组合输出对齐项 |

## Functionality

`d=emax−term_exp`在EXP_W+1位求差。有效输入要求d≥0；d≥MAG_W得到0，否则q=term_mag>>d。输出为`term_sign ? -signed({0,q}) : signed({0,q})`。无效输入输出0。负d属于上游内部协议错误，仿真assert，不通过截断差值制造极大右移。

无寄存、零周期边界；输入定点小数位由父模块左移幅值时定义。验证负数奇数幅值、d=0/MAG_W−1/MAG_W及invalid。不能将`signed_negative >>> d`作为等价实现，因为它向负无穷舍入。
