# SpyGlass Remote Lint - PT_DMA_TOP - 2026-04-19

## Environment

- Remote host: `ic-canopsys` (`host@100.108.220.80`)
- Workspace: `~/Desktop/flash_atten`
- Tool: `/usr/Synopsys/spyglass/T-2022.06-1/SPYGLASS_HOME/bin/spyglass`
- Top: `PT_DMA_TOP`

## What Was Run

### First pass: full staged source list

Initial lint was attempted using the staged SpyGlass file list under `flow/spyglass/lint.f`.

Observed result:

- batch run aborted with `200` fatals
- main causes:
  - Verilog-2005 constructs not enabled
  - `NoD` sources pulled in for a `PT_DMA_TOP` lint run
  - `rtl/nod/param.vh` collided with the root `rtl/param.vh` include name under the SpyGlass include search order

Representative messages:

- `Syntax error near ( localparam ). Please use 'set_option enableV05 yes'`
- `Used macro ( DATA_WIDTH ) has not been defined` in `src/rtl/nod/NoD.v`

### Second pass: PT_DMA_TOP-only lint

To isolate the active wrapper/datapath and remove unrelated NoD noise, a dedicated top-only source list was used and Verilog-2005 support was enabled:

- source list: `flow/spyglass/pt_dma_top_only.f`
- project file: `flow/spyglass/pt_dma_top_lint.prj`
- goal: `lint/lint_rtl`

Observed result:

- `0` fatals
- `0` errors
- `197` warnings

SpyGlass output locations:

- consolidated reports:
  - `~/Desktop/flash_atten/flow/spyglass/pt_dma_top_lint/consolidated_reports/PT_DMA_TOP_lint_lint_rtl/`
- batch log:
  - `~/Desktop/flash_atten/logs/spyglass/spyglass_lint_pt_only_20260419_133442.log`

## Main Warning Families

The meaningful warning groups from the successful `PT_DMA_TOP` lint run were:

1. `W240` / intentionally unused compatibility interface signals
   - `s_axis_tstrb`
   - `s_axis_tkeep`
   - `s_axis_tlast`
   - `s_axis_tid`
   - `s_axis_tdest`
   - `dma_done`
   - `PT_MEM_BANK.rstn`
   - `PT_MEM_BANK.clear`
   - blackbox-stub ports in `tsmc_sram_macros.v`

2. `W415a` / repeated assignments in the same always block
   - concentrated in `pt_ce_v2.v`
   - also present in `pt_dma_top.v`, `pt_md_v2.v`, `pt_malloc.v`

3. `STARC05-2.2.3.3` / sequential self-assignment style warnings
   - same underlying coding style as the `W415a` family

4. `STARC05-2.11.3.1`
   - FSM combinational/sequential logic mixed in one always block in `pt_ce_v2.v`

5. `WarnAnalyzeBBox`
   - `TEM5N28HPCPLVTA64X32M4SWSO` is an empty stub by design for lint/synthesis integration

## First Action

The PT architecture documentation was updated first to explicitly describe the current intentional interface behavior:

- `doc/Processing Tile/README.md`

Added clarifications:

- only `s_axis_tdata`, `s_axis_tuser`, `s_axis_tvalid`, and `s_axis_tready` are functionally consumed in the active PT/PT_DMA_TOP A/B return path
- `s_axis_tstrb`, `s_axis_tkeep`, `s_axis_tlast`, `s_axis_tid`, and `s_axis_tdest` are compatibility sidebands and currently ignored by the datapath
- `dma_done` remains on the interface for compatibility, but fill completion is beat-count driven
- `PT_MEM_BANK` keeps `rstn` and `clear` for interface uniformity and does not scrub SRAM contents on those signals

## Second Action

A focused RTL cleanup was then applied in:

- `rtl/pt_ce_v2.v`

Scope of the RTL change:

- introduced shared launch payload helper wires for the exec/drain handoff path
- collapsed part of the repeated `drain_*` and `macro_next_*` assignments so they no longer get written from as many disjoint branches in the same sequential block
- intentionally kept the state machine semantics unchanged

This was a targeted warning-reduction pass, not a full `pt_ce_v2.v` state-machine rewrite.

## SpyGlass Delta After RTL Cleanup

The same remote `PT_DMA_TOP` SpyGlass lint run was repeated after copying the updated `pt_ce_v2.v` into the remote staged source tree.

Observed delta:

- before cleanup:
  - `197` warnings
- after cleanup:
  - `157` warnings

Net improvement:

- `40` warnings removed

Remaining notable warning buckets after the rerun:

- `W415a`: `45`
- `STARC05-2.2.3.3`: `54`
- `STARC05-2.11.3.1`: `1`
- `W240`: `30`
- `WarnAnalyzeBBox`: `1`

This confirms the targeted `pt_ce_v2.v` cleanup reduced the warning load, but a larger next-state / output-separation refactor would still be needed to remove most of the residual `W415a` and `STARC05-2.2.3.3` findings.

## Third Action

A second low-risk cleanup pass was applied to compatibility-facing wrapper ports:

- `rtl/pt.v`
- `rtl/pt_top_v2.v`
- `rtl/pt_dma_top.v`
- `rtl/pt_dispatch_v2.v`
- `rtl/pt_mem.v`

Scope of this pass:

- forwarded compatibility `s_axis_*` sidebands and `dma_done` through wrapper layers where that did not change functional behavior
- explicitly consumed intentionally retained compatibility inputs in the modules that still keep them on their public interfaces
- kept protocol behavior unchanged

## SpyGlass Delta After Compatibility Cleanup

The remote `PT_DMA_TOP` lint run was repeated again after staging the updated wrapper/datapath RTL.

Observed delta:

- after `pt_ce_v2.v` cleanup:
  - `157` warnings
- after compatibility-input cleanup:
  - `142` warnings

Net improvement from this pass:

- `15` warnings removed

Total improvement from the original successful `PT_DMA_TOP` lint run:

- `197 -> 142`
- net reduction: `55` warnings

Remaining notable warning buckets after the latest rerun:

- `W415a`: `45`
- `STARC05-2.2.3.3`: `54`
- `STARC05-2.11.3.1`: `1`
- `W240`: `10`
- `WarnAnalyzeBBox`: `1`

The latest rerun therefore confirmed that the compatibility-sideband cleanup primarily reduced the `W240` family without introducing new lint errors.

## Cocotb Check

To make sure the repository stayed healthy after the documentation update and RTL cleanup, the local cocotb suites were rerun.

Suites run with `PT_DMA_TOP` target:

- `smoke` with `icarus`: passed
- `full` with `icarus`: passed
- `randomized` with `icarus`: passed
- `extended` with `icarus`: passed
- `ci` with `icarus`: passed
- `stress` with `icarus`: passed
- `soak` with `icarus`: passed
- `coverage` with `verilator`: passed
- `perf` with `icarus`: passed
- `axil` with `icarus`: passed
- `axil_perf` with `icarus`: passed

Coverage note:

- `coverage` must be run with `verilator`; an earlier attempt with `icarus` was an invocation mistake rather than an RTL failure
- resulting coverage summary:
  - `line(adjusted) = 2443 / 2541 = 96.14%`
  - `branch(adjusted) = 97979 / 165993 = 59.03%`
  - `expr(adjusted) = 590 / 599 = 98.50%`
  - `toggle = 92407 / 159408 = 57.97%`
- generated report:
  - `debug/cocotb/PT/coverage_PASS_20260419.md`

Final verification status on the latest RTL state:

- the non-coverage suite matrix was rerun again after the last compatibility-sideband updates
- passing suites on the final RTL snapshot:
  - `smoke`
  - `full`
  - `randomized`
  - `extended`
  - `ci`
  - `stress`
  - `soak`
  - `perf`
  - `axil`
  - `axil_perf`
- `coverage` was separately rerun on the same RTL snapshot with `verilator` and remained passing

## Recommended Next Cleanup Order

If we want to reduce SpyGlass noise further without changing public behavior, the lowest-risk order is:

1. add targeted waivers or lint-only handling for the SRAM macro stub
2. split out intentional compatibility sideband warnings from real functional issues
3. continue refactoring `pt_ce_v2.v` toward explicit next-state / output staging to remove the remaining repeated-assignment warnings
4. revisit full-file lint of `NoD` separately with an include strategy that disambiguates `rtl/param.vh` vs `rtl/nod/param.vh`
