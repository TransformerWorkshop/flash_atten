# PT Cocotb Test Environment

## 1. DUT

- DUT: [`PT`](../../../rtl/pt.v)
- Verification style: strict black-box
- Boundary assumptions:
  - drive and observe top-level PT ports only
  - do not read internal hierarchy
  - do not inspect internal SRAM, FIFO, or FSM state directly

## 2. Software Environment

- Python: `3.12.10`
- Interpreter path: `/opt/anaconda3/bin/python3`
- cocotb: `2.0.1`
- Icarus Verilog: `12.0 (stable)`
- `pytest`: not installed
  - cocotb regression still runs correctly
  - logs may include `pytest not found`, which is non-blocking

## 3. Simulation Environment

- Default simulator for main regressions: `icarus`
- Coverage simulator: `verilator`
- Top-level module: `PT`
- Default timescale: `1ns / 1ps`
- cocotb runner entry: [`run.py`](../../../sim/cocotb/run.py)
- Make entry: [`Makefile`](../../../sim/cocotb/Makefile)
- Case catalog: [`pt_case_catalog.py`](../../../sim/cocotb/tests/pt_case_catalog.py)

Canonical environment/model:

- [`pt_blackbox_env.py`](../../../sim/cocotb/tests/pt_blackbox_env.py)
- [`pt_model.py`](../../../sim/cocotb/tests/pt_model.py)

Compatibility wrappers:

- [`pt_blackbox_env_v2.py`](../../../sim/cocotb/tests/pt_blackbox_env_v2.py)
- [`pt_model_v2.py`](../../../sim/cocotb/tests/pt_model_v2.py)

Main testcase files:

- [`test_pt_smoke_cases.py`](../../../sim/cocotb/tests/test_pt_smoke_cases.py)
- [`test_pt_numeric_cases.py`](../../../sim/cocotb/tests/test_pt_numeric_cases.py)
- [`test_pt_qcfg_cases.py`](../../../sim/cocotb/tests/test_pt_qcfg_cases.py)
- [`test_pt_protocol_cases.py`](../../../sim/cocotb/tests/test_pt_protocol_cases.py)
- [`test_pt_protocol_edge_cases.py`](../../../sim/cocotb/tests/test_pt_protocol_edge_cases.py)
- [`test_pt_state_cases.py`](../../../sim/cocotb/tests/test_pt_state_cases.py)
- [`test_pt_backpressure_cases.py`](../../../sim/cocotb/tests/test_pt_backpressure_cases.py)
- [`test_pt_randomized_cases.py`](../../../sim/cocotb/tests/test_pt_randomized_cases.py)
- [`test_pt_stress_cases.py`](../../../sim/cocotb/tests/test_pt_stress_cases.py)
- [`test_pt_csr_cases.py`](../../../sim/cocotb/tests/test_pt_csr_cases.py)
- [`test_pt_perf_cases.py`](../../../sim/cocotb/tests/test_pt_perf_cases.py)
- [`test_pt_coverage_cases.py`](../../../sim/cocotb/tests/test_pt_coverage_cases.py)
- [`test_pt_guard_boot.py`](../../../sim/cocotb/tests/test_pt_guard_boot.py)

## 4. Dimensions And Parameter Sweep

Default parameters from [`run.py`](../../../sim/cocotb/run.py):

- `DATA_WIDTH = 32`
- `EXT_ADDR_W = 32`
- `DMA_BEATS_W = 16`
- `LUT_DEPTH = 8`
- `A_BANK_DEPTH = 8`
- `B_BANK_DEPTH = 16`
- `M_BANK_DEPTH = 16`
- `A_LOAD_LANES = 1` for legacy regression profiles
- `B_LOAD_LANES = 1` for legacy regression profiles
- `M_WRITE_LANES = 1` for legacy regression profiles
- `M_EXPORT_LANES = 1` for legacy regression profiles
- `M_PHYSICAL_COPIES = 3` for legacy regression profiles

Additional widened profiles are used in `perf` and `coverage`:

- `A_LOAD_LANES = GEMM_X_DIM`
- `B_LOAD_LANES = GEMM_Y_DIM`
- `M_WRITE_LANES = GEMM_Y_DIM`
- `M_EXPORT_LANES = GEMM_Y_DIM`
- `M_PHYSICAL_COPIES = 2`

Dimension coverage:

- `2x2`
- `4x4`
- `8x8`
- `20` illegal guard profiles for non-power-of-two dimension checks

## 5. Regression Entry Points

```bash
make -C sim/cocotb clean
make -C sim/cocotb smoke
make -C sim/cocotb full
make -C sim/cocotb ci
make -C sim/cocotb extended
make -C sim/cocotb randomized
make -C sim/cocotb soak
make -C sim/cocotb perf
make -C sim/cocotb coverage
```

## 6. Output Directories

- xUnit results: [`sim/cocotb/results/`](../../../sim/cocotb/results)
- build and test logs: [`sim/cocotb/logs/`](../../../sim/cocotb/logs)
- build directory: [`sim/cocotb/build/`](../../../sim/cocotb/build)
- coverage directory: [`sim/cocotb/coverage/`](../../../sim/cocotb/coverage)

Functional-coverage examples:

- [`sim/cocotb/coverage/coverage/functional_coverage.md`](../../../sim/cocotb/coverage/coverage/functional_coverage.md)
- [`sim/cocotb/coverage/ci/functional_coverage.md`](../../../sim/cocotb/coverage/ci/functional_coverage.md)
- [`sim/cocotb/coverage/soak/functional_coverage.md`](../../../sim/cocotb/coverage/soak/functional_coverage.md)

Residual classification output:

- [`sim/cocotb/coverage/coverage/residual_uncovered.md`](../../../sim/cocotb/coverage/coverage/residual_uncovered.md)

## 7. Current Validation Snapshot

The currently revalidated matrix is:

- `smoke`: `2` files, `12` testcases, `0` failures
- `perf`: `4` files, `12` testcases, `0` failures
- `full`: `23` files, `56` testcases, `0` failures
- `randomized`: `20` files, `20` testcases, `0` failures
- `ci`: `23` files, `66` testcases, `0` failures
- `coverage`: `6` files, `66` testcases, `0` failures

Additional notes:

- `full_pow2_guard_<profile>_seed10.xml` files are synthetic PASS records from the runner
- the raw logs still show time-zero fatal hits from the PT power-of-two guard, which is the intended behavior

## 8. Related Documents

- PT black-box requirements: [pt_cocotb_blackbox_test_requirements.md](../../../doc/pt_cocotb_blackbox_test_requirements.md)
- Historical summary: [summary_20260413.md](./summary_20260413.md)
- Latest repair log: [pt_v2_cold_miss_fix_20260414_173023.md](./pt_v2_cold_miss_fix_20260414_173023.md)
- Latest coverage report: [coverage_PASS_20260415.md](./coverage_PASS_20260415.md)
- Performance iteration note: [20260414_pt_perf_upgrade_eval.md](../../20260414_pt_perf_upgrade_eval.md)
