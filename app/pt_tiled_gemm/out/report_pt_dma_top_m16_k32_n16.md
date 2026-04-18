# PT Application Report (M=16, K=32, N=16, target=PT_DMA_TOP)

## Corrected Shape / Notation
- A = 16x32
- B = 32x16
- C = 16x16
- App target: `PT_DMA_TOP`
- Notation: `M=16, K=32, N=16`
- PT primitive: `16x16 full-tile MATMUL`
- per_tensor inverse scale: `0x00010000`

## Tile Summary
| Metric | Value |
| --- | ---: |
| `tile_dim` | 16 |
| `m_tiles` | 1 |
| `k_tiles` | 2 |
| `n_tiles` | 1 |
| `output_tiles` | 1 |
| `partial_matmuls` | 2 |

## K-Slice Decomposition
### M Tiles
| Tile | Range | Size |
| --- | --- | ---: |
| `m0` | `0:16` | 16 |

### K Tiles
| Tile | Range | Size |
| --- | --- | ---: |
| `k0` | `0:16` | 16 |
| `k1` | `16:32` | 16 |

### N Tiles
| Tile | Range | Size |
| --- | --- | ---: |
| `n0` | `0:16` | 16 |

## Reduction Strategy Comparison
| Algorithm | Ranking Cycles | Source | Estimated Cycles | DMA Reqs | Export Reqs | Export Beats | MATADD Count | Host Add Ops |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `host_reduce_direct_tiled_matmul` | 274.0 | measured | 190.0 | 4 | 2 | 32 | 0 | 256 |
| `host_reduce_direct_pipelined` | 159.0 | measured | 159.0 | 4 | 2 | 32 | 0 | 256 |
| `host_reduce_load_then_matmul` | 312.0 | measured | 210.0 | 4 | 2 | 32 | 0 | 256 |
| `pt_matadd_reduce` | 457.0 | measured | 265.0 | 5 | 3 | 48 | 1 | 0 |

## Recommendation
- Winner: `host_reduce_direct_pipelined`
- Ranking source: `measured`
- Reasoning:
  - 问题定义：A=16x32，B=32x16，C=16x16。
  - 当前 app target = PT_DMA_TOP。
  - 当前 PT primitive 固定为 16x16x16 full-tile MATMUL。
  - 因此完整问题会被分解成 M_tiles * K_tiles * N_tiles = 2 次 partial GEMM。
  - 默认 per_tensor inverse scale 固定为 0x00010000。
  - 该 target 会经过 AXI-Lite CSR + DMA descriptor wrapper，再驱动内部 PT datapath。
  - 当前 winner 基于 `/Users/yucheng/Documents/GitHub/flash_atten/app/pt_tiled_gemm/out/verify_metrics_pt_dma_top_m16_k32_n16.json` 中的实测结果排序。

### Command Sequences
- `host_reduce_direct_tiled_matmul`
  - CFG A_BASE
  - CFG B_BASE
  - QCFG(per_tensor, payload=0x0001_0000)
  - 对每个输出 tile C[m_i, n_j]，遍历所有 K tiles：
  -   MATMUL(A[m_i, k_t], B[k_t, n_j]) -> P_t
  - HOST: reduce(P_0..P_t) -> C[m_i, n_j]
  - Note: 最贴合当前 RTL：所有 partial 只用原生 full-tile MATMUL。
  - Note: host 端额外逐元素加法 = (K_tiles-1) * M * N = 256。
- `host_reduce_direct_pipelined`
  - CFG A_BASE
  - CFG B_BASE
  - QCFG(per_tensor, payload=0x0001_0000)
  - 对每个输出 tile C[m_i, n_j]，遍历所有 K tiles：
  -   先发起 MATMUL(A[m_i, k_t], B[k_t, n_j])
  -   在前一个 partial 仍在 compute/export 时继续发下一个 MATMUL
  - HOST: drain/export 完成后 reduce(P_0..P_t) -> C[m_i, n_j]
  - Note: 当前 app testbench 使用 pipeline_depth=2，受 `M_PHYSICAL_COPIES=2` 限制。
  - Note: fallback estimate 来自当前 16x16 app-level re-measurement，而不是低层 structural perf model。
- `host_reduce_load_then_matmul`
  - CFG A_BASE
  - CFG B_BASE
  - QCFG(per_tensor, payload=0x0001_0000)
  - 对每个输出 tile C[m_i, n_j]，遍历所有 K tiles：
  -   LOAD(A[m_i, k_t], B[k_t, n_j])
  -   MATMUL(A[m_i, k_t], B[k_t, n_j]) -> P_t
  - HOST: reduce(P_0..P_t) -> C[m_i, n_j]
  - Note: 相对 direct path，多了显式 LOAD 控制开销。
- `pt_matadd_reduce`
  - CFG A_BASE
  - CFG B_BASE
  - QCFG(per_tensor, payload=0x0001_0000)
  - 对每个输出 tile C[m_i, n_j]：
  -   MATMUL(A[m_i, k_0], B[k_0, n_j]) -> P0
  -   MATMUL(A[m_i, k_1], B[k_1, n_j]) -> P1
  -   MATADD(P1, ext=P0) -> S01
  -   重复直到完成全部 K tiles
  - Note: host 只负责把上一步 export 结果重新注册成下一次 MATADD 的 external C tile。
  - Note: MATADD 次数 = output_tiles * (K_tiles - 1)。

## Unsupported / Not Recommended Paths
- `same_id_k_slice_swap`: A/B residency 是 cache-by-id；不换 ctrl_id 时不会形成预期的新 A/B reload。
  - observed_dma_increment: 0
  - observed_same_result: True

## Verification Results
- success: True
- target: `PT_DMA_TOP`
- simulator: `icarus`
- tests: 5
- failures: 0
- errors: 0
- results_xml: `/Users/yucheng/Documents/GitHub/flash_atten/app/pt_tiled_gemm/out/cocotb/pt_dma_top/m16_k32_n16/icarus/results.xml`
- metrics_path: `/Users/yucheng/Documents/GitHub/flash_atten/app/pt_tiled_gemm/out/verify_metrics_pt_dma_top_m16_k32_n16.json`
