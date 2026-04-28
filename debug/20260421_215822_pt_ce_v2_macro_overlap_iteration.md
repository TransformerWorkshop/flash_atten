# PT_CE_V2 Macro Overlap Iteration

- Timestamp: `2026-04-21 21:58:22 +0800`
- Branch: `codex-app`
- Commit baseline: `79399d3`

## Scope

- Optimize the first-priority bottleneck identified in the previous analysis:
  - `PT_CE_V2` `ce_cmd -> ce_resp`
- Keep numerical correctness intact and rerun the `{1,2,4}^3` multitile sweep.

## Change

This iteration adds a small full-width drain shadow queue in `PT_CE_V2` and moves macro-tile shadow scheduling earlier for the `DRAIN_FULL_WIDTH` case.

Main idea:

- before:
  - next macro tile could only be staged after current drain completed
  - this left tile-to-tile bubbles in multitile matmul
- now:
  - next macro tile can be staged at `exec_complete`
  - if current drain is still active, next tile’s drain metadata is parked in a one-entry shadow slot
  - when current drain completes, the shadow drain is promoted immediately

Files:

- `rtl/pt_ce_v2.v`

This is a core-side optimization, so it improves both:

- native `PT`
- wrapper `PT_DMA_TOP`

## Local Regression

### Build / Basic

- `./scripts/synth_sanity.sh`
  - `PASS`

### Numerical

- native PT spot check:
  - `python3 app/pt_tiled_gemm/run.py verify --target pt --sim icarus --submission-mode shadow_delta --m 16 --k 32 --n 16`
  - `PASS`
- wrapper spot check:
  - `python3 app/pt_tiled_gemm/run.py verify --target pt_dma_top --sim icarus --submission-mode compact --m 16 --k 64 --n 16`
  - `PASS`
- wrapper AXI-Lite / soft-clear suite:
  - `python3 sim/cocotb/run.py axil --target pt_dma_top --sim icarus`
  - command exited successfully
- full `{1,2,4}^3` multitile numerical sweep:
  - native PT
    - `python3 app/pt_tiled_gemm/run.py multitile --target pt --sim icarus --submission-mode shadow_delta`
    - `27/27 PASS`
  - PT_DMA_TOP compact
    - `python3 app/pt_tiled_gemm/run.py multitile --target pt_dma_top --sim icarus --submission-mode compact --m-tiles 1,2,4 --n-tiles 1,2,4 --k-tiles 1,2,4`
    - `27/27 PASS`

Artifacts:

- `app/pt_tiled_gemm/out/multitile_sweep_pt_icarus_shadow_delta.json`
- `app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_icarus_compact.json`
- `app/pt_tiled_gemm/out/verify_metrics_m16_k32_n16.json`
- `app/pt_tiled_gemm/out/verify_metrics_pt_dma_top_m16_k64_n16.json`

## Performance Effect

### PT_DMA_TOP compact

Representative improvements:

| Shape | Previous cycles | Current cycles | Delta | Throughput Change |
| --- | ---: | ---: | ---: | ---: |
| `16x32x16` | `201` | `183` | `-18` | `+9.83%` |
| `32x16x16` | `201` | `183` | `-18` | `+9.83%` |
| `32x32x16` | `357` | `303` | `-54` | `+17.86%` |
| `64x64x64` | `6133` | `5269` | `-864` | `+16.40%` |

Updated `PT_DMA_TOP` compact highlights:

- `32x32x16`
  - `21.629 GOPS @ 200MHz`
- `64x64x64`
  - `19.901 GOPS @ 200MHz`

### Native PT

Because this change is inside the core, native PT also improved:

- `32x32x16`
  - `107.436 ops/cycle`
  - `21.487 GOPS @ 200MHz`
- `64x64x64`
  - `106.736 ops/cycle`
  - `21.347 GOPS @ 200MHz`

## Wrapper Delta Vs Native PT

After updating both native and wrapper baselines, wrapper-only tax is:

| Bucket | Wrapper done delta / cmd | Avg GOPS delta |
| --- | ---: | ---: |
| `1 cmd` | `-2.0` | `+0.203` |
| `2 cmds` | `9.5` | `-0.861` |
| `4 cmds` | `15.25` | `-1.342` |
| `8 cmds` | `18.125` | `-1.498` |
| `16 cmds` | `22.312` | `-1.446` |

Interpretation:

- this CE optimization mostly improved the shared core
- the wrapper-specific tax remains roughly where it was before
- so the optimization was directionally correct, but it does not replace future wrapper-path work

## Remote Signoff

### SpyGlass

- status:
  - `PASS`
- result:
  - `0 error`
  - `233 warnings`

Delta vs previous iteration:

- previous:
  - `215 warnings`
- current:
  - `233 warnings`
- delta:
  - `+18 warnings`

The increase is dominated by additional `W415a`-style multiple-assignment warnings around CE / related sequential style, not by new high-severity errors.

### DC

- status:
  - `compile complete`
- log:
  - `synopsys/dc/logs/compile_20260421_214850.log`

Final QoR:

- setup:
  - `WNS = 0.00`
  - `TNS = 0.00`
- hold:
  - worst hold `-0.12ns`
  - hold TNS `-1121.51`
  - hold violating paths `24292`
- area:
  - `218083.466224`
- design rules:
  - `2` max-cap violations

Delta vs previous remote DC reference:

- area:
  - old `217966.454228`
  - new `218083.466224`
  - delta `+117.012`
  - about `+0.054%`
- hold TNS magnitude:
  - old `1120.12`
  - new `1121.51`
  - delta `+1.39`
  - effectively flat

Interpretation:

- QoR movement is small
- setup still closes
- hold remains open but did not materially worsen
- the main caution in this iteration is the SpyGlass warning count increase

## Conclusion

This iteration is a real performance win:

- numerical regression passed
- full `27`-case multitile sweep passed
- CE-side optimization delivered strong gains on the shapes that were previously bottlenecked by multitile CE completion

But it also surfaced a cleanup item:

- SpyGlass warning count increased from `215` to `233`

So the next sensible move is:

1. keep this optimization
2. clean up the new CE sequential coding style enough to recover or reduce the warning increase
3. then continue with the next bottleneck, likely serialized `A/B` fill or the remaining wrapper tax
