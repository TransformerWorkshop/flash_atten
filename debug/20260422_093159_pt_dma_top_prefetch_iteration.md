# PT_DMA_TOP Load-Prefetch Iteration

- Timestamp: `2026-04-22 09:31:59 +0800`
- Branch: `codex-app`
- Commit baseline: `b593d69`

## Scope

- Enable the “best-effort safe” front-end optimization path:
  - allow `LOAD` to issue while compute is busy
  - keep single-port SRAM safe with bank-aware allocator gating
  - overlap software `LOAD(next)` with `MATMUL(cur)` for adapted `PT_DMA_TOP` cases
- Preserve numerical correctness for both native `PT` and `PT_DMA_TOP`
- Re-run remote SpyGlass and DC for the RTL delta

## RTL Changes

Files updated:

- `rtl/pt_dispatch_v2.v`
  - `LOAD` is no longer blocked by `malloc_exec_busy`
  - issue still remains under `malloc_cmd_ready`, so unsafe bank pressure becomes backpressure instead of conflict
- `rtl/pt_malloc.v`
  - allocator now consults the actual per-bank busy counters for A/B
  - busy gating is keyed off `exec_busy && dec_need_{a,b}`
  - this preserves hit semantics and only stalls miss/fill paths
- `rtl/pt_top_v2.v`
  - `PT_MALLOC` now sees the real `ce_resp` instead of `32'd0`
  - this lets bank-busy bookkeeping retire on the real response `id`

## Software / Test Updates

Files updated:

- `app/pt_tiled_gemm/tests/test_pt_multitile_bench.py`
  - added safe two-stage `LOAD(next)` / `MATMUL(cur)` pipeline for `PT_DMA_TOP`
  - only enabled when the logical schedule has more than one command and the ID pool has at least two entries
  - metrics now expose:
    - `load_prefetch_enabled`
    - `logical_command_count`
    - `issued_command_count`
    - `load_prefetch_count`
    - `axil_writes_per_logical_command`
- `sim/cocotb/tests/pt_dma_top_env.py`
  - added `wait_next_ctrl_resp()` to consume FIFO head safely
  - fixed `wr_dma_agent` to snapshot descriptor signals at handshake time before awaiting model-side export expectation
- `app/pt_tiled_gemm/tests/test_pt_tiled_gemm.py`
  - added safe runtime recycling windows for verify algorithms
  - clears happen only on output-tile boundaries, so there is no live-slot reuse and no overrun beyond `LUT_DEPTH=8`

## Local Validation

Static / lint:

- `python3 -m py_compile app/pt_tiled_gemm/tests/test_pt_tiled_gemm.py app/pt_tiled_gemm/tests/test_pt_multitile_bench.py sim/cocotb/tests/pt_dma_top_env.py`
  - `PASS`
- `./scripts/synth_sanity.sh`
  - `PASS`

Numerical regression:

- `python3 app/pt_tiled_gemm/run.py multitile --target pt_dma_top --sim icarus --submission-mode compact --m-tiles 1,2,4 --n-tiles 1,2,4 --k-tiles 1,2,4`
  - `27/27 PASS`
- `python3 app/pt_tiled_gemm/run.py verify --m 16 --k 32 --n 16 --target pt --sim icarus`
  - `PASS`
- `python3 app/pt_tiled_gemm/run.py verify --m 16 --k 32 --n 16 --target pt_dma_top --sim icarus`
  - `PASS`
- `python3 app/pt_tiled_gemm/run.py verify --m 16 --k 64 --n 16 --target pt --sim icarus`
  - `PASS`
- `python3 app/pt_tiled_gemm/run.py verify --m 16 --k 64 --n 16 --target pt_dma_top --sim icarus`
  - `PASS`
- `python3 app/pt_tiled_gemm/run.py verify --m 32 --k 32 --n 32 --target pt --sim icarus`
  - `PASS`
- `python3 app/pt_tiled_gemm/run.py verify --m 32 --k 32 --n 32 --target pt_dma_top --sim icarus`
  - `PASS`
- `python3 app/pt_tiled_gemm/run.py verify --m 48 --k 32 --n 32 --target pt --sim icarus`
  - `PASS`
- `python3 app/pt_tiled_gemm/run.py verify --m 48 --k 32 --n 32 --target pt_dma_top --sim icarus`
  - `PASS`

## Performance

Updated artifact:

- [`multitile_sweep_pt_dma_top_200mhz_gops.md`](/Users/yucheng/Documents/GitHub/flash_atten/app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_200mhz_gops.md)

Key results:

- best measured:
  - `32x64x64 = 24.534 GOPS @ 200MHz`
- `64x64x64`:
  - old baseline: `15.606 GOPS @ 200MHz`
  - current: `24.055 GOPS @ 200MHz`
  - uplift: `+54.1%`

Logical-command bucket averages:

- old baseline:
  - `1 cmd`: `17.062 GOPS`
  - `2 cmds`: `16.800 GOPS`
  - `4 cmds`: `16.761 GOPS`
  - `8 cmds`: `16.447 GOPS`
  - `16 cmds`: `15.606 GOPS`
- current:
  - `1 cmd`: `18.358 GOPS`
  - `2 cmds`: `20.122 GOPS`
  - `4 cmds`: `23.022 GOPS`
  - `8 cmds`: `24.244 GOPS`
  - `16 cmds`: `24.055 GOPS`

Interpretation:

- the old front-end command tax is now mostly hidden behind compute
- current remaining bottleneck is CE + export, not AXI-Lite submission
- on `m4_n4_k4`, the per-case metrics show:
  - `16` logical commands
  - `32` issued commands
  - `6.0` AXI-Lite writes per issued command
  - `12.0` AXI-Lite writes per logical command
  - `2800` cycles in `accept->resp`
  - `2096` cycles in `resp->done`

## Remote Gates

Stage workspace:

- `~/Desktop/flash_atten_stage_20260421_155212`

SpyGlass:

- command:
  - `spyglass -project synopsys/spyglass/flow/pt_dma_top_lint.prj -batch -goals "lint/lint_rtl"`
- report root:
  - `synopsys/spyglass/flow/pt_dma_top_lint/consolidated_reports/PT_DMA_TOP_lint_lint_rtl/`
- result:
  - `0 error / 178 warnings / 4 infos`
- status:
  - no new high-severity issue introduced
  - warning count stayed flat versus the previous cleaned CE-overlap revision

DC:

- log:
  - `synopsys/dc/logs/compile_20260422_084542.log`
- result:
  - setup `WNS/TNS = 0.00 / 0.00`
  - hold `WNS/TNS = -0.12 / -1121.16`
  - area `218325.036228`
  - max-cap violations `1`
- delta vs previous remote reference (`218091.404226`, hold TNS `-1122.22`, max-cap `2`):
  - area `+233.632002` (`+0.11%`)
  - hold TNS slightly improved
  - max-cap improved from `2` to `1`

## Remaining Bottleneck

Priority has shifted:

1. deeper CE / export overlap
2. A/B fill parallelism below the shared MD datapath
3. only after that, larger structural queue surgery

The wrapper front-end is no longer the dominant limiter for adapted `PT_DMA_TOP` cases.
