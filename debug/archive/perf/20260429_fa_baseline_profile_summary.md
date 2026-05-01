# FA Baseline RTL Profiling

- Date: `2026-04-29`
- Top: `FA_TOP_BASELINE_SIM`
- Method: sample per-stage RTL latency on early tiles, then extrapolate with deterministic scheduler invocation counts
- Row-update correction: override scheduler sampling with direct `FA_ROW_STATE_REAL` microbench for `masked` vs `valid` tiles
- P-load: bypassed in the main path, modeled as `0` cycles
- Causal optimization: whole future-masked KV tiles are skipped, and the next Q tile is prefetched during store

## Summary

- Estimated scheduled full-run cycles: `69986`
- Serial stage-sum cycles before modeled overlap: `113648`
- Row-state sub-total inside row-update: `11152`
- P-load sub-total inside row-update: `0`

## Top-Level Stages

| Stage | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `pv` | 229 | 136 | 31144 | 27.40% | `229` |
| `qk` | 157 | 136 | 21352 | 18.79% | `157` |
| `k_load` | 130 | 136 | 17680 | 15.56% | `130` |
| `v_load` | 130 | 136 | 17680 | 15.56% | `130` |
| `row_update` | - | 136 | 11152 | 9.81% | `-` |
| `store` | 562 | 16 | 8992 | 7.91% | `562` |
| `oacc_update` | 18 | 136 | 2448 | 2.15% | `18` |
| `q_load` | 130 | 16 | 2080 | 1.83% | `130` |
| `score_post` | 6 | 136 | 816 | 0.72% | `6` |
| `oacc_clear` | 17 | 16 | 272 | 0.24% | `17` |
| `row_init` | 2 | 16 | 32 | 0.03% | `2` |

## Row-Update Breakdown

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `history` | 82 | 120 | 9840 | 8.66% | `82` |
| `diagonal` | 82 | 16 | 1312 | 1.15% | `82` |
| `future_masked` | 34 | 0 | 0 | 0.00% | `34` |

## Row-State Substage

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `history` | 82 | 120 | 9840 | 8.66% | `82` |
| `diagonal` | 82 | 16 | 1312 | 1.15% | `82` |
| `future_masked` | 34 | 0 | 0 | 0.00% | `34` |

## P-Load Substage

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `diagonal` | 0 | 16 | 0 | 0.00% | `0` |
| `future_masked` | 0 | 0 | 0 | 0.00% | `0` |
| `history` | 0 | 120 | 0 | 0.00% | `0` |

## Sampled Stage Latency

| Stage | Selected cycles | Sample count | Observed uniques |
| --- | ---: | ---: | --- |
| `k_load` | 130 | 2 | `130` |
| `oacc_clear` | 17 | 2 | `17` |
| `oacc_update` | 18 | 1 | `18` |
| `pv` | 229 | 1 | `229` |
| `q_load` | 130 | 2 | `130` |
| `qk` | 157 | 2 | `157` |
| `row_init` | 2 | 2 | `2` |
| `score_post` | 6 | 2 | `6` |
| `store` | 562 | 1 | `562` |
| `v_load` | 130 | 2 | `130` |
