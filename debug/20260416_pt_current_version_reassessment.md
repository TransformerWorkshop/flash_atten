# PT Current-Version Reassessment - 2026-04-16

## Scope

This note re-evaluates the current PT implementation in the present working tree,
not just the previously committed baseline.

At evaluation time, the workspace already contained uncommitted changes in:

- `rtl/pt_ce_v2.v`
- `rtl/pt_dispatch_v2.v`
- `scripts/pt_perf_model.py`
- `app/pt_tiled_gemm/tests/test_pt_tiled_gemm.py`

So the conclusions below describe the current local version as of `2026-04-16`.

## What Was Re-run

### 1. PT perf regression

- Command:
  - `python3 sim/cocotb/run.py perf --sim icarus`
- Result:
  - existing perf suite passed again
  - legacy `4x4`, upgrade `4x4`, legacy `8x8`, upgrade `8x8` all remained `PASS`

Artifacts:

- `sim/cocotb/logs/perf_legacy_4x4_seed10.test.log`
- `sim/cocotb/logs/perf_upgrade_4x4_seed10.test.log`
- `sim/cocotb/logs/perf_legacy_8x8_seed10.test.log`
- `sim/cocotb/logs/perf_upgrade_8x8_seed10.test.log`

### 2. PT perf one-off at the app's current `16x16` configuration

The stock perf suite only covers `4x4` and `8x8`, so a one-off run was executed
with the app's real configuration:

- `GEMM_X_DIM = 16`
- `GEMM_Y_DIM = 16`
- `A/B/M lane width = 16`
- `M_PHYSICAL_COPIES = 2`

Result:

- `3 / 3` tests passed

Artifacts:

- `sim/cocotb/results/perf_current_16x16_seed10.xml`
- `sim/cocotb/logs/perf_current_16x16_seed10.test.log`

The passing assertions in `tests.test_pt_perf_cases` imply these current top-level
timing facts for the `16x16` wide configuration:

| Metric | Current value |
| --- | ---: |
| cache-hit `ctrl_accept -> ctrl_resp` | `41` cycles |
| cold-miss `ctrl_accept -> ctrl_resp` | `81` cycles |
| export `m_dma_req -> m_axis_tlast` | `33` cycles |

This is consistent with the updated perf test expectation that front-end overhead
is now `6` cycles instead of the older `9`-cycle model.

## App-Level Verify Results

### Current representative shapes

| Shape | Verify result | Direct | Pipelined | PT MATADD reduce | Notes |
| --- | --- | ---: | ---: | ---: | --- |
| `16x16x16` | `PASS (5/5)` | `117` | `117` | `117` | all paths pass |
| `32x16x32` | `PASS (5/5)` | `471` | `471` | `471` | all paths pass |
| `32x32x32` | `FAIL (3/5)` | `943` | `639` | fail | direct/pipelined still usable |
| `48x32x32` | `FAIL (1/5)` | fail | fail | fail | capacity boundary exposed |

Artifacts:

- `app/pt_tiled_gemm/out/verify_metrics_m16_k16_n16.json`
- `app/pt_tiled_gemm/out/verify_metrics_m32_k16_n32.json`
- `app/pt_tiled_gemm/out/verify_metrics_m32_k32_n32.json`
- `app/pt_tiled_gemm/out/verify_metrics_m48_k32_n32.json`

### Important updated finding

For `32x32x32`, the best verified current path is no longer the plain direct path:

- `host_reduce_direct_tiled_matmul = 943 cycles`
- `host_reduce_direct_pipelined = 639 cycles`

So the pipelined direct path is currently:

- `304` cycles faster
- `1.476x` as fast as the plain direct path

This is visible in:

- `app/pt_tiled_gemm/out/verify_metrics_m32_k32_n32.json`

## Failure Analysis

### 1. `32x32x32` failure mode

Observed failures:

- `test_numeric_pt_matadd_reduce_per_tensor`
- `test_algorithm_compare_reduction_strategies`

The failing point is `assert not plan.err` inside `run_matadd_tile()`.

Based on the log sequence and current model behavior, the most likely root cause is:

- current app flow uses a fresh `ctrl_id` for every partial MATMUL and every MATADD
- `LUT_DEPTH = 8`
- `32x32x32` requires:
  - `8` MATMUL ids
  - plus extra MATADD ids
- the third output tile's MATADD attempts to allocate a ninth-or-later unique id
  into the current residency model

This strongly indicates the failure is a `lut_full_miss` style capacity limit,
not a regression in the direct compute datapath itself.

### 2. `48x32x32` failure mode

Observed failures:

- `test_numeric_host_reduce_per_tensor`
- `test_numeric_host_reduce_pipelined`
- `test_numeric_pt_matadd_reduce_per_tensor`
- `test_algorithm_compare_reduction_strategies`

This shape needs:

- `m_tiles = 3`
- `k_tiles = 2`
- `n_tiles = 2`
- `partial_matmuls = 12`

So even the direct and pipelined host-reduce flows exceed the current `LUT_DEPTH = 8`
when they keep allocating fresh `ctrl_id`s.

This confirms the current app-level scalability boundary:

- with the present id-allocation style, the flow is reliable while unique live ids
  stay within `8`
- once the app needs more than `8` unique ids, verification starts failing even if
  the underlying MATMUL datapath is otherwise correct

## Planner / Reporting Gap

There is now a mismatch between the testbench and the planner:

- `app/pt_tiled_gemm/tests/test_pt_tiled_gemm.py` already measures
  `host_reduce_direct_pipelined`
- `app/pt_tiled_gemm/planner.py` still builds candidates only for:
  - `host_reduce_direct_tiled_matmul`
  - `host_reduce_load_then_matmul`
  - `pt_matadd_reduce`

Consequence:

- current recommendation/report output can miss the actual best verified path
- for `32x32x32`, the planner still reports `host_reduce_direct_tiled_matmul`
  because the pipelined candidate is not part of its ranking set
- if `algorithm_compare_reduction_strategies` aborts before recording all algorithms,
  planner ranking may also fall back to mixed measured/estimated behavior

## Updated Conclusion

The current PT version should be described as follows:

- the widened `16x16` direct datapath is healthy at the low level
- the current top-visible front-end path is better than the older `9`-cycle note;
  perf tests now validate a `6`-cycle front-end overhead model
- current app-level direct execution remains valid for the previously published
  direct-path comparison points:
  - `16x16x16 -> 117 cycles`
  - `32x16x32 -> 471 cycles`
  - `32x32x32 -> 943 cycles`
- however, for larger multi-tile problems, the real best verified path is now
  `host_reduce_direct_pipelined` when it fits
- the dominant current app-level limitation is no longer pure datapath throughput;
  it is the residency / id-capacity boundary created by `LUT_DEPTH = 8` together
  with fresh-id allocation

## Practical Next Steps

If the goal is to improve the current version rather than only document it, the
highest-value next items are:

1. teach `planner.py` to include `host_reduce_direct_pipelined`
2. decide whether the app flow should reuse / recycle `ctrl_id`s
3. or raise / redesign the residency limit so shapes with `partial_matmuls > 8`
   do not fail immediately
