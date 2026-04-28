# PT_DMA_TOP Multitile Throughput at 200MHz

Source sweep:

- [`multitile_sweep_pt_dma_top_icarus_compact.json`](/Users/yucheng/Documents/GitHub/flash_atten/app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_icarus_compact.json)

Assumptions:

- target: `PT_DMA_TOP`
- simulator: `icarus`
- submission mode: `compact`
- frequency for absolute throughput: `200MHz`
- conversion: `GOPS = ops/cycle * 0.2`
- for multi-command adapted cases, software enables safe `LOAD(next)` prefetch and bank-aware overlap

## Result Table

| M | N | K | done cycles | logical cmds | issued cmds | ops/cycle | GOPS @200MHz | note |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| 16 | 16 | 16 | 115 | 1 | 1 | 71.23 | 14.247 | direct |
| 16 | 16 | 32 | 163 | 1 | 1 | 100.52 | 20.103 | direct |
| 16 | 16 | 64 | 327 | 2 | 4 | 100.21 | 20.042 | software adapted via m=[1] n=[1] k=[2, 2] (2 commands) |
| 16 | 32 | 16 | 183 | 1 | 1 | 89.53 | 17.906 | direct |
| 16 | 32 | 32 | 327 | 2 | 4 | 100.21 | 20.042 | software adapted via m=[1] n=[1, 1] k=[2] (2 commands) |
| 16 | 32 | 64 | 585 | 4 | 8 | 112.03 | 22.405 | software adapted via m=[1] n=[1, 1] k=[2, 2] (4 commands) |
| 16 | 64 | 16 | 377 | 2 | 4 | 86.92 | 17.384 | software adapted via m=[1] n=[2, 2] k=[1] (2 commands) |
| 16 | 64 | 32 | 585 | 4 | 8 | 112.03 | 22.405 | software adapted via m=[1] n=[1, 1, 1, 1] k=[2] (4 commands) |
| 16 | 64 | 64 | 1101 | 8 | 16 | 119.05 | 23.810 | software adapted via m=[1] n=[1, 1, 1, 1] k=[2, 2] (8 commands) |
| 32 | 16 | 16 | 183 | 1 | 1 | 89.53 | 17.906 | direct |
| 32 | 16 | 32 | 327 | 2 | 4 | 100.21 | 20.042 | software adapted via m=[1, 1] n=[1] k=[2] (2 commands) |
| 32 | 16 | 64 | 585 | 4 | 8 | 112.03 | 22.405 | software adapted via m=[1, 1] n=[1] k=[2, 2] (4 commands) |
| 32 | 32 | 16 | 303 | 1 | 1 | 108.15 | 21.629 | direct |
| 32 | 32 | 32 | 595 | 2 | 4 | 110.14 | 22.029 | software adapted via m=[2] n=[2] k=[1, 1] (2 commands) |
| 32 | 32 | 64 | 1109 | 4 | 8 | 118.19 | 23.638 | software adapted via m=[2] n=[2] k=[1, 1, 1, 1] (4 commands) |
| 32 | 64 | 16 | 595 | 2 | 4 | 110.14 | 22.029 | software adapted via m=[2] n=[2, 2] k=[1] (2 commands) |
| 32 | 64 | 32 | 1109 | 4 | 8 | 118.19 | 23.638 | software adapted via m=[2] n=[2, 2] k=[1, 1] (4 commands) |
| 32 | 64 | 64 | 2137 | 8 | 16 | 122.67 | 24.534 | software adapted via m=[2] n=[2, 2] k=[1, 1, 1, 1] (8 commands) |
| 64 | 16 | 16 | 377 | 2 | 4 | 86.92 | 17.384 | software adapted via m=[2, 2] n=[1] k=[1] (2 commands) |
| 64 | 16 | 32 | 585 | 4 | 8 | 112.03 | 22.405 | software adapted via m=[1, 1, 1, 1] n=[1] k=[2] (4 commands) |
| 64 | 16 | 64 | 1101 | 8 | 16 | 119.05 | 23.810 | software adapted via m=[1, 1, 1, 1] n=[1] k=[2, 2] (8 commands) |
| 64 | 32 | 16 | 595 | 2 | 4 | 110.14 | 22.029 | software adapted via m=[2, 2] n=[2] k=[1] (2 commands) |
| 64 | 32 | 32 | 1109 | 4 | 8 | 118.19 | 23.638 | software adapted via m=[2, 2] n=[2] k=[1, 1] (4 commands) |
| 64 | 32 | 64 | 2137 | 8 | 16 | 122.67 | 24.534 | software adapted via m=[2, 2] n=[2] k=[1, 1, 1, 1] (8 commands) |
| 64 | 64 | 16 | 1109 | 4 | 8 | 118.19 | 23.638 | software adapted via m=[2, 2] n=[2, 2] k=[1] (4 commands) |
| 64 | 64 | 32 | 2137 | 8 | 16 | 122.67 | 24.534 | software adapted via m=[2, 2] n=[2, 2] k=[1, 1] (8 commands) |
| 64 | 64 | 64 | 4359 | 16 | 32 | 120.28 | 24.055 | software adapted via m=[2, 2] n=[2, 2] k=[1, 1, 1, 1] (16 commands) |

## Bucket Summary

- logical `1 cmd`: average `18.358 GOPS`
- logical `2 cmd`: average `20.122 GOPS`
- logical `4 cmd`: average `23.022 GOPS`
- logical `8 cmd`: average `24.244 GOPS`
- logical `16 cmd`: average `24.055 GOPS`

## Bottleneck Analysis

- Direct `1 cmd` cases are no longer the best-performing bucket; the adapted multi-command cases now win because `LOAD(next)` overlaps most of the old A/B fill tax with current compute.
- The best measured case is `32x64x64 = 24.534 GOPS @ 200MHz`; the worst is still the tiny `16x16x16 = 14.247 GOPS @ 200MHz`, which is dominated by fixed control and export startup cost.
- `64x64x64` improved to `24.055 GOPS @ 200MHz` with `16` logical commands / `32` issued commands, which means the fixed front-end tax is now largely hidden instead of paid serially.
- The remaining first-order limiter is CE + export time, not AXI-Lite submission. For `64x64x64`, the per-case metrics show `2800` cycles in `accept->resp` and `2096` cycles in `resp->done`, while AXI-Lite stays at `6` writes per issued command.
- Front-end submission is now close to the practical floor for the current compact path: `6` AXI-Lite writes per issued command, `1` push per issued command, and safe bank-aware software prefetch only for `logical_command_count > 1`.
- The next hardware bottleneck priority therefore shifts from wrapper launch overhead to deeper CE/export overlap and, if needed, true A/B fill parallelism below the shared MD datapath.
