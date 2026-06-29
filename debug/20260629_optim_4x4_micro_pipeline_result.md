# Optim 4x4 Micro Pipeline Functional Closure

Date: 2026-06-29

Remote run:

- VM: `ic-canopsys` / `host@100.108.220.80`
- Staging path: `/home/host/codex_runs/fa_optim_4x4_micro_20260629_183659`
- Branch: `optim`

## Scope

This milestone lands the first measurable `4*4x4` functional RTL slice for the optim
direction. It is not a 4x16 transition module and it is not an SA-only test.

The active RTL path is:

```text
Q/K local tile -> one 4x4 QK SA lane -> score block
score block -> FA_SCORE_POST_REAL -> shared FA_ROW_STATE_REAL
row-state P tile -> FA_P_BYPASS_REAL -> four 4x4 PV SA lanes
PV partial O -> FA_OACC_UPDATE_REAL -> observable O tile
```

The important architectural interpretation is:

- QK does not require four 4x4 SAs to consume the same SRAM feeder at once.
- QK fills the 4x16 score block by reusing one 4x4 lane across four key groups.
- PV consumes local buffered P plus local V and can use the four 4x4 lanes together.
- The shared score/row-state/OACC path is in the measured RTL path, not mocked out.

## VCS Functional Smoke

Command shape:

```sh
vcs -full64 -sverilog -timescale=1ns/1ps +v2k +incdir+rtl \
  sim/rtl_smoke/fa_optim_4x4_micro_pipeline_tb.v \
  rtl/fa_optim_4x4_micro_pipeline.v \
  rtl/gemm_v3.v rtl/gemu_v3.v \
  rtl/fa_score_post_real.v rtl/fa_row_state_real.v rtl/fa_recip_q16_16.v \
  rtl/fa_p_bypass_real.v rtl/fa_oacc_update_real.v \
  -top fa_optim_4x4_micro_pipeline_tb \
  -o remote_reports/vcs_micro/simv
./remote_reports/vcs_micro/simv
```

Workload:

- Tile shape: `4` query rows, `16` K/V rows, `d=64`
- Input format: Q/K/V signed Q8.8
- Q/K pattern: all zero
- V pattern: `V[k, col] = 0x0100 + k + col`
- Expected behavior: uniform softmax over 16 K rows, PV computes per-column average,
  and OACC writes Q4.12 output words.

Result:

- PASS marker:
  `PASS: fa_optim_4x4_micro_pipeline_tb cycles=347 qk_tasks=128 pv_tasks=128`
- Simulation time: `3506000 ps`
- Counter checks in the bench:
  - `qk_task_count = 128`
  - `score_task_count = 1`
  - `row_state_task_count = 1`
  - `pv_task_count = 128`
  - `oacc_task_count = 1`
- Output checks: all `4 x 64` O words are checked against the expected Q4.12 average.

## Bug Fixed During Landing

The first VCS run compiled but timed out in `ST_QK_DRAIN`:

- State at timeout: `ST_QK_DRAIN`
- QK feeds had completed: `qk_tasks=32` for the first key group
- GEMM output valid never asserted

Root cause:

- `GEMU_V3` still compares `acc_cnt` against `num_acc` while draining.
- The first version drove `gemm_num_acc_r=0` outside feed states, so the PE never saw
  `acc_done`.

Fix:

- Hold `gemm_num_acc_r=32` during QK feed and drain.
- Hold `gemm_num_acc_r=8` during PV feed and drain.

## Current Evidence Boundary

This is current RTL evidence for a measurable functional slice, not a complete
`S=256,d=64` product top. It closes the main gap from the prior scheduler-only result:
the path now includes real numerical QK, score post, shared row-state, P bypass, PV,
OACC, and an observable O tile.

Remaining gaps before a product-level optim claim:

- Tile iteration over all `S=256` Q/KV blocks is not integrated.
- Persistent row-state/OACC lifetime across multiple KV blocks still needs top-level
  scheduling.
- AXI Q/K/V fetch and O writeback are not connected to this micro pipeline.
- The `347` cycle value is a 4-row x 16-KV x 64-D slice result, not complete operator
  latency.
- DC/NAND2 should wait until the functional top/scheduler boundary is complete enough
  to represent the landing architecture.

## Artifact Paths

- VCS compile log:
  `/home/host/codex_runs/fa_optim_4x4_micro_20260629_183659/remote_reports/vcs_micro/compile.log`
- VCS run log:
  `/home/host/codex_runs/fa_optim_4x4_micro_20260629_183659/remote_reports/vcs_micro/run.log`
