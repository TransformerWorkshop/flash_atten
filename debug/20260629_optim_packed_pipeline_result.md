# Optim Packed SA Pipeline Prototype Result

Date: 2026-06-29

Remote run:

- VM: `ic-canopsys` / `host@100.108.220.80`
- Staging path: `/home/host/codex_runs/fa_optim_packed_20260629_165643`
- Branch: `optim`

## Scope

This milestone keeps the same target scheduler/resource contract as
`FA_OPTIM_SA_PIPELINE_PROTOTYPE`, but changes the local-buffer footprint from the
conservative `21` SRAM-bank contract to a packed `9` SRAM-bank contract. It is still a
target RTL prototype, not a complete `FA_TOP_BASELINE` replacement.

The packed variant is `FA_OPTIM_SA_PIPELINE_PACKED_PROTOTYPE`. It reuses the same
synthesizable scheduler/counter logic and instantiates the same `256x64` SRAM tile
primitive through `FA_LOCAL_TILE_SRAM_16X64X16`; only `SRAM_BANK_COUNT` changes from
`21` to `9`.

## Packed Buffer Contract

The packed contract is intended to test whether the local-buffer area can be reduced
without changing the useful compute schedule:

| Buffer group | Conservative 21-bank contract | Packed 9-bank contract |
|---|---:|---:|
| Shared Q operand | 1 bank | 1 bank |
| Per-cluster K/V operand storage | 8 banks | 4 packed banks |
| Per-cluster PV/OACC large state | 12 banks | 4 packed banks |
| Small P tile + row-scale state | registers | registers |
| Total large SRAM banks | 21 | 9 |

This is an area/provisioning experiment. A product RTL integration must still prove the
packed lifetime schedule, bank arbitration, and no read/write conflict between paired
logical buffers.

## VCS Packed Smoke

Command shape:

```sh
vcs -full64 -sverilog -timescale=1ns/1ps +v2k +incdir+rtl \
  sim/rtl_smoke/fa_optim_sa_pipeline_packed_tb.v \
  rtl/fa_sram_hard.v rtl/fa_sram_tile_buffers.v \
  rtl/fa_optim_sa_pipeline_prototype.v \
  -top fa_optim_sa_pipeline_packed_tb \
  -o remote_reports/vcs_packed/simv
./remote_reports/vcs_packed/simv
```

Result:

| Counter | Packed RTL value | 21-bank RTL value |
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

Interpretation:

- The scheduler/utilization result is unchanged from the 21-bank prototype.
- Average active clusters remain `8704 / 2242 = 3.88`.
- SA utilization remains `8704 / (2242 x 4) = 0.971`.

## TSMC28 Library Setup

Same as the previous prototype run:

- Stdcell: TSMC28 7T CCS `ffg0p99v0c`
- SRAM: run-local `tem5n28hpcplvta256x64m4swso_110a_ffg0p99v0c.db`
- SRAM macro: `TEM5N28HPCPLVTA256X64M4SWSO`
- Clock period requested: `5.0 ns`

## DC Area And Timing

Top:

- `FA_OPTIM_SA_PIPELINE_PACKED_PROTOTYPE`

Area result:

| Metric | Packed 9-bank | Conservative 21-bank |
|---|---:|---:|
| Number of cells | 7530 | 10187 |
| Sequential cells | 799 area report / 808 QoR leaf count | 794 area report / 815 QoR leaf count |
| Macro count | 9 | 21 |
| Combinational area | 2705.486002 | 3618.846016 |
| Noncombinational area | 1566.432030 | 1516.060010 |
| Macro/Black Box area | 75592.801758 | 176383.204102 |
| Total cell area | 79864.719790 | 181518.110127 |

Area delta:

| Metric | Delta | Reduction |
|---|---:|---:|
| Total cell area | -101653.390337 | 56.00% |
| Macro/Black Box area | -100790.402344 | 57.14% |
| Packed total / 21-bank total | 0.440 | - |
| Packed macro share of packed area | 94.65% | - |

Timing/QoR:

| Metric | Packed value |
|---|---:|
| Critical path length | 2.66 ns |
| Critical path slack | 2.32 ns |
| Clock period | 5.00 ns |
| Setup WNS/TNS | 0.00 / 0.00 |
| Setup violating paths | 0 |
| Hold worst violation | -0.02 ns |
| Hold TNS | -0.14 ns |
| Hold violating paths | 20 |
| Max transition/cap violations | 0 / 0 |

The small hold estimate appears in this packed wrapper compile under ideal-clock
module-level constraints. Treat it as a closure risk to check once real operand ports,
clock constraints, and placement context exist, not as evidence that the packed banking
contract is physically infeasible.

## Check-Design Notes

DC `check_design` warning counts decreased with bank count:

| Warning bucket | Packed 9-bank count | 21-bank count |
|---|---:|---:|
| `LINT-28` unconnected ports | 2539 | 5775 |
| `LINT-31` shorted outputs | 63 | 63 |
| `LINT-52` constant outputs | 64 | 64 |
| `LINT-32` tied pins | 882 | 2058 |
| `LINT-33` same-net multi-pin | 43 | 140 |
| `LINT-60` hier pins without driver/load | 1584 | 3696 |

Root cause remains the prototype wiring style: synthetic bank probe/output visibility and
constant unused counters such as `pv_feed_count` when `PV_FEED_CYCLES=0`. Product RTL
should replace this with real operand ports and bank arbitration rather than waive it as
final behavior.

## Architecture Conclusion

This packed prototype strengthens the area conclusion:

- The earlier 21-bank full-local prototype proves the local-buffered schedule can keep
  four 4x4 SA clusters busy with one feeder.
- The 9-bank packed prototype keeps the same measured schedule counters but cuts total
  cell area by about `56%` in DC.
- SRAM macro area remains dominant, so bank-count reduction is the main first-order
  area knob.
- The packed contract is the better next RTL landing target, but it must add real
  lifetime/bank-conflict checks before product-top integration.

## Remaining Gap Before Product-Level Claim

- Packed logical lifetimes are not yet enforced by real operand read/write ports.
- `FA_OPTIM_SA_PIPELINE_PACKED_PROTOTYPE` still does not compute numerical QK/PV/OACC
  data.
- `FA_TOP_BASELINE` is not yet wired to the packed local-buffer architecture.
- Product-top performance and area still require a top-level VCS/DC run after real
  storage/datapath integration.

## Artifact Paths

Remote artifacts:

- VCS compile log: `/home/host/codex_runs/fa_optim_packed_20260629_165643/remote_reports/vcs_packed/compile.log`
- VCS run log: `/home/host/codex_runs/fa_optim_packed_20260629_165643/remote_reports/vcs_packed/run.log`
- LC log: `/home/host/codex_runs/fa_optim_packed_20260629_165643/remote_reports/libs/lc_compile.log`
- DC QoR: `/home/host/codex_runs/fa_optim_packed_20260629_165643/remote_reports/dc_packed/qor.rpt`
- DC area: `/home/host/codex_runs/fa_optim_packed_20260629_165643/remote_reports/dc_packed/area.rpt`
- DC references: `/home/host/codex_runs/fa_optim_packed_20260629_165643/remote_reports/dc_packed/reference.rpt`
- DC check-design: `/home/host/codex_runs/fa_optim_packed_20260629_165643/remote_reports/dc_packed/check_design.rpt`
- Mapped netlist: `/home/host/codex_runs/fa_optim_packed_20260629_165643/remote_reports/dc_packed/results/FA_OPTIM_SA_PIPELINE_PACKED_PROTOTYPE.mapped.v`
