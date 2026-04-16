# TPU Cocotb Testbench

This directory contains a cocotb + Verilator black-box testbench for
`comparison/tpu/rtl/tpu_top.v`.

The checked-in `comparison/tpu/rtl` configuration is intentionally trimmed to
the `INT8` / `INT8_INT32` paths that are exercised by this testbench.

## Files

- `tb_tpu_top_64bit.v`: wrapper around `tpu_top` with a minimal AXI master sink
  and observable counters for cocotb.
- `tests/test_tpu_top_64bit.py`: smoke tests and AXI/AXI-Lite helpers.
- `run.py`: cocotb runner entry.
- `Makefile`: common build and smoke targets.

## Usage

From `comparison/tpu/tb`:

```bash
make build
make smoke
make smoke-both
make coverage
make numeric
make numeric-both
make smoke TESTCASE=test_load_abc_and_observe_writeback_activity
```

Or run directly:

```bash
python run.py build --sim verilator
python run.py smoke --sim verilator
python run.py smoke --sim verilator --axi-data-width 128 --ram-data-width 128
python run.py coverage --sim verilator
python run.py numeric --sim verilator
python run.py numeric --sim verilator --axi-data-width 128 --ram-data-width 128
python run.py numeric --sim verilator --variant vanilla_v2 --rtl-root ../../../../tpu_vanilla/third_party/tpu_vanilla-v2-local/rtl --axi-data-width 64 --ram-data-width 64
```

## Current smoke coverage

- Reset defaults and CSR readback.
- AXI-Lite staggered write/readback plus short soft-reset sequence.
- AXI full write bursts for A/B/C load path and end-to-end store/writeback activity.
- Forty numeric cases covering edge, boundary, typical, and randomized INT8 / INT8_INT32 scenarios.
- Functional coverage report output under `comparison/tpu/tb/coverage/`.
