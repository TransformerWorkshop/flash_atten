# FA Baseline RTL Profiling

- Date: `2026-04-27`
- Top: `FA_TOP_BASELINE_SIM`
- Method: sample per-stage RTL latency on early tiles, then extrapolate with deterministic scheduler invocation counts
- Row-update correction: override scheduler sampling with direct `FA_ROW_STATE_REAL` microbench for `masked` vs `valid` tiles
- P-load: bypassed in the main path, modeled as `0` cycles

## Summary

- Estimated full-run cycles: `158960`
- Row-state sub-total inside row-update: `15232`
- P-load sub-total inside row-update: `0`

## Top-Level Stages

| Stage | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `k_load` | 130 | 256 | 33280 | 20.94% | `130` |
| `v_load` | 130 | 256 | 33280 | 20.94% | `130` |
| `pv` | 106 | 256 | 27136 | 17.07% | `106` |
| `oacc_update` | 81 | 256 | 20736 | 13.04% | `81` |
| `row_update` | - | 256 | 15232 | 9.58% | `-` |
| `qk` | 52 | 256 | 13312 | 8.37% | `52` |
| `store` | 562 | 16 | 8992 | 5.66% | `562` |
| `score_post` | 18 | 256 | 4608 | 2.90% | `18` |
| `q_load` | 130 | 16 | 2080 | 1.31% | `130` |
| `oacc_clear` | 17 | 16 | 272 | 0.17% | `17` |
| `row_init` | 2 | 16 | 32 | 0.02% | `2` |

## Row-Update Breakdown

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `history` | 82 | 120 | 9840 | 6.19% | `82` |
| `future_masked` | 34 | 120 | 4080 | 2.57% | `34` |
| `diagonal` | 82 | 16 | 1312 | 0.83% | `82` |

## Row-State Substage

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `history` | 82 | 120 | 9840 | 6.19% | `82` |
| `future_masked` | 34 | 120 | 4080 | 2.57% | `34` |
| `diagonal` | 82 | 16 | 1312 | 0.83% | `82` |

## P-Load Substage

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `diagonal` | 0 | 16 | 0 | 0.00% | `0` |
| `future_masked` | 0 | 120 | 0 | 0.00% | `0` |
| `history` | 0 | 120 | 0 | 0.00% | `0` |

## Sampled Stage Latency

| Stage | Selected cycles | Sample count | Observed uniques |
| --- | ---: | ---: | --- |
| `k_load` | 130 | 17 | `130` |
| `oacc_clear` | 17 | 2 | `17` |
| `oacc_update` | 81 | 16 | `81` |
| `pv` | 106 | 16 | `106` |
| `q_load` | 130 | 2 | `130` |
| `qk` | 52 | 17 | `52` |
| `row_init` | 2 | 2 | `2` |
| `score_post` | 18 | 17 | `18` |
| `store` | 562 | 1 | `562` |
| `v_load` | 130 | 17 | `130` |

