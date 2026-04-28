# FA Area Step 3: Share QK/PV GEMM

- Date: `2026-04-27`
- Base commit: `beca43e fa: bypass p buffer for pv input`
- Scope: replace independent top-level QK and PV GEMM instances with one shared `FA_QK_PV_SHARED_CORE_REAL`
- DC: skipped per latest instruction; only local regressions and remote SpyGlass were run

## RTL Change

- Added `FA_QK_PV_SHARED_CORE_REAL`, which contains one 16x16 `GEMM_V3`.
- QK mode drives Q/K read ports, uses `num_acc=32`, and writes `qk_result_tile_flat`.
- PV mode drives P/V read ports, uses `num_acc=8`, iterates the four V column blocks, and writes `pv_result_tile_flat`.
- `FA_CORE_BASELINE` now instantiates the shared core as `u_qk_pv_core`; external scheduler handshakes remain `qk_req_ready/qk_done_pulse` and `pv_req_ready/pv_done_pulse`.
- Existing full-tile result interfaces remain unchanged for score post and OACC update.

## Local Checks

```text
python3 -m py_compile \
  sim/cocotb/tests/test_fa_baseline.py \
  sim/cocotb/tests/test_fa_baseline_perf_profile.py \
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

- Step 2 estimated cycles: `160240`
- Step 3 estimated cycles: `160240`
- Cycle delta: `0`
- Timing requirement: `160240 <= 300000`

## Remote SpyGlass

- Remote workspace: `/home/host/Desktop/flash_atten_fa_area_20260427_step3_after`
- Flow: `synopsys/spyglass/run.sh fa_top_baseline_lint`
- Consolidated reports: `/home/host/Desktop/flash_atten_fa_area_20260427_step3_after/synopsys/spyglass/flow/fa_top_baseline_lint/consolidated_reports/FA_TOP_BASELINE_lint_lint_rtl/`
- Run log: `/home/host/Desktop/flash_atten_fa_area_20260427_step3_after/synopsys/spyglass/logs/fa_top_baseline_lint_20260427_132529.log`

```text
Total: 0 error, 91 warnings, 3 information messages
SpyGlass Exit Code 0
```

## Area Expectation

- Removes one top-hierarchy `GEMM_V3` array by serializing QK and PV through the shared core.
- Top reachable synthesis module count dropped from Step 2 `33` to Step 3 `32`.
- SpyGlass flattening progress dropped from about `2.65M` instances in Step 2 to about `1.95M` instances in Step 3.
- SpyGlass reported warnings dropped from `99` to `91`; no new errors were introduced.
- The last full top DC area reference remains the pre-optimization value around `3,065,011` standard-cell area units; no new DC data was collected after the instruction to skip DC.

## Notes

- Older SpyGlass work databases were removed on the remote host to recover disk space; consolidated reports and `synopsys/spyglass/logs` were retained.
- One initial step3 rerun failed because the RTL package omitted `.vh` files, and one later rerun hit remote disk exhaustion after synthesis. Both were infrastructure issues; the final run above is the accepted result.
