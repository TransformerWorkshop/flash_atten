# FA Area Direction 3 - Shared GEMM 16x16 to 8x16

- Date: `2026-04-28`
- Baseline top DC area: `1,405,399.127886` standard-cell area, about `4.78M` NAND2 equivalent
- Baseline `u_qk_pv_core` area: `667,983.6045`
- Change: keep one shared QK/PV GEMM, reduce the array from `16x16` to `8x16`, and process each 16-row tile as two 8-row blocks.

## Local Regression

| Check | Result |
| --- | --- |
| `python3 sim/cocotb/run.py fa_baseline --testcase test_fa_baseline_qk_core_real_tile,test_fa_baseline_pv_core_real_tile --rebuild` | PASS |
| `python3 -m py_compile sim/cocotb/tests/test_fa_baseline.py scripts/fa_precision_analysis.py scripts/fa_baseline_profile.py` | PASS |
| `python3 scripts/fa_precision_analysis.py --case single_q_full_kv_causal --q-row-start 0 --q-row-start 112 --q-row-start 240` | PASS; worst sampled mean/max `0.022474 / 0.042657` |
| `python3 sim/cocotb/run.py fa_baseline --testcase test_fa_baseline_qk_buf_banked_write_and_read_decode,test_fa_baseline_qk_core_real_tile,test_fa_baseline_pv_core_real_tile,test_fa_numeric_single_q_single_kv_noncausal,test_fa_numeric_single_q_full_kv_causal,test_fa_baseline_single_q_full_kv_causal_with_backpressure --rebuild` | PASS |
| `python3 sim/cocotb/run.py fa_full --testcase test_fa_baseline_full_causal_end_to_end,test_fa_baseline_full_noncausal_and_soft_reset --rebuild` | PASS |
| `python3 scripts/fa_baseline_profile.py --sim verilator` | PASS; `estimated_cycles=186096` |

## Cycle Impact

| Stage | Before | After | Delta |
| --- | ---: | ---: | ---: |
| `qk` per invocation | `52` | `86` | `+34` |
| `pv` per invocation | `106` | `146` | `+40` |
| Full-run estimate | `167152` | `186096` | `+18944` |

The cycle cost is about `+11.3%`, still well below the `300k` requirement.

## Estimated Area / Timing Impact

| Item | Estimate |
| --- | ---: |
| Removed GEMM PE fraction | about `50%` of the compute array |
| Incremental standard-cell area saving | `260k-330k` |
| Incremental NAND2 equivalent saving, using `ND2D0BWP7T40P140=0.294` | `0.88M-1.12M` |
| Cumulative standard-cell area after directions 1+2+3 | `0.73M-0.85M` |
| Cumulative NAND2 equivalent after directions 1+2+3 | `2.49M-2.90M` |

Timing risk is low-to-medium. The reduced PE array should help placement and local routing, while the new row-block mux on Q/P inputs adds a small select path before GEMM input registers/handshake. The main metric to watch in DC is whether Q/P input muxing or GEMM ready reduction becomes a setup or max-transition hotspot.

## Benefit Evaluation

This is the highest-return structural step so far: it targets the largest hotspot, cuts compute parallelism without changing external result semantics, and spends only `18,944` estimated cycles. It is still not enough by itself to reach `<2M` NAND2, but it moves the design close enough that smaller buffer/state optimizations can plausibly close the remaining gap.
