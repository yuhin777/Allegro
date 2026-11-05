# blackwell_tmem_rf_group

> 规范版本 v1.0

## 1. 模块概述

两级流水分组器，把一个RF beat未处理的thread cell聚合成一次合法bank word请求。每lane最多一个128bit word；读允许同cell扇出，写仅合并不重叠byte mask。相同位置的重复写按thread编号从小到大分拍处理。

### 微架构与资源

```mermaid
flowchart LR
I[req与pending快照] --> W[S0 每lane最小thread选word]
    W --> C[S1 每cell写冲突选择/读扇出]
    C --> O[候选bank请求]
```

2级弹性流水、II=1、无背压L=2。S0仅保存选中的一组32个cell地址、RF beat及valid/pending/word选择快照，不保存两份cell0/cell1；S1保存selected32、128lane column与实际写word；rd/wr column端口由同一个column寄存器驱动。输出槽即bank请求保持槽，caller不再复制相同payload。每lane用5层32-thread优先树选择最小pending thread的word；每word的四个cell独立选择最小thread写者，读同cell可扇出。所有thread使用同一pack模式，冲突mask为相同cell的同宽byte，因此该并行规则与按thread递增的greedy选择一致。

输入快照在req_fire接受，结果只有rsp_fire交给caller，pending由caller在成功bank响应后清除；不把流水输出接受当作完成。只有当前beat group未在途时才请求同一个pending快照，避免重复发出。

所有资源与时序的默认值见[微架构配置](../common/interfaces.md#微架构配置与性能约束)。周期从接受边沿计至结果首次有效；延迟式另加实际背压和外部响应等待。payload 不复位，valid、credit 和身份有效性复位；clock enable 随实际推进，SRAM 仅启用有效 bank。

## 2. 接口定义

全部握手、身份、完成、错误和复位遵循[公共规则](../common/interfaces.md#握手身份与生命周期)；表内位宽单位为 bit，符号见[公用位宽配置](../common/interfaces.md#公用位宽配置)，参数项注明默认配置。无握手的组合输出随输入变化；有握手的流水输出按所属通道保持。

pending/valid各32bit；cell0/cell1各1024bit=32×u32；second选择第二cell，pack16决定低16bit写mask，writing区分读写；rf_data1024按thread排列。selected32是本拍候选集合，all_valid仅检查pending thread。输出bank lane_mask、column、data、byte_mask见[共享接口](../common/interfaces.md)。

本模块req/rsp采用vld/rdy；caller必须保持已发请求的selected快照，只有成功bank响应后才清pending。输入invalid不允许caller发出部分写入。first/second packed访问分开请求，不能把两cell当一个32bit存储。

### 输入信号

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `clk` | 1 | 公共上升沿时钟。 |
| `rst_n` | 1 | 低有效控制复位，payload不清零。 |
| `pending_i` | `RF_THREADS` | 每个 thread 对应 1 bit 的待处理位图。 |
| `valid_i` | `RF_THREADS` | 每个 thread 对应 1 bit 的地址合法位图。 |
| `cell0_i` | `RF_THREADS * TMEM_ADDR_W` | 32 × 32 bit 的 TMEM 第一 cell 地址，[31:16]=lane、[15:0]=column向量，低位为 thread0。 |
| `cell1_i` | `RF_THREADS * TMEM_ADDR_W` | 32 × 32 bit 的 TMEM 第二 cell 地址，[31:16]=lane、[15:0]=column向量，低位为 thread0。 |
| `second_i` | 1 | 选择 cell1；0 选择 cell0。 |
| `pack16_i` | 1 | LD pack16 / ST unpack16 标志。 |
| `writing_i` | 1 | 1 为 ST 写分组，0 为 LD 读分组。 |
| `rf_data_i` | `RF_BEAT_W` | 32 thread × 32 bit RF 数据，低位为 thread0。 |
| `req_vld_i` | 1 | 输入RF beat/pending快照有效。 |
| `rsp_rdy_i` | 1 | caller接受分组输出，之后由其等bank真实确认。 |


### 输出信号

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `all_valid_o` | 1 | 所有 pending thread 的地址均合法。 |
| `selected_o` | `RF_THREADS` | 每个 thread 对应 1 bit，标记该 bank 请求覆盖的 thread；成功响应后才清 pending。 |
| `rd_lane_mask_o` | `TMEM_LANE_MASK_W` | 128 个 TMEM lane 的读使能；bit j 选择 lane j。 |
| `rd_column_o` | `TMEM_COLUMN_BUS_W` | 128 × 16 bit TMEM word 起始 column；低位对应 lane0，各有效 lane 按 4 column 对齐。 |
| `wr_column_o` | `TMEM_COLUMN_BUS_W` | 128 × 16 bit TMEM word 起始 column；低位对应 lane0，各有效 lane 按 4 column 对齐。 |
| `wr_data_o` | `TMEM_DATA_W` | 128 lane × 128 bit TMEM word 数据；低位为 lane0，word 内低位为低地址 byte。 |
| `wr_byte_mask_o` | `TMEM_BYTE_MASK_W` | 128 × 16 bit TMEM byte mask；bit 16*l+b 选择 lane l 的 word byte b，0 保持。 |
| `req_rdy_o` | 1 | 两级弹性流水可接收新快照。 |
| `rsp_vld_o` | 1 | selected及bank候选payload有效，被反压时稳定。 |

## 3. 伪代码

```text
on req_fire:
    S0: capture pending/valid/cells/mode/data; choose lowest pending thread word separately for each lane
    S1: for each selected word/cell use priority tree for smallest eligible write thread
        reads select every matching thread for fanout; writes select non-overlapping cell byte masks
        merge 128 lane masks/columns/data; invalid snapshot has all_valid=0 and no partial write
hold rsp(selected,all_valid,bank_payload) until rsp_fire
caller saves selected identity and only clears those pending bits on corresponding successful bank response
```
