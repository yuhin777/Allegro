# blackwell_dot_signed_reduce_tree

## Description

组合平衡树对父级提供的有符号定点项求和。参数为 `TERM_N≥1, TERM_W≥1, SUM_W≥TERM_W`。

| 信号 / 通道 | 方向 | 类型 / 位宽 | 对端 | 握手或采样条件 |
| --- | --- | --- | --- | --- |
| term[TERM_N] | 入 | 每项 signed[TERM_W] | 父级定点通路 | 组合，项 0 位于低索引 |
| sum | 出 | signed[SUM_W] | 父级结果级 | 组合，无时钟或握手 |

## Functionality

各项先符号扩展到 SUM_W，再在该位宽内逐层相加。通用无溢出选择`SUM_W=TERM_W+ceil(log2 TERM_N)`；dot允许根据有效幅值证明缩小位宽，证明和参数由父模块规格给出。若数学和超出SUM_W，输出取二进制低SUM_W位；产品合法输入必须用断言证明不会进入该情况，不通过此行为实现饱和。

输入顺序为低索引对相邻项；N=1直连符号扩展，奇数项补 0，共 ceil(log2 TERM_N) 层。无中间FP舍入、无内部寄存。验证奇数N、交错正负极值、零和、输出溢出定义，并与任意精度整数golden比较。
