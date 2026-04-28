# PT_DMA_TOP_V3 Channelized 200MHz GOPS Sweep

Generated from:

- `app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_v3_ch1_icarus_compact.json`
- `app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_v3_ch2_icarus_compact.json`
- `app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_v3_ch4_icarus_compact.json`

Assumptions:

- simulator: `icarus`
- submission mode: `compact`
- sweep: `m/n/k tiles in {1,2,4}`
- throughput normalization: `GOPS@200MHz = ops_per_cycle * 0.2`

## Summary

- current low-risk cleanup slice is throughput-neutral in local compact sweep.
- `ch2` and `ch4` remain numerically identical across all passing cases.
- average throughput:
  - `ch1`: `49.468 GOPS @ 200MHz`
  - `ch2`: `49.087 GOPS @ 200MHz`
  - `ch4`: `49.087 GOPS @ 200MHz`
- best case:
  - `ch1`: `32x64x64 = 87.236 GOPS @ 200MHz`
  - `ch2/ch4`: `32x64x64 = 86.947 GOPS @ 200MHz`
- `64x64x64`:
  - `ch1`: `69.213 GOPS @ 200MHz`
  - `ch2/ch4`: `69.122 GOPS @ 200MHz`

## Key Shapes

| Target | Shape | Done Cycles | Logical Cmds | Issued Ctrls | GOPS @200MHz |
| --- | --- | ---: | ---: | ---: | ---: |
| `ch1` | `16x16x16` | 79 | 1 | 1 | 20.739 |
| `ch2/ch4` | `16x16x16` | 81 | 1 | 1 | 20.227 |
| `ch1` | `32x32x32` | 251 | 1 | 1 | 52.220 |
| `ch2/ch4` | `32x32x32` | 253 | 1 | 1 | 51.807 |
| `ch1` | `32x64x64` | 601 | 2 | 4 | 87.236 |
| `ch2/ch4` | `32x64x64` | 603 | 2 | 4 | 86.947 |
| `ch1` | `64x64x64` | 1515 | 2 | 4 | 69.213 |
| `ch2/ch4` | `64x64x64` | 1517 | 2 | 4 | 69.122 |

## Command Buckets

| Target | Logical Cmds | Avg GOPS @200MHz |
| --- | ---: | ---: |
| `ch1` | `1` | 43.836 |
| `ch1` | `2` | 74.250 |
| `ch2/ch4` | `1` | 43.455 |
| `ch2/ch4` | `2` | 73.870 |

## Takeaway

Under the current low-risk cleanup slice, `ch2`/`ch4` still track each other exactly, while `ch1` remains slightly faster. The average delta is `-0.77%`, and the `64x64x64` delta is `-0.13%`.
