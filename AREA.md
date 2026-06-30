# Flash Attention Optim 4x4 Area Anchor

Date: 2026-06-30

Branch: `optim`

## Frozen Version

This document freezes the first measured RTL area/performance anchor for the
`4*4x4` optim direction.

Landing top:

```text
FA_OPTIM_4X4_FULL_LOOP
```

Core:

```text
FA_OPTIM_4X4_Q_TILE_STAGGERED_CORE
```

The core uses four 4x4 GEMM lanes, one shared score/row-state/OACC path, and
row-partial P/rescale/partial-O buffering. The full-loop top uses 64-bit
external Q/K/V beat interfaces and local SRAM macros for resident K/V tiles.

This is an operator-core anchor. AXI fetch/writeback shell integration and
timing closure are not part of this frozen first area point.

## Workload

Fixed test shape:

```text
S = 256
d = 64
batch = 1
head = 1
Q/K/V/O format = Q8.8 / fixed-point RTL path
```

External load traffic in the optim full-loop smoke:

| Operand | 64-bit beats |
| --- | ---: |
| Q | `4096` |
| K | `4096` |
| V | `4096` |
| Total Q/K/V | `12288` |

## Performance Evidence

Remote run:

```text
/home/host/codex_runs/fa_optim_4x4_row_partial_20260630_025951/remote_reports/vcs_full
```

VCS result:

```text
PASS: fa_optim_4x4_full_loop_tb shape=S256_D64_B1_H1 perf_max_cycles=123202 cycles=116065 micro_tiles=1024 q_tiles=64 kv_tiles=1024 q_reqs=64 q_beats=4096 k_reqs=16 k_beats=4096 v_reqs=16 v_beats=4096 qk_tasks=131072 pv_tasks=131072
```

Baseline full-compute reference:

```text
/home/host/codex_runs/fa_full_compute_baseline_20260629_173040
PASS: fa_top_baseline_full_compute_tb shape=S256_D64_B1_H1 format=Q8.8 cycles=123203 rd_bytes=1081344 wr_bytes=32768
```

Performance summary:

| Metric | Optim first version | Baseline |
| --- | ---: | ---: |
| Cycles | `116065` | `123203` |
| Ratio vs baseline | `0.942x` | `1.000x` |
| Speedup vs baseline | `1.061x` | `1.000x` |
| Effective MAC/cycle, QK+PV | `72.27` | N/A |
| Latency at 5 ns | `0.580 ms` | `0.616 ms` |
| Throughput at 5 ns, MAC=2 ops | `28.90 GOPS` | N/A |

## SRAM Macro Configuration

TSMC28 same-spec SRAM replacement for the original Sky130 256-depth macro:

```text
TEM5N28HPCPLVTA256X64M4SWSO
```

SRAM counts in this frozen version:

| Macro group | Count | Role |
| --- | ---: | --- |
| K tile SRAM | `32` | 16 K rows x 2 KV half groups |
| V tile SRAM | `16` | V read packing by row/chunk wave |
| Total | `48` | resident K/V local tile storage |

SRAM macro area from DC library:

```text
ND2D0BWP7T40P140 area = 0.294000
TEM5N28HPCPLVTA256X64M4SWSO area = 8399.200195
```

Macro floor:

| Item | Cell area | NAND2 |
| --- | ---: | ---: |
| K SRAM, 32 macros | `268774.406240` | `914198.66` |
| V SRAM, 16 macros | `134387.203120` | `457099.33` |
| Total SRAM, 48 macros | `403161.609360` | `1371297.99` |

## DC Area Evidence

Remote mapped quick DC run:

```text
/home/host/codex_runs/fa_optim_4x4_row_partial_20260630_025951/remote_reports/dc_full/quick_row_partial_20260630_030309
```

Tool/runtime:

```text
Design Compiler T-2022.03-SP2
Elapsed time: 5143 s = 1.43 h
CPU time:     5128 s = 1.42 h
Peak memory:  9842 MB
```

Mapped area from `area.rpt` / `qor.rpt`:

| Bucket | Cell area | NAND2 |
| --- | ---: | ---: |
| Total cell area | `932731.853663` | `3172557.33` |
| Macro/black-box area | `403161.609375` | `1371297.99` |
| Logic + registers, excluding SRAM macros | `529570.244288` | `1801259.33` |
| Combinational area | `376612.334082` | `1280994.33` |
| Noncombinational area | `152957.910206` | `520264.66` |

Cell counts:

| Metric | Count |
| --- | ---: |
| Leaf cells | `682003` |
| Combinational cells | `599293` |
| Sequential cells | `82710` |
| Macros | `48` |

Key hierarchy hot spots:

| Hierarchy | Cell area | NAND2 |
| --- | ---: | ---: |
| `u_q_tile_core` | `508605.6924` | `1729941.13` |
| `u_q_tile_core/u_oacc_update` | `86638.1740` | `294687.67` |
| `u_q_tile_core/u_row_state` | `76878.7459` | `261492.33` |
| `u_q_tile_core/u_score_post` | `66765.5381` | `227093.67` |
| One `GEMM_V3` 4x4 lane | `36941.3942` | `125650.66` |
| Four 4x4 GEMM lanes | about `147765.58` | about `502602.64` |

## Timing Status

The mapped quick run is an area anchor, not a timing-closed result.

5 ns QoR:

```text
Critical Path Length: 14.16 ns
Critical Path Slack:  -9.16 ns
Total Negative Slack: -654.90 ns
Violating setup paths: 1183
Hold WNS/TNS/paths: 0.00 / 0.00 / 0
Levels of logic: 810
```

Primary timing bottleneck:

```text
u_q_tile_core/u_row_state/u_recip
```

## Check-Design Status

The first frozen anchor still has check-design noise because it is an
operator-core with many structural/debug/status ports and generated arithmetic.

Summary:

| Check | Count |
| --- | ---: |
| LINT-28 unconnected ports | `71225` |
| LINT-8 unloaded inputs | `3417` |
| LINT-29 feedthrough | `4336` |
| LINT-31 shorted outputs | `79` |
| LINT-52 constant outputs | `11` |
| LINT-33 same-net multi-pin cells | `1795` |

This is not signoff-clean RTL. It is sufficient for the first architecture
area/performance anchor.

## Interpretation

The first frozen version proves:

- The `4*4x4` row-partial architecture is measurable in RTL for full
  `S=256,d=64`.
- It beats the current full-compute baseline in cycles:
  `116065 < 123203`.
- It produces a mapped DC area point:
  `3.173M NAND2`.
- It avoids the old flat-buffer DC failure mode. The flat partial-O/P/rescale
  structure reached about `29-30 GB` without useful mapped area; the row-partial
  version completed mapped quick DC at `9.8 GB`.

Compared with the historical numerical `FA_TOP_BASELINE` DC area
(`1405399.127886` cell area, about `4.780M NAND2`), this first optim anchor is
directionally smaller by about `33.6%`. This is not a final product-top
apples-to-apples signoff comparison because AXI shell integration and timing
closure remain open.

## Post-Freeze VCS Cleanup

This section tracks RTL cleanup after the frozen first area point. It does not
replace the DC area numbers above until a new DC run is explicitly requested.

K SRAM bank folding:

| Item | Frozen first area point | Post-freeze RTL cleanup |
| --- | ---: | ---: |
| K tile SRAM macros | `32` | `16` |
| V tile SRAM macros | `16` | `16` |
| Total K/V SRAM macros | `48` | `32` |

Contract:

- K write bank is the K row index, `0..15`.
- Full KV tile index `kv_idx[3:0]` is stored in the 256-depth SRAM row field.
- K read still returns 16 K rows in parallel, so the QK feeder bandwidth is
  unchanged for the current full-loop schedule.

VCS-only evidence:

```text
/home/host/codex_runs/fa_optim_4x4_kfold_20260630_1113/remote_reports/vcs_kfold
PASS: fa_optim_4x4_full_loop_tb shape=S256_D64_B1_H1 perf_max_cycles=123202 cycles=116065 micro_tiles=1024 q_tiles=64 kv_tiles=1024 q_reqs=64 q_beats=4096 k_reqs=16 k_beats=4096 v_reqs=16 v_beats=4096 qk_tasks=131072 pv_tasks=131072
```

The smoke now also checks the folded K SRAM physical layout by writing a
nonzero K pattern and verifying:

```text
bank = k_row_idx
addr = {kv_idx[3:0], chunk_idx}
```

No DC was run for this cleanup per the current milestone scope.

## Current Q4 20-Macro Compile-Ultra DC Evidence

This section records the latest landed q4 windowed product-top area point. It
replaces the earlier pre-DC estimate for this q4 macro-backed architecture.
The flow order was SpyGlass lint first, then mapped DC with
`compile_ultra -no_autoungroup`.

Current RTL contract:

| Resource | Count | Role |
| --- | ---: | --- |
| K window SRAM | `8` | Packed K window, adjacent rows in low/high 32b lanes |
| V window SRAM | `8` | Packed V window, slot identity in address |
| OACC group SRAM | `4` | q4 OACC state backing |
| Total SRAM | `20` | q4 windowed storage contract |

Using the same DC library numbers as the frozen anchor:

```text
ND2D0BWP7T40P140 area = 0.294000
TEM5N28HPCPLVTA256X64M4SWSO area = 8399.200195
```

Current macro floor:

| Item | Cell area | NAND2 |
| --- | ---: | ---: |
| K SRAM, 8 macros | `67193.601560` | `228549.67` |
| V SRAM, 8 macros | `67193.601560` | `228549.67` |
| OACC SRAM, 4 macros | `33596.800780` | `114274.83` |
| Total SRAM, 20 macros | `167984.003900` | `571374.16` |

SpyGlass lint gate:

```text
RUN=/home/host/codex_runs/fa_q4_windowed_spyglass_fixw122_20260630_224456
Top=FA_TOP_OPTIM_WINDOWED
SpyGlass_vT-2022.06-1 lint/lint_rtl
FATAL=0 ERROR=0 WARNING=264 INFO=4
```

The first SpyGlass run reported one `W122` error in
`FA_OPTIM_4X4_Q_TILE_STAGGERED_CORE`: `get_q_word` read `q_block_flat` as a
hidden function dependency. The RTL fix made the helper pure by passing the
4096-bit Q block as an explicit function input. The rerun reached the
`0 fatal / 0 error` lint gate, but warnings remain and this is not lint
signoff-clean.

Mapped DC run:

```text
RUN=/home/host/codex_runs/fa_q4_windowed_spyglass_fixw122_20260630_224456/dc_ultra
Tool=Design Compiler T-2022.03-SP2
Compile=compile_ultra -no_autoungroup
Clock=5 ns
Elapsed=5104 s = 1.42 h
CPU=4872 s = 1.35 h
Peak session memory including child processes=5283 MB
```

Mapped area from `area.rpt` / `nand2_area.log`:

| Bucket | Cell area | NAND2 |
| --- | ---: | ---: |
| Total cell area | `577668.887590` | `1964860.16` |
| Macro/black-box area | `167984.003906` | `571374.16` |
| Logic + registers, excluding SRAM macros | `409684.883684` | `1393486.00` |
| Combinational area | `256331.250573` | `871875.00` |
| Noncombinational area | `153353.633111` | `521611.00` |

Cell counts:

| Metric | Count |
| --- | ---: |
| Leaf cells | `521076` |
| Combinational cells | `438424` |
| Sequential cells | `82652` |
| Macros | `20` |

Key hierarchy hot spots:

| Hierarchy | Cell area | NAND2 |
| --- | ---: | ---: |
| `u_q_tile_core` | `368330.1578` | `1252823.67` |
| `u_q_tile_core/u_oacc_update` | `75216.4700` | `255838.33` |
| `u_q_tile_core/u_row_state` | `39992.1339` | `136027.67` |
| `u_q_tile_core/u_row_state/u_recip` | `3128.5520` | `10641.33` |
| `u_q_tile_core/u_score_post` | `16185.9739` | `55054.33` |
| Four `GEMM_V3` 4x4 lanes | `127142.9460` | `432459.00` |

Timing and rule status from `qor.rpt`:

| Metric | Result |
| --- | ---: |
| Critical path length | `4.98 ns` |
| Setup WNS / TNS / violating paths | `0.00 / 0.00 / 0` |
| Hold WNS / TNS / violating paths | `0.00 / 0.00 / 0` |
| Levels of logic | `149` |
| Nets with design-rule violations | `4` |
| Max transition / max capacitance violations | `2 / 2` |

The reported critical paths start at
`u_windowed_loop/u_q_tile_core/feed_count_r_reg[5]` and end in GEMM accumulator
registers. DC also reports two high-fanout nets with `TIM-134`; this is a
front-end timing estimate, not a routed timing signoff result.

DC `check_design` still has non-signoff warning noise:

| Check | Count |
| --- | ---: |
| `LINT-28` unconnected ports | `59290` |
| `LINT-31` shorted outputs | `25` |
| `LINT-52` constant outputs | `18` |
| `LINT-32` tied pins | `40429` |
| `LINT-33` same-net multi-pin cells | `70` |
| `LINT-60` hierarchy pins without driver/load | `539` |

The dominant buckets are generated SRAM wrapper pins, unused CSR/config bits,
and writer/setup artifacts. They do not block this area probe, but they are not
waived as final product signoff.

Compared with the frozen 48-macro area point, the SRAM macro floor alone drops:

| Change | NAND2 saved |
| --- | ---: |
| 48 macros -> 20 macros | `799923.83` |

Area interpretation:

- The current q4 windowed product-top maps to `1.965M NAND2` including SRAM
  macros, so it is just under a hard `2.0M NAND2` area line in this DC run.
- The margin is thin: about `35.1k NAND2`, or `1.8%` of a `2.0M` budget. It is
  acceptable as a first compile-ultra area anchor, but not comfortable enough
  to stop area cleanup.
- Relative to the frozen 48-macro row-partial point (`3.173M NAND2`), total
  area is down about `38.1%`. The macro floor is down about `58.3%`, and
  non-SRAM logic is down about `22.6%`.
- Relative to the historical numerical baseline area of about `4.780M NAND2`,
  this point is down about `58.9%`, with the usual caveat that this is still a
  front-end mapped DC comparison, not routed signoff.
- The macro question is no longer the dominant risk. The main remaining area is
  inside `u_q_tile_core`: OACC update, GEMM lanes, row-state, and score-post.

## Post-Latest-Run RTL Area Cleanup

Date: 2026-07-01

The `1.965M NAND2` number above is the latest measured DC result. The RTL
cleanup in this section landed after that run and has not been re-run through
DC per the current milestone scope. Treat these as implemented area-reduction
items with local static/model verification; fresh post-cleanup VCS and DC
numbers are still pending before replacing the measured NAND2 anchor.

Completed priority items:

1. Q4 score-post specialization:
   - Added `FA_SCORE_POST_Q4_BLOCK_REAL` and switched the active q4 core to it.
   - Removed the 16-row tile interface shape from the active product path.
   - Dropped row/tile debug outputs and the configurable score-scale multiply
     from the active q4 path; the current top uses fixed unit scale.

2. Q4 row-state specialization:
   - Added `FA_ROW_STATE_Q4_BLOCK_REAL`.
   - Restore/snapshot state width is now 4 rows:
     `m/l = 128b + 128b`, `seen = 4b`.
   - The reciprocal remains `FA_RECIP_Q16_16`; no approximation was introduced
     in this cleanup.

3. Q4 OACC update specialization:
   - Added `FA_OACC_UPDATE_Q4_BLOCK_REAL`.
   - OACC row addressing is now local `2b` q4 row addressing.
   - Removed the older partial-row/tile-wide input muxing from the active q4
     update path while keeping the q4 OACC macro-backed contract.

4. GEMM/GEMU control-width cleanup:
   - `GEMM_V3` and `GEMU_V3` now expose `ACC_COUNT_WIDTH`.
   - `GEMM_V3` also exposes `GROUP_IDX_WIDTH`.
   - The active 4x4 product path uses `ACC_COUNT_WIDTH=6` and
     `GROUP_IDX_WIDTH=2`, instead of carrying default 32-bit control fields
     through the synthesized datapath.

5. Q-group state-width cleanup:
   - `FA_OPTIM_4X4_WINDOWED_LOOP` q4 row-state arrays now store only the active
     q4 state:
     `q_tile_m_state_r/q_tile_l_state_r = 128b`, `q_tile_row_seen_r = 4b`.
   - This removes the old 16-row snapshot shape from the q4 window scheduler.

Expected impact:

- Macro count remains `20`; this cleanup targets non-macro area.
- No intentional scheduler or memory-traffic change was made, so performance
  should stay on the q4 OACC macro-backed contract. VCS counters are still the
  authority for the landed build.
- The K/V `16 -> 8` bank compression is already part of the latest q4
  macro-backed schedule. K writes split each 64b external beat into two packed
  SRAM writes through `k_pack_pending_r`, so the load path pays an explicit
  extra cycle per K beat. That is why this is an area/performance trade-off,
  not a free macro reduction.
- The largest expected post-latest-run gains are in `u_score_post`,
  `u_row_state`, `u_oacc_update`, and narrow GEMM/GEMU control logic. A new DC
  run is needed before replacing the latest measured `1.964860M NAND2` result.

## Next Area Optimization Targets

These are follow-ups after the q4 20-macro compile-ultra point and the
post-latest-run q4-specialization cleanup above. They should not change the
current architecture contract unless a new performance run proves the trade-off.

1. OACC update:
   - Current `u_oacc_update` costs `0.256M NAND2`.
   - Keep the q4 OACC macro-backed contract, but look for narrower update
     datapaths or better operand reuse before increasing SRAM macro count.

2. GEMM lanes:
   - Four 4x4 GEMM lanes cost about `0.432M NAND2`.
   - The critical paths are now from `feed_count_r` into GEMM accumulator
     registers, so any area compaction here must keep the 5 ns schedule honest.

3. Row-state and score-post:
   - `u_row_state` is now `0.136M NAND2`; the reciprocal sub-block itself is
     only `0.011M NAND2` after compile-ultra pruning.
   - Score-post is `0.055M NAND2`, much smaller than the frozen anchor, so it is
     no longer the first area target.

4. Check-design and design-rule cleanup:
   - Reduce generated unconnected ports and CSR/debug/status unused bits after
     the architecture point is stable.
   - Clear or explain the remaining `4` design-rule violating nets before any
     signoff-oriented physical flow.

## Frozen Artifact Paths

Local files:

```text
rtl/fa_optim_4x4_full_loop.v
rtl/fa_optim_4x4_q_tile_staggered_core.v
sim/rtl_smoke/fa_optim_4x4_full_loop_tb.v
scripts/fa_optim_4x4_full_loop_area.tcl
debug/20260629_optim_4x4_full_loop_result.md
AREA.md
```

Remote evidence:

```text
/home/host/codex_runs/fa_optim_4x4_row_partial_20260630_025951/remote_reports/vcs_full/run.log
/home/host/codex_runs/fa_optim_4x4_row_partial_20260630_025951/remote_reports/dc_full/quick_row_partial_20260630_030309/area.rpt
/home/host/codex_runs/fa_optim_4x4_row_partial_20260630_025951/remote_reports/dc_full/quick_row_partial_20260630_030309/qor.rpt
/home/host/codex_runs/fa_optim_4x4_row_partial_20260630_025951/remote_reports/dc_full/quick_row_partial_20260630_030309/timing.rpt
/home/host/codex_runs/fa_optim_4x4_row_partial_20260630_025951/remote_reports/dc_full/quick_row_partial_20260630_030309/check_design.rpt
```
