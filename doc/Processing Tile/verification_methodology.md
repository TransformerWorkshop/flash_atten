# Processing Tile Verification Methodology

This document is the canonical verification overview for the current PT black-box cocotb environment.

## 1. DUT Boundary

- DUT: [`PT`](../../rtl/pt.v)
- Verification style: strict black-box
- Allowed observations:
  - top-level `ctrl_*`
  - top-level `s_axis_*`
  - top-level `m_axis_*`
  - top-level `dma_req_*`
  - top-level `m_dma_req_*`
  - top-level `irq`
- Not relied on:
  - hierarchical internal state
  - direct SRAM array inspection
  - white-box FSM assertions

The reference model reconstructs expected behavior from public PT ports only.

## 2. Test Environment Architecture

Core entry points:

- Runner: [`sim/cocotb/run.py`](../../sim/cocotb/run.py)
- Make entry: [`sim/cocotb/Makefile`](../../sim/cocotb/Makefile)
- Shared environment: [`sim/cocotb/tests/pt_blackbox_env.py`](../../sim/cocotb/tests/pt_blackbox_env.py)
- Reference model: [`sim/cocotb/tests/pt_model.py`](../../sim/cocotb/tests/pt_model.py)
- Case catalog: [`sim/cocotb/tests/pt_case_catalog.py`](../../sim/cocotb/tests/pt_case_catalog.py)

Compatibility note:

- `*_v2.py` environment/model files are compatibility wrappers only
- The canonical environment/model are:
  - [`sim/cocotb/tests/pt_blackbox_env.py`](../../sim/cocotb/tests/pt_blackbox_env.py)
  - [`sim/cocotb/tests/pt_model.py`](../../sim/cocotb/tests/pt_model.py)

Environment responsibilities:

- `PTBlackBoxEnv` drives `ctrl_*`, widened A/B stream traffic, DMA ready/error behavior, and M export backpressure
- `PTBlackBoxModel` predicts cache behavior, `LOAD` outcomes, `MATMUL`, `MATADD`, export contents, and expected responses from current RTL semantics
- Monitors validate:
  - `dma_req_kind/id`
  - `ctrl_resp`
  - `m_axis_tdata/tstrb/tkeep/tid/tdest/tuser/tlast`
  - `irq` count

The environment is protocol-aware and validates transport metadata as well as payload values.

## 3. Regression Taxonomy

### 3.1 Smoke

- Typical legal flows
- Main `CFG/QCFG/LOAD -> MATMUL -> MATADD -> hit` sequencing
- Primary file:
  - [`test_pt_smoke_cases.py`](../../sim/cocotb/tests/test_pt_smoke_cases.py)

### 3.2 Numeric

- Numeric correctness, rounding, saturation, and sign behavior
- `2x2`, `4x4`, and `8x8`
- Primary file:
  - [`test_pt_numeric_cases.py`](../../sim/cocotb/tests/test_pt_numeric_cases.py)

### 3.3 QCFG

- All supported granularity modes
- Payload count, scale-index mapping, and numeric effect
- Primary file:
  - [`test_pt_qcfg_cases.py`](../../sim/cocotb/tests/test_pt_qcfg_cases.py)

### 3.4 Protocol And Edge/Error Handling

- Illegal opcode
- Illegal `MATMUL`, `MATADD`, and `LOAD` encodings
- Illegal `QCFG` qtype or granularity
- Payload ID mismatch
- Wrong `s_axis_tuser`
- DMA before-, mid-, and after-stream errors
- Primary files:
  - [`test_pt_protocol_cases.py`](../../sim/cocotb/tests/test_pt_protocol_cases.py)
  - [`test_pt_protocol_edge_cases.py`](../../sim/cocotb/tests/test_pt_protocol_edge_cases.py)

### 3.5 State And `clear`

- Default state before and after `clear`
- Base-register hi/lo behavior
- Cache invalidation and M-buffer invalidation after `clear`
- Recovery after `clear`
- Primary file:
  - [`test_pt_state_cases.py`](../../sim/cocotb/tests/test_pt_state_cases.py)

### 3.6 Backpressure

- `dma_req_ready`
- `m_dma_req_ready`
- `m_axis_tready`
- `s_axis_valid`
- Multiple disturbance patterns and phase shifts
- Primary file:
  - [`test_pt_backpressure_cases.py`](../../sim/cocotb/tests/test_pt_backpressure_cases.py)

### 3.7 Randomized

- Named traffic profiles
- Mixed legal, cache-hit, error, export-error, and backpressure activity
- Fixed seeds for reproducibility
- Primary file:
  - [`test_pt_randomized_cases.py`](../../sim/cocotb/tests/test_pt_randomized_cases.py)

### 3.8 Directed Stress / CI

- Queue-fill and control admission pressure
- `slot_scan` hit/free/full behavior
- Near-full capacity rejection
- Clear-phase recovery and re-entry
- Primary files:
  - [`test_pt_stress_cases.py`](../../sim/cocotb/tests/test_pt_stress_cases.py)
  - [`test_pt_csr_cases.py`](../../sim/cocotb/tests/test_pt_csr_cases.py)

### 3.9 Performance

- Cache-hit `ctrl_accept -> ctrl_resp` scaling with `M_WRITE_LANES`
- Cold-miss `ctrl_accept -> ctrl_resp` scaling with `A_LOAD_LANES/B_LOAD_LANES`
- Cold-miss export `m_dma_req -> m_axis_tlast` scaling with `M_EXPORT_LANES`
- Primary file:
  - [`test_pt_perf_cases.py`](../../sim/cocotb/tests/test_pt_perf_cases.py)

### 3.10 Coverage

- Coverage-only closure tests
- Legacy-width and widened-width coverage runs
- Verilator coverage artifact generation and residual classification
- Primary file:
  - [`test_pt_coverage_cases.py`](../../sim/cocotb/tests/test_pt_coverage_cases.py)

The suites are organized by proof objective rather than by RTL file ownership.

## 4. Behavior-To-Suite Mapping

| Behavior | Primary suites |
| --- | --- |
| `CFG` and base updates | smoke, state, coverage |
| `QCFG` header/payload/commit paths | qcfg, protocol, coverage |
| Explicit `LOAD` success/error and reuse | smoke, protocol, coverage, ci |
| Widened A/B load tail handling | perf, coverage |
| A/B cache hit and miss behavior | smoke, protocol-edge, randomized, ci |
| `MATMUL` numeric correctness | numeric, smoke |
| `MATADD` chaining and B/C residency interactions | smoke, protocol, backpressure, coverage, ci |
| Export sideband, ordering, and export error response | smoke, protocol, backpressure, coverage, perf |
| No deadlock under backpressure | backpressure, randomized |
| Recovery after `clear` | state, ci |
| Power-of-two build guards | full negative profiles, ci negative profiles |

## 5. Coverage Intent

### 5.1 Functional/Protocol Intent

- Every major `PT_MD_V2` fill/export path is exercised
- `PT_MALLOC` slot scan, LUT miss/hit/full, and overwrite/reload behavior are exercised
- `PT_CE_V2` `MATMUL` and `MATADD` paths are exercised, including widened M writeback
- Widened A/B load tails, wrong-`tuser`, and DMA error interaction are exercised
- Widened export request/stream timing and error response paths are exercised
- QCFG stay/commit/error behavior is covered
- `clear` is exercised across multiple control phases

### 5.2 Numeric Intent

- Typical dense and sparse tiles
- Monotonic and constant patterns
- Saturation boundaries
- Rounding ties
- Positive and negative scale behavior
- Per-tensor, X-wise, Y-wise, and div2 modes

### 5.3 Residual Philosophy

Residual uncovered points are intentionally split into:

- `test_gap`: behavior that still lacks meaningful stimulus
- `instrumentation_noise`: declaration-line or fanout-line branch explosions that do not represent missing behavior coverage
- `low_value_bit_toggle`: wide data-bus bit toggles that are tracked separately from behavior-driven closure

The goal is to keep `test_gap` actionable, not to bury real gaps under low-value instrumentation noise.

## 6. Current Active Regression Matrix

The currently revalidated suite matrix is:

| Suite group | xUnit files | Executed testcases | Failures |
| --- | ---: | ---: | ---: |
| `smoke` | `2` | `12` | `0` |
| `perf` | `4` | `12` | `0` |
| `full` | `23` | `56` | `0` |
| `randomized` | `20` | `20` | `0` |
| `ci` | `23` | `66` | `0` |
| `coverage` | `6` | `66` | `0` |

Latest coverage snapshot from [`coverage_metrics.json`](../../sim/cocotb/coverage/coverage/coverage_metrics.json):

- Overall `expr(adjusted) = 628 / 676 = 92.90%`
- `pt_md_v2.v expr(adjusted) = 204 / 228 = 89.47%`
- Residual classes:
  - `instrumentation_noise = 525`
  - `low_value_bit_toggle = 167`
  - `test_gap = 152730`

Primary output directories remain:

- `sim/cocotb/results/`
- `sim/cocotb/logs/`
- `sim/cocotb/build/`
- `sim/cocotb/coverage/`

## 7. Reproduction

Typical commands:

```bash
make -C sim/cocotb clean
make -C sim/cocotb smoke
make -C sim/cocotb full
make -C sim/cocotb ci
make -C sim/cocotb randomized
make -C sim/cocotb perf
make -C sim/cocotb coverage SIM=verilator
```

Direct runner usage:

```bash
python3 sim/cocotb/run.py smoke --sim icarus
python3 sim/cocotb/run.py full --sim icarus
python3 sim/cocotb/run.py ci --sim icarus
python3 sim/cocotb/run.py randomized --sim icarus
python3 sim/cocotb/run.py perf --sim icarus
python3 sim/cocotb/run.py coverage --sim verilator
```

## 8. Known Blind Spots And Non-Goals

Areas intentionally not treated as primary closure targets yet:

- Long-duration soak maintenance as a day-to-day gate
- Full bit-level toggle closure on wide data buses
- Physical SRAM-content-level validation beyond black-box behavior
- White-box assertions on internal control registers
- Unimplemented `M`-as-`A` `MATMUL` reuse

Residual risk is concentrated in long-duration randomized behavior and the remaining behavior-classified `test_gap` points, not in the documented black-box contract.

## 9. Related Files

- cocotb environment: [`sim/cocotb/tests/pt_blackbox_env.py`](../../sim/cocotb/tests/pt_blackbox_env.py)
- reference model: [`sim/cocotb/tests/pt_model.py`](../../sim/cocotb/tests/pt_model.py)
- case catalog: [`sim/cocotb/tests/pt_case_catalog.py`](../../sim/cocotb/tests/pt_case_catalog.py)
- latest coverage report: [`debug/cocotb/PT/coverage_PASS_20260415.md`](../../debug/cocotb/PT/coverage_PASS_20260415.md)
- performance iteration note: [`debug/20260414_pt_perf_upgrade_eval.md`](../../debug/20260414_pt_perf_upgrade_eval.md)
