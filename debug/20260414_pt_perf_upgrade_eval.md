# PT Performance Iteration Log - 2026-04-14

## 1. Scope

This note tracks the current PT performance-oriented iteration, including:

- widened A/B load beats
- widened M writeback
- widened M export
- reduced M physical-copy count
- the later migration of `PT_M_MEM` to standard SRAM-backed row views

The goal of this document is to keep the structural model, measured RTL behavior, and current verification status aligned in one place.

## 2. Current Architecture Delta

The active PT datapath now supports these structural knobs:

- `A_LOAD_LANES`
- `B_LOAD_LANES`
- `M_WRITE_LANES`
- `M_EXPORT_LANES`
- `M_PHYSICAL_COPIES`

Current intent by configuration:

| Profile | `A_LOAD_LANES` | `B_LOAD_LANES` | `M_WRITE_LANES` | `M_EXPORT_LANES` | `M_PHYSICAL_COPIES` |
| --- | ---: | ---: | ---: | ---: | ---: |
| Legacy regression profile | `1` | `1` | `1` | `1` | `3` |
| Wide/upgrade profile | `GEMM_X_DIM` | `GEMM_Y_DIM` | `GEMM_Y_DIM` | `GEMM_Y_DIM` | `2` |

Important architectural facts:

- `MATMUL` still consumes only A and B banks.
- `M`-as-`A` `MATMUL` reuse is not implemented in the current RTL.
- `MATADD` still uses retained M plus an external/B-bank tile.
- `PT_M_MEM` is now standard-SRAM-backed and row-major only; export and retained-M reads are handled through row views.

## 3. Structural Model Snapshot

The structural estimator in [`scripts/pt_perf_model.py`](../scripts/pt_perf_model.py) models beat counts, internal stage widths, bytes/op, and throughput scaling for the parameterized datapath.

### 3.1 Cache-Hit Snapshot @ 1 GHz

| Mode | Tile | `ctrl_resp` cycles | Tile cycles | Sustained ops/cycle | Utilization | Bottleneck |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| Legacy | `4x4` | 29 | 49 | 2.6122 | 8.16% | `internal_execution` |
| Wide | `4x4` | 17 | 25 | 5.1200 | 16.00% | `internal_execution` |
| Legacy | `8x8` | 85 | 153 | 6.6928 | 5.23% | `internal_execution` |
| Wide | `8x8` | 29 | 41 | 24.9756 | 19.51% | `internal_execution` |

### 3.2 What The Structural Model Captures Well

- internal execution shrink from widened writeback
- A/B load beat shrink from widened load lanes
- external byte pressure and bytes/op
- physical M-copy write amplification via `M_PHYSICAL_COPIES`

### 3.3 What Is Measured Separately In RTL

After `PT_M_MEM` moved to standard SRAM-backed storage, export timing picked up per-row fetch latency that is easier to validate in RTL than to fold into the lightweight structural model. The perf suite therefore serves as the cycle-accurate ground truth for export request-to-last timing.

## 4. Measured RTL Performance Facts

All numbers below come from [`sim/cocotb/tests/test_pt_perf_cases.py`](../sim/cocotb/tests/test_pt_perf_cases.py) and current passing logs.

### 4.1 Cache-Hit `ctrl_accept -> ctrl_resp`

Measured top-visible latency follows:

- `top_visible_cycles = 9 + internal_total`

Where the constant `9` cycles is the current front-end / issue merge overhead visible at the PT top boundary.

### 4.2 Cold-Miss `ctrl_accept -> ctrl_resp`

Measured top-visible latency follows:

- `top_visible_cycles = 9 + input_phase + internal_total`

With widened A/B loads:

| Mode | Tile | Measured `ctrl_accept -> ctrl_resp` |
| --- | --- | ---: |
| Legacy | `4x4` | 78 cycles |
| Wide | `4x4` | 42 cycles |
| Legacy | `8x8` | 230 cycles |
| Wide | `8x8` | 62 cycles |

This is the most visible gain from widened A/B load beats.

### 4.3 Export `m_dma_req -> m_axis_tlast`

After the standard-SRAM migration, measured export latency follows:

- `req_to_last_cycles = export_beats + X + 1`

The added `X` term is the row-fetch cost through synchronous SRAM-backed export storage.

Measured values:

| Mode | Tile | Export beats | Measured `m_dma_req -> tlast` |
| --- | --- | ---: | ---: |
| Legacy | `4x4` | 16 | 21 cycles |
| Wide | `4x4` | 4 | 9 cycles |
| Legacy | `8x8` | 64 | 73 cycles |
| Wide | `8x8` | 8 | 17 cycles |

## 5. Performance Interpretation

### 5.1 A/B Load Widening

Widening A/B load beats primarily improves cold-miss behavior:

- fewer A/B return beats
- lower fixed protocol overhead per tile
- much shorter `ctrl_accept -> ctrl_resp` on cold misses

It does not materially change cache-hit or retained-M behavior.

### 5.2 M Writeback Widening

Widening `M_WRITE_LANES` reduces the dominant internal writeback term:

- legacy internal writeback cost: `X * Y`
- widened internal writeback cost: `X * ceil(Y / M_WRITE_LANES)`

This is why cache-hit `ctrl_resp` shrinks so aggressively in the wide configuration.

### 5.3 M Export Widening

Widening `M_EXPORT_LANES` reduces export beat count sharply, but the standard-SRAM export path still pays one row-fetch cost per row. That is why the measured export latency is no longer simply `export_beats + 1`.

### 5.4 M Physical-Copy Reduction

Reducing `M_PHYSICAL_COPIES` from `3` to `2` lowers physical write traffic and storage duplication without changing public PT behavior. The tradeoff is that export now shares the same standard SRAM style as retained-M reads, which is exactly why the export pipeline now exposes the synchronous row-fetch term described above.

## 6. Verification Status

The current matrix has been revalidated as follows:

| Suite group | xUnit files | Executed testcases | Failures |
| --- | ---: | ---: | ---: |
| `smoke` | 2 | 12 | 0 |
| `perf` | 4 | 12 | 0 |
| `full` | 23 | 56 | 0 |
| `randomized` | 20 | 20 | 0 |
| `ci` | 23 | 66 | 0 |
| `coverage` | 6 | 66 | 0 |

Backends:

- `smoke/full/randomized/ci/perf` use `icarus`
- `coverage` uses `verilator`

## 7. Coverage Snapshot

Latest coverage metrics from [`coverage_metrics.json`](../sim/cocotb/coverage/coverage/coverage_metrics.json):

- `line(adjusted) = 2072 / 2161 = 95.88%`
- `branch(adjusted) = 108951 / 185900 = 58.61%`
- `expr(adjusted) = 628 / 676 = 92.90%`
- `toggle = 104434 / 180770 = 57.77%`
- `pt_md_v2.v expr(adjusted) = 204 / 228 = 89.47%`

Residual uncovered points are now split into:

- `instrumentation_noise`
- `low_value_bit_toggle`
- `test_gap`

This keeps behavior-relevant gaps visible instead of burying them under declaration-line branch explosions or wide data-bus toggle noise.

## 8. Practical Takeaways

- The wide configuration is now validated end-to-end, not just projected structurally.
- The standard-SRAM migration did not break top-level behavior, but it did make export timing more realistic and slightly more expensive than the earlier idealized path.
- The main next-step choice is not whether widening works; it does. The next decision is whether to:
  - keep the current standard-SRAM export cost,
  - add more aggressive export prefetching,
  - or further widen/overlap memory-side behavior beyond the current knobs.

## 9. Related Artifacts

- Structural model: [`scripts/pt_perf_model.py`](../scripts/pt_perf_model.py)
- Perf-directed tests: [`sim/cocotb/tests/test_pt_perf_cases.py`](../sim/cocotb/tests/test_pt_perf_cases.py)
- Coverage report: [`debug/cocotb/PT/coverage_PASS_20260415.md`](./cocotb/PT/coverage_PASS_20260415.md)
- Architecture overview: [`doc/Processing Tile/README.md`](../doc/Processing%20Tile/README.md)
