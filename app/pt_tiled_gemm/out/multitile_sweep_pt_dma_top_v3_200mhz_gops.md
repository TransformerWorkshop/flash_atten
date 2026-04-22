# PT_DMA_TOP_V3 200MHz GOPS Sweep

- Source JSON: `app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_v3_icarus_compact.json`
- Target: `PT_DMA_TOP_V3`
- Simulator: `icarus`
- Submission mode: `compact`
- GOPS conversion: `GOPS@200MHz = ops_per_cycle * 0.2`
- `command_count` = logical sub-commands after safe software partition
- `issued_command_count` = actual wrapper control submissions, including prefetch `LOAD` plus `MATMUL`
- This revision uses packed export aggregation: `4` logical row chunks per `512-bit` beat when `PACK_LANES=4` and `M_EXPORT_LANES=16`

| Shape (M,N,K) | Logical Cmds | Issued Ctrls | AXI-Lite Writes | Export Beats | Done Cycles | GOPS @200MHz | push->accept | accept->resp | resp->done | Note |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 16x16x16 | 1 | 1 | 6 | 4 | 70 | 23.406 | 1 | 43 | 26 |  |
| 16x16x32 | 1 | 1 | 6 | 4 | 82 | 39.961 | 1 | 55 | 26 |  |
| 16x16x64 | 1 | 1 | 6 | 4 | 106 | 61.826 | 1 | 79 | 26 |  |
| 16x32x16 | 1 | 1 | 6 | 8 | 114 | 28.744 | 1 | 63 | 50 |  |
| 16x32x32 | 1 | 1 | 6 | 8 | 130 | 50.412 | 1 | 79 | 50 |  |
| 16x32x64 | 1 | 1 | 6 | 8 | 166 | 78.959 | 1 | 115 | 50 |  |
| 16x64x16 | 1 | 1 | 6 | 16 | 202 | 32.444 | 1 | 103 | 98 |  |
| 16x64x32 | 1 | 1 | 6 | 16 | 226 | 57.996 | 1 | 127 | 98 |  |
| 16x64x64 | 2 | 4 | 24 | 16 | 343 | 76.427 | 4 | 238 | 100 | software adapted via m=[1] n=[2, 2] k=[4] (2 commands) |
| 32x16x16 | 1 | 1 | 6 | 8 | 114 | 28.744 | 1 | 63 | 50 |  |
| 32x16x32 | 1 | 1 | 6 | 8 | 130 | 50.412 | 1 | 79 | 50 |  |
| 32x16x64 | 1 | 1 | 6 | 8 | 166 | 78.959 | 1 | 115 | 50 |  |
| 32x32x16 | 1 | 1 | 6 | 16 | 198 | 33.099 | 1 | 99 | 98 |  |
| 32x32x32 | 1 | 1 | 6 | 16 | 218 | 60.125 | 1 | 119 | 98 |  |
| 32x32x64 | 1 | 1 | 6 | 16 | 270 | 97.090 | 1 | 171 | 98 |  |
| 32x64x16 | 1 | 1 | 6 | 32 | 366 | 35.812 | 1 | 171 | 194 |  |
| 32x64x32 | 1 | 1 | 6 | 32 | 394 | 66.534 | 1 | 199 | 194 |  |
| 32x64x64 | 2 | 4 | 24 | 32 | 529 | 99.109 | 4 | 350 | 196 | software adapted via m=[2] n=[2, 2] k=[4] (2 commands) |
| 64x16x16 | 1 | 1 | 6 | 16 | 202 | 32.444 | 1 | 103 | 98 |  |
| 64x16x32 | 1 | 1 | 6 | 16 | 226 | 57.996 | 1 | 127 | 98 |  |
| 64x16x64 | 2 | 4 | 24 | 16 | 343 | 76.427 | 4 | 238 | 100 | software adapted via m=[2, 2] n=[1] k=[4] (2 commands) |
| 64x32x16 | 1 | 1 | 6 | 32 | 366 | 35.812 | 1 | 171 | 194 |  |
| 64x32x32 | 1 | 1 | 6 | 32 | 394 | 66.534 | 1 | 199 | 194 |  |
| 64x32x64 | 2 | 4 | 24 | 32 | 529 | 99.109 | 4 | 350 | 196 | software adapted via m=[2, 2] n=[2] k=[4] (2 commands) |
| 64x64x16 | 1 | 1 | 6 | 64 | 694 | 37.773 | 1 | 307 | 386 |  |
| 64x64x32 | 1 | 1 | 6 | 64 | 730 | 71.820 | 1 | 343 | 386 |  |
| 64x64x64 | 2 | 4 | 24 | 128 | 1449 | 72.365 | 4 | 694 | 772 | software adapted via m=[4] n=[4] k=[2, 2] (2 commands) |
