# Flash Attention Algorithm / RTL Consistency Check

Date: 2026-04-29

This note checks the current `FA_TOP_BASELINE` implementation against the Flash Attention algorithm, the cocotb floating golden model, and the RTL-like fixed-point model used by precision scripts.

## Scope

Current baseline shape:

| Item | Current RTL |
|---|---|
| Sequence length | fixed `S = 256` |
| Head dimension | fixed `d = 64` |
| Q block | `16 x 64` |
| KV block | `16 x 64` |
| QK tile | `16 x 16`, streamed as four `4 x 16` blocks |
| PV tile | `16 x 64`, streamed as four `4 x 64` blocks |
| External Q/K/V/O | packed Q8.8, two 16-bit lanes per 32-bit word |
| Supported masks | causal and non-causal |
| Not in baseline | padding/valid length, multi-head, variable `S`, variable `d`, FP16/BF16 |

The mathematical target is:

```text
score_ij = Q_i dot K_j / sqrt(d) + M_ij
P_ij     = exp(score_ij) / sum_t exp(score_it)
O_i      = sum_j P_ij * V_j
```

## Datapath Mapping

```text
External Q/K/V
    |
    v
FA_RD_DMA -> Q_BUF / K_BUF / V_BUF / V_BUF_PV
    |
    +--> Q_BUF + K_BUF
            |
            v
        FA_QK_PV_SHARED_CORE_REAL, QK mode
        shared GEMM_V3, X_DIM=4, Y_DIM=16, num_acc=32
            |
            v
        qk_block: 4 rows x 16 cols, Q16.16-related score words
            |
            v
        FA_SCORE_POST_REAL
        scale by CSR SCALE, apply causal mask, emit explicit valid mask
            |
            v
        FA_ROW_STATE_REAL
        online m/l update, exp LUT, reciprocal, P Q8.8, rescale Q16.16
            |
            +--> P_BYPASS ----+
                              |
                              v
V_BUF_PV ----------------> FA_QK_PV_SHARED_CORE_REAL, PV mode
                           shared GEMM_V3, X_DIM=4, Y_DIM=16, num_acc=8
                              |
                              v
                           pv_block: 4 rows x 64 cols, Q8.8
                              |
                              v
                           FA_OACC_UPDATE_REAL
                           O_old * rescale + PV_partial
                              |
                              v
                           OACC_BUF Q4.12 -> FA_WR_DMA -> External O Q8.8
```

## Stage Consistency

| Algorithm stage | RTL stage | Software model | Consistency result |
|---|---|---|---|
| Q/K/V quantization | Q/K/V buffer load | `q88_from_float`, packed row-major helpers | Same packed Q8.8 convention |
| `Q x K^T` | shared QK/PV core in QK mode | `expected_qk_tile_words` | Same `16 x 16` tile shape, 64-lane dot, 32 packed accumulations |
| scale | `FA_SCORE_POST_REAL` | `expected_score_post_words` | Same Q16.16 multiply, round/saturate |
| causal mask | scheduler future-tile skip plus score-post diagonal mask | golden `causal=True` and fixed model | Same global index rule `global_k > global_q` |
| online softmax | `FA_ROW_STATE_REAL` | `expected_row_state_update` | Same `m/l`, alpha, beta, reciprocal, P, rescale recurrence |
| `P x V` | shared QK/PV core in PV mode | `expected_pv_tile_words` | Same `16 x 64` output shape, streamed as `4 x 64` blocks |
| O update | `FA_OACC_UPDATE_REAL` | `expected_oacc_update_q412_words` | Same rescale/add and Q4.12 internal OACC |
| O export | OACC export and write DMA | output unpack helpers | Same external packed Q8.8 output |

## Fixed-Point Semantics

| Data | RTL format | Notes |
|---|---|---|
| Q/K/V input | Q8.8 | cocotb golden first quantizes external payload |
| QK raw score | 32-bit signed accumulator interpreted on Q16.16 path | saturates to signed 32-bit |
| scale | Q16.16 CSR word | default `1/sqrt(64) = 0.125 = 0x00002000` |
| row-state `m/l/rescale` | Q16.16 | exp LUT covers deltas clamped to `[-8, 0]` |
| P | Q8.8 | produced per KV tile and bypassed to PV |
| PV partial | Q8.8 | 16-term PV dot per KV tile |
| OACC internal | Q4.12 | area-optimized accumulator storage |
| O output | Q8.8 | OACC export rounds/saturates |

The fixed-point path is not bit-exact to floating Flash Attention. End-to-end numeric tests compare against the floating golden model with error thresholds; block-level tests compare against the RTL-like fixed model bit-for-bit.

## Mask Validity Fix

The consistency check found one real semantic edge case: the previous row-state valid-column decision used:

```text
valid(col) = masked_score_word != NEG_LARGE
```

That made a real, unmasked score numerically equal to CSR `NEG_LARGE` look masked. The active block-streaming path now carries:

```text
masked_score_block_valid[local_row, col]
```

from `FA_SCORE_POST_REAL` to `FA_ROW_STATE_REAL`. A score value equal to `NEG_LARGE` can now remain valid when it was not produced by the mask condition.

Directed regression added:

```text
test_fa_numeric_valid_score_equals_neg_large_noncausal
```

This case constructs Q/K so every valid non-causal score equals `NEG_LARGE`; the expected output is the average of all V rows, not zero.

## Known Boundaries

| Boundary | Status |
|---|---|
| Padding / valid length | Not implemented in baseline; listed as bonus/future work |
| Variable sequence length | Not implemented; fixed `256` |
| Multi-head | Not implemented in baseline |
| Exp underflow | Deltas below `-8` clamp to `exp(-8)` rather than mathematical zero |
| Reciprocal | Floor integer reciprocal approximation |
| Debug flat mirrors | QK/PV full-tile flat outputs are debug/simulation mirrors; synthesized datapath uses streamed blocks |

## Regression Evidence

Commands run after the consistency fix:

```bash
python3 -m py_compile \
  sim/cocotb/tests/test_fa_baseline.py \
  sim/cocotb/tests/test_fa_baseline_numeric_cases.py \
  scripts/fa_precision_analysis.py \
  scripts/fa_extreme_precision_analysis.py

iverilog -g2012 -I rtl -s FA_TOP_BASELINE_SIM \
  -o /tmp/fa_top_baseline_sim_consistency.out rtl/*.v

iverilog -g2012 -DSYNTHESIS -I rtl -s FA_TOP_BASELINE \
  -o /tmp/fa_top_baseline_synth_consistency.out rtl/*.v

python3 sim/cocotb/run.py fa_baseline \
  --testcase test_fa_numeric_valid_score_equals_neg_large_noncausal --rebuild

python3 sim/cocotb/run.py fa_baseline \
  --testcase test_fa_numeric_single_q_single_kv_noncausal,test_fa_numeric_single_q_full_kv_causal --rebuild

python3 sim/cocotb/run.py fa_baseline \
  --testcase test_fa_baseline_score_post_real_scale_mask,test_fa_baseline_row_state_real_update_single_tile

python3 sim/cocotb/run.py fa_baseline \
  --testcase test_fa_baseline_qk_core_real_tile,test_fa_baseline_pv_core_real_tile

python3 sim/cocotb/run.py fa_baseline \
  --testcase test_fa_baseline_single_q_full_kv_causal_with_backpressure

python3 sim/cocotb/run.py fa_full \
  --testcase test_fa_baseline_full_causal_end_to_end,test_fa_baseline_full_noncausal_and_soft_reset --rebuild

python3 sim/cocotb/run.py fa_rowstate_profile --rebuild

python3 scripts/fa_precision_analysis.py --case single_tile_noncausal --q-row-start 0

python3 scripts/fa_precision_analysis.py \
  --case single_q_full_kv_causal \
  --q-row-start 0 --q-row-start 112 --q-row-start 240
```

All commands above passed. The long multi-test cocotb command was split because the generated log filename exceeded the local filesystem limit; the split runs passed.

Sampled precision after the fix stayed unchanged for the existing random cases:

| Case | Mean error | Max error |
|---|---:|---:|
| single tile non-causal | `0.003252` | `0.008083` |
| full-KV causal, q row start 0 | `0.006241` | `0.014877` |
| full-KV causal, q row start 112 | `0.013960` | `0.025750` |
| full-KV causal, q row start 240 | `0.022474` | `0.042657` |

## Conclusion

Within the baseline scope, the algorithm, RTL-like fixed model, and real RTL now match at the intended stage boundaries. Remaining differences from mathematical Flash Attention are deliberate fixed-point approximations or unsupported modes, not accidental control/dataflow mismatches.
