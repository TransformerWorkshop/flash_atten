# PT 16x64x16 Application Report

## Corrected Shape / Notation
- A = 16x64
- B = 64x16
- C = 16x16
- Notation: `M=16, K=64, N=16`
- PT primitive: `16x16 full-tile MATMUL`
- per_tensor inverse scale: `0x00010000`

## K-Slice Decomposition
| Slice | A slice | B slice | Shape |
| --- | --- | --- | --- |
| 0 | `A[:, 0:16]` | `B[0:16, :]` | `16x16 * 16x16` |
| 1 | `A[:, 16:32]` | `B[16:32, :]` | `16x16 * 16x16` |
| 2 | `A[:, 32:48]` | `B[32:48, :]` | `16x16 * 16x16` |
| 3 | `A[:, 48:64]` | `B[48:64, :]` | `16x16 * 16x16` |

## Reduction Strategy Comparison
| Algorithm | Ranking Cycles | Source | Estimated Cycles | DMA Reqs | Export Reqs | Export Beats | MATADD Count | Host Add Ops |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `host_reduce_direct_4x_matmul` | 547.0 | measured | 452.0 | 8 | 4 | 64 | 0 | 768 |
| `host_reduce_load_then_matmul` | 567.0 | measured | 492.0 | 8 | 4 | 64 | 0 | 768 |
| `pt_matadd_reduce` | 973.0 | measured | 731.0 | 11 | 7 | 112 | 3 | 0 |

## Recommendation
- Winner: `host_reduce_direct_4x_matmul`
- Ranking source: `measured`
- Reasoning:
  - 问题已纠正为 A=16x64、B=64x16、C=16x16，即 M=16, K=64, N=16。
  - 当前 PT 只能原生执行 full-tile 16x16x16 MATMUL，因此 K=64 需要拆成 4 个 K-slice partial GEMM。
  - 默认 `per_tensor` inverse scale 固定为 0x0001_0000，用于保证小范围测试下 partial sum 精确累加。
  - 当前 winner 基于 `/Users/yucheng/Documents/GitHub/flash_atten/app/pt_mnk16x64x16/out/verify_metrics.json` 中的实测结果排序。

### Command Sequences
- `host_reduce_direct_4x_matmul`
  - CFG A_BASE
  - CFG B_BASE
  - QCFG(per_tensor, payload=0x0001_0000)
  - MATMUL(A0, B0) -> P0
  - MATMUL(A1, B1) -> P1
  - MATMUL(A2, B2) -> P2
  - MATMUL(A3, B3) -> P3
  - HOST: P0 + P1 + P2 + P3 -> C
  - Note: 最贴合当前 RTL：只用原生 full-tile MATMUL。
  - Note: host 端 768 次逐元素加法仅做附注，不计入默认 PT 周期 winner。
- `host_reduce_load_then_matmul`
  - CFG A_BASE
  - CFG B_BASE
  - QCFG(per_tensor, payload=0x0001_0000)
  - LOAD(A0, B0) -> MATMUL(A0, B0) -> P0
  - LOAD(A1, B1) -> MATMUL(A1, B1) -> P1
  - LOAD(A2, B2) -> MATMUL(A2, B2) -> P2
  - LOAD(A3, B3) -> MATMUL(A3, B3) -> P3
  - HOST: P0 + P1 + P2 + P3 -> C
  - Note: 与直接 MATMUL 的 DMA 总量接近，但多了显式 LOAD 控制开销。
- `pt_matadd_reduce`
  - CFG A_BASE
  - CFG B_BASE
  - QCFG(per_tensor, payload=0x0001_0000)
  - MATMUL(A0, B0) -> P0
  - MATMUL(A1, B1) -> P1
  - MATADD(P1, ext=P0) -> S01
  - MATMUL(A2, B2) -> P2
  - MATADD(P2, ext=S01) -> S012
  - MATMUL(A3, B3) -> P3
  - MATADD(P3, ext=S012) -> S0123
  - Note: host 只负责把上一步 export 结果重新注册成下一次 `MATADD` 的 external C tile。
  - Note: 由于多了 3 次 MATADD 与额外 export，默认估算下会慢于 host reduction。

## Unsupported / Not Recommended Paths
- `same_id_k_slice_swap`: A/B residency 是 cache-by-id；不换 ctrl_id 时不会形成预期的新 A/B reload。
  - observed_dma_increment: 0
  - observed_same_result: True

## Verification Results
- success: True
- simulator: `icarus`
- tests: 4
- failures: 0
- errors: 0
- results_xml: `/Users/yucheng/Documents/GitHub/flash_atten/app/pt_mnk16x64x16/out/cocotb/icarus/results.xml`
- metrics_path: `/Users/yucheng/Documents/GitHub/flash_atten/app/pt_mnk16x64x16/out/verify_metrics.json`
