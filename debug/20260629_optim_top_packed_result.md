# Optim Packed RTL First Full-Compute And Schedule/Area Result

Date: 2026-06-29

Remote runs:

- VM: `ic-canopsys` / `host@100.108.220.80`
- Full-compute staging path: `/home/host/codex_runs/fa_full_compute_baseline_20260629_173040`
- Packed-wrapper staging path: `/home/host/codex_runs/fa_top_optim_packed_20260629_171208`
- Branch: `optim`

## Scope

This milestone adds a top-level schedule/area wrapper for the packed 4x4-SA SRAM
pipeline direction:

- Top: `FA_TOP_OPTIM_PACKED`
- External interface: port-compatible with `FA_TOP_BASELINE`
- Control plane: existing `FA_CSR`
- Internal core: `FA_OPTIM_SA_PIPELINE_PACKED_PROTOTYPE`
- AXI master: intentionally idle in this wrapper

This is current RTL evidence for a CSR-compatible packed scheduling and local-SRAM area
wrapper. It is not a complete numerical Flash Attention top. It does not yet perform
real Q/K/V DMA, numerical QK/PV/OACC computation, or O writeback.

Important interpretation: the `2242` cycle value below is a prototype schedule counter
for a fixed synthetic tile-task stream (`TILE_COUNT=136`) in the packed scheduler. It is
not the latency of one complete numerical Flash Attention computation and must not be
reported as end-to-end operator performance.

The complete-computation performance anchor for this milestone is therefore measured
on the current numerical `FA_TOP_BASELINE_SIM` path with the fixed baseline shape
from the spec screenshot: `S=256`, `d=64`, `batch=1`, `head=1`, Q/K/V/O in Q8.8.

## Full Numerical Baseline VCS

Command shape:

```sh
vcs -full64 -sverilog -timescale=1ns/1ps +v2k +incdir+rtl \
  sim/rtl_smoke/fa_top_baseline_full_compute_tb.v \
  rtl/*.v \
  -top fa_top_baseline_full_compute_tb \
  -o remote_reports/vcs_full_compute/simv
./remote_reports/vcs_full_compute/simv
```

Workload:

- Top: `FA_TOP_BASELINE_SIM`
- Shape: `S=256`, `d=64`, `batch=1`, `head=1`
- Mode: noncausal
- Format: Q/K/V/O are signed Q8.8 packed two 16-bit values per 32-bit word
- Input pattern: Q all zero, K all zero, V all `1.0` (`0x0100_0100`)
- Output check: all `256 x 64` O elements should be about `1.0`, tolerance `16`
  Q8.8 LSBs

Result:

- PASS marker:
  `PASS: fa_top_baseline_full_compute_tb shape=S256_D64_B1_H1 format=Q8.8 cycles=123203 rd_bytes=1081344 wr_bytes=32768`
- This is one complete numerical Flash Attention computation for the fixed baseline
  shape, not a tile-only or CSR-only smoke.
- At the 5 ns DC target clock, `123203` cycles corresponds to about `0.616 ms`.
  At the plain testbench's 10 ns simulation clock, it corresponds to about `1.232 ms`.
  The cycle count is the primary performance datum.

Derived performance/counter facts:

| Metric | Value |
|---|---:|
| QK MACs | 4,194,304 |
| PV MACs | 4,194,304 |
| Total MACs | 8,388,608 |
| Total ops, 2 ops/MAC | 16,777,216 |
| MAC/cycle | 68.09 |
| Ops/cycle | 136.18 |
| Effective GOPS at 5 ns | 27.24 |
| Read bytes | 1,081,344 |
| Write bytes | 32,768 |
| Total external bytes | 1,114,112 |
| Total bytes/cycle | 9.04 |
| External ops/byte | 15.06 |

The read byte count equals `528` reads of a `16 x 64 x 16b` tile:

- Q tiles: `16`
- K tiles: `16 q_blk x 16 kv_blk = 256`
- V tiles: `16 q_blk x 16 kv_blk = 256`

The write byte count equals `16` O tiles, or the full `256 x 64 x 16b` output.
Compared with the minimum whole-matrix Q/K/V/O traffic of `131,072 B`, the current
baseline moves `8.5x` more external bytes through the simulation DMA shell. This is
the measured full-run evidence for the current storage-reuse bottleneck.

## VCS Top Smoke

Command shape:

```sh
vcs -full64 -sverilog -timescale=1ns/1ps +v2k +incdir+rtl \
  sim/rtl_smoke/fa_top_optim_packed_tb.v \
  rtl/csr_array.v rtl/fa_csr.v rtl/fa_sram_hard.v rtl/fa_sram_tile_buffers.v \
  rtl/fa_optim_sa_pipeline_prototype.v rtl/fa_top_optim_packed.v \
  -top fa_top_optim_packed_tb \
  -o remote_reports/vcs_top/simv
./remote_reports/vcs_top/simv
```

Result:

- PASS marker: `PASS: fa_top_optim_packed_tb cycles=2242`
- Simulation time: `22556000 ps`
- CSR behavior checked:
  - AXI-Lite write `CTRL.START`
  - poll `STATUS.DONE`
  - read `CYCLES`
  - verify AXI master outputs stay idle

Schedule counters inherited from the packed pipeline:

| Metric | Value |
|---|---:|
| Cycles | 2242 |
| SA busy cycles | 8704 |
| Average active clusters | 3.88 |
| 4-cluster utilization | 97.1% |
| Feeder busy cycles | 2176 |
| Row-state busy cycles | 136 |

## VCS Packed Negative-Control Smoke

Command shape:

```sh
vcs -full64 -sverilog -timescale=1ns/1ps +v2k +incdir+rtl \
  sim/rtl_smoke/fa_optim_sa_pipeline_packed_negative_tb.v \
  rtl/tsmc_sram_macros.v rtl/fa_sram_hard.v rtl/fa_sram_tile_buffers.v \
  rtl/fa_optim_sa_pipeline_prototype.v \
  -top fa_optim_sa_pipeline_packed_negative_tb \
  -o remote_reports/vcs_packed_negative/simv
./remote_reports/vcs_packed_negative/simv
```

This test is a negative control for the packed architecture contract. It uses the same
9-bank packed scheduler but overrides `PV_FEED_CYCLES=16`, modeling the bad case where
PV also has to consume the same external SRAM feeder instead of using local buffered
operands.

Result:

- PASS marker:
  `PASS: fa_optim_sa_pipeline_packed_negative_tb cycles=4418 sa_busy=8704 feeder_busy=4352 pv_feeds=136`
- Simulation time: `44216000 ps`

Counter comparison:

| Metric | Buffered PV/OACC target | PV reuses feeder |
|---|---:|---:|
| Cycles | 2242 | 4418 |
| SA busy cycles | 8704 | 8704 |
| 4-cluster utilization | 97.1% | 49.3% |
| Feeder busy cycles | 2176 | 4352 |
| Feeder utilization | 97.1% | 98.5% |
| PV feed count | 0 | 136 |
| 4-active cycles | 2127 | 0 |

Interpretation:

- The negative control validates the earlier model conclusion in RTL: if PV is allowed
  to re-read through the same feeder, the feeder becomes the dominant serialized
  resource and the four 4x4-SA clusters are never all active.
- The packed direction therefore requires local PV/OACC operand buffering and state
  reuse. Otherwise the area-saving 4x4-SA organization keeps the same compute count but
  loses about half of the schedule-level throughput.
- This is still a scheduler/prototype smoke, not a complete numerical FA latency.

## DC Setup

- DC: `/usr/Synopsys/syn/T-2022.03-SP2/bin/dc_shell`
- LC: `/usr/Synopsys/lc/T-2022.03/bin/lc_shell`
- Stdcell DB: TSMC28 7T CCS `ffg0p99v0c`
- SRAM DB: run-local `tem5n28hpcplvta256x64m4swso_110a_ffg0p99v0c.db`
- Clock period requested: `5.0 ns`
- NAND2 reference cell queried in the same DC library:
  - `tcbn28hpcplusbwp7t40p140ffg0p99v0c_ccs/ND2D0BWP7T40P140`
  - area: `0.294000`

## DC Area And NAND2 Equivalent

Top:

- `FA_TOP_OPTIM_PACKED`

Area result:

| Metric | Raw area | NAND2 equivalent |
|---|---:|---:|
| Combinational area | 1706.669999 | 5805 |
| Noncombinational area | 1358.868001 | 4622 |
| Macro/Black Box area | 75592.801758 | 257118 |
| Total cell area | 78658.339757 | 267545 |

Other area facts:

| Metric | Value |
|---|---:|
| Number of cells | 5782 |
| Macro count | 9 |
| Total NAND2 equivalent | 0.268M |
| Macro NAND2 equivalent | 0.257M |
| Macro share of total area | 96.1% |

Comparison points:

| Reference | Raw total area | NAND2 equivalent | Notes |
|---|---:|---:|---|
| Historical `FA_TOP_BASELINE` on 2026-04-27 | 1405399.127886 | 4.780M | Numerical baseline top area archive |
| `FA_OPTIM_SA_PIPELINE_PACKED_PROTOTYPE` | 79864.719790 | 0.272M | Packed prototype without CSR/top wrapper |
| `FA_TOP_OPTIM_PACKED` | 78658.339757 | 0.268M | CSR-compatible packed wrapper |

The wrapper is about `94.4%` smaller than the historical baseline top in raw/NAND2
area, but this is not an apples-to-apples product replacement comparison because the
wrapper does not yet include the full numerical datapath and DMA writeback.

Against the packed prototype, the top wrapper area is slightly lower because many
prototype-only output counters and probe outputs are not externally observable through
the wrapper and are optimized away. The SRAM macro footprint remains the same 9-bank
contract.

## DC Timing And Design Rules

| Metric | Value |
|---|---:|
| Critical path length | 2.42 ns |
| Critical path slack | 2.56 ns |
| Clock period | 5.00 ns |
| Setup WNS/TNS | 0.00 / 0.00 |
| Setup violating paths | 0 |
| Hold worst violation | -0.01 ns |
| Hold TNS | -0.12 ns |
| Hold violating paths | 15 |
| Max transition/cap violations | 0 / 0 |

The hold result is a small module-level ideal-clock min-delay estimate. It should be
tracked when real operand ports, clock constraints, and placement context are added.

## Check-Design Notes

DC `check_design` warning counts:

| Warning bucket | Count |
|---|---:|
| `LINT-28` unconnected ports | 6393 |
| `LINT-31` shorted outputs | 306 |
| `LINT-52` constant outputs | 308 |
| `LINT-1` cells do not drive | 36 |
| `LINT-32` tied pins | 952 |
| `LINT-33` same-net multi-pin | 59 |
| `LINT-60` hier pins without driver/load | 1584 |

Root causes:

- Top-level AXI master inputs are unused because the wrapper intentionally keeps DMA
  idle.
- Packed pipeline counters and SRAM probe outputs are mostly not exposed through the
  CSR-compatible top interface.
- The synthetic SRAM exerciser preserves macro footprint but is not yet a real operand
  read/write datapath.

Disposition:

- Clean enough for a focused top-wrapper schedule/area milestone.
- Not product-top signoff.
- Preferred next RTL step is replacing the synthetic SRAM exerciser with real Q/K/V,
  PV, and OACC operand ports plus lifetime/bank-conflict arbitration.

## Architecture Conclusion

This result gives the first top-boundary schedule/area evidence for the packed direction:

- The packed 9-bank local SRAM contract remains area-dominant but is small enough to
  fit well below a `2M` NAND2 raw area budget in this wrapper form.
- CSR-compatible start/done/schedule-cycle behavior works through VCS.
- The measured schedule still keeps four 4x4-SA clusters nearly full in the target
  model/prototype contract.
- The packed negative-control VCS run proves the main architectural hazard: PV must
  use local buffered operands. Reusing the feeder increases schedule cycles from
  `2242` to `4418` and drops 4-cluster utilization from `97.1%` to `49.3%`.
- The remaining work is not area math; it is functional integration of real operand
  lifetimes, bank arbitration, numerical datapath, and DMA.

The full-compute VCS run also confirms the current baseline bottleneck that motivated
the packed direction:

- Current numerical RTL performs a complete `S=256,d=64` run in `123203` cycles.
- External read traffic is dominated by repeated K/V tile reloads across Q blocks.
- The next optimized product-top claim must reduce this traffic and still pass the
  same full-compute bench, rather than only preserving the `2242` prototype schedule.

## Remaining Gap Before Product-Level Claim

- `FA_TOP_OPTIM_PACKED` does not fetch Q/K/V from AXI.
- It does not compute numerical QK, softmax row state, PV, or OACC.
- It does not write O through AXI.
- `FA_TOP_BASELINE` is not replaced.
- The SRAM banks are still exercised through synthetic probe wiring instead of real
  operand traffic.
- End-to-end latency for one complete numerical Flash Attention computation has been
  measured for the current baseline path (`123203` cycles), but not yet for the packed
  wrapper.

## Artifact Paths

Remote artifacts:

- VCS compile log: `/home/host/codex_runs/fa_top_optim_packed_20260629_171208/remote_reports/vcs_top/compile.log`
- VCS run log: `/home/host/codex_runs/fa_top_optim_packed_20260629_171208/remote_reports/vcs_top/run.log`
- Full-compute VCS compile log: `/home/host/codex_runs/fa_full_compute_baseline_20260629_173040/remote_reports/vcs_full_compute/compile.log`
- Full-compute VCS run log: `/home/host/codex_runs/fa_full_compute_baseline_20260629_173040/remote_reports/vcs_full_compute/run.log`
- Packed negative-control VCS compile log: `/home/host/codex_runs/fa_packed_negative_20260629_174607/remote_reports/vcs_packed_negative/compile.log`
- Packed negative-control VCS run log: `/home/host/codex_runs/fa_packed_negative_20260629_174607/remote_reports/vcs_packed_negative/run.log`
- LC log: `/home/host/codex_runs/fa_top_optim_packed_20260629_171208/remote_reports/libs/lc_compile.log`
- NAND2 query log: `/home/host/codex_runs/fa_top_optim_packed_20260629_171208/remote_reports/dc_top/nand2_area.log`
- DC QoR: `/home/host/codex_runs/fa_top_optim_packed_20260629_171208/remote_reports/dc_top/qor.rpt`
- DC area: `/home/host/codex_runs/fa_top_optim_packed_20260629_171208/remote_reports/dc_top/area.rpt`
- DC references: `/home/host/codex_runs/fa_top_optim_packed_20260629_171208/remote_reports/dc_top/reference.rpt`
- DC check-design: `/home/host/codex_runs/fa_top_optim_packed_20260629_171208/remote_reports/dc_top/check_design.rpt`
- Mapped netlist: `/home/host/codex_runs/fa_top_optim_packed_20260629_171208/remote_reports/dc_top/results/FA_TOP_OPTIM_PACKED.mapped.v`
