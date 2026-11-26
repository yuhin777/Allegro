# Supported PTX for Allegro v1

The initial semantic baseline is PTX 8.7, SM100a, one CTA, and `cta_group::1`. One backend serves one active CTA. A launch can contain multiple CTAs. The surrounding system enforces issue granularity, warp convergence, thread identity, and synchronization dependencies. See the [Microarch Brief](microarch_brief.md) for resources and performance targets.

## 1. Target workloads

| ID | kernel / case | Coverage |
|---|---|---|
| L | `linear_bulk_two_phase_kernel` | Two rounds of linear G2S, each issuing four 4096 B copies against the same mbarrier |
| F1 | `H32D64FullB2S128` | FP16 FA4 with SMEM A/B and N128 for QK, TMEM A, SMEM B, and N64 for PV |
| F2 | `H16D128CausalB32S1024` | FP16 causal FA4 with SMEM A/B and N128 for QK, TMEM A, SMEM B, and N128 for PV |

The pinned versions are FlashGPU-Sim `7a48f7685d604d71da3692fb1b24825fdb7cc79c`, flash-attention `d80a77103021c4e980f8cbbf85774f6a19e6474a`, and CuTe DSL 4.5.2. Coverage comprises these three workloads plus the precisions and WS forms explicitly listed below. Other FlashGPU-Sim SM100 tests are outside this scope. [Linear kernel](https://github.com/FlashGPU-Sim/FlashGPU-Sim/blob/7a48f7685d604d71da3692fb1b24825fdb7cc79c/tests/src/tma/tma_test.cu#L380-L446) · [mbarrier helper](https://github.com/FlashGPU-Sim/FlashGPU-Sim/blob/7a48f7685d604d71da3692fb1b24825fdb7cc79c/tests/src/include/ptx/mbarrier.cuh) · [FA4 cases](https://github.com/FlashGPU-Sim/FlashGPU-Sim/blob/7a48f7685d604d71da3692fb1b24825fdb7cc79c/tests/dsl/cutedsl/validation/fa4_forward.py) · [QK/PV definition](https://github.com/Dao-AILab/flash-attention/blob/d80a77103021c4e980f8cbbf85774f6a19e6474a/flash_attn/cute/flash_fwd_sm100.py#L474-L498)

<a id="dense-mma"></a>
## 2. Dense MMA

M=128, N∈{64,128,256}, and kind determines K. The ordinary form is `tcgen05.mma.cta_group::1.kind::*`. Scaled kinds use `.block_scale` with their legal scale-vector modifiers. The WS form is `tcgen05.mma.ws.cta_group::1.kind::*`. The table contains 33 kind/mode/shape combinations. Dtype cross-products and scale combinations receive separate coverage.

| kind | A/B formats | K | D | Ordinary | WS |
|---|---|---:|---|---|---|
| f16 | FP16 or BF16, independently selected per input | 16 | FP32 | Yes | Yes |
| tf32 | TF32 × TF32 | 8 | FP32 | Yes | Yes |
| f8f6f4 | E4M3, E5M2, E3M2, E2M3, or E2M1, independently selected per input | 32 | FP32 | Yes | Yes |
| i8 | S8 or U8, independently selected per input | 32 | S32 | Yes | Yes |
| mxf8f6f4 | The five low-precision formats above with UE8M0 1X | 32 | FP32 | Yes | No |
| mxf4 | E2M1 × E2M1, UE8M0 2X | 64 | FP32 | Yes | No |
| mxf4nvf4 | E2M1 × E2M1 with UE8M0 2X or UE4M3 4X | 64 | FP32 | Yes | No |

A single thread issues MMA. A comes from an SMEM descriptor or a TMEM address and B from an SMEM descriptor. Interpret their layouts according to the [matrix descriptor](../rtl_specs/tensor_core/blackwell_tc_mma_engine.md#matrix-descriptor), [TMEM layout](../rtl_specs/tmem/blackwell_tmem_fabric.md#tmem-layout), and [scale layout](../rtl_specs/tensor_core/blackwell_tc_scale_b_snapshot.md#scale-layout). F1/F2 require K-major QK, MN-major V, and the corresponding swizzle. Contiguous-only addressing is insufficient. Arithmetic follows the [dot arithmetic rules](../rtl_specs/tensor_core/blackwell_tc_dot_array.md#numeric-routing).

- `enable-input-d` selects old D or zero as C. Consecutive MMAs from the same issuer using the same accumulator must see the preceding result. Completion requires every actual D write ACK and resource release. Commit must not produce an early arrival.
- Floating-point negate support depends on kind. i8 selects A/B signedness independently. Only i8 allows final saturation, and both its negate bits must be zero. Ordinary f16/tf32 allow `scale-input-d`. Other forms require zero. Neither native FP4 kind allows transpose.
- The four ordinary base kinds allow disable-output-lane. WS and block-scale require all output lanes enabled. Scale type, vector size, address, and ID must form a legal combination for the layout. UE8M0 4X is unsupported.
- Ordinary and WS source data must remain valid for the PTX-defined lifetime, including on collector hits.

[PTX shape table](https://docs.nvidia.com/cuda/archive/12.8.2/parallel-thread-execution/index.html#tcgen05-kind-shapes) · [Block-scale combinations](https://docs.nvidia.com/cuda/archive/12.8.2/parallel-thread-execution/index.html#valid-combinations-of-scale-vec-size-with-types-and-mma-kind)

## 3. Collector

Ordinary MMA supports `a::{fill,use,lastuse,discard}` and defaults to a::discard. WS supports `b0…b3::{fill,use,lastuse,discard}` and defaults to b0::discard. Names apply within the current CTA/epoch. Software coordinates reuse of a name across threads. TC commit still isolates by full issuer identity.

Fill loads the source. A legal use can reuse a complete matching resident entry. A physical miss may reread the source. Lastuse permits discard after use, and discard can fill directly from source. Cross-instruction ordinary A hits are implementation-dependent. Software provides valid sequences, including the required fill. A physical miss alone raises no hardware error. [PTX collector rules](https://docs.nvidia.com/cuda/archive/12.8.2/parallel-thread-execution/index.html#tensorcore-5th-generation-matrix-multiply-and-accumulate-operations) · [WS instructions](https://docs.nvidia.com/cuda/archive/12.8.2/parallel-thread-execution/index.html#tensorcore-5th-generation-instructions-tcgen05-mma-ws)

WS names can map to resident regions of different sizes. Cross-instruction reuse requires complete installation on all four cores. See [MMA engine](../rtl_specs/tensor_core/blackwell_tc_mma_engine.md#b-residency) for partition allocation, LRU, and reload timing.

## 4. Asynchronous data and synchronization instructions

Only the listed forms are supported. L/F1/F2 identify the target workloads using them. Normalize omitted default scopes according to PTX. `shared::cluster` accepts only addresses provably local to this CTA. Remote and multicast accesses are outside scope.

| Instruction or family | Legal operands, granularity, and completion boundary | Workload / owner |
|---|---|---|
| `tcgen05.alloc.cta_group::1.sync.aligned.shared::cta.b32`, `tcgen05.dealloc.cta_group::1.sync.aligned.b32`, `tcgen05.relinquish_alloc_permit.cta_group::1.sync.aligned` | Converged warp with uniform operands. F1/F2 exclusively own 512 columns at base=0. ALLOC writes its result to SMEM [dst] and waits at ingress if the allocation is occupied. Release only after use ends. DEALLOC returns INVALID while references remain. Smaller allocations are outside scope. [TMEM management commands](../rtl_specs/tmem/blackwell_tmem_manager.md#management-types) | F1/F2 / manager and external SMEM write |
| `tcgen05.ld.sync.aligned.32x32b.x16.b32`, `tcgen05.ld.sync.aligned.32x32b.x32.b32`, `tcgen05.st.sync.aligned.32x32b.x16.b32`, `tcgen05.wait::st.sync.aligned` | Converged warp, ordinary b32, no pack. LD waits for final RF writeback. ST waits for its last actual write ACK. wait::st waits for the warp's set of preceding stores. | F1/F2 / LDST, RF tracker |
| `tcgen05.commit.cta_group::1.mbarrier::arrive::one.b64`, including the local `shared::cluster` form | One thread captures earlier operations of the same issuer in the current CTA/epoch, excluding operations accepted on the same edge. Successful completion submits exactly one arrival. An error must not wake a waiter successfully. | F1/F2 / TC tracker, completion bridge |
| `cp.async.bulk.shared::cta.global.mbarrier::complete_tx::bytes` | Single thread, 16 B aligned base, length a multiple of 16 B. Submit complete-tx once all actual destination SMEM write ACKs settle. | L / TMA, mbarrier |
| `cp.async.bulk.tensor.4d.shared::cluster.global.tile.mbarrier::complete_tx::bytes.L2::cache_hint`, `cp.async.bulk.tensor.4d.global.shared::cta.tile.bulk_group.L2::cache_hint` | Single thread, rank-4 FP16 project [Tensor Map](../rtl_specs/tma/blackwell_tma_setup.md#tensor-map), four s32 coordinates. Q/K/V are loaded and O is stored. A load waits for destination writes and complete-tx. A store has separate source-read and destination write ACK completion boundaries. | F1/F2 / TMA |
| `cp.async.bulk.commit_group`, `cp.async.bulk.wait_group.read` | Single thread, cutoff group of the same issuer. Wait supports immediates 0/1 only. `.read` waits for source reads. Destination write ACKs retire separately. | F1/F2 / TMA unit |
| `mbarrier.init.shared::cta.b64`, `mbarrier.inval.shared::cta.b64` | Single thread, local 8 B aligned object. Init initializes atomically. Inval waits for references to leave and backing confirmation. Includes the default `.shared` spelling. | L/F1/F2 / barrier frontend, unit, backing |
| `mbarrier.arrive.expect_tx.shared::cta.b64` and `.arrive.expect_tx.release.cta.shared::cta.b64`, and `mbarrier.arrive.release.cta.shared::cta.b64` | Single thread. expect_tx registers bytes and arrives at the same commit point. L registers 16384 B per phase. Release requires actual ordering. | L/F1/F2 / barrier frontend, unit |
| `mbarrier.try_wait.parity.shared::cta.b64`, including default `.shared` and default acquire semantics | Single thread, target parity. A time hint is allowed and cannot bypass phase matching or acquire visibility. | L/F1/F2 / barrier wait, ordering |
| `fence.proxy.async.shared::cta`, `fence.mbarrier_init.release.cluster` | Single thread. Publish the relevant preceding generic shared writes and barrier initialization, respectively. Cluster scope is restricted to this CTA. Completion requires actual ordering acknowledgment. | L/F1/F2 / TMA or barrier front end and external ordering |
| `prefetch.tensormap` | Descriptor prefetch hint. It neither transfers tile data nor substitutes for copy completion. | F1/F2 / descriptor cache |

The surrounding system handles address arithmetic, branching, softmax, RF, ordinary LSU, `bar.sync`/`bar.arrive`/`bar.warp.sync`, `elect.sync`, and `setmaxnreg`. It must supply actual RF acceptance, memory ACKs, visibility acknowledgments, and thread arrivals at their specified edges. Tensor Map uses the published project encoding. The surrounding system normalizes host descriptors. NVIDIA opaque binary compatibility is outside the contract.

## 5. Exclusions and workload guarantees

Unsupported forms include sparse, M32/M64 or other M sizes, FP16 MMA results, cross-CTA operation, `.ashift`, standalone SHIFT, `tcgen05.cp`, an active zero-column mask, nonzero column shift, and UE8M0 4X. Unlisted TMEM shapes/repeats, pack/unpack, `tcgen05.wait::ld`, `tcgen05.fence`, TMA ranks/types, linear store, map replace, reduction, multicast, and registration of ordinary cp.async with a barrier are outside scope.

Before asynchronous registration, the surrounding system rejects detectable out-of-scope PTX (UNSUPPORTED), illegal encodings (INVALID), and out-of-range addresses (RANGE). A memory, ordering, or protocol error in an active transaction terminates the run with a sticky fault. [Top-level recovery contract](../rtl_specs/top/blackwell_async_subsystem_top.md#common-protocol)

F1/F2 cover QK → TMEM/RF intermediates → PV → O writeback. Under the documented data and ACK conditions, consecutive K16 first dots within one product are 64 cycles apart for QK, and 32 (F1) or 64 (F2) for PV. The two 16 KiB F2 copies for a stage submit separately. Consumption requires completion of all 32,768 B and successful acquire. [FA4 addresses and timing](mma_inter_instruction_pipeline.md)
