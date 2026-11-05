# blackwell_tmem_cp_engine

> 规范版本 v1.0

## 1. 模块概述

执行 `tcgen05.cp`，把SMEM矩阵复制到TMEM，可做4/6bit容器解压和CTA内部warp multicast。它与GMEM↔SMEM的TMA是不同路径。parent为RF subsystem；使用四路Tensor SMEM中的第0读端口（其余三路不发请求）和唯一TMEM bank，一次执行一条命令，保留四个32B source槽和一个bank输出beat。命令/descriptor错误status10、SMEM失败16，bank错误原样传播。

### 微架构与资源

```mermaid
flowchart LR
    N0[完整probe] --> N1[4个source槽/乱序匹配]
    N1[4个source槽/乱序匹配] --> N2[16B转换与multicast]
    N2[16B转换与multicast] --> N3[2写记录/确认]
```

source4槽、每槽32B，合计128B；SMEM ID0..3，slot保存source_row/half/等待状态，允许乱序返回。source row按descriptor映射后合并32B请求；每16B转换在1级完成，b4/b6只移位取bit，无通用算术。最多聚合4个已就绪source row的同一目标word为bank请求；最多2笔write metadata在途，返回顺序匹配selected快照，成功后释放对应half。

source满则停止SMEM请求但继续bank确认；multicast复用同一source槽广播到不同lane，不建立复制buffer。一次preflight完成整个目标，再消费source。Lcp=2*Gprobe+Rsmem+max(Lsource, Lconvert, Lbank_writes)+drain，实际事件模型计算重叠；无背压转换II=1，源/目标端口均最多1请求/cycle，32B/cycle只有合并写及source在途窗口均足以承载时成立；默认4槽的实际上限为128B/slot占用往返，不能把32B接口宽度当作稳态吞吐。

所有资源与时序的默认值见[微架构配置](../common/interfaces.md#微架构配置与性能约束)。周期从接受边沿计至结果首次有效；延迟式另加实际背压和外部响应等待。payload 不复位，valid、credit 和身份有效性复位；clock enable 随实际推进，SRAM 仅启用有效 bank。

## 2. 接口定义

全部握手、身份、完成、错误和复位遵循[公共规则](../common/interfaces.md#握手身份与生命周期)；表内位宽单位为 bit，符号见[公用位宽配置](../common/interfaces.md#公用位宽配置)，参数项注明默认配置。无握手的组合输出随输入变化；有握手的流水输出按所属通道保持。

shape/source/multicast编码见[CP payload](../common/interfaces.md#cp-命令)。128x256b复制128×32B，其他全lane形状复制128×16B目标；4x256b复制四个指定lane各32B。全lane形状base lane=0；4x256b base lane L∈[0,31]，目标为L+32q。column按目标word对齐、范围和owner先全量检查。descriptor是完整64bit matrix descriptor，不是TMA v3，也不是SMEM linear base。

SMEM 请求只读；Flash 依据已接受命令的 id 关联 issuer/seq、CTA scope 及 async proxy。bank 请求 tag 取 cmd.id.tag，parent 核对响应 tag 后路由到本引擎。

128x256b/128x128b/4x256b仅multicast=0；64x128b必须为1或2；32x128b必须为3。这是同CTA内部复制，不是cluster路由。解压每16B容器输出16B，padding忽略；4bit左移2、高2bit为0，6bit高2bit为0，不能用FP数值转换替代位重排。SMEM descriptor按[官方canonical布局](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#tcgen05-canonical-layouts)读取，CP没有独立transpose位。absolute-stride不作为CP支持形式。

### Probe 与在途返回

完整源/目标地址检查先于任何目标写；probe响应身份由RF parent核对并顺序路由。bank read/write返回按各方向接受顺序匹配原命令tag和局部工作记录，未知或重复响应失败并排空，不能释放其他请求。

probe仅覆盖实际源/目标cell，排除padding和禁用lane；不连续footprint拆成精确连续段，不能以包含未访问cell的保守范围拒绝合法命令。

### 输入信号

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `clk` | 1 | 公共上升沿时钟。 |
| `rst_n` | 1 | 低有效异步复位，释放同步；控制状态与外部旧响应隔离见共享规则。 |
| `cmd_vld_i` | 1 | `cmd` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `cmd_i` | `CP_CMD_A1_W` | CP 命令；packed `cp_cmd_a1_t`，见[共享字段](../common/interfaces.md#cp-命令)。 |
| `complete_rdy_i` | 1 | `complete` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `smem_req_rdy_i` | 1 | `smem_req` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `smem_rsp_vld_i` | 1 | `smem_rsp` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `smem_rsp_data_i` | `SMEM_DATA_W` | memory 读返回行数据；data[8*j+:8] 对应请求 addr+j，未选读 byte 返回 0。 |
| `smem_rsp_id_i` | `TENSOR_SMEM_ID_W` | 所属 memory 通道事务 ID；live ID 未退休前不复用，响应按 ID 匹配。 |
| `smem_rsp_status_i` | `MEM_STATUS_W` | memory 状态，0 成功、非 0 失败。 |
| `rd_rdy_i` | 1 | `rd` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `rd_rsp_vld_i` | 1 | `rd_rsp` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `rd_rsp_status_i` | `STATUS_W` | 模块诊断状态，0 成功、非 0 失败；错误完成不得伪装成功。 |
| `rd_rsp_data_i` | `TMEM_DATA_W` | 128 lane × 128 bit TMEM word 数据；低位为 lane0，word 内低位为低地址 byte。 |
| `wr_rdy_i` | 1 | `wr` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `wr_rsp_vld_i` | 1 | `wr_rsp` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `wr_rsp_status_i` | `STATUS_W` | 模块诊断状态，0 成功、非 0 失败；错误完成不得伪装成功。 |
| `probe_rdy_i` | 1 | probe请求接受能力。 |
| `probe_rsp_vld_i` | 1 | 对应probe已完成；失败时不得执行目标写。 |
| `probe_rsp_status_i` | `STATUS_W` | 完整范围权限检查结果。 |

### 输出信号

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `cmd_rdy_o` | 1 | `cmd` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `complete_vld_o` | 1 | `complete` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `complete_o` | `ASYNC_EVENT_A1_W` | TC 内部完成，domain=TC；packed `async_event_a1_t`，见[共享字段](../common/interfaces.md#身份与事件字段)。 |
| `smem_req_vld_o` | 1 | `smem_req` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `smem_req_addr_o` | `SMEM_BYTE_ADDR_W` | SMEM/backing byte 地址，32B 行对齐；禁止截断 overflow。 |
| `smem_req_byte_mask_o` | `SMEM_MASK_W` | memory byte mask；bit j 选择 addr+j 的实际访问，未选读 byte 返回 0。 |
| `smem_req_id_o` | `TENSOR_SMEM_ID_W` | 所属 memory 通道事务 ID；live ID 未退休前不复用，响应按 ID 匹配。 |
| `smem_rsp_rdy_o` | 1 | `smem_rsp` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `rd_vld_o` | 1 | `rd` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `rd_ctx_o` | `CTX_ID_W` | 物理 context 槽编号；与 epoch 共同检查权限。 |
| `rd_epoch_o` | `EPOCH_W` | context 生命周期编号；须与 live context 及 owner 记录匹配。 |
| `rd_column_o` | `TMEM_COLUMN_BUS_W` | 128 × 16 bit TMEM word 起始 column；低位对应 lane0，各有效 lane 按 4 column 对齐。 |
| `rd_tag_o` | `ASYNC_TAG_W` | 请求 tag；响应原样恢复，不能单独作为跨 epoch 唯一身份。 |
| `rd_lane_mask_o` | `TMEM_LANE_MASK_W` | 128 个 TMEM lane 的读使能；bit j 选择 lane j。 |
| `rd_rsp_rdy_o` | 1 | `rd_rsp` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `wr_vld_o` | 1 | `wr` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `wr_ctx_o` | `CTX_ID_W` | 物理 context 槽编号；与 epoch 共同检查权限。 |
| `wr_epoch_o` | `EPOCH_W` | context 生命周期编号；须与 live context 及 owner 记录匹配。 |
| `wr_column_o` | `TMEM_COLUMN_BUS_W` | 128 × 16 bit TMEM word 起始 column；低位对应 lane0，各有效 lane 按 4 column 对齐。 |
| `wr_tag_o` | `ASYNC_TAG_W` | 请求 tag；响应原样恢复，不能单独作为跨 epoch 唯一身份。 |
| `wr_data_o` | `TMEM_DATA_W` | 128 lane × 128 bit TMEM word 数据；低位为 lane0，word 内低位为低地址 byte。 |
| `wr_byte_mask_o` | `TMEM_BYTE_MASK_W` | 128 × 16 bit TMEM byte mask；bit 16*l+b 选择 lane l 的 word byte b，0 保持。 |
| `wr_rsp_rdy_o` | 1 | `wr_rsp` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `idle_o` | 1 | 无执行、在途 SMEM/bank 请求或响应及 held complete。 |
| `probe_vld_o` | 1 | probe 请求有效。 |
| `probe_ctx_o` | `CTX_ID_W` | 对象context身份，随请求保存。 |
| `probe_epoch_o` | `EPOCH_W` | 对象生命周期，与bank live身份精确比较。 |
| `probe_lane_mask_o` | `TMEM_LANE_MASK_W` | 启用lane位图；禁用lane不访问也不报其地址错误。 |
| `probe_column_o` | `TMEM_COLUMN_BUS_W` | 各lane完整16bit起始column；probe允许非word对齐。 |
| `probe_columns_o` | `TMEM_COLUMNS_COUNT_W` | 每个enabled lane的连续column数量，1..512；先加宽检查末地址。 |
| `probe_tag_o` | `ASYNC_TAG_W` | 原命令tag，随probe响应运输。 |
| `probe_rsp_rdy_o` | 1 | 接收probe响应；身份由parent核对，顺序按已接受probe队列。 |

## 3. 伪代码

```text
on cmd_fire: validate shape/format/multicast/descriptor; preflight entire TMEM target
source_row(dest_lane):
    shape0/1: dest_lane
    shape2,multicast1: dest_lane%64
    shape2,multicast2: 32*(dest_lane//64)+dest_lane%32
    shape3,multicast3: dest_lane%32
    shape4: q, with dest_lane=base.lane+32*q
for each required source row and 16B chunk:
    generate physical SMEM addresses from descriptor and logical source chunk
    read masked 32B beats; gather chunk in element order
    raw: output=chunk
    b4: output[i]=extract_bits(chunk,4*i,4)<<2, i=0..15
    b6: output[i]=extract_bits(chunk,6*i,6),    i=0..15
    mark decoded source half ready; retain it for all required multicast destinations
when write credit available: assemble up to4 same-word ready rows; broadcast and issue masked write
on ordered bank acknowledgment: release only selected halves in that write record
on error: stop new requests; drain issued requests; hold complete(error)
after all writes acknowledged: hold complete(key,TC,OK)
```

### 流水、资源与排空

```text
reserve source slot before read; coalesce descriptor-contiguous bytes into32B SMEM requests
match ID0..3 out-of-order returns; mark two16B halves ready in each source slot
decode each half once; choose up to4 ready source rows targeting the same word
broadcast each logical source half into every required destination lane without duplicate source storage
keep<=2 ordered write records; clear selected source halves only after corresponding success ack
when source halves, writes and SMEM IDs all retire: hold complete
```
