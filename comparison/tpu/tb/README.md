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
python run.py smoke --sim verilator --axi-data-width 128 --ram-data-width 64
python run.py coverage --sim verilator
python run.py numeric --sim verilator
python run.py numeric --sim verilator --axi-data-width 128 --ram-data-width 64
python run.py numeric --sim verilator --variant vanilla_v2 --rtl-root ../../../../tpu_vanilla/third_party/tpu_vanilla-v2-local/rtl --axi-data-width 64 --ram-data-width 64
```

## Reports

- `PERFORMANCE_REPORT.md`: historical `16x16 / AXI128 / RAM128` comparison results
  versus the `vanilla_v2 8x8 / AXI64 / RAM64` baseline.

## Current smoke coverage

- Reset defaults and CSR readback.
- AXI-Lite staggered write/readback plus short soft-reset sequence.
- AXI full write bursts for A/B/C load path and end-to-end store/writeback activity.
- Sixty-two numeric cases covering edge, boundary, typical, randomized, shape, and compat INT8 / INT8_INT32 scenarios.
- Functional coverage report output under `comparison/tpu/tb/coverage/`.

## Current 16x16 Snapshot

- The checked-in `comparison/tpu/rtl` now runs as a true `16x16` datapath rather
  than a mixed `16x16` wrapper around several `8`-lane internal stages.
- Default testbench configuration is now `AXI128 / RAM64`.
- Local validation status:
  - `make smoke`: `3/3` pass
  - `make numeric`: `62/62` pass
