# PT_DMA_TOP Bottleneck Reassessment After Safe Load-Prefetch

- Timestamp: `2026-04-22 09:37:41 +0800`
- Branch: `codex-app`
- Analysis baseline:
  - current sweep: [`multitile_sweep_pt_dma_top_icarus_compact.json`](/Users/yucheng/Documents/GitHub/flash_atten/app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_icarus_compact.json)
  - current summary: [`multitile_sweep_pt_dma_top_200mhz_gops.md`](/Users/yucheng/Documents/GitHub/flash_atten/app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_200mhz_gops.md)
  - previous 200MHz baseline was the pre-prefetch table committed before `ae136f0`

## Summary

- The front-end command tax is no longer the dominant limiter for adapted `PT_DMA_TOP` cases.
- Safe software `LOAD(next)` prefetch plus bank-aware overlap successfully hid most of the old A/B fill serialization cost.
- The next first-order bottleneck has shifted to:
  1. CE-side `accept -> resp`
  2. export-side `resp -> done`
  3. only then deeper A/B fill-path structure below the shared MD datapath

## Quantitative Delta

Previous bucket averages:

- `1 cmd`: `17.062 GOPS`
- `2 cmds`: `16.800 GOPS`
- `4 cmds`: `16.761 GOPS`
- `8 cmds`: `16.447 GOPS`
- `16 cmds`: `15.606 GOPS`

Current bucket averages:

- `1 cmd`: `18.358 GOPS`
- `2 cmds`: `20.122 GOPS`
- `4 cmds`: `23.022 GOPS`
- `8 cmds`: `24.244 GOPS`
- `16 cmds`: `24.055 GOPS`

Key case delta:

- `64x64x64`
  - old: `15.606 GOPS @ 200MHz`
  - new: `24.055 GOPS @ 200MHz`
  - uplift: `+54.1%`

Interpretation:

- Before this round, more commands always meant worse GOPS.
- After this round, multi-command buckets are now better than direct `1 cmd` on average.
- That inversion is strong evidence that the wrapper-visible per-command tax has largely been hidden behind overlap.

## Current Stage Breakdown

Bucket averages from current compact sweep:

- logical `1 cmd`
  - done `189.4 cycles`
  - `push->accept = 1`
  - `accept->resp = 121.4`
  - `resp->done = 67`
- logical `2 cmds`
  - done `440.0 cycles`
  - `push->accept = 4`
  - `accept->resp = 289.0`
  - `resp->done = 158.0`
- logical `4 cmds`
  - done `847.0 cycles`
  - `push->accept = 8`
  - `accept->resp = 612.0`
  - `resp->done = 332.0`
- logical `8 cmds`
  - done `1722.6 cycles`
  - `push->accept = 16`
  - `accept->resp = 1259.2`
  - `resp->done = 740.8`
- logical `16 cmds`
  - done `4359 cycles`
  - `push->accept = 32`
  - `accept->resp = 2800`
  - `resp->done = 2096`

Important note:

- `perf_other_cycles` is negative on overlapped cases because the interval counters are no longer disjoint.
- So the correct reading is not “negative time exists”; it is “multiple stages overlap enough that simple additive decomposition double-counts”.

## What This Means

### 1. Front-end launch is now small

- `push->accept` is about `0.7%` of total time on the long cases.
- AXI-Lite is already at the compact-path floor:
  - `6` writes per issued command
  - `12` writes per logical command for prefetch workloads (`LOAD + MATMUL`)

So continuing to optimize descriptor submission is no longer the highest-ROI next move.

### 2. CE dominates the remaining critical path

Representative long cases:

- `32x64x64`
  - done `2137`
  - `accept->resp = 1400`
  - `resp->done = 1048`
- `64x64x64`
  - done `4359`
  - `accept->resp = 2800`
  - `resp->done = 2096`

Even with overlap, `accept->resp` is still the single biggest term.

This points to remaining cost inside:

- CE command execution
- quant / drain scheduling
- internal A/B fill handling that is still serialized under the shared MD path

### 3. Export is now the secondary limiter

`resp->done` remains large on wide-`N` and long schedules.

For example:

- `64x64x64`
  - export beats: `1024`
  - `resp->done = 2096 cycles`

So once CE returns a response, writeback/export still takes a meaningful tail.

## Updated Priority

### P0

- Keep the current software prefetch path as the default high-performance path for adapted `PT_DMA_TOP` workloads.
- Do not reopen unsafe residency reuse or unsafe `ctrl_id` reuse ideas; the current scheme is both fast and safe.

### P1

- Attack CE-side `accept->resp`.
- Best next direction:
  - split or pipeline the A/B fill machinery further below the shared MD datapath
  - reduce cases where A fill and B fill still serialize behind one internal path

Why:

- front-end launch is already cheap
- long-case runtime is still dominated by the period before response visibility

### P2

- Improve export / `resp->done` overlap.
- Candidates:
  - earlier export launch
  - deeper decoupling between CE completion and M-buffer drain/export bookkeeping

### P3

- Only after P1/P2 should we revisit larger architectural surgery such as a true split of compute queue vs fill queue at the wrapper/core boundary.
- The latest data says that kind of top-level queue split is now lower ROI than deeper CE/MD restructuring.

## Bottom Line

- Old bottleneck:
  - wrapper submission overhead
- New bottleneck:
  - CE-side execution latency first
  - export tail second

So the next optimization round should move off the wrapper front-end and go after:

1. A/B fill parallelism under MD / CE
2. export tail reduction
