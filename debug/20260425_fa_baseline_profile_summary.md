# FA Baseline RTL Profiling

- Date: `2026-04-25`
- Top: `FA_TOP_BASELINE_SIM`
- Method: sample per-stage RTL latency on early tiles, then extrapolate with deterministic scheduler invocation counts
- Row-update correction: override scheduler sampling with direct `FA_ROW_STATE_REAL` microbench for `masked` vs `valid` tiles

## Summary

- Estimated full-run cycles: `481904`
- Row-state sub-total inside row-update: `82432`
- P-load sub-total inside row-update: `2304`

## Top-Level Stages

| Stage | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `k_load` | 514 | 256 | 131584 | 27.31% | `514` |
| `v_load` | 514 | 256 | 131584 | 27.31% | `514` |
| `row_update` | - | 256 | 84736 | 17.58% | `-` |
| `pv` | 206 | 256 | 52736 | 10.94% | `206` |
| `qk` | 149 | 256 | 38144 | 7.92% | `149` |
| `oacc_update` | 82 | 256 | 20992 | 4.36% | `82` |
| `store` | 562 | 16 | 8992 | 1.87% | `562` |
| `q_load` | 514 | 16 | 8224 | 1.71% | `514` |
| `score_post` | 18 | 256 | 4608 | 0.96% | `18` |
| `oacc_clear` | 17 | 16 | 272 | 0.06% | `17` |
| `row_init` | 2 | 16 | 32 | 0.01% | `2` |

## Row-Update Breakdown

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `history` | 586 | 120 | 70320 | 14.59% | `586` |
| `diagonal` | 586 | 16 | 9376 | 1.95% | `586` |
| `future_masked` | 42 | 120 | 5040 | 1.05% | `42` |

## Row-State Substage

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `history` | 577 | 120 | 69240 | 14.37% | `577` |
| `diagonal` | 577 | 16 | 9232 | 1.92% | `577` |
| `future_masked` | 33 | 120 | 3960 | 0.82% | `33` |

## P-Load Substage

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `future_masked` | 9 | 120 | 1080 | 0.22% | `9` |
| `history` | 9 | 120 | 1080 | 0.22% | `9` |
| `diagonal` | 9 | 16 | 144 | 0.03% | `9` |

## Sampled Stage Latency

| Stage | Selected cycles | Sample count | Observed uniques |
| --- | ---: | ---: | --- |
| `k_load` | 514 | 17 | `514` |
| `oacc_clear` | 17 | 2 | `17` |
| `oacc_update` | 82 | 16 | `82` |
| `pv` | 206 | 16 | `206` |
| `q_load` | 514 | 2 | `514` |
| `qk` | 149 | 17 | `149` |
| `row_init` | 2 | 2 | `2` |
| `score_post` | 18 | 17 | `18` |
| `store` | 562 | 1 | `562` |
| `v_load` | 514 | 17 | `514` |

