# blackwell_dot_emax_tree

## Description

组合式有效指数最大值树。参数`TERM_N≥1, EXP_W≥2, DEFAULT_EXP`，指数均有符号；无clk、reset、valid/ready寄存通道。

| 信号 / 通道 | 方向 | 类型 / 位宽 | 对端 | 握手或采样条件 |
| --- | --- | --- | --- | --- |
| term_valid | 入 | TERM_N | dot 指数选择级 | 各项组合有效位 |
| term_exp | 入 | TERM_N×EXP_W | dot 指数选择级 | 组合有符号指数 |
| result_valid | 出 | 1 | dot 指数选择级 | 组合输出，至少一项有效 |
| result_exp | 出 | EXP_W | dot 指数选择级 | 组合输出，全部无效时取 DEFAULT_EXP |

## Functionality

### 有效项的成对比较

叶节点`(v,e)`；合并两个节点时，无效项不参与比较，两项有效则取有符号较大指数，相等取左侧；两者无效输出invalid/DEFAULT_EXP。按相邻索引递归，奇数尾项与invalid合并。共 ceil(log2 TERM_N) 层，结果 valid 是所有输入 valid 的 OR。

没有内部状态和额外拍数。父模块必须将输出捕获到其指定工作寄存级，不在本模块暗加流水。验证N=1、奇数N、所有invalid、最小负指数及相等指数；检查比较使用signed类型而不是无符号大小。
