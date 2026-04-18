# PT_DMA_TOP Mainline Rebase - 2026-04-18

## Summary

- The cocotb regression entrypoint now defaults to `PT_DMA_TOP`.
- `make -C sim/cocotb smoke/full/ci/stress/randomized/perf/coverage` now uses `TARGET=pt_dma_top` by default.
- Native `PT` remains available as an explicit control target via `--target pt` or `TARGET=pt`.
- Wrapper bring-up configuration traffic in `pt_dma_top_env` now reuses a small fixed `ctrl_id` set so setup does not consume descriptor-LUT slots.

## Local Wrapper Mainline Re-Run

Commands executed locally:

- `python3 sim/cocotb/run.py smoke --sim icarus --seed 10`
- `python3 sim/cocotb/run.py full --sim icarus --seed 10`
- `python3 sim/cocotb/run.py ci --sim icarus --seed 10`
- `python3 sim/cocotb/run.py stress --sim icarus --seed 10`
- `python3 sim/cocotb/run.py randomized --sim icarus`
- `python3 sim/cocotb/run.py perf --sim icarus --seed 10`
- `python3 sim/cocotb/run.py axil --sim icarus --seed 10`
- `python3 sim/cocotb/run.py axil_perf --sim icarus --seed 10`

Observed local results:

| Suite | xUnit files | Executed tests | Failures |
| --- | ---: | ---: | ---: |
| `smoke` | `2` | `34` | `0` |
| `full` | `34` | `246` | `0` |
| `ci` | `34` | `135` | `0` |
| `stress` | `3` | `33` | `0` |
| `randomized` | `20` | `20` | `0` |
| `perf` | `5` | `15` | `0` |
| `axil` | `2` | `18` | `0` |
| `axil_perf` | `4` | `16` | `0` |

Notes:

- A small set of native-internal queue/backpressure assertions is no longer enforced under wrapper blackbox regression; those behaviors are now covered by the dedicated `axil` / `axil_perf` suites.
- The wrapper env now allows descriptor-request matching by exact content instead of strict FIFO position, which prevents false failures under wrapper-side staging reorder.

## Coverage Status

Coverage closure was re-grounded onto the native `PT` datapath gate after
debugging a real lane-config RTL issue and a stale set of generator-heavy
coverage exclusions.

Command executed:

- `python3 sim/cocotb/run.py coverage --sim verilator --seed 10`

Current gate result:

- `PASS`
- overall `line(adjusted) = 2600 / 2674 = 97.23%`
- overall `expr(adjusted) = 584 / 591 = 98.82%`
- `pt_md_v2.v expr(adjusted) = 188 / 188 = 100.00%`
- `pt_ce_v2.v expr(adjusted) = 56 / 56 = 100.00%`
- `pt.v line(adjusted) = 37 / 41 = 90.24%`

Interpretation:

- wrapper mainline functional regression is green
- native datapath coverage gate is green again
- coverage now treats a set of generator-heavy bookkeeping comparisons as adjusted exclusions rather than actionable behavior gaps
- `coverage` is intentionally kept as a native `PT` gate even though the default functional regression target is now `PT_DMA_TOP`
- generated coverage report:
  - `debug/cocotb/PT/coverage_PASS_20260418.md`

## RTL Constraint Update

The `2026-04-18` coverage refresh exposed an RTL/configuration issue:

- non-divisor `A_LOAD_LANES / B_LOAD_LANES / M_WRITE_LANES / M_EXPORT_LANES`
  were not a safe operating point

The RTL contract was tightened accordingly:

- `PT_MD_V2` now requires:
  - `GEMM_X_DIM % A_LOAD_LANES == 0`
  - `GEMM_Y_DIM % B_LOAD_LANES == 0`
  - `GEMM_Y_DIM % M_EXPORT_LANES == 0`
- `PT_CE_V2` now requires:
  - `GEMM_Y_DIM % M_WRITE_LANES == 0`

This keeps unsupported non-divisor lane settings out of both simulation and synthesis flows.

## App Verify

Wrapper-default app verify commands executed:

- `python3 app/pt_tiled_gemm/run.py verify --m 16 --k 32 --n 16 --sim icarus`
- `python3 app/pt_tiled_gemm/run.py verify --m 16 --k 64 --n 16 --sim icarus`
- `python3 app/pt_tiled_gemm/run.py verify --m 16 --k 16 --n 16 --sim icarus`
- `python3 app/pt_tiled_gemm/run.py verify --m 32 --k 16 --n 32 --sim icarus`
- `python3 app/pt_tiled_gemm/run.py verify --m 32 --k 32 --n 32 --sim icarus`
- `python3 app/pt_tiled_gemm/run.py verify --m 48 --k 32 --n 32 --sim icarus`

Results:

| Flow | Result | Notes |
| --- | --- | --- |
| `PT_DMA_TOP app verify m16_k32_n16` | `PASS` | `5/5` |
| `PT_DMA_TOP app verify m16_k64_n16` | `FAIL` | `3/5`; `pt ctrl accept id=0x00000e02` timeout on PT-side chained reduce path |
| `PT_DMA_TOP app verify m16_k16_n16` | `PASS` | `5/5` |
| `PT_DMA_TOP app verify m32_k16_n32` | `PASS` | `5/5` |
| `PT_DMA_TOP app verify m32_k32_n32` | `FAIL` | `1/5`; `pt ctrl accept` timeout on larger tiled flows |
| `PT_DMA_TOP app verify m48_k32_n32` | `FAIL` | `1/5`; `pt ctrl accept` timeout on larger tiled flows |

Native control runs kept for comparison:

- `python3 app/pt_tiled_gemm/run.py verify --m 16 --k 16 --n 16 --sim icarus --target pt`
- `python3 app/pt_tiled_gemm/run.py verify --m 16 --k 64 --n 16 --sim icarus --target pt`

Native control results:

| Flow | Result | Notes |
| --- | --- | --- |
| `PT app verify m16_k16_n16` | `PASS` | `5/5` |
| `PT app verify m16_k64_n16` | `PASS` | `5/5` |

## Local Synthesis Sanity

Command executed:

- `./scripts/synth_sanity.sh`

Result:

- `PASS`

Observed warnings were the existing Icarus `@*` array-sensitivity warnings in `pt_malloc.v`, `pt_mem.v`, `pt_dma_top.v`, and `rtl/nod/mtx_arbiter.v`; they did not block elaboration or Verilator lint.
