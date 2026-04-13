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
  - internal hierarchical signals
  - internal SRAM contents
  - internal state machine registers

The reference model reconstructs expected behavior from public PT ports only.

## 2. Test Environment Architecture

Core entry points:

- Runner: [`sim/cocotb/run.py`](../../sim/cocotb/run.py)
- Make entry: [`sim/cocotb/Makefile`](../../sim/cocotb/Makefile)
- Shared environment: [`sim/cocotb/tests/pt_blackbox_env.py`](../../sim/cocotb/tests/pt_blackbox_env.py)
- Reference model: [`sim/cocotb/tests/pt_model.py`](../../sim/cocotb/tests/pt_model.py)
- Case catalog: [`sim/cocotb/tests/pt_case_catalog.py`](../../sim/cocotb/tests/pt_case_catalog.py)

Environment responsibilities:

- `PTBlackBoxEnv` drives `ctrl_*`, A/B stream traffic, DMA ready/complete/error behavior, and M export readiness.
- `PTBlackBoxModel` generates expected DMA requests, success responses, error responses, and M export contents based on current RTL semantics.
- Monitors check:
  - `dma_req_tuser/id/ext_addr/local_addr/beats`
  - `ctrl_resp`
  - `m_axis_tdata/tstrb/tkeep/tid/tdest/tuser/tlast`
  - `irq` count

The testbench is intentionally protocol-aware and validates both payload correctness and transport metadata.

## 3. Regression Taxonomy

### 3.1 Smoke

- Typical legal flows
- Covers the main `CFG/QCFG -> miss -> hit -> M-window` sequence
- Primary file:
  - [`test_pt_smoke_cases.py`](../../sim/cocotb/tests/test_pt_smoke_cases.py)

### 3.2 Numeric

- Numeric correctness, rounding, saturation, and sign-flip behavior
- Runs across `2x2`, `4x4`, and `8x8`
- Primary file:
  - [`test_pt_numeric_cases.py`](../../sim/cocotb/tests/test_pt_numeric_cases.py)

### 3.3 QCFG

- Covers every supported granularity
- Checks payload count, scale-index mapping, and numeric effects
- Primary file:
  - [`test_pt_qcfg_cases.py`](../../sim/cocotb/tests/test_pt_qcfg_cases.py)

### 3.4 Protocol And Error

- Illegal opcode
- Illegal `MATMUL` encoding
- Illegal `QCFG` qtype or granularity
- Payload ID mismatch
- Wrong `s_axis_tuser`
- DMA before-, mid-, and after-stream errors
- Primary files:
  - [`test_pt_protocol_cases.py`](../../sim/cocotb/tests/test_pt_protocol_cases.py)
  - [`test_pt_protocol_edge_cases.py`](../../sim/cocotb/tests/test_pt_protocol_edge_cases.py)

### 3.5 State And `clear`

- Default state before and after `clear`
- A/B base hi/lo behavior
- Cache and M-window invalidation after `clear`
- Recovery and re-run after `clear`
- Primary file:
  - [`test_pt_state_cases.py`](../../sim/cocotb/tests/test_pt_state_cases.py)

### 3.6 Backpressure

- `dma_req_ready`
- `m_dma_req_ready`
- `m_axis_tready`
- `s_axis_valid`
- Multiple fixed disturbance patterns and phase-shifted ready/valid interactions
- Primary file:
  - [`test_pt_backpressure_cases.py`](../../sim/cocotb/tests/test_pt_backpressure_cases.py)

### 3.7 Randomized

- Named traffic profiles
- Mixed legal, hit, mwindow, qcfg, error, export-error, and backpressure activity
- Fixed seeds for reproducibility
- Primary file:
  - [`test_pt_randomized_cases.py`](../../sim/cocotb/tests/test_pt_randomized_cases.py)

### 3.8 Coverage

- Targeted closure for state and edge-path holes
- Includes Verilator coverage artifact generation
- Primary file:
  - [`test_pt_coverage_cases.py`](../../sim/cocotb/tests/test_pt_coverage_cases.py)

The suites are organized by behavioral proof objective, not by RTL submodule.

## 4. Behavior-To-Suite Mapping

| Behavior | Primary suites |
| --- | --- |
| `CFG` and base updates | smoke, state, coverage |
| `QCFG` session and commit | qcfg, protocol, coverage |
| A/B cache hit and miss behavior | smoke, protocol-edge, randomized |
| M-window reuse | smoke, protocol-edge, randomized |
| `MATMUL` numeric correctness | numeric, smoke |
| No deadlock under backpressure | backpressure, randomized |
| Export sideband and ordering | smoke, protocol, backpressure |
| Secondary export error response | protocol, randomized, coverage |
| Recovery after `clear` | state |
| Power-of-two guard | guard boot, full negative profiles |

## 5. Coverage Intent

### 5.1 Functional And Protocol Intent

- Every `PT_MD` main state and export substate is hit at least once.
- Every `PT_CE` main state and A/B/M operand-source combination is hit.
- `QCFG` stay, commit, and error branches are all exercised.
- Mixed A/B `hit/miss/M-window` combinations are exercised.
- Wrong `tuser`, DMA error, and export error are all exercised.
- The effect of `clear` on cache, CSR state, and M-buffer lifetime is exercised.

### 5.2 Numeric Intent

- Typical matrices
- Sparse matrices
- Monotonic patterns
- Constant matrices
- Saturation boundaries
- Rounding ties
- Positive and negative scale combinations
- X-wise, Y-wise, and div2 granularity modes

### 5.3 Export And Sideband Intent

- Row-major ordering
- `m_axis_tlast`
- `m_axis_tuser == buffer`
- `m_axis_tstrb` all ones
- `m_axis_tkeep == 1`
- `m_axis_tid == 0`
- `m_axis_tdest == 0`

The methodology intentionally validates metadata semantics, not just payload values.

## 6. Current Baseline

Based on the current repository baseline documents and result directories:

- Total xUnit files: `73`
- Executed testcases: `546`
- Failures: `0`
- Skipped: `0`

Primary output directories:

- `sim/cocotb/results/`
- `sim/cocotb/logs/`
- `sim/cocotb/build/`
- `sim/cocotb/coverage/`

Supplementary run notes remain in:

- [`debug/cocotb/PT/tb_env.md`](../../debug/cocotb/PT/tb_env.md)
- [`debug/cocotb/PT/summary_20260413.md`](../../debug/cocotb/PT/summary_20260413.md)

This document defines methodology. Detailed one-off run artifacts remain in `debug/cocotb/PT/`.

## 7. Reproduction

Standard commands:

```bash
make -C sim/cocotb clean
make -C sim/cocotb smoke
make -C sim/cocotb full
make -C sim/cocotb extended
make -C sim/cocotb randomized
make -C sim/cocotb coverage
```

Common parameters:

```bash
make -C sim/cocotb smoke SIM=icarus
make -C sim/cocotb full SEED=10
make -C sim/cocotb randomized WAVES=1 VERBOSE=1
make -C sim/cocotb coverage SEED=10
```

## 8. Known Blind Spots And Non-Goals

Areas that are not yet expanded into a standalone long-term baseline include:

- Full long-term maintenance of multi-seed `extended` baselines
- Longer delay sweeps on the successful `dma_done` path
- Extreme control-queue depth stress
- Physical SRAM-content-level validation
- White-box assertions on internal state registers

The goal of this document is to explain what the current black-box verification proves, not to claim exhaustive coverage of every implementation-space possibility.

Residual risk mainly sits in long-duration stress and implementation-internal observability, not in the documented black-box contract.

## 9. Related Files

- cocotb environment: [`sim/cocotb/tests/pt_blackbox_env.py`](../../sim/cocotb/tests/pt_blackbox_env.py)
- reference model: [`sim/cocotb/tests/pt_model.py`](../../sim/cocotb/tests/pt_model.py)
- case catalog: [`sim/cocotb/tests/pt_case_catalog.py`](../../sim/cocotb/tests/pt_case_catalog.py)
- old environment note: [`debug/cocotb/PT/tb_env.md`](../../debug/cocotb/PT/tb_env.md)
