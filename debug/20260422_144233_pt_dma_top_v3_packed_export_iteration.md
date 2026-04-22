# PT_DMA_TOP V3 Packed-Export Iteration

- Timestamp: `2026-04-22 14:42:33 +0800`
- Branch: `codex-app`
- Previous v3 baseline commit: `b3629d1`

## Scope

- This iteration targets the dominant `PT_DMA_TOP_V3` export tail after the packed `A/B` milestone.
- Kept stable:
  - public CSR / descriptor / AXIS widths
  - current scalar32 `M` storage semantics inside the core
  - current software safety rules and command partitioning
- Changed:
  - `PT_MD_V3` export path now aggregates `4` logical row chunks into one `512-bit` beat
  - wrapper/native cocotb envs now decode packed export beats
  - app-side export beat accounting now uses packed-v3 semantics

## Implemented Changes

- `rtl/pt_md_v3.v`
  - redesigned export streaming from `1 row chunk -> 1 beat` to packed export aggregation
  - `m_dma_req_beats` now reflects packed export beats instead of scalar row count
  - added chained row prefetch so export readout stays at `1 row / cycle` after the initial prime
- `sim/cocotb/tests/pt_model.py`
  - added shared helpers for packed export beat packing and beat-count calculation
- `sim/cocotb/tests/pt_dma_top_env.py`
  - wrapper export checker now uses the shared packed export helper
- `sim/cocotb/tests/pt_blackbox_env.py`
  - native export checker now uses the shared packed export helper
- `app/pt_tiled_gemm/tests/test_pt_tiled_gemm.py`
  - verify metrics now compute export beats with packed-v3 semantics
- `app/pt_tiled_gemm/tests/test_pt_multitile_bench.py`
  - multitile metrics now compute export beats with packed-v3 semantics

## Functional Validation

Local synth/lint gate:

- `./scripts/synth_sanity.sh`
  - `PASS`

Numerical verify:

- `python3 app/pt_tiled_gemm/run.py verify --m 16 --k 32 --n 16 --target pt_v3 --sim icarus`
  - `PASS`
- `python3 app/pt_tiled_gemm/run.py verify --m 16 --k 64 --n 16 --target pt_v3 --sim icarus`
  - `PASS`
- `python3 app/pt_tiled_gemm/run.py verify --m 32 --k 32 --n 32 --target pt_v3 --sim icarus`
  - `PASS`
- `python3 app/pt_tiled_gemm/run.py verify --m 48 --k 32 --n 32 --target pt_v3 --sim icarus`
  - `PASS`
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

Saved artifacts:

- `app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_v3_icarus_compact.json`
- `app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_v3_200mhz_gops.md`

## Performance Delta

Representative before/after versus `b3629d1`:

- `16x16x32`
  - `36.009 -> 39.961 GOPS @ 200MHz`
  - `done_cycles: 91 -> 82`
  - `resp->done: 35 -> 26`
  - `export_beats: 16 -> 4`
- `32x32x16`
  - `28.371 -> 33.099 GOPS @ 200MHz`
  - `done_cycles: 231 -> 198`
  - `resp->done: 131 -> 98`
  - `export_beats: 64 -> 16`
- `32x64x64`
  - `88.116 -> 99.109 GOPS @ 200MHz`
  - `done_cycles: 595 -> 529`
  - `resp->done: 262 -> 196`
  - `export_beats: 128 -> 32`
- `64x64x64`
  - `61.428 -> 72.365 GOPS @ 200MHz`
  - `done_cycles: 1707 -> 1449`
  - `resp->done: 1030 -> 772`
  - `export_beats: 512 -> 128`

Bucket view:

- logical `1 cmd`
  - average `44.918 -> 51.223 GOPS`, `+14.0%`
  - average `resp->done: 158.6 -> 118.7 cycles`
  - average `export_beats: 77.8 -> 19.5`
- logical `2 cmds`
  - average `75.346 -> 84.688 GOPS`, `+12.4%`
  - average `resp->done: 364.4 -> 272.8 cycles`
  - average `export_beats: 179.2 -> 44.8`

Stretch target status:

- `64x64x64 >= 70 GOPS @ 200MHz`
  - achieved: `72.365 GOPS`

## Bottleneck Reassessment

The export tail is no longer overwhelmingly dominant.

Current `64x64x64` split:

- `push->accept = 4 cycles`
- `accept->resp = 694 cycles`
- `resp->done = 772 cycles`

Interpretation:

- packed export aggregation removed the largest easy win in wrapper-visible tail cost
- export is still slightly heavier than compute completion, but the gap is now much smaller
- the next meaningful performance step is no longer “fewer export beats” alone; it shifts toward:
  - packed `M` storage semantics instead of scalar32 row staging
  - `PT_CE_V3` post-compute cleanup and drain/write tail reduction

## Hardware Gates

Remote SpyGlass on `ic-canopsys`:

- top: `PT_DMA_TOP_V3`
- result: `0 error / 197 warnings / 4 infos`
- no new high-severity blocker
- warning count increased versus the previous packed-AB slice
  - primary additions are `PT_MD_V3` `InitValUsingNBA` / `W415a` style warnings from the new export sequencing block
  - these are style/structure warnings, not functional or synthesis blockers

Remote DC on `ic-canopsys`:

- top: `PT_DMA_TOP_V3`
- compile: `PASS`
- setup timing: `WNS=0.00`, `TNS=0.00`
- hold timing: `WNS=0.12`, `TNS=1133.74`
- cell area: `204137.086`

QoR versus previous v3 packed-AB milestone:

- cell area: `204165.114 -> 204137.086`, `-0.01%`
- setup closure: unchanged, still closed at `5ns`
- hold TNS magnitude: `1127.56 -> 1133.74`, about `+0.55%`

This is comfortably within the current `5%` QoR guardrail.

## Follow-Up Priority

1. clean the new `PT_MD_V3` SpyGlass warning cluster by splitting export next-state and registered-update logic
2. move from packed export only to true packed `M` storage / packed `C` semantics
3. then revisit `PT_CE_V3` tail cleanup, because compute completion and export tail are now much closer in weight
