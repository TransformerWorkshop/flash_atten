# FA Area Direction 5 - Trim Wide Reset/Clear Fanout

- Date: `2026-04-28`
- Baseline top DC area: `1,405,399.127886` standard-cell area, about `4.78M` NAND2 equivalent
- Change: remove synthesis-path reset/clear/pre-zero assignments from wide outputs that are fully overwritten before their valid handshake:
  - `FA_SCORE_POST_REAL.masked_score_tile_flat` (`8192` bits)
  - `FA_ROW_STATE_REAL.p_tile_flat` (`4096` bits)
  - `FA_ROW_STATE_REAL.rescale_vec_flat` (`512` bits)
  - `FA_OACC_UPDATE_REAL.oacc_row_wr_data` (`1024` bits)
- Simulation still clears these values under `ifndef SYNTHESIS` so directed debug visibility remains deterministic.

## Local Regression

| Check | Result |
| --- | --- |
| `python3 sim/cocotb/run.py fa_baseline --testcase test_fa_baseline_score_post_real_scale_mask,test_fa_baseline_row_state_real_update,test_fa_baseline_row_state_all_masked_tile,test_fa_baseline_row_state_masked_tile_after_history,test_fa_baseline_oacc_update_rescale_and_add,test_fa_baseline_oacc_update_overwrite_full_tile,test_fa_baseline_oacc_update_no_stale_tail --rebuild` | PASS |
| `python3 -m py_compile sim/cocotb/tests/test_fa_baseline.py scripts/fa_precision_analysis.py scripts/fa_baseline_profile.py` | PASS |
| `python3 scripts/fa_precision_analysis.py --case single_q_full_kv_causal --q-row-start 0 --q-row-start 112 --q-row-start 240` | PASS; worst sampled mean/max `0.022474 / 0.042657` |
| `python3 sim/cocotb/run.py fa_baseline --testcase test_fa_baseline_score_post_real_scale_mask,test_fa_baseline_row_state_real_update,test_fa_baseline_row_state_all_masked_tile,test_fa_baseline_row_state_masked_tile_after_history,test_fa_baseline_oacc_update_rescale_and_add,test_fa_baseline_oacc_update_overwrite_full_tile,test_fa_baseline_oacc_update_no_stale_tail,test_fa_numeric_single_q_single_kv_noncausal,test_fa_numeric_single_q_full_kv_causal,test_fa_baseline_single_q_full_kv_causal_with_backpressure --rebuild` | PASS |
| `python3 sim/cocotb/run.py fa_full --testcase test_fa_baseline_full_causal_end_to_end,test_fa_baseline_full_noncausal_and_soft_reset --rebuild` | PASS |
| `python3 scripts/fa_baseline_profile.py --sim verilator` | PASS; `estimated_cycles=186096` |

## Estimated Area / Timing Impact

| Item | Estimate |
| --- | ---: |
| Wide reset/clear/pre-zero muxes removed | `13,824` data bits affected |
| Incremental standard-cell area saving | `10k-25k` |
| Incremental NAND2 equivalent saving, using `ND2D0BWP7T40P140=0.294` | `0.03M-0.09M` |
| Cumulative standard-cell area after directions 1-5 | `0.58M-0.76M` |
| Cumulative NAND2 equivalent after directions 1-5 | `1.97M-2.58M` |

Timing benefit should come mostly from lower high-fanout clear/reset loading and fewer wide zeroing muxes. There is no intentional cycle change; local profile stayed at `186096`.

## Benefit Evaluation

This is a low-cost, low-risk cleanup with modest direct area benefit. It is valuable as a timing/DRC cleanup after the larger structural reductions, especially if DC reports reset/clear nets or wide output registers as transition/fanout hotspots.
