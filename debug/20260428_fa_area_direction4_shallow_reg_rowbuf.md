# FA Area Direction 4 - Shallow Wide SRAMs to Register Row Buffers

- Date: `2026-04-28`
- Baseline top DC area: `1,405,399.127886` standard-cell area, about `4.78M` NAND2 equivalent
- Change: add `FA_MASKED_ROWBUF_REG_REAL` and use it for shallow/wide buffers where 64-deep SRAM macros waste depth:
  - `FA_V_BUF_PV_REAL.u_bank` (`32 x 512`)
  - `FA_OACC_BUF_REAL.u_mem` (`16 x 1024`)
  - `FA_QK_PV_SHARED_CORE_REAL.u_qk_result_rows` (`16 x 512`)
  - `FA_QK_PV_SHARED_CORE_REAL.u_pv_result_rows` (`16 x 1024`)

## Local Regression

| Check | Result |
| --- | --- |
| `python3 sim/cocotb/run.py fa_baseline --testcase test_fa_baseline_vbuf_pv_layout,test_fa_baseline_qk_core_real_tile,test_fa_baseline_pv_core_real_tile,test_fa_baseline_oacc_update_rescale_and_add,test_fa_baseline_oacc_update_overwrite_full_tile,test_fa_baseline_oacc_update_no_stale_tail --rebuild` | PASS |
| `python3 -m py_compile sim/cocotb/tests/test_fa_baseline.py scripts/fa_precision_analysis.py scripts/fa_baseline_profile.py` | PASS |
| `python3 scripts/fa_precision_analysis.py --case single_q_full_kv_causal --q-row-start 0 --q-row-start 112 --q-row-start 240` | PASS; worst sampled mean/max `0.022474 / 0.042657` |
| `python3 sim/cocotb/run.py fa_baseline --testcase test_fa_baseline_vbuf_pv_layout,test_fa_baseline_qk_core_real_tile,test_fa_baseline_pv_core_real_tile,test_fa_baseline_oacc_update_rescale_and_add,test_fa_baseline_oacc_update_overwrite_full_tile,test_fa_baseline_oacc_update_no_stale_tail,test_fa_numeric_single_q_single_kv_noncausal,test_fa_numeric_single_q_full_kv_causal,test_fa_baseline_single_q_full_kv_causal_with_backpressure --rebuild` | PASS |
| `python3 sim/cocotb/run.py fa_full --testcase test_fa_baseline_full_causal_end_to_end,test_fa_baseline_full_noncausal_and_soft_reset --rebuild` | PASS |
| `python3 scripts/fa_baseline_profile.py --sim verilator` | PASS; `estimated_cycles=186096` |

## Estimated Area / Timing Impact

| Item | Estimate |
| --- | ---: |
| `u_oacc_buf` shallow SRAM saving | `44k-64k` |
| `u_v_buf_pv` shallow SRAM saving | `6k-16k` |
| QK/PV result row buffer saving inside `u_qk_pv_core` | `30k-50k` |
| Incremental standard-cell area saving | `80k-130k` |
| Incremental NAND2 equivalent saving, using `ND2D0BWP7T40P140=0.294` | `0.27M-0.44M` |
| Cumulative standard-cell area after directions 1+2+3+4 | `0.60M-0.77M` |
| Cumulative NAND2 equivalent after directions 1+2+3+4 | `2.04M-2.62M` |

Timing risk is medium-to-high until DC confirms it: replacing macros with register arrays introduces wide read muxes, especially on `1024`-bit OACC/PV result rows. The benefit is fewer SRAM macro instances and no cycle penalty; the cost is potentially higher local mux/fanout on row reads.

## Benefit Evaluation

This is a medium-benefit, medium-risk step. It is attractive because the local profile stays unchanged, but it needs top-level DC timing to decide whether the mux cost is acceptable versus the macro-area reduction.
