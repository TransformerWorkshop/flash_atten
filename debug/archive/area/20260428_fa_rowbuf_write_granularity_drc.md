# FA Row Buffer Write Granularity DRC Cleanup

- Date: `2026-04-28`
- Base commit before change: `28e015a fa: reduce shared gemm to four rows`
- Scope: small RTL cleanup around `FA_MASKED_ROWBUF_REG_REAL` and FA result/OACC/V row-buffer users.

## Change

- Added `WRITE_GRANULARITY` to `FA_MASKED_ROWBUF_REG_REAL`.
- Default remains `1` bit, preserving generic behavior.
- FA row-buffer instances now use chunk-level writes where the mask is naturally lane-aligned:
  - `FA_V_BUF_PV_REAL.u_bank`: `16b`
  - `FA_OACC_BUF_REAL.u_mem`: `16b`
  - `FA_QK_PV_SHARED_CORE_REAL.u_qk_result_rows`: `32b`
  - `FA_QK_PV_SHARED_CORE_REAL.u_pv_result_rows`: `16b`
- Simulation keeps assertions that chunked masks are all-zero or all-one inside each chunk.

## Local Regression

| Check | Result |
| --- | --- |
| `python3 -m py_compile sim/cocotb/tests/test_fa_baseline.py scripts/fa_precision_analysis.py scripts/fa_baseline_profile.py` | PASS |
| `iverilog -g2012 -I rtl -s FA_TOP_BASELINE_SIM -o /tmp/fa_top_baseline_sim_check.out rtl/*.v` | PASS |
| `iverilog -g2012 -DSYNTHESIS -I rtl -s FA_TOP_BASELINE -o /tmp/fa_top_baseline_synth_check.out rtl/*.v` | PASS |
| `python3 sim/cocotb/run.py fa_baseline --testcase test_fa_baseline_vbuf_pv_layout,test_fa_baseline_qk_core_real_tile,test_fa_baseline_pv_core_real_tile,test_fa_baseline_oacc_update_rescale_and_add,test_fa_baseline_oacc_update_overwrite_full_tile,test_fa_baseline_oacc_update_no_stale_tail --rebuild` | PASS |
| `python3 scripts/fa_precision_analysis.py --case single_q_full_kv_causal --q-row-start 0 --q-row-start 112 --q-row-start 240` | PASS; worst sampled mean/max `0.022474 / 0.042657` |
| `python3 sim/cocotb/run.py fa_full --testcase test_fa_baseline_full_causal_end_to_end,test_fa_baseline_full_noncausal_and_soft_reset --rebuild` | PASS |
| `python3 sim/cocotb/run.py fa_baseline --testcase test_fa_numeric_single_q_single_kv_noncausal,test_fa_numeric_single_q_full_kv_causal,test_fa_baseline_single_q_full_kv_causal_with_backpressure --rebuild` | PASS |
| `python3 scripts/fa_baseline_profile.py --sim verilator` | PASS; `estimated_cycles=223984` |

## Remote SpyGlass

- Host/workspace: `ic-canopsys:~/Desktop/flash_atten`
- Synced files:
  - `rtl/fa_sram_hard.v`
  - `rtl/fa_buffers_real.v`
  - `rtl/fa_cores_real.v`
- Top: `FA_TOP_BASELINE`
- Project: `synopsys/spyglass/flow/fa_top_baseline_lint.prj`
- Goal: `lint/lint_rtl`
- Run log: `synopsys/spyglass/logs/fa_top_baseline_lint_20260428_141042_rowbuf_gran.log`
- Consolidated report dir: `synopsys/spyglass/flow/fa_top_baseline_lint/consolidated_reports/FA_TOP_BASELINE_lint_lint_rtl/`

| SpyGlass Item | Result |
| --- | ---: |
| Command-line read | `0 error / 0 warning / 0 info` |
| Design read | `0 error / 1 warning / 2 info` |
| Blackbox resolution | `0 error / 0 warning / 0 info` |
| SGDC checks | `0 error / 0 warning / 0 info` |
| Policy lint | `0 error / 74 warnings / 1 info` |
| Policy starc2005 | `0 error / 18 warnings / 0 info` |
| Total | `0 error / 93 warnings / 3 info` |

Notes:

- No new blocking lint/error was introduced by the parameterized row buffer.
- The remaining warnings are the existing style/reset-use mix, plus a `FLAT_504` design-read warning on the wide OACC load mux (`fa_buffers_real.v:844`).

## Estimated Area / DRC Impact

Last valid top DC reference after 4x16 GEMM:

| Metric | Value |
| --- | ---: |
| Cell area | `545,044.935124` |
| NAND2 equivalent | `1,853,894` |
| Nets with max-transition violations | `60` |

Expected incremental impact without rerunning DC:

| Item | Estimate |
| --- | ---: |
| Affected reg row-buffer hierarchy area | about `156k` cell area |
| Direct area saving | `2k-8k` cell area |
| NAND2-equivalent saving at `0.294` area/NAND2 | `7k-27k` NAND2 |
| Estimated new top area | `537k-543k` cell area |
| Estimated new NAND2 equivalent | `1.83M-1.85M` NAND2 |

The main benefit is local DRC/timing hygiene around row-buffer write mask and enable logic. The change should reduce per-bit mask fanout in `u_pv_result_rows`, `u_v_buf_pv`, and similar 16-bit-lane row buffers. It does not directly fix the high-fanout GEMM clock net; that remains a CTS/constraint or physical synthesis item unless we make a larger RTL clock-partitioning change.
