# FA Area Baseline Remote Checkpoint

- Date: `2026-04-27`
- Host: `ic-canopsys` (`host@100.108.220.80`)
- Local tree: current FA worktree before area schemes 1/2/3
- Remote stage: `/home/host/Desktop/flash_atten_fa_area_20260427_baseline`

## Local Gates

- `python3 -m py_compile sim/cocotb/tests/test_fa_baseline.py sim/cocotb/tests/test_fa_baseline_perf_rowstate.py scripts/fa_precision_analysis.py scripts/fa_baseline_profile.py`: pass
- `python3 scripts/fa_precision_analysis.py --case single_q_full_kv_causal --q-row-start 0 --q-row-start 112 --q-row-start 240`: pass
  - q0 mean/max: `0.004322 / 0.010971`
  - q112 mean/max: `0.012236 / 0.022636`
  - q240 mean/max: `0.020829 / 0.039985`
- `python3 sim/cocotb/run.py fa_full --testcase test_fa_baseline_full_causal_end_to_end,test_fa_baseline_full_noncausal_and_soft_reset --rebuild`: `2/2 pass`
- `python3 sim/cocotb/run.py fa_baseline --testcase test_fa_numeric_single_q_single_kv_noncausal,test_fa_numeric_single_q_full_kv_causal,test_fa_baseline_single_q_full_kv_causal_with_backpressure --rebuild`: `3/3 pass`
- `python3 sim/cocotb/run.py fa_full_axi --testcase test_fa_baseline_axi_full_causal_end_to_end --rebuild`: `1/1 pass`
- `python3 scripts/fa_baseline_profile.py --sim verilator`: pass
  - profile: `debug/20260427_fa_baseline_profile_summary.md`
  - estimated cycles: `162544`
  - row-state cycles: `15232`
  - P-load cycles: `2304`

## Remote SpyGlass

- Top: `FA_TOP_BASELINE`
- Flow: `synopsys/spyglass/flow/fa_top_baseline_lint.prj`
- Final result: `0 error / 99 warnings / 3 infos`
- Log: `/home/host/Desktop/flash_atten_fa_area_20260427_baseline/synopsys/spyglass/logs/fa_top_baseline_lint_64x32pair_20260427_110247.log`
- Report dir: `/home/host/Desktop/flash_atten_fa_area_20260427_baseline/synopsys/spyglass/flow/fa_top_baseline_lint/consolidated_reports/FA_TOP_BASELINE_lint_lint_rtl/`
- Main report: `moresimple.rpt`

Flow notes:

- `fa_top_baseline_only.f` was used for FA-only RTL dependencies.
- `fa_sram_hard.v` was added to the remote FA filelist.
- SpyGlass `mthresh` was raised to `40000` for the current wide OACC shadow state; the default threshold flagged `FA_OACC_BUF_REAL.shadow_q16_words_r` as too large.

## Remote DC

The full top compile was intentionally stopped after the user changed the strategy to module-level before/after synthesis because full `FA_TOP_BASELINE` DC was taking too long.

Observed top compile progress before stopping:

- Active log: `/home/host/Desktop/flash_atten_fa_area_20260427_baseline/synopsys/dc/logs/compile_20260427_110956.log`
- Progress table area: `3065011.3`
- Elapsed at progress table: `0:21:49`
- Design rule/setup costs were still nonzero at that point, so this is a baseline size reference, not signoff timing closure.

Remote flow fixes used for the successful elaboration path:

- `DESIGN_TOP` set to `FA_TOP_BASELINE`.
- `read_design.tcl` used the FA-only filelist instead of globbing all `synopsys/rtl/*.v`; this avoids non-synth FA proxy models.
- `FA_SRAM64X64` synthesis wrapper maps to two available `TEM5N28HPCPLVTA64X32M4SWSO` 64x32 macros.

## Next Synthesis Policy

Per the updated implementation direction, area optimization will use:

- current top area reference: about `3,065,011` standard-cell area units;
- module-level DC before/after for the affected optimization blocks only;
- SpyGlass on the affected FA RTL/filelist after each scheme.

Target modules by scheme:

- Scheme 1: `FA_OACC_BUF_REAL`, `FA_OACC_UPDATE_REAL`, and their row-width integration at `FA_CORE_BASELINE`.
- Scheme 2: `FA_P_BUF_REAL` removal/bypass path and `FA_CORE_BASELINE` row-state-to-PV connection.
- Scheme 3: `FA_QK_CORE_REAL`, `FA_PV_CORE_REAL`, `GEMM_V3`, and the shared GEMM wrapper.
