# FA Baseline RTL Profiling

- Date: `2026-04-27`
- Top: `FA_TOP_BASELINE_SIM`
- Method: sample per-stage RTL latency on early tiles, then extrapolate with deterministic scheduler invocation counts
- Row-update correction: override scheduler sampling with direct `FA_ROW_STATE_REAL` microbench for `masked` vs `valid` tiles

## Summary

- Estimated full-run cycles: `162544`
- Row-state sub-total inside row-update: `15232`
- P-load sub-total inside row-update: `2304`

## Top-Level Stages

| Stage | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `k_load` | 130 | 256 | 33280 | 20.47% | `130` |
| `v_load` | 130 | 256 | 33280 | 20.47% | `130` |
| `pv` | 110 | 256 | 28160 | 17.32% | `110` |
| `oacc_update` | 81 | 256 | 20736 | 12.76% | `81` |
| `row_update` | - | 256 | 17536 | 10.79% | `-` |
| `qk` | 53 | 256 | 13568 | 8.35% | `53` |
| `store` | 562 | 16 | 8992 | 5.53% | `562` |
| `score_post` | 18 | 256 | 4608 | 2.83% | `18` |
| `q_load` | 130 | 16 | 2080 | 1.28% | `130` |
| `oacc_clear` | 17 | 16 | 272 | 0.17% | `17` |
| `row_init` | 2 | 16 | 32 | 0.02% | `2` |

## Row-Update Breakdown

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `history` | 91 | 120 | 10920 | 6.72% | `91` |
| `future_masked` | 43 | 120 | 5160 | 3.17% | `43` |
| `diagonal` | 91 | 16 | 1456 | 0.90% | `91` |

## Row-State Substage

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `history` | 82 | 120 | 9840 | 6.05% | `82` |
| `future_masked` | 34 | 120 | 4080 | 2.51% | `34` |
| `diagonal` | 82 | 16 | 1312 | 0.81% | `82` |

## P-Load Substage

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `future_masked` | 9 | 120 | 1080 | 0.66% | `9` |
| `history` | 9 | 120 | 1080 | 0.66% | `9` |
| `diagonal` | 9 | 16 | 144 | 0.09% | `9` |

## Sampled Stage Latency

| Stage | Selected cycles | Sample count | Observed uniques |
| --- | ---: | ---: | --- |
| `k_load` | 130 | 17 | `130` |
| `oacc_clear` | 17 | 2 | `17` |
| `oacc_update` | 81 | 16 | `81` |
| `pv` | 110 | 16 | `110` |
| `q_load` | 130 | 2 | `130` |
| `qk` | 53 | 17 | `53` |
| `row_init` | 2 | 2 | `2` |
| `score_post` | 18 | 17 | `18` |
| `store` | 562 | 1 | `562` |
| `v_load` | 130 | 17 | `130` |

