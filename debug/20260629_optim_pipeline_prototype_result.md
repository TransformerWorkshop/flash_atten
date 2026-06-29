# Optim SA Pipeline Prototype Result

Date: 2026-06-29

Remote run:

- VM: `ic-canopsys` / `host@100.108.220.80`
- Staging path: `/home/host/codex_runs/fa_optim_proto_20260629_164406`
- Branch: `optim`

## Scope

This is target-prototype RTL evidence for the 4-cluster 4x4-SA SRAM direction. It is
closer to RTL than the Python model because the scheduler/resource counters and local
SRAM-bank allocation are implemented as synthesizable RTL, but it is still not a full
`FA_TOP_BASELINE` replacement. Product-top dataflow, numeric datapath integration, and
end-to-end cocotb/VCS runs remain open.

Current evidence in this milestone:

- `FA_OPTIM_SA_PIPELINE_PROTOTYPE` models four 4x4-SA clusters, one shared SRAM
  feeder, one shared row-state pipe, local post-GEMM PV/OACC work, and explicit
  counters for cycles/resource occupancy/tasks/stalls.
- It instantiates `21` `FA_LOCAL_TILE_SRAM_16X64X16` banks so DC sees the intended
  local-buffer macro footprint, not only control logic.
- Each local tile SRAM maps to one same-spec `256x64` SRAM wrapper. Under
  `SYNTHESIS`, the process-neutral wrapper resolves to the TSMC28 substitute
  `TEM5N28HPCPLVTA256X64M4SWSO`.

## Buffer Contract Reflected In RTL

The `21` SRAM banks correspond to this target local-buffer allocation:

| Buffer group | Scope | Banks | Logical payload |
|---|---|---:|---|
| Q operand buffer | shared | 1 | 4 Q rows x 64 dim x 16b = 512 B |
| K operand buffer | per cluster | 4 | 4 clusters x 512 B |
| V operand buffer | per cluster | 4 | 4 clusters x 512 B |
| PV partial buffer | per cluster | 4 | 4 clusters x 512 B |
| OACC old buffer | per cluster | 4 | 4 clusters x 512 B |
| OACC new buffer | per cluster | 4 | 4 clusters x 512 B |

Small per-cluster state remains register-oriented in the contract: P tile is `32 B`
and row-scale state is `48 B` per cluster. The model-level full buffer estimate remains
`11584 B` including shared Q and task queues; the prototype intentionally macroizes the
large 512 B operand/partial/OACC blocks first.

## VCS Prototype Smoke

Command shape:

```sh
vcs -full64 -sverilog -timescale=1ns/1ps +v2k +incdir+rtl \
  sim/rtl_smoke/fa_optim_sa_pipeline_tb.v \
  rtl/fa_sram_hard.v rtl/fa_sram_tile_buffers.v \
  rtl/fa_optim_sa_pipeline_prototype.v \
  -top fa_optim_sa_pipeline_tb \
  -o remote_reports/vcs_proto/simv
./remote_reports/vcs_proto/simv
```

Result:

| Counter | RTL value | Model target |
|---|---:|---:|
| Cycles | 2242 | 2242 |
| SA busy cycles | 8704 | 8704 |
| Feeder busy cycles | 2176 | 2176 |
| Row-state busy cycles | 136 | 136 |
| QK tasks | 136 | 136 |
| PV tasks | 136 | 136 |
| OACC tasks | 136 | 136 |
| Row updates | 136 | 136 |
| QK feeds | 136 | 136 |
| PV feeds | 0 | 0 |
| Cluster wait slots | 264 | 264 |
| Feeder wait slots | 66 | 66 |

Active-cluster histogram:

| Active clusters | Cycles |
|---:|---:|
| 0 | 17 |
| 1 | 33 |
| 2 | 32 |
| 3 | 33 |
| 4 | 2127 |

Interpretation:

- Average active clusters: `8704 / 2242 = 3.88`.
- SA utilization: `8704 / (2242 x 4) = 0.971`.
- The single feeder is busy for `2176 / 2242 = 0.971` of cycles, but the local
  PV/OACC phases add enough independent cluster work to keep all four clusters active
  for most of the run.
- The shared row-state pipe is short in this target (`1` cycle per tile), so it is
  reused by phase staggering and is not the bottleneck in this scenario.

## TSMC28 Library Setup

`lc_shell -f scripts/fa_compile_tsmc_sram_libs.tcl` generated run-local DBs:

- `remote_reports/libs/tem5n28hpcplvta256x64m4swso_110a_ffg0p99v0c.db`
- `remote_reports/libs/tem5n28hpcplvta256x32m4swso_110a_ffg0p99v0c.db`

The prototype area compile links only the 256x64 SRAM DB. LC emitted `LBDB-366` and
`LIBG-280` library metadata/deprecation warnings, but both DB files were generated and
DC linked the 256x64 macro.

## DC Area And Timing

Top:

- `FA_OPTIM_SA_PIPELINE_PROTOTYPE`

Library setup:

- Stdcell: TSMC28 7T CCS `ffg0p99v0c`
- SRAM: run-local `tem5n28hpcplvta256x64m4swso_110a_ffg0p99v0c.db`
- Clock period requested: `5.0 ns`

Area result:

| Metric | Value |
|---|---:|
| Number of cells | 10187 |
| Sequential cells | 794 area report / 815 QoR leaf count |
| Macro count | 21 |
| Combinational area | 3618.846016 |
| Noncombinational area | 1516.060010 |
| Macro/Black Box area | 176383.204102 |
| Total cell area | 181518.110127 |

Timing/QoR:

| Metric | Value |
|---|---:|
| Critical path length | 2.49 ns |
| Critical path slack | 2.49 ns |
| Clock period | 5.00 ns |
| Setup WNS/TNS | 0.00 / 0.00 |
| Hold WNS/TNS | 0.00 / 0.00 |
| Max transition/cap violations | 0 / 0 |

Area interpretation:

- Raw SRAM macro area is `21 x 8399.200195 = 176383.204095`, matching the DC
  macro/black-box area within rounding.
- Non-SRAM control/counter/wrapper area is about `5134.906` cell-area units.
- Macro area dominates: `176383.204102 / 181518.110127 = 97.17%`.

## Check-Design Notes

DC `check_design` reports many prototype warnings:

- `LINT-28` unconnected ports: mostly constant/unused SRAM wrapper ports after
  this synthetic bank exerciser is optimized.
- `LINT-31` shorted outputs and `LINT-52` constant outputs: expected from the
  prototype's probe/XOR observability and constant masks.
- `LINT-32/LINT-33/LINT-60`: mostly hierarchy and constant-tie effects around the
  SRAM wrapper and generated bank array.

These are residual-risk notes for this prototype, not product-top signoff. The next
landing step should replace the synthetic bank exerciser with real operand read/write
ports, which should remove most of these warnings naturally.

## Architecture Conclusion

The user hypothesis now has RTL-prototype evidence:

- One SRAM feeder alone cannot make QK-only work fill four clusters, but once PV/OACC
  operate on local buffered operands, four 4x4 SA clusters can remain nearly full.
- Shared row-state/state-maintenance logic does not need to be replicated four times
  when it is short enough and the GEMM phases are staggered.
- Area is dominated by local SRAM banks, not by the scheduler/counter control logic.
  This supports treating bank count and buffer sizing as the main area knob for the
  next iteration.

## Remaining Gap Before Product-Level Claim

- `FA_OPTIM_SA_PIPELINE_PROTOTYPE` is not wired into `FA_TOP_BASELINE`.
- It does not compute numerical QK/PV/OACC data; it verifies resource scheduling,
  local SRAM allocation, and area footprint.
- Product-top performance and area still require connecting the storage-native path
  to the real scheduler/datapath and running top-level VCS/DC.

## Artifact Paths

Remote artifacts:

- VCS compile log: `/home/host/codex_runs/fa_optim_proto_20260629_164406/remote_reports/vcs_proto/compile.log`
- VCS run log: `/home/host/codex_runs/fa_optim_proto_20260629_164406/remote_reports/vcs_proto/run.log`
- LC log: `/home/host/codex_runs/fa_optim_proto_20260629_164406/remote_reports/libs/lc_compile.log`
- DC QoR: `/home/host/codex_runs/fa_optim_proto_20260629_164406/remote_reports/dc_proto/qor.rpt`
- DC area: `/home/host/codex_runs/fa_optim_proto_20260629_164406/remote_reports/dc_proto/area.rpt`
- DC references: `/home/host/codex_runs/fa_optim_proto_20260629_164406/remote_reports/dc_proto/reference.rpt`
- DC check-design: `/home/host/codex_runs/fa_optim_proto_20260629_164406/remote_reports/dc_proto/check_design.rpt`
- Mapped netlist: `/home/host/codex_runs/fa_optim_proto_20260629_164406/remote_reports/dc_proto/results/FA_OPTIM_SA_PIPELINE_PROTOTYPE.mapped.v`
