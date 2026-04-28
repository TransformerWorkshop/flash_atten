# FA Area Direction 6 - Shared GEMM 8x16 to 4x16

- Date: `2026-04-28`
- Previous top DC area after directions 1-5: `671,715.423004` standard-cell area, about `2.285M` NAND2 equivalent
- Previous `u_qk_pv_core` area: `327,229.6440`
- Previous `u_qk_pv_core/u_gemm` area: `253,776.4876`
- Change: keep one shared QK/PV GEMM, reduce the array from `8x16` to `4x16`, and process each 16-row tile as four 4-row blocks.

## Local Regression

| Check | Result |
| --- | --- |
| `python3 -m py_compile sim/cocotb/tests/test_fa_baseline.py scripts/fa_precision_analysis.py scripts/fa_baseline_profile.py` | PASS |
| `python3 sim/cocotb/run.py fa_baseline --testcase test_fa_baseline_qk_core_real_tile,test_fa_baseline_pv_core_real_tile --rebuild` | PASS |
| `python3 scripts/fa_precision_analysis.py --case single_q_full_kv_causal --q-row-start 0 --q-row-start 112 --q-row-start 240` | PASS; sampled total mean/max: `0.006241 / 0.014877`, `0.013960 / 0.025750`, `0.022474 / 0.042657` |
| `python3 sim/cocotb/run.py fa_baseline --testcase test_fa_baseline_qk_buf_banked_write_and_read_decode,test_fa_baseline_qk_core_real_tile,test_fa_baseline_pv_core_real_tile,test_fa_numeric_single_q_single_kv_noncausal,test_fa_numeric_single_q_full_kv_causal,test_fa_baseline_single_q_full_kv_causal_with_backpressure --rebuild` | PASS |
| `python3 sim/cocotb/run.py fa_full --testcase test_fa_baseline_full_causal_end_to_end,test_fa_baseline_full_noncausal_and_soft_reset --rebuild` | PASS |
| `python3 scripts/fa_baseline_profile.py --sim verilator` | PASS; `estimated_cycles=223984` |

## Cycle Impact

| Stage | 8x16 GEMM | 4x16 GEMM | Delta |
| --- | ---: | ---: | ---: |
| `qk` per invocation | `86` | `154` | `+68` |
| `pv` per invocation | `146` | `226` | `+80` |
| Full-run estimate | `186096` | `223984` | `+37888` |

The cycle cost is about `+20.4%` versus the 8x16 version. The full-run estimate remains below the `300k` requirement with about `76k` cycles of slack.

## Estimated Area / Timing Impact

| Item | Estimate |
| --- | ---: |
| Removed GEMM PE fraction versus 8x16 | about `50%` of the remaining compute array |
| Incremental standard-cell area saving | `115k-130k` |
| Incremental NAND2 equivalent saving, using `ND2D0BWP7T40P140=0.294` | `0.39M-0.44M` |
| Estimated top standard-cell area after this direction | `541.7k-556.7k` |
| Estimated top NAND2 equivalent after this direction | `1.84M-1.89M` |
| Margin to `2.0M` NAND2 target | about `0.11M-0.16M` NAND2 |

Timing risk is low-to-medium. The smaller PE array should reduce clock load, local routing, max-transition pressure, and GEMM internal cone depth. The added risk is a higher row-block mux fan-in on Q/P input selection plus twice as many serialized GEMM blocks, so the next top DC should check whether the GEMM input mux or ready/done control becomes the new setup or design-rule hotspot.

## Benefit Evaluation

This is the best remaining high-return lever after the 8x16 reduction. It directly attacks the dominant `u_gemm` hotspot and is likely enough to move the top under the `<=2M` NAND2 area target, while preserving the external QK/PV request, response, and result-tile semantics. The cost is a visible but acceptable cycle increase: QK/PV becomes the main compute bottleneck, but the estimated full-run latency still stays below `300k`.
