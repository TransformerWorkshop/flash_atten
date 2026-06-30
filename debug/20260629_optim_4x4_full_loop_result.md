# Optim 4x4 Full-Loop Performance Anchor

Date: 2026-06-30

Branch: `optim`

## Current RTL Anchor

This is the current fixed-shape `4*4x4` RTL full-loop anchor for `S=256`,
`d=64`, `batch=1`, `head=1`.

The landing top is `FA_OPTIM_4X4_FULL_LOOP`. It starts one real
`FA_OPTIM_4X4_Q_TILE_STAGGERED_CORE` per Q tile. The q-tile core keeps one
shared score/row-state/OACC path and four 4x4 GEMM lanes, with four local
in-flight slots carrying score/P/rescale/partial-O data across the 16 resident
KV blocks.

Area-oriented row-partial version:

- P is stored as a 4-row block per slot (`1024b`), not a full 16x16 P tile.
- Rescale is stored as a 4-row block per slot (`128b`), not a full 16-row vector.
- Partial-O is stored/read as 4 independent `1024b` rows per slot.
- OACC consumes partial-O through the row-read interface, avoiding a `4096b`
  block mux/copy inside the q-tile core and OACC update.

The external Q/K/V tile interfaces remain 64-bit beat interfaces:

- Q load: `64` beats per Q tile, `4096` beats total.
- K load: `256` beats per KV tile, `4096` beats total for 16 resident KV tiles.
- V load: `256` beats per KV tile, `4096` beats total for 16 resident KV tiles.
- The 512-bit K/V paths are internal SRAM-bank response packs, not external bus
  ports.

This is still an operator-core anchor, not a product top: AXI fetch, CSR shell,
and full O writeback are not integrated here.

## Remote VCS Evidence

Remote VM: `ic-canopsys` (`host@100.108.220.80`)

Current row-partial q-tile full-loop run:

```text
RUN=/home/host/codex_runs/fa_optim_4x4_row_partial_20260630_025951
VCS compile: CODEX_VCS_COMPILE_STATUS=0
VCS run: CODEX_VCS_RUN_STATUS=0
PASS: fa_optim_4x4_full_loop_tb shape=S256_D64_B1_H1 perf_max_cycles=123202 cycles=116065 micro_tiles=1024 q_tiles=64 kv_tiles=1024 q_reqs=64 q_beats=4096 k_reqs=16 k_beats=4096 v_reqs=16 v_beats=4096 qk_tasks=131072 pv_tasks=131072
```

Previous fastest q-tile staggered full-loop run before row-partial OACC:

```text
RUN=/home/host/codex_runs/fa_optim_4x4_stagger_20260629_235329
PASS: fa_optim_4x4_full_loop_tb shape=S256_D64_B1_H1 perf_max_cycles=123202 cycles=112353 micro_tiles=1024 q_tiles=64 kv_tiles=1024 q_reqs=64 q_beats=4096 k_reqs=16 k_beats=4096 v_reqs=16 v_beats=4096 qk_tasks=131072 pv_tasks=131072
```

Baseline full-compute reference:

```text
RUN=/home/host/codex_runs/fa_full_compute_baseline_20260629_173040
PASS: fa_top_baseline_full_compute_tb shape=S256_D64_B1_H1 format=Q8.8 cycles=123203 rd_bytes=1081344 wr_bytes=32768
```

## Current Performance Conclusion

| Metric | Row-partial optim | Previous fastest optim |
| --- | ---: | ---: |
| Full-loop cycles | `116065` | `112353` |
| Baseline full-compute cycles | `123203` | `123203` |
| Ratio vs baseline | `0.942x` | `0.912x` |
| Speedup vs baseline | `1.061x` | `1.097x` |
| Q 64b beats | `4096` | `4096` |
| K 64b beats | `4096` | `4096` |
| V 64b beats | `4096` | `4096` |
| Total Q/K/V load beats | `12288` | `12288` |
| Effective MAC/cycle, QK+PV | `72.27` | `74.66` |
| 5 ns latency | `0.580 ms` | `0.562 ms` |
| Effective throughput at 5 ns, MAC=2 ops | `28.90 GOPS` | `29.87 GOPS` |

The area-oriented row-partial RTL still beats the current baseline cycle anchor:
`116065 < 123203`. The row-partial OACC path costs about `3712` cycles versus
the fastest flat partial-O version, but it removes the DC-blocking wide
partial-O mux/copy structure.

## Functional Coverage Status

The current full-loop smoke is a complete fixed-shape run with Q/K/V external
64-bit beat traffic, resident K/V SRAM loading, 64 Q tiles, and 1024 logical
micro tiles.

The smoke data keeps Q/K at zero and V nonzero, so it verifies the full-loop
control/data movement counters and nonzero final O, but it is not yet a strong
nonzero Q/K golden compare. The micro-pipeline TB still covers nonzero local
tile data through the real score/row-state/PV/OACC path.

## Area/DC Status

TSMC28 NAND2 reference:

```text
ref=tcbn28hpcplusbwp7t40p140ffg0p99v0c_ccs/ND2D0BWP7T40P140
nand2_area=0.294000
```

SRAM macro floor from the generated 256x64 SRAM `.db`:

```text
CODEX_FA_OPTIM_FULL_LOOP_PRECOMPILE_MACRO_FLOOR_NAND2 ref=tcbn28hpcplusbwp7t40p140ffg0p99v0c_ccs/ND2D0BWP7T40P140 nand2_area=0.294000 sram256x64_area=8399.200195 k_sram_count=32 k_sram_area=268774.40624 k_sram_nand2=914198.66068 v_sram_count=16 v_sram_area=134387.20312 v_sram_nand2=457099.33034 total_sram_count=48 total_sram_area=403161.60936 total_sram_nand2=1371297.99102
```

Old flat-buffer DC failure mode:

- `quick` mapped compile on the flat partial-O/P/rescale version reached about
  `29.86GB` RSS after about 52 minutes and produced no mapped area.
- `exact_map` on the same family reached about `29.7GB` RSS and produced no
  `nand2_area.log`.
- A buffer-reduced P/rescale-only version still reached about `29.6GB` RSS in
  `hier_area` and produced no `hier_area_nand2.log`.

Current row-partial `hier_area` result:

```text
RUN=/home/host/codex_runs/fa_optim_4x4_row_partial_20260630_025951/remote_reports/dc_full/hier_area_row_partial_20260630_030117
CODEX_FA_OPTIM_FULL_LOOP_DC_HIER_AREA full_mapped=0 ref=tcbn28hpcplusbwp7t40p140ffg0p99v0c_ccs/ND2D0BWP7T40P140 nand2_area=0.294000 total_sram_count=48 total_sram_area=403161.60936 total_sram_nand2=1371297.99102 top_cell_count=18175 hier_cell_count=211616 register_count=83031 q_tile_core=FA_OPTIM_4X4_Q_TILE_STAGGERED_CORE
```

This is not a mapped area claim (`full_mapped=0`), but it proves the row-partial
RTL gets through DC elaboration/link/reporting in about 90 seconds and reduces
the pre-map hierarchy from the earlier `1553096` hierarchical cells / `100314`
registers to `211616` hierarchical cells / `83031` registers.

Current row-partial mapped quick DC result:

```text
RUN=/home/host/codex_runs/fa_optim_4x4_row_partial_20260630_025951/remote_reports/dc_full/quick_row_partial_20260630_030309
CODEX_FA_OPTIM_FULL_LOOP_DC_DONE top=FA_OPTIM_4X4_FULL_LOOP report_dir=/home/host/codex_runs/fa_optim_4x4_row_partial_20260630_025951/remote_reports/dc_full/quick_row_partial_20260630_030309 result_dir=/home/host/codex_runs/fa_optim_4x4_row_partial_20260630_025951/remote_reports/dc_full/quick_row_partial_20260630_030309/results
```

Resource usage:

```text
Elapsed time: 5143 s = 1.43 h
CPU time:     5128 s = 1.42 h
Peak memory:  9842 MB
```

Mapped area from `area.rpt` / `qor.rpt`:

| Area bucket | Cell area | NAND2 equivalent |
| --- | ---: | ---: |
| Total cell area | `932731.853663` | `3172557.33` |
| Macro/black-box area, 48 SRAMs | `403161.609375` | `1371297.99` |
| Logic + registers, excluding SRAM macros | `529570.244288` | `1801259.33` |
| Combinational area | `376612.334082` | `1280994.33` |
| Noncombinational area | `152957.910206` | `520264.66` |

The original `nand2_area.log` from this run contains an extraction bug:

```text
CODEX_FA_OPTIM_FULL_LOOP_DC_NAND2 ref=tcbn28hpcplusbwp7t40p140ffg0p99v0c_ccs/ND2D0BWP7T40P140 area=0.294000 total_area= nand2_equiv=0.0
```

The checked-in DC Tcl now falls back to parsing `Total cell area` and
`Macro/Black Box area` from `area.rpt`, so future runs should directly report
`full_mapped=1`, `total_nand2`, `macro_nand2`, and `logic_nand2`.

Mapped quick timing status at the 5 ns anchor:

```text
Critical Path Length: 14.16 ns
Critical Path Slack:  -9.16 ns
Total Negative Slack: -654.90 ns
Violating setup paths: 1183
Hold WNS/TNS/paths: 0.00 / 0.00 / 0
Levels of logic: 810
```

This is a mapped area anchor, not a timing-closed 5 ns implementation. The
exposed timing bottleneck is the shared row-state reciprocal/divide path
(`u_q_tile_core/u_row_state/u_recip`), not the SRAM bank structure.

Check-design is still noisy because this is an operator-core anchor with many
debug/status/unconnected structural ports: `LINT-28=71225`, `LINT-8=3417`,
`LINT-29=4336`, `LINT-31=79`, `LINT-52=11`, and `LINT-33=1795`.

## Current Area Conclusion

The first complete row-partial `4*4x4` RTL anchor now has both performance and
mapped area evidence:

- Performance: `116065` cycles versus the current baseline full-compute anchor
  `123203` cycles, or `1.061x` faster.
- Mapped area: `3.173M` NAND2 total, including `1.371M` NAND2 SRAM macro floor
  and `1.801M` NAND2 synthesized logic/registers.
- DC tractability: the old flat-buffer structure failed around `29-30GB`; the
  row-partial structure completed mapped quick DC in `9.8GB`.

Against the historical numerical `FA_TOP_BASELINE` DC area
(`1405399.127886` cell area = about `4.780M` NAND2), this anchor is about
`33.6%` smaller in NAND2. Treat that as a directional architecture comparison,
not a final product-top apples-to-apples result, because this optim anchor still
lacks AXI fetch/writeback shell integration and timing closure.
