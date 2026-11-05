# 单 CTA 后端共享接口

> 规范版本 v1.0

## 1. 模块概述

本规范定义 Tensor Core、TMA、mbarrier、TMEM 及顶层使用的公共类型和协议。支持 SM100a、单活跃 CTA、`cta_group::1`；Flash 提交已译码命令并提供 RF、SMEM、GMEM 和 ordering 服务。RTL 是 TMEM/mbarrier 的唯一状态持有者。

合法指令行为依据 [PTX ISA 9.4](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#tensorcore-5th-generation-instructions)，页面版本及 SHA256 见来源清单（原文档已清理）的 isa_baseline；项目编码、容量、诊断和仲裁由本目录定义。基础 [dot](../../dot/F16TF32_DotProd.md)、[低精度 dot](../../dot/F4F6F8_DotProd.md)、[FP4](../../dot/FP4_DotProd.md)、[INT8](../../dot/INT8_DotProd.md)、[FIFO](../../../rtl/common/blackwell_fifo.sv) 和 [SRAM](../../../rtl/common/blackwell_banked_sram.sv) 引用各自定义。

### MMA 合法组合

下表是 SM100a 支持集，`sparse K` 不是非零元素数量。完整的 type/transpose/descriptor 限制同时适用，依据 [形状及 Target ISA Notes](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#tcgen05-matrix-shape)。

| kind | 非 WS：M / N / dense K / sparse K | A、B / D |
| --- | --- | --- |
| f16 | M=64或128；N=8..256步8；K=16/32 | A/B各自选FP16或BF16→FP32；仅两者均FP16可→FP16 |
| tf32 | M=64或128；N=8..256步8；K=8/16 | TF32×TF32→FP32 |
| f8f6f4 | M=64或128；N=8..256步8；K=32/64 | E4M3/E5M2/E2M3/E3M2/E2M1 的合法交叉组合→FP16或FP32 |
| i8 | M=64或128；N={8,16,24,32,48,64,…256}；K=32/64 | S8/U8 的四种组合→S32，饱和或非饱和 |
| mxf8f6f4 | M=128；N=8..256步8；K=32/64 | 上述低精度交叉组合，UE8M0，1X→FP32 |
| mxf4 | M=128；N=8..256步8；K=64/128 | E2M1，UE8M0，2X→FP32 |
| mxf4nvf4 | M=128；N=8..256步8；K=64/128 | E2M1；UE8M0的2X/4X或UE4M3的4X→FP32 |

WS/WS.SP 仅 f16、tf32、f8f6f4、i8：M∈{32,64,128}，dense N∈{64,128,256}，sparse N∈{64,128}，K/type 沿用上表。所有block-scale形式的scale A均采用32-lane布局；instruction descriptor bit26必须为0，128-lane布局属于SM107f。FP4 sparse的SparsityVersion固定v0（bit12=0）；v1不在目标内。scale ID、稀疏 selector 与子列按 [block scale](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#tcgen05-block-scaling) 和 [sparse layout](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#tcgen05-sparse-matrices) 的图定义，不与普通矩阵 layout 合并。

非WS各kind支持A collector；ashift仅非block-scale、非WS、A在TMEM且M=128，可含sparse，不能与A fill/use同时指定。WS只使用B的b0..b3 collector，不带ashift或scale_input_d。所有kind除mxf4/mxf4nvf4均允许transpose；所有浮点kind允许negate，i8禁止negate。TF32 transpose 必须使用128B/32B atom，其他类型的 transpose 排除该模式；8bit transpose B 的 N 为16..256步16。未使用的scale/meta/zero-mask/修饰字段必须为0；dtype、selector和layout的合法值须同时满足[官方instruction descriptor及Target ISA Notes](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#tcgen05-instruction-descriptor)，Flash拒绝保留bit后才生成目标命令。数值 NaN/Inf/FTZ、累加精度、整数饱和遵守各 kind 的公开规则和所引用算术合同。

明确拒绝 group2、跨 CTA、cluster 多播、SM103a K96/byte-address-stride，以及 SM107f 专属128-lane scale A、FP4 sparse v1、ti16、K64低精度 dense/K128 sparse 扩展、UE5M3、LUT-B、非 WS B collector、restrict-commit。LD.RED（SM103f/SM110系列）、SPCOMPRESS（SM107a）和需要family target的alloc/dealloc.exclusive不纳入本SM100a ABI。`.block16/32`不增加RTL字段，Flash按合法目标的别名规则归一化为1X/2X/4X。普通 cp.async 的 LSU 数据执行在 Flash，登记/完成仍送入 RTL mbarrier。同 CTA shared-copy 保留为明确项目扩展。

## 2. 接口定义

字段表使用“接口名｜位宽｜说明”，位宽单位为 bit，符号在下方公用配置中定义；字段均为 unsigned，明确标注的坐标除外。握手方向由各模块端口表规定，共享 payload 的字段含义在此统一定义。

### 命名规则

模块与端口使用小写下划线命名，名称表达功能和通道角色；规范条文及来源见命名依据（原文档已清理）。

- 模块使用 `blackwell_<功能层级>_<功能>`；Tensor Core、TMA、TMEM、mbarrier 分别使用 `blackwell_tc_*`、`blackwell_tma_*`、`blackwell_tmem_*`、`blackwell_mbarrier_*`。集成模块为 `blackwell_tma_mbarrier_subsystem` 和 `blackwell_async_subsystem_top`。模块文档文件名与目标模块名一致。
- 输入以 `_i` 结尾，输出以 `_o` 结尾；公共 `clk/rst_n` 为明确例外。`rst_n` 表示低有效复位，极性与时序规则见公共协议。
- 同一握手通道采用共同功能前缀；`vld/rdy` 分别表示有效与接受能力，ready 的方向与 payload/valid 相反。常用缩写 `tc/tma/tmem/mma/rf/gmem/smem/ctx/cmd/req/rsp/rd/wr/vld/rdy/addr/cpl` 保留，含义由对应接口表定义。
- memory 请求的 byte 选择掩码命名为 `*_req_byte_mask_*`；TMEM 的读 lane 掩码为 `*_rd_lane_mask_*` 或 `rd_lane_mask_*`，写 byte 掩码为 `*_wr_byte_mask_*` 或 `wr_byte_mask_*`。同一数据含义沿层级保持名称，owner 前缀和方向后缀可按连接角色变化。
- `complete` 表示 TC 内部完成通道，`done` 表示外部完成通知，`finish` 表示 RF 方向 tracker 的退休通道；这些名称保留各自完成域，不互相替换。barrier 计数查询输出使用 `bar_rsp_pending_count_o`。
- 类型使用小写下划线及 `_t` 后缀；公共配置和模块参数使用大写下划线。共享字段不带端口方向后缀，其名称、顺序和编码由字段表规定。

### 公用位宽配置

下列公用定义集中描述身份、地址、状态和数据通道。定义列为数值或表达式，说明列给出展开值；除注明计数或 byte 单位的资源项外，单位均为 bit。`clog2(x)` 为向上取整的二进制对数，`max(a,b)` 取较大值。单字段固定编码、1 bit 标志和局部枚举直接写位数；简单局部派生宽度直接使用公用定义组成的表达式。

公用定义分为三类：

- **固定协议常量**：身份、地址、状态编码，以及 TMEM/RF 存储组织和 memory beat 的基准值，规定 目标字段和数据通道布局。
- **派生宽度**：定义为表达式的向量、mask 和 packed 总位宽，由基准值或字段求和计算，不作为独立可调参数。
- **模块参数默认值**：`*_DEFAULT_W` 与 `TMA_MSHR_ENTRIES` 提供下表所列参数的默认配置；固定协议常量也可作为参数默认值的来源。参数仅作用于注明参数化的接口，调整参数不改变固定 packed 类型。

协议依据区分 PTX 操作数/地址、项目身份值域和既定存储组织：shared byte 地址依据[PTX 地址定义](https://docs.nvidia.com/cuda/ptx-writers-guide-to-interoperability/index.html#fundamental-types)，barrier unsigned32 增减量依据[mbarrier.expect_tx](https://docs.nvidia.com/cuda/parallel-thread-execution/index.html#parallel-synchronization-and-communication-instructions-mbarrier-expect-tx)。完整 TMEM taddr、matrix descriptor、opaque state 和原始 timeHint/repeat 数值分别保留各自格式；物理索引及译码枚举按本目标的合法值域编码。

`max(GMEM_ADDR_W, SMEM_BYTE_ADDR_W)` 表示可携带 global/shared byte 地址的统一字段宽度，地址空间及范围检查由对应字段规定。独立身份和存储组织的同值常量按语义分别命名；数值相同不表示协议可以互换。

#### 身份与公共字段

| 配置名 | 定义 | 说明 |
| --- | --- | --- |
| `BYTE_W` | `8` | 展开值 8；一个 byte 的位数。 |
| `CTX_ID_W` | `5` | 展开值 5；物理 context 槽编号。 |
| `ISSUER_ID_W` | `10` | 展开值 10；CTA 内执行 thread ID。 |
| `WARP_ID_W` | `5` | 展开值 5；warp 编号。 |
| `ASYNC_TAG_W` | `16` | 展开值 16；固定 packed 身份及默认请求 tag。 |
| `EPOCH_W` | `16` | 展开值 16；context 生命周期编号。 |
| `SEQ_W` | `64` | 展开值 64；操作序号。 |
| `STATUS_W` | `8` | 展开值 8；模块诊断状态。 |
| `MEM_STATUS_W` | `2` | 展开值 2；外部 memory 状态。 |
| `BYTE_COUNT_W` | `64` | 展开值 64；payload cursor、总字节数及 ordering 范围；不作为 barrier transaction 操作数。 |
| `BARRIER_TX_BYTES_W` | `32` | 展开值 32；barrier transaction 增减量；候选 signed tx 状态另做范围检查。 |
| `BARRIER_COUNT_W` | `32` | 展开值 32；barrier 命令计数及查询返回值。 |
| `BARRIER_STATE_W` | `64` | 展开值 64；opaque barrier token。 |
| `BARRIER_TIME_HINT_W` | `32` | 展开值 32；barrier 有限等待提示。 |
| `BARRIER_REPORT_W` | `8` | 展开值 8；barrier report payload。 |
| `CACHE_POLICY_W` | `64` | 展开值 64；外部后端 cache policy。 |

#### 地址与 descriptor

| 配置名 | 定义 | 说明 |
| --- | --- | --- |
| `GMEM_ADDR_W` | `64` | 展开值 64；GMEM byte 地址。 |
| `SMEM_BYTE_ADDR_W` | `32` | 展开值 32；SMEM byte 地址。 |
| `MATRIX_DESC_W` | `64` | 展开值 64；PTX SMEM matrix descriptor。 |
| `TENSOR_MAP_BYTES` | `128` | 展开值 128；项目 v3 tensor map 的字节数，单位 byte。 |
| `TENSOR_DIMS` | `5` | 展开值 5；tensor map 坐标维度数，单位维度。 |
| `TENSOR_COORD_VECTOR_W` | `TENSOR_DIMS * 32` | 展开值 160；完整坐标向量。 |
| `IM2COL_W` | `5 * 16` | 展开值 80；完整 im2col 参数向量。 |

#### TMEM 数据接口

| 配置名 | 定义 | 说明 |
| --- | --- | --- |
| `TMEM_LANES` | `128` | 展开值 128；物理 TMEM lane 数，单位 lane。 |
| `TMEM_COLUMNS` | `512` | 展开值 512；每 lane 的 column 数，单位 column。 |
| `TMEM_CELL_W` | `32` | 展开值 32；一个 TMEM cell。 |
| `TMEM_WORD_COLUMNS` | `4` | 展开值 4；一个 bank word 覆盖的 column 数。 |
| `TMEM_WORD_W` | `TMEM_WORD_COLUMNS * TMEM_CELL_W` | 展开值 128；一个 lane 的 bank word。 |
| `TMEM_ADDR_LANE_W` | `16` | 展开值 16；taddr 中的 lane 字段，保留完整范围供检查。 |
| `TMEM_COLUMN_FIELD_W` | `16` | 展开值 16；taddr 与 bank 向量中的 column 字段。 |
| `TMEM_ADDR_W` | `TMEM_ADDR_LANE_W + TMEM_COLUMN_FIELD_W` | 展开值 32；完整 TMEM 地址。 |
| `TMEM_COLUMN_INDEX_W` | `clog2(TMEM_COLUMNS)` | 展开值 9；物理 column 起点索引。 |
| `TMEM_COLUMNS_COUNT_W` | `clog2(TMEM_COLUMNS + 1)` | 展开值 10；alloc/free 列数，可表达 512。 |
| `TMEM_HALF_OFFSET_W` | `32` | 展开值 32；16x32bx2 的 column 偏移字段。 |
| `TMEM_LANE_MASK_W` | `TMEM_LANES` | 展开值 128；bank 读使能或 D lane 禁写掩码。 |
| `TMEM_COLUMN_BUS_W` | `TMEM_LANES * TMEM_COLUMN_FIELD_W` | 展开值 2048；128 lane 的 column 向量。 |
| `TMEM_DATA_W` | `TMEM_LANES * TMEM_WORD_W` | 展开值 16384；128 lane 的 bank word 数据向量。 |
| `TMEM_BYTE_MASK_W` | `TMEM_LANES * TMEM_WORD_W / BYTE_W` | 展开值 2048；128 lane 的 bank byte mask 向量。 |

#### RF 数据接口

| 配置名 | 定义 | 说明 |
| --- | --- | --- |
| `RF_THREADS` | `32` | 展开值 32；一个 warp 的 thread 数，单位 thread。 |
| `RF_REG_W` | `32` | 展开值 32；一个 thread 的 RF 寄存器。 |
| `RF_REPEAT_W` | `8` | 展开值 8；RF LD/ST 的 repeat 字段。 |
| `RF_INDEX_W` | `7` | 展开值 7；RF 寄存器向量索引 0..127；最多 128 个 vector。 |
| `RF_BEAT_W` | `RF_THREADS * RF_REG_W` | 展开值 1024；一个完整 RF 寄存器向量。 |

#### 外部 memory 与 ID

| 配置名 | 定义 | 说明 |
| --- | --- | --- |
| `GMEM_BEAT_BYTES` | `128` | 展开值 128；GMEM 行请求字节数，单位 byte。 |
| `SMEM_BEAT_BYTES` | `32` | 展开值 32；SMEM 行请求字节数，单位 byte。 |
| `GMEM_DATA_W` | `GMEM_BEAT_BYTES * BYTE_W` | 展开值 1024；GMEM 行数据。 |
| `GMEM_MASK_W` | `GMEM_BEAT_BYTES` | 展开值 128；GMEM byte mask。 |
| `SMEM_DATA_W` | `SMEM_BEAT_BYTES * BYTE_W` | 展开值 256；SMEM 行数据。 |
| `SMEM_MASK_W` | `SMEM_BEAT_BYTES` | 展开值 32；SMEM byte mask。 |
| `GMEM_ID_DEFAULT_W` | `max(1,clog2(TMA_MSHR_ENTRIES + 1))` | 展开值 5；GMEM_ID_W 默认值；MSHR ID 0..15，descriptor fetch ID 16。 |
| `TMA_SMEM_ID_DEFAULT_W` | `max(1,clog2(TMA_MSHR_ENTRIES))` | 展开值 4；TMA 叶模块 SMEM_ID_W 默认值；MSHR ID 0..15。 |
| `TMA_MSHR_ENTRIES` | `16` | 展开值 16；TMA MSHR_ENTRIES 的默认项数，单位 entry。 |
| `SUBSYSTEM_SMEM_ID_DEFAULT_W` | `1 + max(TMA_SMEM_ID_DEFAULT_W,BARRIER_MEM_ID_DEFAULT_W)` | 展开值 5；TMA/bar 聚合口 SMEM_ID_W 默认值；最高 bit 为来源。 |
| `BARRIER_MEM_ID_DEFAULT_W` | `1` | 展开值 1；barrier backing MEM_ID_W 默认值；读 ID 0、写 ID 1。 |
| `TENSOR_SMEM_ID_W` | `7` | 展开值 7；MMA/CP 共享 Tensor SMEM 读口 ID；协议请求位置编号0..127；v1.0默认MMA活跃0..15、CP活跃0..3，其余未在途ID响应非法。 |
| `ORDER_ID_W` | `16` | 展开值 16；ordering 通道事务 ID。 |

#### Packed payload 总位宽

| 配置名 | 定义 | 说明 |
| --- | --- | --- |
| `ASYNC_ID_W` | `ISSUER_ID_W + WARP_ID_W + ASYNC_TAG_W + SEQ_W + EPOCH_W` | 展开值 111；按 [async_id_t](#async_id_t) 的字段位宽求和；字段顺序由类型表规定。 |
| `ASYNC_EVENT_W` | `ASYNC_ID_W + 3 + STATUS_W + 1` | 展开值 123；按 [async_event_t](#async_event_t) 的字段位宽求和；字段顺序由类型表规定。 |
| `TC_COMMIT_W` | `ASYNC_ID_W + SMEM_BYTE_ADDR_W` | 展开值 143；按 [tc_commit_t](#tc_commit_t) 的字段位宽求和；字段顺序由类型表规定。 |
| `ASYNC_KEY_A1_W` | `CTX_ID_W + ASYNC_ID_W` | 展开值 116；按 [async_key_a1_t](#async_key_a1_t) 的字段位宽求和；字段顺序由类型表规定。 |
| `ASYNC_EVENT_A1_W` | `CTX_ID_W + ASYNC_EVENT_W` | 展开值 128；按 [async_event_a1_t](#async_event_a1_t) 的字段位宽求和；字段顺序由类型表规定。 |
| `TC_COMMIT_A1_W` | `CTX_ID_W + TC_COMMIT_W` | 展开值 148；按 [tc_commit_a1_t](#tc_commit_a1_t) 的字段位宽求和；字段顺序由类型表规定。 |
| `MMA_CMD_A1_W` | `CTX_ID_W + ASYNC_ID_W + 3 + 2 * 4 + 2 + 8 + 9 + 8 + 3 * MATRIX_DESC_W + 5 * TMEM_ADDR_W + 12 * 1 + 4 + 6 * 2 + 1 + 2 + TMEM_LANE_MASK_W` | 展开值 665；按 [mma_cmd_a1_t](#mma_cmd_a1_t) 的字段位宽求和；字段顺序由类型表规定。 |
| `CP_CMD_A1_W` | `CTX_ID_W + ASYNC_ID_W + TMEM_ADDR_W + MATRIX_DESC_W + 3 + 2 * 2` | 展开值 219；按 [cp_cmd_a1_t](#cp_cmd_a1_t) 的字段位宽求和；字段顺序由类型表规定。 |
| `SHIFT_CMD_A1_W` | `CTX_ID_W + ASYNC_ID_W + TMEM_ADDR_W` | 展开值 148；按 [shift_cmd_a1_t](#shift_cmd_a1_t) 的字段位宽求和；字段顺序由类型表规定。 |
| `TMA_CMD_W` | `4 + ASYNC_TAG_W + ISSUER_ID_W + SEQ_W + max(GMEM_ADDR_W, SMEM_BYTE_ADDR_W) + TENSOR_COORD_VECTOR_W + SMEM_BYTE_ADDR_W + max(GMEM_ADDR_W, SMEM_BYTE_ADDR_W) + 32 + SMEM_BYTE_ADDR_W + 2 * 3 + IM2COL_W + 5 * 2 + 9 * 1 + 32 + 4 * 4 + 3 + 16 + CACHE_POLICY_W + 64` | 展开值 778；按 [tma_cmd_t](#tma_cmd_t) 的字段位宽求和；字段顺序由类型表规定。 |
| `TMA_RSP_W` | `ASYNC_TAG_W + ISSUER_ID_W + STATUS_W + BYTE_COUNT_W` | 展开值 98；按 [tma_rsp_t](#tma_rsp_t) 的字段位宽求和；字段顺序由类型表规定。 |
| `BAR_CMD_W` | `5 + ASYNC_TAG_W + ISSUER_ID_W + SEQ_W + SMEM_BYTE_ADDR_W + BARRIER_COUNT_W + BARRIER_TX_BYTES_W + 6 * 1 + BARRIER_STATE_W + BARRIER_TIME_HINT_W + BARRIER_REPORT_W + 2 * 2` | 展开值 305；按 [bar_cmd_t](#bar_cmd_t) 的字段位宽求和；字段顺序由类型表规定。 |
| `BAR_RSP_W` | `ASYNC_TAG_W + ISSUER_ID_W + STATUS_W + 5 * 1 + BARRIER_STATE_W + BARRIER_COUNT_W + BARRIER_REPORT_W` | 展开值 143；按 [bar_rsp_t](#bar_rsp_t) 的字段位宽求和；字段顺序由类型表规定。 |
| `BAR_REPORT_REQ_W` | `ASYNC_TAG_W + SMEM_BYTE_ADDR_W + BARRIER_REPORT_W` | 展开值 56；按 [bar_report_req_t](#bar_report_req_t) 的字段位宽求和；字段顺序由类型表规定。 |
| `BW_ASYNC_REQ_W` | `1 + ISSUER_ID_W + SEQ_W + STATUS_W` | 展开值 83；按 [bw_async_req_t](#bw_async_req_t) 的字段位宽求和；字段顺序由类型表规定。 |
| `BW_ASYNC_RSP_W` | `ISSUER_ID_W + SEQ_W + STATUS_W` | 展开值 82；按 [bw_async_rsp_t](#bw_async_rsp_t) 的字段位宽求和；字段顺序由类型表规定。 |
| `BW_MEM_ATTR_W` | `2 + 4 + 3 + 3 * 1 + ISSUER_ID_W + SEQ_W + 3 * 2 + CACHE_POLICY_W` | 展开值 156；按 [bw_mem_attr_t](#bw_mem_attr_t) 的字段位宽求和；字段顺序由类型表规定。 |
| `BW_ORDER_REQ_W` | `ORDER_ID_W + ISSUER_ID_W + SEQ_W + 2 + 3 * 2 + max(GMEM_ADDR_W, SMEM_BYTE_ADDR_W) + BYTE_COUNT_W` | 展开值 226；按 [bw_order_req_t](#bw_order_req_t) 的字段位宽求和；字段顺序由类型表规定。 |
| `BW_ORDER_RSP_W` | `ORDER_ID_W + STATUS_W` | 展开值 24；按 [bw_order_rsp_t](#bw_order_rsp_t) 的字段位宽求和；字段顺序由类型表规定。 |

#### 模块参数默认配置

| 参数名 | 默认配置 | 说明 |
| --- | --- | --- |
| `TAG_W` | `ASYNC_TAG_W` | TMEM bank、RF subsystem、SHIFT 和 RF wait tracker 的请求 tag 参数。 |
| `ADDR_W` | `GMEM_ADDR_W` / `SMEM_BYTE_ADDR_W` | TMA engine/copy/data 与 TMA/bar 聚合模块的 GMEM 口使用前者；mbarrier frontend/unit 使用后者。TMA tx_cpl_addr 使用 SMEM_ADDR_W。 |
| `SMEM_ADDR_W` | `SMEM_BYTE_ADDR_W` | TMA engine/copy/data 与 TMA/bar 聚合模块的 SMEM byte 地址参数。 |
| `GMEM_ID_W` | `GMEM_ID_DEFAULT_W` | TMA 数据、控制及聚合口的 GMEM ID 参数。 |
| `SMEM_ID_W` | `TMA_SMEM_ID_DEFAULT_W` / `SUBSYSTEM_SMEM_ID_DEFAULT_W` | TMA 叶模块默认使用前者，TMA/bar 聚合口默认使用后者。 |
| `MEM_ID_W` | `BARRIER_MEM_ID_DEFAULT_W` | mbarrier frontend/unit 的 backing ID 参数。 |
| `MSHR_ENTRIES` | `TMA_MSHR_ENTRIES` | TMA 的 MSHR 容量参数；集成时决定 TMA local SMEM ID 位宽。 |

TMA/bar 聚合实例将 TMA 子模块的 `SMEM_ID_W` 设为 `max(1,clog2(MSHR_ENTRIES))`，默认 4 bit；barrier 子模块的 `MEM_ID_W` 设为 `BARRIER_MEM_ID_DEFAULT_W`，local ID 为 1 bit（读 0、写 1）。聚合口最高 bit 区分 TMA/barrier，其余 bit 零扩展 local ID，并满足 `SMEM_ID_W >= 1 + max(max(1,clog2(MSHR_ENTRIES)),BARRIER_MEM_ID_DEFAULT_W)`；默认聚合口为 5 bit。Tensor SMEM 独立使用 `TENSOR_SMEM_ID_W`，默认7bit，由活动MMA/CP引擎检查live ID，顶层按稳定执行owner路由；它与 TMA/bar 聚合口各自匹配 ID。

参数约束：`MSHR_ENTRIES>=2`，`GMEM_ID_W>=max(1,clog2(MSHR_ENTRIES+1))`，`SMEM_ID_W>=max(1,clog2(MSHR_ENTRIES))`（TMA 叶模块），`MEM_ID_W>=1`（barrier）。聚合口另满足上式，barrier 实例的 ADDR_W 取聚合模块的 SMEM_ADDR_W；TMA 的 ADDR_W 只用于 GMEM。v1.0 顶层采用表中默认配置；改变叶模块资源/ID 参数时父层必须同步匹配，固定 packed 类型不自动改变。v1.0 集成的 TAG_W=ASYNC_TAG_W，CONTEXTS 不超过 2^CTX_ID_W；内部 ticket/CAM 索引必须容纳在其 tag 值域内，bar 软件内部 tag 最高 bit 保留给 TC，外部用户 tag 原样恢复。

### 微架构配置与性能约束

以下是固定结构常量及资源/调度参数，独立于75项固定ABI位宽定义；默认值保留在本节与规范清单中；原外部资源配置及模型已清理。局部存储宽度由本节数据组织及payload字段求和，简单派生量不再命名为公共位宽。

| 配置名 | 默认值 | 说明 |
| --- | --- | --- |
| `TMA_QUEUE_ENTRIES` | 8 | data命令FIFO项数；一条active、其余等待。 |
| `TMA_CACHE_ENTRIES` | 4 | descriptor cache对象数。 |
| `TMA_SETUP_SLOTS` | 2 | 当前与下一条准备上下文，独立于copy active数量。 |
| `TMA_SEGMENT_BYTES` | 32 | 每片段最大源、目标及逻辑payload字节，单位B。 |
| `TMA_LINE_CHILDREN` | 4 | 普通同行GMEM请求最多child数。 |
| `TMA_CONVERT_STAGES` | 2 | 格式转换弹性流水拍数。 |
| `TMA_WALK_STAGES` | 3 | 增量walker弹性流水拍数。 |
| `SETUP_MUL_CYCLES` | 4 | 共享64x64乘法资源调用延迟。 |
| `SETUP_DIV_CYCLES` | 64 | 共享64/64除法资源调用延迟。 |
| `TMA_TICKET_ENTRIES` | 20 | 用户身份/边界/结果记录；2*queue+4。 |
| `TMA_CONTROL_RESERVE` | 2 | ticket中控制/等待专用保留名额。 |
| `BAR_CACHE_ENTRIES` | 4 | 独立8B对象cache项数。 |
| `BAR_WAIT_ENTRIES` | 32 | 独立有限等待记录数。 |
| `BAR_WB_ENTRIES` | 2 | 一个live backing写＋一个已选victim。 |
| `BAR_PIPE_STAGES` | 3 | 对象lookup/update/commit流水拍数。 |
| `BAR_RETURN_ENTRIES` | 4 | software/TMA各自返回credit数；各含3笔pipeline＋1held。 |
| `BAR_COMMAND_ENTRIES` | 44 | 32 wait＋8普通/order＋4控制名额。 |
| `BAR_ASYNC_ENTRIES` | 16 | ordinary cp.async登记项数。 |
| `BAR_TC_CREDITS` | 1 | 独立TC在途/返回名额。 |
| `TC_COUNT` | 4 | 固定四个物理core；每core32逻辑行，M128/M64/M32启用4/2/1个低编号实例；不是可变CTA数量。 |
| `TC_DOT_LANES` | 64 | 固定结构常量，不可覆盖；每core每类阵列64颗dot，输出tile固定8×8。 |
| `MMA_SMEM_CREDITS` | 16 | 每core的32B SMEM请求名额，四路合计64；各路ID独立。 |
| `MMA_TAG_CREDITS` | 2 | 每core原生dot slot票据；最多对应两个已预留结果槽，不复制完整身份。 |
| `MMA_RESULT_SLOTS` | 2 | 每core76bit状态/32bit结果共用槽，最后写请求接受后释放；ACK归父层。 |
| `MMA_C_SLOTS` | 1 | 每core独立1024B旧C预取槽，保存32×8个32bit cell；两笔512B直写返回，第四行块dot_fire后释放，input_d=0不读。 |
| `MMA_A_READ_STAGES` | 1 | 每core一个352B同步A/metadata/scale读出级，每dot读取8行、实际接受后释放，ashift复用。 |
| `MMA_PREP_B_SLOTS` | 2 | 每core当前／下一N块的完整B列槽，每槽8列和scale；只绑定N，四个8行块复用，第四次dot_fire且填充／scale返回退休后释放。 |
| `TC_OPERATIONS` | 1 | 顶层数据命令互斥推导的live TC操作数。 |
| `TC_COMMITS` | 8 | 独立commit快照队列项数。 |
| `RF_OPERATIONS` | 1 | 命令互斥推导的live LD/ST操作数。 |
| `RF_WAITS` | 16 | 独立方向wait记录数。 |
| `RF_BEAT_SLOTS` | 2 | 当前bank工作与下一RF beat准备数据槽。 |
| `RF_GROUP_STAGES` | 2 | RF group弹性流水拍数。 |
| `CP_SOURCE_SLOTS` | 4 | 各32B source槽数。 |
| `CP_WRITE_CREDITS` | 2 | bank write在途工作记录数。 |
| `SHIFT_SNAPSHOT_BYTES` | 1024 | 完整32lane*8column*4B源快照，单位B。 |
| `BANK_CHECK_STAGES` | 2 | 完整地址及owner检查拍数。 |
| `BANK_MEMORY_CYCLES` | 1 | 逻辑SRAM同步读/写确认拍数；宏绑定须满足此契约。 |
| `BANK_PROBE_CREDITS` | 2 | probe弹性metadata在途名额。 |
| `BANK_READ_CREDITS` | 3 | 2级检查+1读结果寄存器。 |
| `BANK_WRITE_CREDITS` | 3 | 2级检查+1写确认状态。 |

本地metadata和payload预算分别由资源配置的`control_storage`、`register_payload_bytes`给出，`memories`规定SRAM组织；每项列出唯一owner、项数、字宽和用途。预算为逻辑存储上限，不是物理面积；原生dot算术流水寄存器随dot合同另行统计，不能遗漏后计作零。父层只能运输真实credit/状态，不得重复实例化这些记录。probe只访问实际footprint，正常hit提交和flush成功是不同事件。

固定32逻辑行分区属于结构属性，资源配置的tiling记录`rows_per_core=32`及按M启用低编号实例；不引入可覆盖参数。每活动实例保存完整32行A，以8列N块为外层、四个8行块为内层，驻留A跨全部N复用。8行读出视图每dot接受后释放；当前B与32×8旧C跨四行块保持，第四次实际消费后释放，另一B槽预取下一N。B消费边界由唯一有序行块游标决定，不另存消费者计数或mask。覆盖／ashift保护在原A上延长生命周期。未启用实例不申请请求或返回credit，所有屏障和退休按active_mask汇总，不借用闲置端口或槽。

SRAM契约为1R1W、同步1周期读、byte mask写；寄存器bank按模块指定的字段写与组合读，不冒充额外SRAM端口。数据不复位，valid/control复位。TMEM128×128×128bit=256KiB；四core各5120B数据存储、共享scale B4096B及同步输出32B，合计24608B，组织见[core](../tensor_core/blackwell_tc_core.md#微架构与资源)；控制及原生dot流水另计。bank唯一2KiB返回级只计入bank；C返回按32-bank×16B=512B/core直接连接预留行半字，普通源仍用窄回填，无额外宽holding。M128直连32-bank分组，F/E/G按布局作有限置换，不修改PTX地址。每bank最多1R+1W，同word冲突轮询。TMA payload4×4×256bit=512B；bit打包不推导隐式RAM读口。

所有周期目标均以无背压且指定外部服务延迟为条件。默认外部存储模型为四路Tensor读口和TMA/bar口共用一个32B/cycle SMEM服务；另测无bank冲突四路各32B/cycle的配置（SMEM状态仍唯一），以及一个128B GMEM请求口；payload宽度不意味着两组独立物理存储。模型计算所有请求、源/目标确认、bank冲突、pipeline/queue占用与ordering等待；不采用其他GPU的私有峰值作为本实现吞吐。

资源下界Q>=ceil(rate*RTT)+held_margin；超过有限窗口时降低实际吞吐而非省略等待。1ns是ASAP7 RVT TT（0.7V/25C）逻辑评估约束，不自动放宽；SRAM宏未表征时单列容量/端口/访问次数，面积与功耗保持未定，不填0。CLOCK_PERIOD_NS按真实执行时钟换算time_hint，默认10ns不由1ns逻辑评估改写。功耗比较使用917/918/919种子及相同请求/停顿场景，分别计有效传输、bank enable、dot激活、payload更新和空闲。

### 握手、身份与生命周期

- 所有带 `vld/rdy` 的通道在时钟上升沿 `fire=vld && rdy` 接受一次；被反压时发送方保持 valid 和全部 payload。`clk` 为共同上升沿时钟，`rst_n` 低有效异步复位、释放须同步。只有RF map为组合模块；TMA map与RF group采用各自规定的有时钟握手。
- Flash 对 generic pointer 做状态空间转换，验证完整原始地址、枚举和形状，再生成目标命令；shared 地址必须落在本 CTA 的 228KiB SMEM 内。非法高位不能通过 cast、mask 或取低位变成合法地址/枚举。RTL 对译码后的组合和实际访问 footprint 继续检查，宽地址加法保留进位。
- 完整操作 key 为 `(ctx,id)`，身份及事件字段见下表。TC seq 由 Flash 在同 issuer 生命周期严格递增，RF 方向 seq 由 subsystem 分配；各域不回绕，tag 不能单独作为跨 epoch 唯一标识。注册、内部完成、commit 和通知携带同一 key。
- MMA/CP/SHIFT/LDST命令接受前同时预留执行、tracker、内部完成和外部通知资源。每类资源只按[唯一归属](#状态登记与缓冲归属)保存一份；父层参数传递和连接不增加资源副本。TMA/bar按各自ticket/CAM保存响应状态。内部完成不等待普通DONE消费；DONE长期反压可以阻止后续同类命令接受。
- commit/wait 捕获接受边沿前的已登记前驱；同拍新登记不纳入快照，同拍完成须从快照清除并传播失败。Flash 不得把程序序中的生产者与依赖它的 commit/wait 同拍提交。
- idle/drained只统计已接受工作、内部held请求及held响应；外部未握手valid不计入drain，发送方仍须保持它或在协议复位时取消。
- 接收端响应 ID 在所属通道内匹配，ID 未退休前不复用。未知/重复/旧生命周期响应为协议错误，不关联到新命令。复位前 Flash 停止提交，排空或取消外部请求并隔离旧响应；复位清控制状态，不清TMEM数据；mbarrier backing由软件重新INIT，初值不由复位保证。
- `stop_i` 阻止新的外部执行命令/登记，已接受的父层排队工作仍可向子层dispatch，不能因层层stop而滞留。完成、memory/order响应及已接受的wait继续推进；全后端排空后，停止窗口内仍允许TMEM管理握手和控制响应，管理完成前禁止重新发射。
- tag/epoch 保留完整输入值域；seq 及生命周期编号的分配不得通过回绕复用尚有关联的身份。耗尽前停止发射、排空并隔离旧响应，再按生命周期协议复位。
- context 退出前停止新执行命令、排空数据/ordering/生产者/响应，显式释放 TMEM，并由软件按对象生命周期处理 mbarrier。仅切换 epoch 不清除 TC/TMA/普通 cp.async 的 sticky fault；新 CTA 必须在排空后复位整个后端。

### 状态、登记与缓冲归属

| 状态或资源 | 唯一归属 | 规则 |
| --- | --- | --- |
| TMEM storage、live/epoch/permit、allocation owner | TMEM bank | 父层只保存事务身份和路由选择；有效allocation不影响drained。 |
| mbarrier cache、计数、phase、wait与writeback状态 | mbarrier unit | frontend只负责ordering、生产者依赖及返回身份，不保存第二份对象状态。 |
| TC op1/commit8及sticky failure | TC completion tracker | 顶层在MMA/CP/SHIFT cmd_fire登记一次；complete由活动引擎直接提交。 |
| RF op1/wait16及class poison | RF wait tracker | RF subsystem在LD/ST cmd_fire登记一次；top只授予命令。 |
| MMA/CP/SHIFT内部complete槽 | 各自执行引擎 | 各一个；父层直接转发，不增加内部完成副本。 |
| LD/ST内部finish槽 | RF subsystem | 一个；LD最后RF写回握手、ST最后TMEM写确认后产生。 |
| MMA普通DONE槽 | async subsystem top | 一个；MMA complete_fire后入队一次，DONE消费不再次退休操作。 |
| LD/ST、CP、SHIFT普通DONE槽 | RF subsystem | 各一个；对应finish/complete_fire后入队，top直接连接输出。 |
| 完整在途commit身份、event | TC async completion | 默认一笔；同一身份记录生成arrival和event，event消费前不接收下一笔内部arrival。 |
| TC return route、独立TC响应槽 | mbarrier frontend | 保存tag/issuer路由信息及一个响应；命令payload由上游保持到unit接受，不建立TC命令副本。 |
| TMA data FIFO8、descriptor cache4、MSHR16 | TMA data engine | engine/copy/subsystem配置仅传递，不重复实例化。 |
| bulk-group、ticket20及用户响应状态 | TMA engine | ticket保存身份、边界及结果；它与data FIFO的执行排队职责不同。 |
| map control执行状态与响应 | TMA map control | copy层仅仲裁owner并mux响应；缓存仍属于data engine。 |
| software command44记录及预留响应 | mbarrier frontend | unit响应写入对应记录，外部bar_rsp背压不阻塞unit返回；TC独立于软件表。 |
| Tensor SMEM live ID／阶段 | 四个TC core或CP引擎 | 每路ID7保持，(port,ID)匹配；CP只用port0；top用稳定owner路由，无逐ID镜像。 |
| 完整MMA命令、全局预检/退休/首次错误 | MMA engine | 一条命令共享视图，active_mask由合法M/32派生，已有四位记录只汇总active core；未启动实例保持idle且不产生局部退休；局部退休不产生tracker事件。 |
| MMA原始A、B/C、结果/76bit状态、slot票据 | TC core | 四实例各自持有；每输出一次完整dot，旧D直接接C；完整32行A跨N驻留，读出视图每dot释放，B/C跨四行块保持至最后消费，保护原A另等必要ashift读取；结果按result_release释放。 |
| MMA已发写事务及ACK | MMA engine | payload最后写请求被bank接受后可释放，route保留至全部ACK；旧ACK不经core槽匹配。 |
| TMEM稳定读返回payload | TMEM bank | MMA仅记录分片交付，最后片段接受才响应完整beat；bank2KiB级只实例化一次。 |

TC tracker、RF wait tracker和bank的idle/drained由其权威状态直接输出；SHIFT的idle包含held complete。父层只聚合输出，不维护镜像表或复制计数。idle/drained只统计已接受工作，正常allocation/驻留cache及保留fault不计作在途；flush success与drained分开。命令预检检查完整footprint，bank逐请求检查权限，二者保护不同边界，均须保留。

### Barrier 提交、写回与生命周期

mbarrier unit的驻留cache是当前对象状态的唯一权威；backing仅用于miss恢复与非驻留保存。更新合法候选后本地原子提交，返回token/phase、唤醒waiter及TC/TMA响应；barrier状态提交不等待backing写回，也不替代数据/ordering的可见性确认。

TMA的成功链为“所有目标数据确认→必要release/proxy确认→complete_tx缓存提交→TMA响应”；TC成功event为“快照依赖退休→arrival缓存提交→event”。descriptor/source完成仍各有独立边界。错误不伪造成功arrival/complete_tx，payload report与backend status分开。

有效对象的8B存储只由mbarrier路径访问；Flash不得通过普通SMEM读写与缓存对象状态混用。software先排空旧producer、该对象waiter及held结果，再完成INVAL；INVAL把失效状态写入backing、等待确认，再释放对象地址供普通SMEM复用。新INIT检查对象生命周期并建立新cache状态。不同对象即使同32B行也只写各自8B mask。

dirty eviction冻结victim，写确认后才能替换；waiter独立保存namespace/address/phase，不要求对象一直驻留。flush停止新对象操作并等待已接受producer/ordering/访问退休，再写回dirty对象；invalidate请求在成功后清cache有效位。backing失败保留sticky namespace fault，释放在途credit、返回真实错误；未来相关操作及正常context回收失败，已返回的cache提交结果不追溯修改。

idle/drained不把正常dirty驻留cache及保留fault当在途。stop窗口先退休工作再flush；flush response退休后drained可成立，即使status非零。正常context destroy/create绑定必须检查flush成功，失败用现有ctrl_rsp返回错误并保留context。恢复须为同namespace安全重试或全后端静默复位，并隔离外部旧响应、重新INIT；不能仅变更epoch清除fault。

### 内部 Probe 与流水连接

bank probe输入(ctx,epoch,lane_mask,column_vector,columns,tag)，输出(status,tag)；span为1..512、每lane起始column保持完整16bit，检查前使用加宽end=start+span-1。probe只检查权限，L=2；data逐请求仍检查，L=3。probe不改变对象状态，也不读取SRAM。

MMA probe↔RF parent↔bank；CP/SHIFT probe及RF preflight在RF内部接入相同bank通道。parent按稳定owner与已接受request FIFO序号路由，核对tag后送活动引擎；management等待所有probe/read/write及响应退休。响应顺序为各方向接受顺序，不把相同command tag当作唯一位置编号。

TMA data拥有descriptor cache/FIFO/MSHR；map拥有两个decoded上下文和一个active walker。setup_rsp返回槽身份及参数，walk激活所选槽，step_rsp返回下一连续段，retire回收；copy控制窗口排空next setup和预取后失效cache。RF group的req/rsp由RF beat槽驱动，group只形成候选，bank真实确认才清pending。生命周期flush为top↔TMA/mbarrier subsystem↔frontend↔unit的内部通道，ctx/epoch由top绑定。

### 身份与事件字段

#### async_id_t

Packed payload 总位宽为 `ASYNC_ID_W`（展开值 111 bit），按表序从高位到低位排列。

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `issuer` | `ISSUER_ID_W` | CTA 内执行 thread ID。 |
| `warp` | `WARP_ID_W` | warp 编号。 |
| `tag` | `ASYNC_TAG_W` | 用户请求 tag，不能单独作为跨 epoch 唯一身份。 |
| `seq` | `SEQ_W` | 同 issuer 的操作序号，严格递增且不回绕。 |
| `epoch` | `EPOCH_W` | context 生命周期编号。 |

#### async_event_t

Packed payload 总位宽为 `ASYNC_EVENT_W`（展开值 123 bit），按表序从高位到低位排列。

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `id` | `ASYNC_ID_W` | 完整 `async_id_t`。 |
| `domain` | 3 | 0=TC，1=TMEM_LD，2=TMEM_ST，3=TMA_BYTES，4=BULK_GROUP；其他值非法。 |
| `status` | `STATUS_W` | 0 成功，非 0 为模块诊断错误。 |
| `value` | 1 | 1 bit 诊断值；普通 MMA/CP/SHIFT 完成固定 0，TC commit 为诊断 phase，不作为 wait token。 |

#### tc_commit_t

Packed payload 总位宽为 `TC_COMMIT_W`（展开值 143 bit），按表序从高位到低位排列。

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `id` | `ASYNC_ID_W` | 完整 `async_id_t`。 |
| `barrier` | `SMEM_BYTE_ADDR_W` | 本 CTA SMEM byte 地址，8B 对齐；generic 指针由 Flash 转换后才编码。 |

#### async_key_a1_t

Packed payload 总位宽为 `ASYNC_KEY_A1_W`（展开值 116 bit），按表序从高位到低位排列。

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `ctx` | `CTX_ID_W` | 物理 context 槽。 |
| `id` | `ASYNC_ID_W` | 完整 `async_id_t`。 |

#### async_event_a1_t

Packed payload 总位宽为 `ASYNC_EVENT_A1_W`（展开值 128 bit），按表序从高位到低位排列。

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `ctx` | `CTX_ID_W` | 物理 context 槽，与 event.id.epoch 共同确定生命周期。 |
| `event` | `ASYNC_EVENT_W` | 完整 `async_event_t`，domain/status/value 规则见上表。 |

#### tc_commit_a1_t

Packed payload 总位宽为 `TC_COMMIT_A1_W`（展开值 148 bit），按表序从高位到低位排列。

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `ctx` | `CTX_ID_W` | 物理 context 槽。 |
| `commit` | `TC_COMMIT_W` | 完整 `tc_commit_t`，含同 issuer 身份及 barrier 地址。 |

事件 value 只表示零或 TC commit 诊断 phase。TMA 字节数/分组结果由 tma_rsp/bulk wait 接口传递，RF 完成由方向 DONE/wait 接口传递，不把这些数值塞入 1 bit value。domain 编码仍由类型表规定，各实际事件端口只接受本模块声明的完成域。

### MMA 命令

#### mma_cmd_a1_t

Packed payload 总位宽为 `MMA_CMD_A1_W`（展开值 665 bit），按表序从高位到低位排列。地址完整检查后才截取物理索引。

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `ctx` | `CTX_ID_W` | 物理 context 槽。 |
| `id` | `ASYNC_ID_W` | 完整 `async_id_t`。 |
| `kind` | 3 | 0=f16，1=tf32，2=f8f6f4，3=i8，4=mxf8f6f4，5=mxf4，6=mxf4nvf4。 |
| `a_type` | 4 | A 精度：0=FP16，1=BF16，2=TF32，3=E4M3，4=E5M2，5=E2M3，6=E3M2，7=E2M1，8=S8，9=U8。 |
| `b_type` | 4 | B 精度，编码同 a_type。 |
| `d_type` | 2 | 0=FP16，1=FP32，2=S32。 |
| `m` | 8 | 逻辑 M 元素数。 |
| `n` | 9 | 逻辑 N 元素数。 |
| `k` | 8 | 逻辑 K 元素数，sparse 使用完整 K。 |
| `a_desc` | `MATRIX_DESC_W` | A 的完整 SMEM matrix descriptor。 |
| `b_desc` | `MATRIX_DESC_W` | B 的完整 SMEM matrix descriptor。 |
| `a_tmem` | `TMEM_ADDR_W` | A 的 TMEM 地址，[31:16]=lane，[15:0]=column。 |
| `d_tmem` | `TMEM_ADDR_W` | D 的 TMEM 地址，编码同 a_tmem。 |
| `scale_a` | `TMEM_ADDR_W` | A scale 的 TMEM 地址，编码同 a_tmem。 |
| `scale_b` | `TMEM_ADDR_W` | B scale 的 TMEM 地址，编码同 a_tmem。 |
| `sparse_meta` | `TMEM_ADDR_W` | 稀疏 metadata 的 TMEM 地址，编码同 a_tmem。 |
| `a_from_tmem` | 1 | 1 从 TMEM 读取 A，0 从 a_desc 指定的 SMEM 读取 A。 |
| `sparse` | 1 | 启用 sparse MMA。 |
| `ws` | 1 | 启用 WS MMA。 |
| `ashift` | 1 | 执行 A 移动副作用。 |
| `input_d` | 1 | 启用旧 D 累加。 |
| `transpose_a` | 1 | A transpose 修饰，由 instruction descriptor 解码。 |
| `transpose_b` | 1 | B transpose 修饰，由 instruction descriptor 解码。 |
| `negate_a` | 1 | A negate 修饰。 |
| `negate_b` | 1 | B negate 修饰。 |
| `int_sat` | 1 | 整数最终饱和，仅 i8。 |
| `sp_selector` | 2 | 非 block-scale sparse 的 metadata 子列选择；block-scale 固定 0，不将 metadata 简化为零检测。 |
| `scale_input_d` | 4 | 仅非 WS 的 f16/tf32（含 SP），D 乘 2^(-value)；其他形式为 0。 |
| `scale_type` | 1 | 0=UE8M0，1=UE4M3。 |
| `scale_vec` | 2 | 0=无，1=1X，2=2X，3=4X。 |
| `scale_a_layout` | 1 | 固定 0=32-lane；1 在 SM100a 非法。 |
| `scale_a_id` | 2 | mxf8 为 0..3，mxf4/nvf4 仅 0 或 2。 |
| `scale_b_id` | 2 | mxf8 为 0..3，mxf4/nvf4 仅 0 或 2。 |
| `collector_op` | 2 | 0=discard，1=fill，2=use，3=lastuse。 |
| `collector_buffer` | 2 | 非 WS 的 A 仅 0，WS 的 B 为 0..3。 |
| `disable_lane_mask` | `TMEM_LANE_MASK_W` | bit j 为 1 禁止写物理 D lane j；WS 及 block-scale 形式置零。 |
| `zero_mask_enable` | 1 | 启用 WS 的 B 列零替换，未指定时为 0。 |
| `zero_mask_desc` | `MATRIX_DESC_W` | WS B 列零替换 descriptor，未指定时为 0。 |
| `ws_max_shift` | 2 | 0/1/2/3 对应允许复用时最大移位 0/8/16/32；完整重读 B 合法。 |

Flash 将 PTX 的 idesc、predicate 和操作数译码为此 payload；SMEM/TMEM 取数、layout、packing、scale/metadata 读取由 RTL 完成。Flash 不预计算 dot operands 或 MMA 结果。

### TMEM、RF、CP 与内存通道

#### RF LD/ST 命令

下列为扁平命令字段；LD pack/ST unpack 由方向解释，seq 在实际接受时由 subsystem 分配。

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `ctx` | `CTX_ID_W` | 物理 context 槽。 |
| `epoch` | `EPOCH_W` | context 生命周期编号。 |
| `warp` | `WARP_ID_W` | warp 编号，低 2 bit 选 32-lane 分区。 |
| `store` | 1 | 1=ST，0=LD。 |
| `shape` | 3 | 0=32x32b，1=16x64b，2=16x128b，3=16x256b，4=16x32bx2。 |
| `repeat` | `RF_REPEAT_W` | 重复次数及形状上限见 RF map。 |
| `pack16` | 1 | LD pack16 / ST unpack16 状态。 |
| `base_addr` | `TMEM_ADDR_W` | TMEM 地址，[31:16]=lane，[15:0]=column。 |
| `half_offset` | `TMEM_HALF_OFFSET_W` | 16x32bx2 的 column 偏移。 |
| `tag` | `ASYNC_TAG_W` | 用户请求 tag。 |

#### RF beat

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `data` | `RF_BEAT_W` | 32 thread 各一个 32 bit 寄存器，低位为 thread0。 |
| `index` | `RF_INDEX_W` | 从 0 起递增的寄存器向量索引。 |
| `last` | 1 | 最后一个寄存器向量。 |

### CP 命令

#### cp_cmd_a1_t

Packed payload 总位宽为 `CP_CMD_A1_W`（展开值 219 bit），按表序从高位到低位排列。

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `ctx` | `CTX_ID_W` | 物理 context 槽。 |
| `id` | `ASYNC_ID_W` | 完整 `async_id_t`。 |
| `base_addr` | `TMEM_ADDR_W` | TMEM 地址，[31:16]=lane，[15:0]=column。 |
| `smem_desc` | `MATRIX_DESC_W` | 完整 PTX matrix descriptor，不是 TMA v3。 |
| `shape` | 3 | 0=128x256b，1=128x128b，2=64x128b，3=32x128b，4=4x256b。 |
| `multicast` | 2 | 0=none，1=02_13，2=01_23，3=warpx4；仅 CTA 内部复制。 |
| `source_format` | 2 | 0=raw，1=b4x16_p64，2=b6x16_p32。 |

### SHIFT 命令

#### shift_cmd_a1_t

Packed payload 总位宽为 `SHIFT_CMD_A1_W`（展开值 148 bit），按表序从高位到低位排列。

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `ctx` | `CTX_ID_W` | 物理 context 槽。 |
| `id` | `ASYNC_ID_W` | 完整 `async_id_t`。 |
| `base_addr` | `TMEM_ADDR_W` | TMEM 地址，[31:16]=lane，[15:0]=column；无 repeat 或 TMA descriptor。 |

#### TMEM word 请求与响应

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `read.ctx` | `CTX_ID_W` | 物理 context 槽。 |
| `read.epoch` | `EPOCH_W` | context 生命周期编号。 |
| `read.tag` | `ASYNC_TAG_W` | 请求 tag。 |
| `read.lane_mask` | `TMEM_LANE_MASK_W` | bit j 选择 lane j。 |
| `read.column` | `TMEM_COLUMN_BUS_W` | 128 × 16 bit column，低位为 lane0；每个有效 lane 的 128 bit word 起点按 4 column 对齐。 |
| `write.ctx` | `CTX_ID_W` | 物理 context 槽。 |
| `write.epoch` | `EPOCH_W` | context 生命周期编号。 |
| `write.tag` | `ASYNC_TAG_W` | 请求 tag。 |
| `write.column` | `TMEM_COLUMN_BUS_W` | 128 × 16 bit word 起点 column，规则同 read.column。 |
| `write.data` | `TMEM_DATA_W` | 128 × 128 bit，低位为 lane0。 |
| `write.byte_mask` | `TMEM_BYTE_MASK_W` | 128 × 16 bit，mask 为 0 的 byte 保持。 |
| `read_rsp.data` | `TMEM_DATA_W` | 128 × 128 bit word 数据。 |
| `read_rsp.tag` | `ASYNC_TAG_W` | 原请求 tag。 |
| `read_rsp.status` | `STATUS_W` | 0 成功，非 0 为模块诊断。 |
| `write_rsp.tag` | `ASYNC_TAG_W` | 原请求 tag。 |
| `write_rsp.status` | `STATUS_W` | 0 成功，非 0 为模块诊断。 |

parent 先核对 owner/tag，再交给一次一个在途 bank 请求的子引擎；子端可省略 response tag。参数化 TAG_W 默认 16 bit，具体端口以模块表为准。

#### 外部 memory 字段

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `gmem.addr` | `GMEM_ADDR_W` | byte 地址，128B 对齐。 |
| `gmem.data` | `GMEM_DATA_W` | 128B 行数据。 |
| `gmem.byte_mask` | `GMEM_MASK_W` | 每 bit 选择一个实际访问 byte。 |
| `gmem.id` | `GMEM_ID_DEFAULT_W` | 默认事务 ID 位宽；参数 GMEM_ID_W 默认 5，MSHR 索引之外保留 descriptor ID 16。 |
| `smem.addr` | `SMEM_BYTE_ADDR_W` | byte 地址，32B 对齐。 |
| `smem.data` | `SMEM_DATA_W` | 32B 行数据。 |
| `smem.byte_mask` | `SMEM_MASK_W` | 每 bit 选择一个实际访问 byte。 |
| `smem.id` | `SUBSYSTEM_SMEM_ID_DEFAULT_W` | TMA/bar 聚合口默认 5 bit；bar 内部 MEM_ID_W 默认 1，TMA 叶模块 SMEM_ID_W 默认 4；集成 TMA local ID=max(1,clog2(MSHR_ENTRIES))。 |
| `tensor_smem.addr` | `SMEM_BYTE_ADDR_W` | MMA/CP 共享的 SMEM byte 读地址，32B 对齐。 |
| `tensor_smem.data` | `SMEM_DATA_W` | 32B 物理行数据，RTL 恢复 matrix layout。 |
| `tensor_smem.byte_mask` | `SMEM_MASK_W` | 每 bit 选择一个实际读取 byte。 |
| `tensor_smem.id` | `TENSOR_SMEM_ID_W` | MMA/CP 的事务 ID，MMA fetch 位置编号为 0..127；活动引擎检查 live ID，顶层按稳定执行 owner 路由。 |
| `memory.status` | `MEM_STATUS_W` | 0 成功，非 0 失败。 |
| `module.status` | `STATUS_W` | 0 成功，1..255 均为模块诊断错误，包含未命名诊断值；不得混淆未满足等待与错误。 |

地址均以 byte 或明确的 TMEM column 为单位。GMEM请求地址按128B对齐、SMEM按32B对齐；mask[j]/data[8*j+:8]对应addr+j，最低bit为低地址byte。未选读byte返回0；所有读写byte mask约束**实际访问**，不能先整行越界读再屏蔽。response 成功表示所请求访问已经完成；写完成可供后续同地址读观察，跨 proxy/scope 的可见性还需 ordering。reduction 由外部后端逐元素原子执行，atomic128按自然对齐16B单位执行；multimem成功意味着全部目标完成。

### TMA、barrier 与 ordering 类型

以下 packed 类型的操作码和枚举数值使用[tma_mbarrier_pkg 编码](../../../rtl/common/tma_mbarrier_pkg.sv)，字段顺序及位宽以本规范的字段表为准。同一实例只有一个活跃 CTA，外层 lifecycle 绑定 ctx/epoch，排空前不得切换。

### TMA 命令与响应

#### tma_cmd_t

Packed payload 总位宽为 `TMA_CMD_W`（展开值 778 bit），按表序从高位到低位排列。

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `opcode` | 4 | TMA_OP_* 操作码，保留 0..15 的枚举数值；barrier 的 MBAR_OP_* 使用 bar_cmd_t。 |
| `tag` | `ASYNC_TAG_W` | 用户请求 tag，响应原样恢复。 |
| `issuer` | `ISSUER_ID_W` | CTA 内执行 thread ID。 |
| `seq` | `SEQ_W` | 同 issuer 的操作序号，递增且不回绕。 |
| `desc_ptr` | `max(GMEM_ADDR_W, SMEM_BYTE_ADDR_W)` | 128B 项目 v3 tensor map 的 byte 地址，按 global/shared 选择解释。 |
| `coord` | `TENSOR_COORD_VECTOR_W` | 5 × signed32 坐标，低 32 bit 为 coord0。 |
| `smem_addr` | `SMEM_BYTE_ADDR_W` | SMEM byte 地址。 |
| `linear_addr` | `max(GMEM_ADDR_W, SMEM_BYTE_ADDR_W)` | linear 源/目标 byte 地址，所属空间按 opcode。 |
| `linear_bytes` | 32 | linear 逻辑 payload 字节数。 |
| `barrier_addr` | `SMEM_BYTE_ADDR_W` | 本 CTA SMEM byte 地址，8B 对齐；generic 指针由 Flash 转换后才编码。 |
| `mode` | 3 | 0=tile，1=im2col，2=im2col_w，3=im2col_w128，4=im2col_no_offs，5=gather4，6=scatter4。 |
| `im2col` | `IM2COL_W` | {wOffset,wHalo,offsetD,offsetH,offsetW}，各 16 bit。 |
| `completion` | 2 | 0=mbarrier，1=bulk group，2=none；与 opcode 的合法组合见 TMA engine。 |
| `multi_cta` | 1 | 固定 0。 |
| `wait_n` | 32 | WAIT_GROUP 保留的最近 group 数。 |
| `wait_read` | 1 | 1 等待源读取，0 等待完整复制边界。 |
| `dtype` | 4 | 元素精度编码，按 package 的 TMA_TYPE_*。 |
| `reduce_op` | 3 | reduction 编码，按 package 的 TMA_RED_*。 |
| `multimem` | 1 | 访问全部多目标，成功意味着所有目标完成。 |
| `cp_mask_enable` | 1 | 启用 16B 内的 byte 复制 mask。 |
| `cp_mask` | 16 | 重复应用于 16B 单位的 byte mask；0 的 byte 不访问。 |
| `ignore_oob` | 1 | 启用指令规定的越界忽略。 |
| `oob_start` | 4 | linear load 首部忽略字节数，0..15 byte。 |
| `oob_end` | 4 | linear load 尾部忽略字节数，0..15 byte。 |
| `atomic128` | 1 | 按自然对齐 16B 单位原子访问。 |
| `sem` | 2 | 0=relaxed，1=release，2=acquire。 |
| `scope` | 2 | 0=CTA，1=cluster，2=GPU，3=system。 |
| `cache_hint` | 1 | 启用 cache policy 提示。 |
| `cache_policy` | `CACHE_POLICY_W` | 外部后端兑现的 cache policy。 |
| `map_shared` | 1 | 1 为 shared descriptor，0 为 global descriptor。 |
| `replace_field` | 4 | tensormap.replace 字段编号，编码见 TMA 字段行为定义。 |
| `replace_ord` | 3 | 被替换字段的维度 ordinal。 |
| `replace_value` | 64 | 独立 replace 的值。 |
| `from_proxy` | 2 | 源 proxy：0=generic，1=async，2=tensormap。 |
| `to_proxy` | 2 | 目标 proxy，编码同 from_proxy。 |
| `warp_converged` | 1 | CP_FENCE 的 warp 到齐条件，由 Flash 保证。 |

#### tma_rsp_t

Packed payload 总位宽为 `TMA_RSP_W`（展开值 98 bit），按表序从高位到低位排列。

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `tag` | `ASYNC_TAG_W` | 用户请求 tag，响应原样恢复。 |
| `issuer` | `ISSUER_ID_W` | CTA 内执行 thread ID。 |
| `status` | `STATUS_W` | 0 成功，非 0 为模块诊断。 |
| `bytes` | `BYTE_COUNT_W` | 规定的完成 payload 字节数，不含 SMEM 容器 padding。 |

### Barrier 命令与响应

#### bar_cmd_t

Packed payload 总位宽为 `BAR_CMD_W`（展开值 305 bit），按表序从高位到低位排列。

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `opcode` | 5 | 项目操作码，取对应 TMA_OP_* / MBAR_OP_* 编码。 |
| `tag` | `ASYNC_TAG_W` | 用户请求 tag，响应原样恢复。 |
| `issuer` | `ISSUER_ID_W` | CTA 内执行 thread ID。 |
| `seq` | `SEQ_W` | 同 issuer 的操作序号，递增且不回绕。 |
| `addr` | `SMEM_BYTE_ADDR_W` | 本 CTA SMEM byte 地址，8B 对齐；generic 指针由 Flash 转换后才编码。 |
| `arrive_count` | `BARRIER_COUNT_W` | arrival/expected 计数增减量。 |
| `tx_bytes` | `BARRIER_TX_BYTES_W` | EXPECT_TX/COMPLETE_TX 的 unsigned32 transaction 增减量，单位 byte；不含容器 padding。 |
| `phase_token` | 1 | parity wait 的输入 phase；wait_parity=1 时使用。 |
| `wait_parity` | 1 | 1 选择 phase_token 指定的 parity wait；0 使用 state 中的 opaque token。 |
| `state` | `BARRIER_STATE_W` | opaque barrier token。 |
| `time_hint` | `BARRIER_TIME_HINT_W` | 有限等待提示，单位 ns；0 采用默认周期数。 |
| `layout` | 1 | 0=v0，1=v1。 |
| `no_complete` | 1 | noComplete 修饰，不得使 pending=tx=0。 |
| `conditional` | 1 | v1 conditional 修饰。 |
| `report` | `BARRIER_REPORT_W` | 8 bit report payload，独立于错误诊断。 |
| `noinc` | 1 | CP_ASYNC_ARRIVE 不先增加 pending。 |
| `sem` | 2 | 0=relaxed，1=release，2=acquire。 |
| `scope` | 2 | 0=CTA，1=cluster，2=GPU，3=system。 |

#### bar_rsp_t

Packed payload 总位宽为 `BAR_RSP_W`（展开值 143 bit），按表序从高位到低位排列。

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `tag` | `ASYNC_TAG_W` | 用户请求 tag，响应原样恢复。 |
| `issuer` | `ISSUER_ID_W` | CTA 内执行 thread ID。 |
| `status` | `STATUS_W` | 0 成功，非 0 为模块诊断。 |
| `phase` | 1 | 诊断 phase。 |
| `locked` | 1 | 对象锁定状态。 |
| `state` | `BARRIER_STATE_W` | 操作前 phase/pending 的 opaque token，编码见 barrier unit。 |
| `wait_complete` | 1 | 成功 wait 必须为 1；未满足 TEST_WAIT 可为 0 且 status=OK。 |
| `value` | `BARRIER_COUNT_W` | 查询返回计数。 |
| `predicate` | 1 | 查询/布局谓词。 |
| `report` | `BARRIER_REPORT_W` | 对应成功 wait 的 report payload。 |
| `report_predicate` | 1 | 成功 wait 的 report 有效谓词。 |

#### bar_report_req_t

Packed payload 总位宽为 `BAR_REPORT_REQ_W`（展开值 56 bit），按表序从高位到低位排列。

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `tag` | `ASYNC_TAG_W` | 用户请求 tag，响应原样恢复。 |
| `addr` | `SMEM_BYTE_ADDR_W` | 本 CTA SMEM byte 地址，8B 对齐；generic 指针由 Flash 转换后才编码。 |
| `value` | `BARRIER_REPORT_W` | 8 bit report-on payload，与 status 独立。 |

### 普通 async 登记与完成

#### bw_async_req_t

Packed payload 总位宽为 `BW_ASYNC_REQ_W`（展开值 83 bit），按表序从高位到低位排列。

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `complete` | 1 | 0 登记普通 cp.async，1 报告完成；独立完成入口能在登记表满时释放资源。 |
| `issuer` | `ISSUER_ID_W` | CTA 内执行 thread ID。 |
| `seq` | `SEQ_W` | 同 issuer 的操作序号，递增且不回绕。 |
| `status` | `STATUS_W` | 0 成功，非 0 为模块诊断。 |

#### bw_async_rsp_t

Packed payload 总位宽为 `BW_ASYNC_RSP_W`（展开值 82 bit），按表序从高位到低位排列。

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `issuer` | `ISSUER_ID_W` | CTA 内执行 thread ID。 |
| `seq` | `SEQ_W` | 同 issuer 的操作序号，递增且不回绕。 |
| `status` | `STATUS_W` | 0 成功，非 0 为模块诊断。 |

### 内存属性与 ordering

#### bw_mem_attr_t

Packed payload 总位宽为 `BW_MEM_ATTR_W`（展开值 156 bit），按表序从高位到低位排列。

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `kind` | 2 | 0=read，1=write，2=reduce，3=prefetch。 |
| `dtype` | 4 | 元素精度编码，按 package 的 TMA_TYPE_*。 |
| `reduce_op` | 3 | reduction 编码，按 package 的 TMA_RED_*。 |
| `multimem` | 1 | 访问全部多目标，成功意味着所有目标完成。 |
| `atomic128` | 1 | 按自然对齐 16B 单位原子访问。 |
| `issuer` | `ISSUER_ID_W` | CTA 内执行 thread ID。 |
| `seq` | `SEQ_W` | 同 issuer 的操作序号，递增且不回绕。 |
| `scope` | 2 | 0=CTA，1=cluster，2=GPU，3=system。 |
| `proxy` | 2 | 0=generic，1=async，2=tensormap。 |
| `cache_hint` | 1 | 启用 cache policy 提示。 |
| `cache_policy` | `CACHE_POLICY_W` | 外部后端兑现的 cache policy。 |
| `l2_promotion` | 2 | L2 promotion 提示，按 v3 descriptor 编码。 |

#### bw_order_req_t

Packed payload 总位宽为 `BW_ORDER_REQ_W`（展开值 226 bit），按表序从高位到低位排列。

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `id` | `ORDER_ID_W` | 本 ordering 通道事务 ID，响应匹配此 ID。 |
| `issuer` | `ISSUER_ID_W` | CTA 内执行 thread ID。 |
| `seq` | `SEQ_W` | 同 issuer 的操作序号，递增且不回绕。 |
| `kind` | 2 | 0=release，1=acquire，2=proxy。 |
| `scope` | 2 | 0=CTA，1=cluster，2=GPU，3=system。 |
| `from_proxy` | 2 | 源 proxy：0=generic，1=async，2=tensormap。 |
| `to_proxy` | 2 | 目标 proxy，编码同 from_proxy。 |
| `addr` | `max(GMEM_ADDR_W, SMEM_BYTE_ADDR_W)` | 可见性范围的 byte 起点；非连续 tensor 使用 (addr,bytes)=(0,0)。 |
| `bytes` | `BYTE_COUNT_W` | 范围字节数；(0,0) 表示 seq 覆盖的全部访问。 |

#### bw_order_rsp_t

Packed payload 总位宽为 `BW_ORDER_RSP_W`（展开值 24 bit），按表序从高位到低位排列。

| 接口名 | 位宽 | 说明 |
| --- | --- | --- |
| `id` | `ORDER_ID_W` | 本 ordering 通道事务 ID，响应匹配此 ID。 |
| `status` | `STATUS_W` | 0 成功，非 0 为模块诊断。 |

scope编码0=CTA/1=cluster/2=GPU/3=system；proxy编码0=generic/1=async/2=tensormap；order kind0=release/1=acquire/2=proxy。本地对象可带合法cluster scope，但不产生远端对象访问。release确认发布该issuer相应序号以前的内存操作，acquire确认建立规定可见性；ack不能只表示排队或只刷新barrier自身8B。非连续tensor的range=(0,0)代表seq覆盖的全部访问。

TMA使用项目私有128B v3 tensor map，字段/bit位置沿用v3编码表（原文档已清理），小端、保留bit为0。Flash把CUDA tensor map转换为v3字段，不复制opaque编码。MMA/CP使用64bit PTX matrix descriptor，两种descriptor不可互换；其地址生成留在RTL。

### 默认容量与完成域

TMEM=128×512×32bit、CONTEXTS=32；一个实例同一时刻只执行一个CTA。MMA/CP/SHIFT/LDST各一执行槽、TMEM命令级独占；固定四个物理core，每core32逻辑行，M128/M64/M32只启用TC0–3/TC0–1/TC0；每core四类独立64-dot阵列，输出tile固定8×8，总1024颗dot；不以实例数代替实际服务吞吐。Flash提供228KiB SMEM容量并检查有效地址空间；RTL不另存一份SMEM。TMA queue8/cache4/MSHR16、每次一条active copy；bar cache4/write8/wait32/ordinary-async16/command44；TC op1/commit8；RF op1/wait16。顶层采用轮询仲裁，无在途命令抢占。

TC完成含MMA的D写及ashift副作用、CP/SHIFT写确认；它们不进入RF wait。LD完成含最后RF握手，ST含最后bank写确认；它们不进入TC commit。TMA bytes更新transaction计数，TC commit只产生arrival count=1。容量不足反压，已接受工作最终进展以外部memory/order最终响应和外部响应最终消费为前提。

## 3. 伪代码

### 接受、执行完成和通知

```text
cmd_rdy = execution_available && tracker_available && completion_reserved && done_reserved
on cmd_fire: capture payload; reserve credits; start once
    MMA/CP/SHIFT: top registers TC key once
    LD/ST: RF subsystem registers direction key once
on all_required_data_acks:
    hold internal_complete(key, status) until tracker_fire
on tracker_fire:
    retire dependency once; enqueue one DONE only in its owning module; release owner
on done_fire: release DONE slot                 // 不再次退休 dependency
```

### 快照与生命周期

```text
on commit_or_wait_fire:
    snapshot = matching_operations_live_before_edge
    snapshot -= matching_completions_on_edge
    status = sticky_failure OR failure_on_edge
on each completion: clear its bit in every snapshot before reusing its slot
on management_request: stop new data grants; continue completions, waits and memory responses
on drained: execute management; acknowledge only after its state update completes
on CTA_exit: drain → explicit dealloc → destroy → quiescent reset → create new lifetime
```
