# FA Area Direction 2 - K Buffer SRAM to Register Tile Buffer

- Date: `2026-04-28`
- Baseline top DC area: `1,405,399.127886` standard-cell area, about `4.78M` NAND2 equivalent
- Baseline `u_k_buf` area: `206,256.1882`
- Change: replace `FA_K_BUF_REAL` banked 512 x 32 SRAM-style tile buffer with the same 512 x 32 register tile buffer used by Q.

## Local Regression

| Check | Result |
| --- | --- |
| `python3 sim/cocotb/run.py fa_baseline --testcase test_fa_baseline_qk_buf_banked_write_and_read_decode,test_fa_baseline_qk_core_real_tile --rebuild` | PASS |
| `python3 -m py_compile sim/cocotb/tests/test_fa_baseline.py scripts/fa_precision_analysis.py scripts/fa_baseline_profile.py` | PASS |
| `python3 scripts/fa_precision_analysis.py --case single_q_full_kv_causal --q-row-start 0 --q-row-start 112 --q-row-start 240` | PASS; worst sampled mean/max `0.022474 / 0.042657` |
| `python3 sim/cocotb/run.py fa_baseline --testcase test_fa_baseline_qk_buf_banked_write_and_read_decode,test_fa_numeric_single_q_single_kv_noncausal,test_fa_numeric_single_q_full_kv_causal,test_fa_baseline_single_q_full_kv_causal_with_backpressure --rebuild` | PASS |
| `python3 sim/cocotb/run.py fa_full --testcase test_fa_baseline_full_causal_end_to_end,test_fa_baseline_full_noncausal_and_soft_reset --rebuild` | PASS |
| `python3 scripts/fa_baseline_profile.py --sim verilator` | PASS; `estimated_cycles=167152` |

## Estimated Area / Timing Impact

| Item | Estimate |
| --- | ---: |
| Removed K buffer macro-style area | `206,256` |
| Added 16,384 data FFs, read mux, write decode | `35k-60k` |
| Incremental standard-cell area saving | `146k-171k` |
| Incremental NAND2 equivalent saving, using `ND2D0BWP7T40P140=0.294` | `0.50M-0.58M` |
| Cumulative standard-cell area after directions 1+2 | `1.06M-1.11M` |
| Cumulative NAND2 equivalent after directions 1+2 | `3.62M-3.79M` |

Timing risk is medium and symmetric to Q: the K read data remains registered, but the mux/read-select network is now implemented in standard cells. This can increase local net fanout around the QK input path, so final DC should watch QK input setup and max transition.

## Benefit Evaluation

This is another high-benefit, low-architecture-risk step. Together with direction 1 it removes the two largest non-compute buffer hotspots while preserving the existing scheduler, DMA path, and cycle estimate.
