# PT_DMA_TOP V3 Packed-AB Milestone

- Timestamp: `2026-04-22 13:15:59 +0800`
- Branch: `codex-app`
- Working base commit: `dd2db59`
- Archive baseline commit: `2f002d2`

## Scope

- This iteration closes the first real `v3` milestone on top of the archived `v2` line.
- `v2` stays frozen as the scalar32 baseline.
- `v3` now has:
  - packed `A/B` residency and DMA semantics in `4 x int8 / 32-bit word`
  - packed `dot4` compute in `GEMU_V3/GEMM_V3`
  - corrected packed-`B` row addressing in both `PT_MD_V3` and `PT_CE_V3`
  - target-specific multitile reporting for packed-word capacity and issued-control accounting
- This is still not the full scheme-D endpoint:
  - `C/M/export` are still scalar32 semantic paths
  - `PT_CE_V3` post-compute tail is still visible
  - packed export redesign in `PT_MD_V3` is still pending

## Implemented Fixes

- `rtl/pt_md_v3.v`
  - fixed packed `B` fill row offset so `n_tile` stepping advances in packed-word rows instead of multiplying by `GEMM_Y_DIM` again
- `rtl/pt_ce_v3.v`
  - fixed packed `B` macro row-base advance so multi-`n_tile` execution walks the packed local layout correctly
- `app/pt_tiled_gemm/multitile_runner.py`
  - planner note generation now respects target `PACK_LANES`
  - sweep JSON now records `issued_command_count` beside logical `command_count`, so software partitioning and actual wrapper submits are no longer conflated

## Functional Validation

Wrapper spot verify:

- `python3 app/pt_tiled_gemm/run.py verify --m 16 --k 32 --n 16 --target pt_dma_top_v3 --sim icarus`
  - `PASS`
- `python3 app/pt_tiled_gemm/run.py verify --m 16 --k 64 --n 16 --target pt_dma_top_v3 --sim icarus`
  - `PASS`
- `python3 app/pt_tiled_gemm/run.py verify --m 32 --k 32 --n 32 --target pt_dma_top_v3 --sim icarus`
  - `PASS`
- `python3 app/pt_tiled_gemm/run.py verify --m 48 --k 32 --n 32 --target pt_dma_top_v3 --sim icarus`
  - `PASS`

Multitile sweep:

- `python3 app/pt_tiled_gemm/run.py multitile --target pt_dma_top_v3 --sim icarus --submission-mode compact --m-tiles 1,2,4 --n-tiles 1,2,4 --k-tiles 1,2,4`
  - `27 / 27 PASS`
- Saved baseline:
  - `app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_v3_icarus_compact.json`
  - `app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_v3_200mhz_gops.md`

## Performance Snapshot

Key `200MHz` numbers:

- best measured case: `32x64x64 = 88.116 GOPS`
- `64x64x64 = 61.428 GOPS`
- smallest direct case: `16x16x16 = 20.739 GOPS`

Versus current `v2` compact baseline:

- `64x64x64`: `24.055 -> 61.428 GOPS`, `+2.55x`
- best case: `24.534 -> 88.116 GOPS`, `+3.59x`

Why `64x64x64` is still split in `v3`:

- `PT_SIZE_W=10` means the encoded packed-word max is `1023`
- full `64x64x64` packed `A` or `B` footprint reaches `1024` packed words
- result: software safely partitions it as `k=[2, 2]`, so the case remains `2` logical commands and `4` issued wrapper control submissions

## Bottleneck Reassessment

Front-end launch is no longer the dominant limiter.

Direct `1`-command bucket average:

- `44.918 GOPS @ 200MHz`
- `push->accept = 1 cycle`
- `accept->resp = 133.2 cycles`
- `resp->done = 158.6 cycles`

Large adapted `2`-command bucket average:

- `75.346 GOPS @ 200MHz`
- `issued_command_count = 4`
- `push->accept = 4 cycles`
- `accept->resp = 374.0 cycles`
- `resp->done = 364.4 cycles`

`64x64x64` breakdown:

- logical commands: `2`
- issued wrapper submits: `4`
- AXI-Lite writes: `24`
- total cycles: `1707`
- `push->accept = 4`
- `accept->resp = 694`
- `resp->done = 1030`

Interpretation:

- compact front-end tax has been pushed down to noise level
- the first-order limiter is now `CE completion + export tail`, not wrapper launch
- for larger `N`, `resp->done` becomes the biggest visible bucket because `M/export` is still scalar32

## Hardware Gates

Local gate:

- `./scripts/synth_sanity.sh`
  - `PASS`

Remote SpyGlass:

- top: `PT_DMA_TOP_V3`
- result: `182` reported messages total, matching the expected warning-only profile for this stage
- no new high-severity blocker observed in the v3 lint run
- remaining notable new v3-local warnings are mainly:
  - `SepStateNextLogic` on `PT_CE_V3.add_state_r`
  - several `InitValUsingNBA` warnings in `PT_CE_V3`

Remote DC on `ic-canopsys`:

- top: `PT_DMA_TOP_V3`
- compile: `PASS`
- setup timing: `WNS=0.00`, `TNS=0.00`
- hold summary: `WNS=0.12`, `TNS=1127.56`
- cell area: `204165.114`

QoR versus current `PT_DMA_TOP` DC baseline:

- cell area: `218325.036 -> 204165.114`, `-6.49%`
- setup closure remains met at `5ns`
- hold profile is essentially flat relative to `v2`

## Remaining Gaps

- `PT_DMA_TOP_V3` diagnostic test `test_pt_dma_top_ce_md_block_breakdown` is still intentionally skipped because packed export alignment is not wired into that path yet
- `scheme D` is not complete until:
  - packed `C/M/export`
  - `PT_CE_V3` tail cleanup to the planned low-single-digit cycles
  - packed export beat aggregation in `PT_MD_V3`

## Next Priority

The next hardware priority should stay on the real datapath tail, not front-end CSR polish:

1. pack `C/M/export` so `resp->done` stops scaling like the scalar32 path
2. remove the remaining `PT_CE_V3` post-compute tail
3. re-enable the v3 CE/MD block-breakdown diagnostic with packed export semantics
