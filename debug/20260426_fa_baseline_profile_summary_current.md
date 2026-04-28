# FA Baseline RTL Profiling

- Date: `2026-04-26`
- Top: `FA_TOP_BASELINE_SIM`
- Method: sample per-stage RTL latency on early tiles, then extrapolate with deterministic scheduler invocation counts
- Row-update correction: override scheduler sampling with direct `FA_ROW_STATE_REAL` microbench for `masked` vs `valid` tiles

## Summary

- Conservative serial stage sum: `158448`
- Scheduler-overlap full-flow estimate: `96008`
- Scheduler overlap savings: `62440`
- Row-state sub-total inside row-update: `14976`
- P-load sub-total inside row-update: `2304`

## Scheduler Overlap Estimate

This model accounts for the current scheduler overlap where `v_load` can hide behind `qk + score_post + row_update`, and next `k_load` can be prefetched after `qk`.

| Class | Count | Row-update cycles | Compute before PV | First iteration cycles | Steady iteration cycles | Total cycles |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `history` | 120 | 90 | 161 | 467 | 337 | 42390 |
| `future_masked` | 120 | 42 | 130 | 436 | 306 | 36720 |
| `diagonal` | 16 | 90 | 161 | 467 | 337 | 5522 |

## Top-Level Stages

| Stage | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `k_load` | 130 | 256 | 33280 | 21.00% | `130` |
| `v_load` | 130 | 256 | 33280 | 21.00% | `130` |
| `pv` | 110 | 256 | 28160 | 17.77% | `110` |
| `row_update` | - | 256 | 17280 | 10.91% | `-` |
| `oacc_update` | 66 | 256 | 16896 | 10.66% | `66` |
| `qk` | 53 | 256 | 13568 | 8.56% | `53` |
| `store` | 562 | 16 | 8992 | 5.68% | `562` |
| `score_post` | 18 | 256 | 4608 | 2.91% | `18` |
| `q_load` | 130 | 16 | 2080 | 1.31% | `130` |
| `oacc_clear` | 17 | 16 | 272 | 0.17% | `17` |
| `row_init` | 2 | 16 | 32 | 0.02% | `2` |

## Row-Update Breakdown

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `history` | 90 | 120 | 10800 | 6.82% | `90` |
| `future_masked` | 42 | 120 | 5040 | 3.18% | `42` |
| `diagonal` | 90 | 16 | 1440 | 0.91% | `90` |

## Row-State Substage

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `history` | 81 | 120 | 9720 | 6.13% | `81` |
| `future_masked` | 33 | 120 | 3960 | 2.50% | `33` |
| `diagonal` | 81 | 16 | 1296 | 0.82% | `81` |

## P-Load Substage

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `future_masked` | 9 | 120 | 1080 | 0.68% | `9` |
| `history` | 9 | 120 | 1080 | 0.68% | `9` |
| `diagonal` | 9 | 16 | 144 | 0.09% | `9` |

## Sampled Stage Latency

| Stage | Selected cycles | Sample count | Observed uniques |
| --- | ---: | ---: | --- |
| `k_load` | 130 | 17 | `130` |
| `oacc_clear` | 17 | 2 | `17` |
| `oacc_update` | 66 | 16 | `66` |
| `pv` | 110 | 16 | `110` |
| `q_load` | 130 | 2 | `130` |
| `qk` | 53 | 17 | `53` |
| `row_init` | 2 | 2 | `2` |
| `score_post` | 18 | 17 | `18` |
| `store` | 562 | 1 | `562` |
| `v_load` | 130 | 17 | `130` |
