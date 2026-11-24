# blackwell_banked_sram

## Description

本模块提供参数为 `BANKS, DEPTH, WORD_W=128` 的同步 SRAM，每 bank 有独立的一个读口和一个字节屏蔽写口。SMEM fabric、TMEM partition 和 TMA data path 分别配置 bank 数及深宽，宏内存储与读输出计入各自的父模块。

| 信号 / 通道 | 方向 | 类型 / 位宽 | 对端 | 握手或采样条件 |
| --- | --- | --- | --- | --- |
| read_enable | 入 | BANKS | 父存储控制器 | 读使能沿为该 bank 采样地址 |
| read_addr | 入 | BANKS×ceil(log2 DEPTH) | 父存储控制器 | 该 bank 的 read_enable 为 1 时采样 |
| read_q | 出 | BANKS×WORD_W | 父存储控制器 | 读采样沿后更新，否则保持 |
| write_enable | 入 | BANKS | 父存储控制器 | 写使能沿提交选中字节 |
| write_addr | 入 | BANKS×ceil(log2 DEPTH) | 父存储控制器 | 该 bank 写使能时采样 |
| write_data | 入 | BANKS×WORD_W | 父存储控制器 | 该 bank 写使能时采样 |
| write_byte_mask | 入 | BANKS×WORD_W/8 | 父存储控制器 | bit b 选中数据的第 b 个 byte |
| clk | 入 | 1 bit | 父存储控制器 | 上升沿采样各 bank 使能 |

## Functionality

### 读采样与字节写入

宏在 read_enable 有效的边沿采样地址，沿后更新 SRAM_Q。未使能的 bank 保持 Q。父模块负责在宏采样前确认旧 Q 有处可去。[SMEM](../smem/blackwell_smem_fabric.md) 在 grant 沿 g 直接采样；[TMEM 分区](../tmem/blackwell_tmem_partition.md) 在 g 寄存读控制，g+1 才采样。

TMA 的 RD 是可暂停的地址寄存器；地址可预选，只有 Q 有空间时才在实际采样沿使能宏读。读采样与旧 Q 交给 R_OUT 可以同沿。

write_enable 在写边沿采样，选中 byte 立即提交。父控制器按实际宏访问沿比较读写地址，保证同 bank 同 word 的冲突在使能前解决。不同 word 的 1R+1W 同拍允许。

宏不支持Q保持时须由适配器提供等宽enable寄存，并将其算作这里的Q；不得同时保留两份而仍只计一份。数据RAM及Q不做全阵列复位；父模块valid清零后未定义payload不可观察。

### 端口冲突与边界检查

检查每bank独立enable、Q暂停保持、byte mask不改邻byte、地址DEPTH−1/DEPTH边界、不同word并发读写及被控制器阻止的同word冲突。这里只提供物理存储，不处理事务身份、ready、返回credit或ACK；这些唯一属于对应fabric/partition。
