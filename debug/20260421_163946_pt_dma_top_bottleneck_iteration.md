# PT_DMA_TOP Frontend Iteration Report

- Timestamp: `2026-04-21 16:39:46 +0800`
- Branch: `codex-app`
- Commit: `d46b5cc`

## Scope

- Continue monitoring remote DC compile for the `PT_DMA_TOP` front-end upgrade RTL.
- While waiting, quantify the new residual bottleneck after `legacy -> shadow_delta -> compact`.

## Current Remote Status

- Remote staging workspace remains:
  - `~/Desktop/flash_atten_stage_20260421_155212`
- SpyGlass status remains unchanged:
  - `0 error`
  - `212 warnings`
- Remote DC compile is still in progress.
  - Active local PTY session: `66046`
  - Latest observed DC phase is still inside `compile_ultra` optimization.
  - Latest visible intermediate QoR from the live log:
    - area around `215193.4`
    - WNS `0.00`
    - design rule cost around `161.0`
  - Later optimization snapshots also showed:
    - area around `216698.5`
    - WNS `0.00`
    - design rule cost around `172.9`
- No final DC signoff summary has been extracted yet in this iteration.

## Data Basis

- Native PT reference:
  - `app/pt_tiled_gemm/out/multitile_sweep_pt_icarus_shadow_delta.json`
- Wrapper mode comparison:
  - `app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_icarus_legacy.json`
  - `app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_icarus_shadow_delta.json`
  - `app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_icarus_compact.json`
- Existing summary:
  - `app/pt_tiled_gemm/out/pt_dma_top_submission_mode_compare.md`

## New Bottleneck Findings

### 1. `shadow_delta` already captures almost all observable gain

Average bucket behavior:

| Bucket | Legacy writes/cmd | Shadow writes/cmd | Compact writes/cmd | Legacy GOPS@200MHz | Shadow GOPS@200MHz | Compact GOPS@200MHz |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `1 cmd` | `11.0` | `7.0` | `6.0` | `17.062` | `17.062` | `17.062` |
| `2 cmds` | `11.0` | `6.5` | `6.0` | `16.800` | `17.528` | `17.528` |
| `4 cmds` | `11.0` | `6.25` | `6.0` | `16.761` | `17.790` | `17.790` |
| `8 cmds` | `11.0` | `6.125` | `6.0` | `16.447` | `17.526` | `17.526` |
| `16 cmds` | `11.0` | `6.125` | `6.0` | `15.606` | `16.325` | `16.336` |

Takeaway:

- `legacy -> shadow_delta` is the real performance win.
- `shadow_delta -> compact` reduces writes a bit further, but GOPS barely moves.
- This means the dominant remaining cost is no longer raw AXI-Lite write count.

### 2. All measured performance gain comes from the pre-response side

For all buckets, `shadow_delta` and `compact` reduce:

- `accept_to_resp_cycles`
- `accept_to_done_cycles`

by exactly the same amount for the same case.

Representative examples:

| Shape | Mode | `accept_to_resp` delta vs legacy | `accept_to_done` delta vs legacy |
| --- | --- | ---: | ---: |
| `16x16x64` | `shadow_delta` | `20` | `20` |
| `16x16x64` | `compact` | `20` | `20` |
| `32x32x32` | `shadow_delta` | `20` | `20` |
| `32x32x32` | `compact` | `20` | `20` |
| `64x64x64` | `shadow_delta` | `296` | `296` |
| `64x64x64` | `compact` | `300` | `300` |

Interpretation:

- The optimization is shortening the front-end launch path before response visibility.
- The export tail after response is effectively unchanged by `shadow_delta` and `compact`.

### 3. Export tail is now a clean secondary bottleneck

Average `(done - resp)` tail per command is identical across all three modes:

| Bucket | Tail / cmd | Tail / export beat |
| --- | ---: | ---: |
| `1 cmd` | `61.000` | `1.8781` |
| `2 cmds` | `36.500` | `0.9443` |
| `4 cmds` | `19.250` | `0.4707` |
| `8 cmds` | `10.825` | `0.2371` |
| `16 cmds` | `7.812` | `0.1221` |

Interpretation:

- Export/writeback is still present, but it is not what `shadow_delta` or `compact` improved.
- The export tail overlaps better as command count grows, so it is not the first-order limiter for current front-end changes.
- It remains the next obvious target after launch overhead, especially for large-`N` cases.

### 4. The new dominant bottleneck is the non-CSR part of per-command wrapper launch

Compact-mode average response-side cost per command is still:

| Bucket | `accept_to_resp` cycles / cmd |
| --- | ---: |
| `1 cmd` | `146.400` |
| `2 cmds` | `220.750` |
| `4 cmds` | `258.750` |
| `8 cmds` | `289.575` |
| `16 cmds` | `393.375` |

So after removing most CSR write waste, the remaining repeated cost is now dominated by some combination of:

- descriptor push to PT accept latency
- per-command DMA/load orchestration before response
- descriptor bookkeeping / response enqueue overhead
- repeated command launch tax that still scales with adapted sub-command count

This is why `compact` can save writes without materially improving GOPS beyond `shadow_delta`.

### 5. Native `PT` comparison shows the remaining penalty is almost entirely pre-response

Native `PT` sweep is now available and can be used as the core-only reference.

Average `PT_DMA_TOP compact - PT` overhead by bucket:

| Bucket | Avg done delta | Avg done delta / cmd | Avg resp delta | Avg resp delta / cmd | Avg GOPS delta @200MHz |
| --- | ---: | ---: | ---: | ---: | ---: |
| `1 cmd` | `-2` | `-2.000` | `5` | `5.000` | `+0.182` |
| `2 cmds` | `19` | `9.500` | `26` | `13.000` | `-0.759` |
| `4 cmds` | `61` | `15.250` | `68` | `17.000` | `-1.203` |
| `8 cmds` | `145` | `18.125` | `152` | `19.000` | `-1.302` |
| `16 cmds` | `643` | `40.188` | `650` | `40.625` | `-1.819` |

Representative shapes:

| Shape | PT done | Compact done | Done delta | PT GOPS@200MHz | Compact GOPS@200MHz | GOPS delta |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `16x16x32` | `165` | `163` | `-2` | `19.859` | `20.103` | `+0.244` |
| `32x32x32` | `719` | `738` | `19` | `18.230` | `17.760` | `-0.469` |
| `64x64x64` | `5776` | `6419` | `643` | `18.154` | `16.336` | `-1.819` |

Most important observation:

- `PT_DMA_TOP compact` has a nearly constant `-7 cycle` tail delta vs native `PT` for every case.
- So the wrapper is not slower in the `done - resp` region.
- The real residual penalty vs native `PT` is almost entirely in the `accept -> resp` path.

That narrows the next bottleneck down to the wrapper launch/accept/response machinery, not export completion.

## Updated Priority View

### P0 status

- `shadow_delta` is validated as worthwhile and should remain the default experimental path for `multitile`.
- `compact` is still structurally useful and keeps the RTL path honest, but it is not sufficient by itself to hit the `8/16 command` performance targets.

### P1 next target

The next highest-leverage optimization should focus on reducing repeated wrapper launch cost after descriptor staging, not only further trimming CSR writes.

Best next measurement targets:

1. Add or use counters for:
   - push to PT accept
   - PT accept to response
   - response enqueue to `wr_dma_done`
2. Compare those three intervals across:
   - `legacy`
   - `shadow_delta`
   - `compact`
3. Use native `PT` sweep as the next reference point to isolate wrapper-only overhead from PT core work.

## In-Flight Follow-Up

- Native `PT` multitile sweep has completed successfully:
  - output:
    - `app/pt_tiled_gemm/out/multitile_sweep_pt_icarus_shadow_delta.json`
- Next report should focus on:
  - final remote DC QoR extraction
  - correlating wrapper launch/response overhead with the new perf counters
  - deciding whether the next P1 optimization should target:
    - push-to-accept latency
    - accept-to-response latency
    - descriptor bookkeeping path
