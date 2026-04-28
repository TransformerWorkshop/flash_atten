# FA Baseline RTL Profiling

- Date: `2026-04-25`
- Top: `FA_TOP_BASELINE_SIM`
- Method: sample per-stage RTL latency on early tiles, then extrapolate with deterministic scheduler invocation counts
- Row-update correction: override scheduler sampling with direct `FA_ROW_STATE_REAL` microbench for `masked` vs `valid` tiles

## Summary

- Estimated full-run cycles: `279152`
- Row-state sub-total inside row-update: `82432`
- P-load sub-total inside row-update: `2304`

## Top-Level Stages

| Stage | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `row_update` | - | 256 | 84736 | 30.35% | `-` |
| `pv` | 206 | 256 | 52736 | 18.89% | `206` |
| `qk` | 149 | 256 | 38144 | 13.66% | `149` |
| `k_load` | 130 | 256 | 33280 | 11.92% | `130` |
| `v_load` | 130 | 256 | 33280 | 11.92% | `130` |
| `oacc_update` | 82 | 256 | 20992 | 7.52% | `82` |
| `store` | 562 | 16 | 8992 | 3.22% | `562` |
| `score_post` | 18 | 256 | 4608 | 1.65% | `18` |
| `q_load` | 130 | 16 | 2080 | 0.75% | `130` |
| `oacc_clear` | 17 | 16 | 272 | 0.10% | `17` |
| `row_init` | 2 | 16 | 32 | 0.01% | `2` |

## Row-Update Breakdown

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `history` | 586 | 120 | 70320 | 25.19% | `586` |
| `diagonal` | 586 | 16 | 9376 | 3.36% | `586` |
| `future_masked` | 42 | 120 | 5040 | 1.81% | `42` |

## Row-State Substage

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `history` | 577 | 120 | 69240 | 24.80% | `577` |
| `diagonal` | 577 | 16 | 9232 | 3.31% | `577` |
| `future_masked` | 33 | 120 | 3960 | 1.42% | `33` |

## P-Load Substage

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `future_masked` | 9 | 120 | 1080 | 0.39% | `9` |
| `history` | 9 | 120 | 1080 | 0.39% | `9` |
| `diagonal` | 9 | 16 | 144 | 0.05% | `9` |

## Sampled Stage Latency

| Stage | Selected cycles | Sample count | Observed uniques |
| --- | ---: | ---: | --- |
| `k_load` | 130 | 17 | `130` |
| `oacc_clear` | 17 | 2 | `17` |
| `oacc_update` | 82 | 16 | `82` |
| `pv` | 206 | 16 | `206` |
| `q_load` | 130 | 2 | `130` |
| `qk` | 149 | 17 | `149` |
| `row_init` | 2 | 2 | `2` |
| `score_post` | 18 | 17 | `18` |
| `store` | 562 | 1 | `562` |
| `v_load` | 130 | 17 | `130` |

