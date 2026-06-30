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

## Next Area Optimization Targets

These are not part of the frozen first version.

1. K SRAM bank folding:
   - Current K SRAM uses `32` 256x64 macros.
   - The current K mapping uses only half of each macro depth.
   - Folding K to `16` banks by moving `kv_idx[3]` into the SRAM row address
     should save about `0.457M NAND2` while preserving the 16-row QK read pack.

2. OACC column slicing:
   - Current OACC update costs about `0.295M NAND2`.
   - A 16-column sliced OACC can trade about 3 extra cycles per OACC task for a
     meaningful area reduction.
   - Estimated performance after a simple 4-cycle OACC update remains below the
     current baseline cycle count.

3. Row-state/reciprocal pipeline:
   - Current row-state costs about `0.261M NAND2` and is the 5 ns critical path.
   - The next RTL version should pipeline, iterate, or approximate the reciprocal
     path instead of allowing an 810-level combinational timing chain.

4. Check-design cleanup:
   - Reduce unconnected/debug/status ports after the architecture point is
     stable.
   - Do not use waivers as the first response; clean the RTL interfaces where
     practical.

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
