# blackwell_tmem_rf_map

> 规范版本 v1.0

## 1. 模块概述

组合地址生成器，把一个warp中一个thread的一项32bit寄存器映射到一个或两个TMEM cell；不读存储，不检查owner，不产生完成事件。由RF subsystem并行使用32份映射。

### 微架构与资源

```mermaid
flowchart LR
    N0[32个thread输入] --> N1[固定shape移位/加法]
    N1[固定shape移位/加法] --> N2[完整lane/column检查]
    N2[完整lane/column检查] --> N3[caller捕获cell]
```

32份组合映射并行，每份仅shape选择、固定移位/加法和完整地址进位检查；除数2/4/8均为bit切片。局部状态与缓冲为0，L=0、II=1，caller在一个地址寄存边沿捕获32个映射结果；组合路径以1ns逻辑评估约束检查。完整lane/column范围检查先于截取物理索引。

所有资源与时序的默认值见[微架构配置](../common/interfaces.md#微架构配置与性能约束)。周期从接受边沿计至结果首次有效；延迟式另加实际背压和外部响应等待。payload 不复位，valid、credit 和身份有效性复位；clock enable 随实际推进，SRAM 仅启用有效 bank。

## 2. 接口定义

全部握手、身份、完成、错误和复位遵循[公共规则](../common/interfaces.md#握手身份与生命周期)；表内位宽单位为 bit，符号见[公用位宽配置](../common/interfaces.md#公用位宽配置)，参数项注明默认配置。无握手的组合输出随输入变化；有握手的流水输出按所属通道保持。

输入shape3、warp5/thread5、base32、repeat8、reg_index7、pack16状态1、half_offset32；输出valid、cell0/cell1各32bit及second_cell。base=(lane,column)，half_offset是column数，不乘4、不随pack再乘2。

shape编号0/1/2/3/4对应32x32b/16x64b/16x128b/16x256b/16x32bx2；register_count依次为repeat/repeat/2repeat/4repeat/repeat。repeat为1..128的2次幂，shape2最大64、shape3最大32。warp低2bit决定可访问32-lane分区；输出valid不等于已获分配权限。形状对齐由caller检查：32-lane模式base lane按32对齐，16-lane模式按16对齐。

### 输入信号

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `shape_i` | 3 | RF shape 编码，见本节合法范围。 |
| `warp_i` | `WARP_ID_W` | warp 编号，低 2 bit 选择 32-lane 分区。 |
| `thread_i` | `clog2(RF_THREADS)` | warp 内 thread 编号 0..31。 |
| `base_addr_i` | `TMEM_ADDR_W` | TMEM 地址，[31:16]=lane、[15:0]=column。 |
| `repeat_i` | `RF_REPEAT_W` | 重复次数，1..128 的 2 次幂且受 shape 上限约束。 |
| `reg_index_i` | `RF_INDEX_W` | RF 寄存器向量索引，范围 0..127，从 0 起。 |
| `pack16_i` | 1 | LD pack16 / ST unpack16 标志。 |
| `half_offset_i` | `TMEM_HALF_OFFSET_W` | 16x32bx2 的 column 偏移，单位 column。 |

### 输出信号

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `valid_o` | 1 | 输入组合、索引和地址范围合法；不代表 ownership 已验证。 |
| `cell0_o` | `TMEM_ADDR_W` | TMEM 第一 cell 地址，[31:16]=lane、[15:0]=column。 |
| `cell1_o` | `TMEM_ADDR_W` | TMEM 第二 cell 地址，[31:16]=lane、[15:0]=column。 |
| `second_cell_o` | 1 | 需要第二 cell 的 pack/unpack 标志。 |

## 3. 伪代码

```text
t=thread; j=reg_index; L=base.lane; C=base.column
shape0: dl=t;                  dc=j
shape1: dl=t//4+8*(t%2);        dc=2*j+(t//2)%2
shape2: dl=t//4+8*(j%2);        dc=4*(j//2)+t%4
shape3: dl=t//4+8*((j//2)%2);   dc=8*(j//4)+2*(t%4)+j%2
shape4: dl=t%16;               dc=j
split = half_offset if shape4 and t>=16 else 0
lane = wide_add(L,dl)
column = wide_add(C,split,(2 if pack16 else 1)*dc)
valid = legal_shape_repeat && j<register_count
        && lane in partition(warp%4) && column<=(510 if pack16 else 511)
cell0=(lane,column); second_cell=pack16; cell1=(lane,column+1)
```
