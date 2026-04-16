# PT vs TPU Performance Comparison - 2026-04-16

## Scope

This note compares the current PT path in this repo against `comparison/tpu`
for a few representative INT8/INT32-style shapes.

The comparison uses:

- PT:
  - app-level tiled GEMM direct path (`host_reduce_direct_tiled_matmul`)
  - metrics captured from `app/pt_tiled_gemm/out/verify_metrics_*.json`
- TPU:
  - temporary local iverilog runs derived from
    `comparison/tpu/tb/tb_tpu_top_64bit.v`
  - dense `PM_INT8_INT32`
  - end-to-end cycles measured as:
    - first A ingress RAM write beat
    - to `transfer_done`

Important caveat:

- PT numbers are for the current direct tiled GEMM flow and do not include a
  TPU-style external C-matrix load.
- PT also has a newer measured `host_reduce_direct_pipelined` path for some
  multi-tile shapes, but this note intentionally keeps the earlier
  direct-path-only comparison method.
- TPU numbers are for the `A * B + C` style datapath exercised by its current
  top-level flow, so they include A/B/C ingress plus output transfer.
- This is therefore a practical "current implementation" comparison rather than
  a perfect isolated-kernel apples-to-apples benchmark.

## Peak Array Width

| Design | Array size | Peak MAC/cycle |
| --- | ---: | ---: |
| PT | `16 x 16` | `256` |
| TPU | `8 x 8` | `64` |

PT peak array width is `4.0x` larger.

## End-to-End Comparison

| Shape | MACs | PT cycles | TPU cycles | PT MAC/cycle | TPU MAC/cycle | PT speedup |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `16x16x16` | `4096` | `117` | `386` | `35.009` | `10.611` | `3.299x` |
| `32x32x16` | `16384` | `471` | `1323` | `34.786` | `12.384` | `2.809x` |
| `32x32x32` | `32768` | `943` | `1466` | `34.749` | `22.352` | `1.555x` |

## Source Metrics

### PT

- `16x16x16`
  - direct-path total cycles = `117`
  - file:
    `app/pt_tiled_gemm/out/verify_metrics_m16_k16_n16.json`
- `32x32x16`
  - direct-path total cycles = `471`
  - file:
    `app/pt_tiled_gemm/out/verify_metrics_m32_k16_n32.json`
- `32x32x32`
  - direct-path total cycles = `943`
  - file:
    `app/pt_tiled_gemm/out/verify_metrics_m32_k32_n32.json`

### TPU

Temporary local runs used these derived benches:

- `/tmp/tb_tpu_perf_m16n16k16.v`
- `/tmp/tb_tpu_perf_m32n32k16.v`
- `/tmp/tb_tpu_perf_m32n32k32.v`

Measured end-to-end cycles:

- `16x16x16`
  - first A write beat -> `transfer_done` = `386`
- `32x32x16`
  - first A write beat -> `transfer_done` = `1323`
- `32x32x32`
  - first A write beat -> `transfer_done` = `1466`

## TPU Phase Observations

From the local trace extraction:

- `16x16x16`
  - first data -> `compute_done` = `171` cycles
  - `compute_done` -> `transfer_done` = `139` cycles
- `32x32x16`
  - first data -> `compute_done` = `656` cycles
  - `compute_done` -> `transfer_done` = `527` cycles
- `32x32x32`
  - first data -> `compute_done` = `671` cycles
  - `compute_done` -> `transfer_done` = `527` cycles

This suggests:

- TPU improves as `K` grows because fixed load overhead amortizes better.
- TPU still carries a large fixed store/output tail.
- PT remains ahead across all measured shapes.

## PT Verification Caveats

The PT direct-path totals above remain valid, but current app-level verification
status is more nuanced than the earlier baseline:

- `m16_k16_n16`
  - `numeric_host_reduce_per_tensor` passed
  - app verify now passes fully (`5/5`)
- `m32_k16_n32`
  - `numeric_host_reduce_per_tensor` passed
  - app verify now passes fully (`5/5`)
- `m32_k32_n32`
  - `numeric_host_reduce_per_tensor` passed
  - `numeric_host_reduce_pipelined` also passed with `639` cycles
  - failures remain in `numeric_pt_matadd_reduce_per_tensor` and
    `algorithm_compare_reduction_strategies`

So the PT direct-path totals used in this note are still valid for comparison.

Additional current-version note:

- for `32x32x32`, the best verified PT path is currently
  `host_reduce_direct_pipelined = 639` cycles
- this note still uses `host_reduce_direct_tiled_matmul = 943` cycles because it
  preserves the direct-path comparison method used throughout the table above
