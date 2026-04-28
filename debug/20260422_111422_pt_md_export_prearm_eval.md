# PT_MD_V2 Export Pre-Arm Evaluation

- Timestamp: `2026-04-22 11:14:22 +0800`
- Branch: `codex-app`
- Baseline commits already in tree:
  - diagnostics baseline: `b3d9f56`
  - latest perf baseline before this experiment: `ae136f0`

## Scope

- Prototype a minimal `PT_MD_V2` export pre-arm / 1-entry pending slot.
- Goal was to reduce export serialization pressure on the two M buffers.
- This was evaluated locally and then reverted because it produced no measurable throughput gain.

## What Was Tried

The prototype added:

- one internal pending export slot in `PT_MD_V2`
- direct `EXP_WAIT_DONE -> EXP_REQ` handoff when a next ready buffer existed
- no public interface change
- no ISA change

The experiment was intentionally small and safe:

- only export descriptor selection/staging changed
- no change to M-buffer correctness rules
- no change to visible software semantics

## Local Validation

The prototype itself passed local safety checks before being reverted:

- `./scripts/synth_sanity.sh`
  - `PASS`
- native `PT` verify:
  - `m16_k32_n16` `PASS`
  - `m16_k64_n16` `PASS`
  - `m32_k32_n32` `PASS`
  - `m48_k32_n32` `PASS`
- `PT_DMA_TOP` verify:
  - `m16_k32_n16` `PASS`
  - `m16_k64_n16` `PASS`
  - `m32_k32_n32` `PASS`
  - `m48_k32_n32` `PASS`
- `PT_DMA_TOP compact` multitile sweep:
  - `27/27 PASS`

So the experiment was functionally safe.

## Performance Result

There was no measurable performance uplift in the compact sweep.

Representative unchanged results:

- `16x32x64`
  - before: `585 cycles`
  - experiment: `585 cycles`
- `32x64x64`
  - before: `2137 cycles`
  - experiment: `2137 cycles`
- `64x64x64`
  - before: `4359 cycles`
  - experiment: `4359 cycles`

Bucket-level behavior was also unchanged.

## Why It Did Not Help

The earlier CE/MD block breakdown already exposed the reason:

- `PT_MD_V2` export is stream-dominated, not setup-dominated
- for representative `m2_n2_k1`:
  - `ce_resp -> wr_desc = 2 cycles`
  - `wr_desc -> first_beat = 3 cycles`
  - `first_beat -> last_beat = 126 cycles`
  - `last_beat -> done = 1 cycle`

So even a perfect descriptor pre-arm can only attack about:

- `5 cycles`

while the real export tail is:

- `126 cycles` of payload streaming

Also, current parameters are already at full row width:

- `M_EXPORT_LANES = 16`
- `GEMM_Y_DIM = 16`

That means export bandwidth is already one full row chunk per beat group; the remaining cost comes from the number of row chunks that must be drained, not descriptor setup.

## Interpretation

This experiment confirms:

- export descriptor staging is not the active bottleneck
- the current export tail is fundamentally bandwidth/volume dominated
- a small pre-arm queue is too weak to move app-level GOPS under current interface and parameter constraints

## Decision

- The prototype RTL was reverted locally.
- No remote SpyGlass/DC signoff run was started for this experiment, because there was no surviving RTL candidate worth burning a hardware iteration on.

## Updated Next Step

If the goal remains “reduce export as the dominant end-to-end block”, the next meaningful options are no longer tiny control optimizations.

Higher-ROI directions are:

1. reduce export volume on the critical path
2. increase true export throughput
3. change the M-buffer turnover structure more fundamentally

Concretely, that means the next useful work is more likely:

- deeper CE/export overlap with different completion semantics
- more physical M buffering
- or interface-level export bandwidth changes

not another small descriptor/control optimization inside `PT_MD_V2`.
