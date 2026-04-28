# FA Area Direction 1 - Q Buffer SRAM to Register Tile Buffer

- Date: `2026-04-27`
- Baseline top DC area: `1,405,399.127886` standard-cell area, about `4.78M` NAND2 equivalent
- Baseline `u_q_buf` area: `206,253.8362`
- Change: replace `FA_Q_BUF_REAL` banked 512 x 32 SRAM-style tile buffer with a 512 x 32 register tile buffer; keep QK read latency, DMA write protocol, and external tile interface unchanged.

## Local Regression

| Check | Result |
| --- | --- |
| `python3 -m py_compile sim/cocotb/tests/test_fa_baseline.py scripts/fa_precision_analysis.py scripts/fa_baseline_profile.py` | PASS |
| `python3 scripts/fa_precision_analysis.py --case single_q_full_kv_causal --q-row-start 0 --q-row-start 112 --q-row-start 240` | PASS; worst sampled mean/max `0.022474 / 0.042657` |
| `python3 sim/cocotb/run.py fa_baseline --testcase test_fa_baseline_qk_buf_banked_write_and_read_decode,test_fa_numeric_single_q_single_kv_noncausal,test_fa_numeric_single_q_full_kv_causal,test_fa_baseline_single_q_full_kv_causal_with_backpressure --rebuild` | PASS |
| `python3 sim/cocotb/run.py fa_full --testcase test_fa_baseline_full_causal_end_to_end,test_fa_baseline_full_noncausal_and_soft_reset --rebuild` | PASS |
| `python3 scripts/fa_baseline_profile.py --sim verilator` | PASS; `estimated_cycles=167152` |

## Estimated Area / Timing Impact

| Item | Estimate |
| --- | ---: |
| Removed Q buffer macro-style area | `206,254` |
| Added 16,384 data FFs, read mux, write decode | `35k-60k` |
| Net standard-cell area saving | `146k-171k` |
| Net NAND2 equivalent saving, using `ND2D0BWP7T40P140=0.294` | `0.50M-0.58M` |
| Estimated top NAND2 equivalent after this step | `4.20M-4.28M` |

Timing risk is medium: the Q read path becomes FF/mux based instead of SRAM-output based. The interface still registers `rd_data`, so the expected critical-path risk is mainly write decode fanout and the row-wise read mux feeding the existing QK pipeline, not an additional architectural cycle.

## Benefit Evaluation

This is a high-benefit, medium-cost step because `u_q_buf` alone was the second-largest post-synthesis hotspot after the shared QK/PV compute block. It does not change external behavior or latency, and it preserves the `<=300k` cycle budget in the local profile.
