# PT_DMA_TOP Soft-Clear Regression Check

- Timestamp: `2026-04-21 18:22:27 +0800`
- Branch: `codex-app`
- Commit baseline: `466be96`

## Scope

- Confirm that the preserve-config soft-clear change did not regress numerical correctness or wrapper recovery behavior.

## Local Regression

### Build / Lint

- `./scripts/synth_sanity.sh`
  - `PASS`

### Native PT Numerical Check

- command:
  - `python3 app/pt_tiled_gemm/run.py verify --target pt --sim icarus --submission-mode shadow_delta --m 16 --k 32 --n 16`
- result:
  - `PASS`
  - `5/5` tests passed

Artifact:

- `app/pt_tiled_gemm/out/verify_metrics_m16_k32_n16.json`

### PT_DMA_TOP Multitile Numerical Sweep

- command:
  - `python3 app/pt_tiled_gemm/run.py multitile --target pt_dma_top --sim icarus --submission-mode compact --m-tiles 1,2,4 --n-tiles 1,2,4 --k-tiles 1,2,4`
- result:
  - `27/27 PASS`

Key point:

- the long-schedule case still passes numerically after changing soft-clear behavior
- `64x64x64` now improves from `6473` to `6133` cycles

Artifact:

- `app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_icarus_compact.json`

## Wrapper Recovery Regression

### AXI-Lite / Soft-Clear Recovery Suite

- command:
  - `python3 sim/cocotb/run.py axil --target pt_dma_top --sim icarus`
- result:
  - `PASS`

This suite covers wrapper-side paths such as:

- soft-clear recovery after desc miss
- response / descriptor overflow flag behavior
- descriptor update / wrapper control handling

Interpretation:

- preserving CSR config across `soft_clear` did not break the expected wrapper recovery paths exercised by the AXI-Lite suite

## Remote Gates

### SpyGlass

- status:
  - `PASS`
- result:
  - `0 error`
  - `215 warnings`

### DC

- status:
  - `compile complete`
- key QoR:
  - setup `WNS/TNS = 0`
  - hold TNS `-1120.12`
  - area `217966.454228`

## Conclusion

The preserve-config soft-clear change is now backed by:

- local synth sanity
- native PT numerical regression
- full PT_DMA_TOP multitile numerical regression
- wrapper AXI-Lite / soft-clear recovery regression
- remote SpyGlass
- remote DC compile

So the current evidence says the change improves long-schedule performance while preserving numerical correctness and wrapper recovery behavior.
