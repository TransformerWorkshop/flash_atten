# PT_DMA_TOP_V3 200MHz GOPS Sweep

- Source JSON: `app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_v3_icarus_compact.json`
- Target: `PT_DMA_TOP_V3`
- Simulator: `icarus`
- Submission mode: `compact`
- GOPS conversion: `GOPS@200MHz = ops_per_cycle * 0.2`
- `command_count` = logical sub-commands after safe software partition
- `issued_command_count` = actual wrapper control submissions, including prefetch `LOAD` plus `MATMUL`
- `PT_SIZE_W=10`, so the effective packed-word ceiling is `1023`; exact-`1024` packed-word cases still need software split

| Shape (M,N,K) | Logical Cmds | Issued Ctrls | AXI-Lite Writes | Done Cycles | GOPS @200MHz | push->accept | accept->resp | resp->done | Note |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 16x16x16 | 1 | 1 | 6 | 79 | 20.739 | 1 | 43 | 35 |  |
| 16x16x32 | 1 | 1 | 6 | 91 | 36.009 | 1 | 55 | 35 |  |
| 16x16x64 | 1 | 1 | 6 | 115 | 56.988 | 1 | 79 | 35 |  |
| 16x32x16 | 1 | 1 | 6 | 131 | 25.014 | 1 | 63 | 67 |  |
| 16x32x32 | 1 | 1 | 6 | 147 | 44.582 | 1 | 79 | 67 |  |
| 16x32x64 | 1 | 1 | 6 | 183 | 71.624 | 1 | 115 | 67 |  |
| 16x64x16 | 1 | 1 | 6 | 235 | 27.888 | 1 | 103 | 131 |  |
| 16x64x32 | 1 | 1 | 6 | 259 | 50.607 | 1 | 127 | 131 |  |
| 16x64x64 | 2 | 4 | 24 | 377 | 69.534 | 4 | 238 | 134 | software adapted via m=[1] n=[2, 2] k=[4] (2 commands) |
| 32x16x16 | 1 | 1 | 6 | 131 | 25.014 | 1 | 63 | 67 |  |
| 32x16x32 | 1 | 1 | 6 | 147 | 44.582 | 1 | 79 | 67 |  |
| 32x16x64 | 1 | 1 | 6 | 183 | 71.624 | 1 | 115 | 67 |  |
| 32x32x16 | 1 | 1 | 6 | 231 | 28.371 | 1 | 99 | 131 |  |
| 32x32x32 | 1 | 1 | 6 | 251 | 52.220 | 1 | 119 | 131 |  |
| 32x32x64 | 1 | 1 | 6 | 303 | 86.516 | 1 | 171 | 131 |  |
| 32x64x16 | 1 | 1 | 6 | 431 | 30.411 | 1 | 171 | 259 |  |
| 32x64x32 | 1 | 1 | 6 | 459 | 57.112 | 1 | 199 | 259 |  |
| 32x64x64 | 2 | 4 | 24 | 595 | 88.116 | 4 | 350 | 262 | software adapted via m=[2] n=[2, 2] k=[4] (2 commands) |
| 64x16x16 | 1 | 1 | 6 | 235 | 27.888 | 1 | 103 | 131 |  |
| 64x16x32 | 1 | 1 | 6 | 259 | 50.607 | 1 | 127 | 131 |  |
| 64x16x64 | 2 | 4 | 24 | 377 | 69.534 | 4 | 238 | 134 | software adapted via m=[2, 2] n=[1] k=[4] (2 commands) |
| 64x32x16 | 1 | 1 | 6 | 431 | 30.411 | 1 | 171 | 259 |  |
| 64x32x32 | 1 | 1 | 6 | 459 | 57.112 | 1 | 199 | 259 |  |
| 64x32x64 | 2 | 4 | 24 | 595 | 88.116 | 4 | 350 | 262 | software adapted via m=[2, 2] n=[2] k=[4] (2 commands) |
| 64x64x16 | 1 | 1 | 6 | 823 | 31.852 | 1 | 307 | 515 |  |
| 64x64x32 | 1 | 1 | 6 | 859 | 61.035 | 1 | 343 | 515 |  |
| 64x64x64 | 2 | 4 | 24 | 1707 | 61.428 | 4 | 694 | 1030 | software adapted via m=[4] n=[4] k=[2, 2] (2 commands) |
