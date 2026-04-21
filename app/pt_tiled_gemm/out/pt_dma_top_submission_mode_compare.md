# PT_DMA_TOP Submission Mode Comparison

Compared artifacts:

- legacy:
  - [`multitile_sweep_pt_dma_top_icarus_legacy.json`](/tmp/flash_atten_codex_app/app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_icarus_legacy.json)
- shadow delta:
  - [`multitile_sweep_pt_dma_top_icarus_shadow_delta.json`](/tmp/flash_atten_codex_app/app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_icarus_shadow_delta.json)
- compact:
  - [`multitile_sweep_pt_dma_top_icarus_compact.json`](/tmp/flash_atten_codex_app/app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_icarus_compact.json)

All numbers below use the same `PT_DMA_TOP`, `icarus`, and `200MHz` throughput basis.

## Summary

| Mode | Avg GOPS @200MHz | Avg AXI writes / cmd | `64x64x64` GOPS @200MHz |
| --- | ---: | ---: | ---: |
| `legacy` | `16.728` | `11.000` | `15.606` |
| `shadow_delta` | `17.474` | `6.435` | `16.325` |
| `compact` | `17.475` | `6.000` | `16.336` |

## Bucket Comparison

| Command Count Bucket | Legacy GOPS | Shadow Delta GOPS | Compact GOPS |
| --- | ---: | ---: | ---: |
| `1 cmd` | `17.062` | `17.062` | `17.062` |
| `2 cmds` | `16.800` | `17.528` | `17.528` |
| `4 cmds` | `16.761` | `17.790` | `17.790` |
| `8 cmds` | `16.447` | `17.526` | `17.526` |
| `16 cmds` | `15.606` | `16.325` | `16.336` |

## Improvement Vs Legacy

### Shadow Delta

- average GOPS uplift: `+4.47%`
- average AXI writes / command reduction: `-41.50%`
- `64x64x64` uplift: `+4.61%`

### Compact

- average GOPS uplift: `+4.47%`
- average AXI writes / command reduction: `-45.45%`
- `64x64x64` uplift: `+4.67%`

## Acceptance Check

| Goal | Result |
| --- | --- |
| direct bucket no regression | `PASS` |
| `4 cmds` bucket `>= +5%` | `PASS` (`+6.14%`) |
| `8 cmds` bucket `>= +7%` | `FAIL` (`+6.56%`) |
| `16 cmds` case `>= +10%` | `FAIL` (`+4.67%`) |
| `shadow_delta` writes lower than `legacy` | `PASS` |
| `compact` writes lower than `shadow_delta` | `PASS` |

## Interpretation

- `shadow_delta` already captures almost all currently available performance gain from reducing redundant CSR traffic.
- `compact` further reduces write count from about `6.44` to `6.00` writes per command, but the measured GOPS gain over `shadow_delta` is marginal.
- This suggests the remaining bottleneck is no longer just raw AXI write count; it is the broader per-command wrapper launch/response/export fixed cost that still gets repaid on every adapted sub-command.
- In other words:
  - `legacy -> shadow_delta` is a clear win
  - `shadow_delta -> compact` is structurally cleaner and cheaper in writes, but not yet enough to hit the aggressive `8/16 command` GOPS targets by itself
