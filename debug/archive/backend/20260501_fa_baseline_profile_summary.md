# FA Baseline RTL Profiling

- Date: `2026-05-01`
- Top: `FA_TOP_BASELINE`
- Method: sample per-stage RTL latency on early tiles, then extrapolate with deterministic scheduler invocation counts
- Row-update correction: override scheduler sampling with direct `FA_ROW_STATE_REAL` microbench for `masked` vs `valid` tiles
- P-load: bypassed in the main path, modeled as `0` cycles
- Causal optimization: whole future-masked KV tiles are skipped, and the next Q tile is prefetched during store

## Summary

- Estimated scheduled full-run cycles: `85531`
- Serial stage-sum cycles before modeled overlap: `155712`
- Row-state sub-total inside row-update: `11968`
- P-load sub-total inside row-update: `0`

## Top-Level Stages

| Stage | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `k_load` | 267 | 136 | 36312 | 23.32% | `267` |
| `v_load` | 267 | 136 | 36312 | 23.32% | `267` |
| `pv` | 229 | 136 | 31144 | 20.00% | `229` |
| `qk` | 157 | 136 | 21352 | 13.71% | `157` |
| `row_update` | - | 136 | 11968 | 7.69% | `-` |
| `store` | 674 | 16 | 10784 | 6.93% | `674` |
| `q_load` | 267 | 16 | 4272 | 2.74% | `267` |
| `oacc_update` | 18 | 136 | 2448 | 1.57% | `18` |
| `score_post` | 6 | 136 | 816 | 0.52% | `6` |
| `oacc_clear` | 17 | 16 | 272 | 0.17% | `17` |
| `row_init` | 2 | 16 | 32 | 0.02% | `2` |

## Row-Update Breakdown

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `history` | 88 | 120 | 10560 | 6.78% | `88` |
| `diagonal` | 88 | 16 | 1408 | 0.90% | `88` |
| `future_masked` | 40 | 0 | 0 | 0.00% | `40` |

## Row-State Substage

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `history` | 88 | 120 | 10560 | 6.78% | `88` |
| `diagonal` | 88 | 16 | 1408 | 0.90% | `88` |
| `future_masked` | 40 | 0 | 0 | 0.00% | `40` |

## P-Load Substage

| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |
| --- | ---: | ---: | ---: | ---: | --- |
| `diagonal` | 0 | 16 | 0 | 0.00% | `0` |
| `future_masked` | 0 | 0 | 0 | 0.00% | `0` |
| `history` | 0 | 120 | 0 | 0.00% | `0` |

## Sampled Stage Latency

| Stage | Selected cycles | Sample count | Observed uniques |
| --- | ---: | ---: | --- |
| `k_load` | 267 | 2 | `267` |
| `oacc_clear` | 17 | 2 | `17` |
| `oacc_update` | 18 | 1 | `18` |
| `pv` | 229 | 1 | `229` |
| `q_load` | 267 | 2 | `267` |
| `qk` | 157 | 2 | `157` |
| `row_init` | 2 | 2 | `2` |
| `score_post` | 6 | 2 | `6` |
| `store` | 674 | 1 | `674` |
| `v_load` | 267 | 1 | `267` |

