# blackwell_tma_map_control

> 规范版本 v1.0

## 1. 模块概述

串行执行tensormap.replace、tensormap.cp_fenceproxy和proxy fence。父copy engine先排空此前data，再授予memory/order后端独占权；本模块不同时执行普通TMA copy。GMEM_ID_W5、SMEM_ID_W4，一条控制命令在途。

### 微架构与资源

```mermaid
flowchart LR
    N0[控制接受与独占] --> N1[唯一128B工作缓冲]
    N1[唯一128B工作缓冲] --> N2[masked memory确认]
    N2[masked memory确认] --> N3[ordering与held响应]
```

一个控制命令记录和一个128B descriptor工作缓冲；read_done/write_done各4bit分片有效位图，不保存第二个descriptor。replace仅1个读及1个masked写在途；cp_fence四个SMEM读按ID0..3串行，工作缓冲分四个256bit分片，拼接为一个GMEM128B写；ordering1笔在途，response1槽。

控制 Lreplace=2+Lread+Lwrite；Lcp_fence=2+4*(1+Lsmem)+1+Lgmem_write+Lorder；proxy-only=2+Lorder。控制命令II为其完整退休时间加响应背压；返回前实际等待memory/order ack，不提供数据通路的32B/cycle吞吐承诺。

所有资源与时序的默认值见[微架构配置](../common/interfaces.md#微架构配置与性能约束)。周期从接受边沿计至结果首次有效；延迟式另加实际背压和外部响应等待。payload 不复位，valid、credit 和身份有效性复位；clock enable 随实际推进，SRAM 仅启用有效 bank。

## 2. 接口定义

全部握手、身份、完成、错误和复位遵循[公共规则](../common/interfaces.md#握手身份与生命周期)；表内位宽单位为 bit，符号见[公用位宽配置](../common/interfaces.md#公用位宽配置)，参数项注明默认配置。无握手的组合输出随输入变化；有握手的流水输出按所属通道保持。

cmd/rsp 采用 `tma_cmd_t/tma_rsp_t`，memory/order 通道按下表定义。idle 表示无事务，drained 还要求无 held response。MAP_REPLACE 使用 desc_ptr/map_shared/replace_field/replace_ord/replace_value，只替换目标字段；field 与 ordinal 合法性取[package 编码](../../../rtl/common/tma_mbarrier_pkg.sv)。

global/shared描述符都为项目128B v3。replace不等于公开到另一个proxy，多个replace不保证联合原子；global后端须按该replace操作要求维护独立性。CP_FENCE由SMEM读取128B、写GMEM，全部目标写确认后release；前端保证warp到齐、操作数一致及generic→tensormap获取规则。proxy-only命令只发对应ordering，不伪造数据搬运。

parent完成控制响应后使旧descriptor cache失效，之后才允许新copy使用。错误停止新memory发射、排空已发请求，返回错误，不假设已写字段能回滚。

### 输入信号

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `clk` | 1 | 公共上升沿时钟。 |
| `rst_n` | 1 | 低有效异步复位，释放同步；控制状态与外部旧响应隔离见共享规则。 |
| `cmd_vld_i` | 1 | `cmd` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `cmd_i` | `TMA_CMD_W` | TMA/descriptor 控制命令；packed `tma_cmd_t`，见[共享字段](../common/interfaces.md#tma-命令与响应)。 |
| `rsp_rdy_i` | 1 | `rsp` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `gmem_req_rdy_i` | 1 | `gmem_req` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `gmem_rsp_vld_i` | 1 | `gmem_rsp` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `gmem_rsp_data_i` | `GMEM_DATA_W` | memory 读返回行数据；data[8*j+:8] 对应请求 addr+j，未选读 byte 返回 0。 |
| `gmem_rsp_status_i` | `MEM_STATUS_W` | memory 状态，0 成功、非 0 失败。 |
| `gmem_rsp_id_i` | `GMEM_ID_W`（默认 `GMEM_ID_DEFAULT_W`） | 所属 memory 通道事务 ID；live ID 未退休前不复用，响应按 ID 匹配。 |
| `smem_req_rdy_i` | 1 | `smem_req` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `smem_rsp_vld_i` | 1 | `smem_rsp` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `smem_rsp_data_i` | `SMEM_DATA_W` | memory 读返回行数据；data[8*j+:8] 对应请求 addr+j，未选读 byte 返回 0。 |
| `smem_rsp_status_i` | `MEM_STATUS_W` | memory 状态，0 成功、非 0 失败。 |
| `smem_rsp_id_i` | `SMEM_ID_W`（默认 `TMA_SMEM_ID_DEFAULT_W`） | 所属 memory 通道事务 ID；live ID 未退休前不复用，响应按 ID 匹配。 |
| `tma_order_req_rdy_i` | 1 | `tma_order_req` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `tma_order_rsp_vld_i` | 1 | `tma_order_rsp` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `tma_order_rsp_i` | `BW_ORDER_RSP_W` | ordering 确认，ID 精确匹配；packed `bw_order_rsp_t`，见[共享字段](../common/interfaces.md#内存属性与-ordering)。 |

### 输出信号

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `cmd_rdy_o` | 1 | `cmd` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `rsp_vld_o` | 1 | `rsp` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `rsp_o` | `TMA_RSP_W` | TMA 响应，bytes 为逻辑 payload 字节数；packed `tma_rsp_t`，见[共享字段](../common/interfaces.md#tma-命令与响应)。 |
| `gmem_req_vld_o` | 1 | `gmem_req` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `gmem_req_addr_o` | `GMEM_ADDR_W` | GMEM byte 地址，128B 对齐；禁止截断 overflow。 |
| `gmem_req_data_o` | `GMEM_DATA_W` | memory 行数据；data[8*j+:8] 对应 addr+j，写 mask 为 0 的 byte 保持。 |
| `gmem_req_byte_mask_o` | `GMEM_MASK_W` | memory byte mask；bit j 选择 addr+j 的实际访问，未选读 byte 返回 0。 |
| `gmem_req_id_o` | `GMEM_ID_W`（默认 `GMEM_ID_DEFAULT_W`） | 所属 memory 通道事务 ID；live ID 未退休前不复用，响应按 ID 匹配。 |
| `gmem_req_write_o` | 1 | 1 为写请求，0 为读请求；访问语义同时受 attr.kind 约束。 |
| `gmem_req_attr_o` | `BW_MEM_ATTR_W` | 内存访问属性，随请求保持；packed `bw_mem_attr_t`，见[共享字段](../common/interfaces.md#内存属性与-ordering)。 |
| `gmem_rsp_rdy_o` | 1 | `gmem_rsp` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `smem_req_vld_o` | 1 | `smem_req` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `smem_req_addr_o` | `SMEM_BYTE_ADDR_W` | SMEM/backing byte 地址，32B 行对齐；禁止截断 overflow。 |
| `smem_req_data_o` | `SMEM_DATA_W` | memory 行数据；data[8*j+:8] 对应 addr+j，写 mask 为 0 的 byte 保持。 |
| `smem_req_byte_mask_o` | `SMEM_MASK_W` | memory byte mask；bit j 选择 addr+j 的实际访问，未选读 byte 返回 0。 |
| `smem_req_id_o` | `SMEM_ID_W`（默认 `TMA_SMEM_ID_DEFAULT_W`） | 所属 memory 通道事务 ID；live ID 未退休前不复用，响应按 ID 匹配。 |
| `smem_req_write_o` | 1 | 1 为写请求，0 为读请求；访问语义同时受 attr.kind 约束。 |
| `smem_req_attr_o` | `BW_MEM_ATTR_W` | 内存访问属性，随请求保持；packed `bw_mem_attr_t`，见[共享字段](../common/interfaces.md#内存属性与-ordering)。 |
| `smem_rsp_rdy_o` | 1 | `smem_rsp` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `tma_order_req_vld_o` | 1 | `tma_order_req` 通道有效；握手通道遵循共享 vld/rdy 规则。 |
| `tma_order_req_o` | `BW_ORDER_REQ_W` | ordering 请求，确认须兑现对应 seq/proxy/scope 可见性；packed `bw_order_req_t`，见[共享字段](../common/interfaces.md#内存属性与-ordering)。 |
| `tma_order_rsp_rdy_o` | 1 | `tma_order_rsp` 通道接受能力；仅与对应 vld 同拍为 1 时接受。 |
| `idle_o` | 1 | 无本模块执行或在途访问；具体统计范围见本节规则。 |
| `drained_o` | 1 | 本模块已接受工作及请求、响应保持槽全部排空；具体范围见本节规则。 |

## 3. 伪代码

```text
on cmd_fire: validate opcode/field/ordinal/descriptor address/proxy/warp prerequisites
replace:
    read affected v3 descriptor storage; modify exactly selected field
    write selected bytes preserving all others; wait write acknowledgment
cp_fence:
    read four32B SMEM beats; assemble128B
    write GMEM descriptor; wait acknowledgment
    request required release/proxy ordering; wait successful matching ack
proxy_fence: issue supplied proxy/range ordering; wait matching ack
return one rsp with original tag/issuer/status; retain while backpressured
parent invalidates old cache before dispatching a later data command
```

### 流水、资源与排空

```text
one128B working descriptor holds four32B SMEM slices; no response-independent second working copy
all read/write/order steps wait actual ack; error drains issued IDs before releasing exclusive owner
```
