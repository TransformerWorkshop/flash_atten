# FA Area Step 2: Bypass P Buffer

- Date: `2026-04-27`
- Base commit: `37f684f fa: shrink oacc storage to q4.12`
- Scope: remove `FA_P_BUF_REAL` from the main FA path and feed PV directly from `row_p_tile_flat`
- DC: skipped per latest instruction; only local regressions and remote SpyGlass were run

## RTL Change

- Removed the main-path `FA_P_BUF_REAL` instance from `FA_CORE_BASELINE`.
- `row_update_done_pulse` now follows `FA_ROW_STATE_REAL.done_pulse`; the scheduler no longer waits for the old 9-cycle P-load stage.
- PV reads are served by a registered bypass gather from `row_p_tile_flat`, preserving the old P buffer read layout: one 32-bit P value per row for the selected `pv_rd_addr`.
- `p_tile_flat` remains visible for tests/debug and aliases the row-state P tile.

## Local Checks

```text
python3 -m py_compile \
  sim/cocotb/tests/test_fa_baseline.py \
  sim/cocotb/tests/test_fa_baseline_perf_profile.py \
  sim/cocotb/tests/test_fa_baseline_perf_rowstate.py \
  scripts/fa_precision_analysis.py \
  scripts/fa_baseline_profile.py
PASS

iverilog -g2012 -I rtl -s FA_TOP_BASELINE_SIM -o /tmp/fa_top_baseline_sim_check.out rtl/*.v
PASS
```

```text
python3 scripts/fa_precision_analysis.py --case single_q_full_kv_causal --q-row-start 0 --q-row-start 112 --q-row-start 240
q_row_start=0   mean_err=0.006241 max_err=0.014877
q_row_start=112 mean_err=0.013960 max_err=0.025750
q_row_start=240 mean_err=0.022474 max_err=0.042657
PASS: mean_err <= 0.03, max_err <= 0.10
```

```text
python3 sim/cocotb/run.py fa_full --testcase test_fa_baseline_full_causal_end_to_end,test_fa_baseline_full_noncausal_and_soft_reset --rebuild
TESTS=2 PASS=2 FAIL=0

python3 sim/cocotb/run.py fa_baseline --testcase test_fa_numeric_single_q_single_kv_noncausal,test_fa_numeric_single_q_full_kv_causal,test_fa_baseline_single_q_full_kv_causal_with_backpressure --rebuild
TESTS=3 PASS=3 FAIL=0

python3 sim/cocotb/run.py fa_full_axi --testcase test_fa_baseline_axi_full_causal_end_to_end --rebuild
TESTS=1 PASS=1 FAIL=0
```

## Performance

```text
python3 scripts/fa_baseline_profile.py --sim verilator
estimated_cycles=160240
```

- Previous Step 1 estimated cycles: `162544`
- Step 2 estimated cycles: `160240`
- Cycle delta: `-2304`
- P-load modeled cycles: `0`
- Timing requirement: `160240 <= 300000`

## Remote SpyGlass

- Remote workspace: `/home/host/Desktop/flash_atten_fa_area_20260427_step2_after`
- Flow: `synopsys/spyglass/run.sh fa_top_baseline_lint`
- Consolidated reports: `/home/host/Desktop/flash_atten_fa_area_20260427_step2_after/synopsys/spyglass/flow/fa_top_baseline_lint/consolidated_reports/FA_TOP_BASELINE_lint_lint_rtl/`
- Run log: `/home/host/Desktop/flash_atten_fa_area_20260427_step2_after/synopsys/spyglass/logs/fa_top_baseline_lint_20260427_130726.log`

```text
Total: 0 error, 99 warnings, 3 information messages
SpyGlass Exit Code 0
```

## Area Expectation

- Removes one `FA_P_BUF_REAL` instance from the top hierarchy.
- Removes the P buffer SRAM path: `FA_MASKED_ROWBUF_REAL` configured as `ROW_WIDTH=512`, `DEPTH=8`, plus the P shadow/load staging and associated control.
- SpyGlass elaboration module count dropped from the Step 1 top hierarchy count of 34 modules to 33 modules.
