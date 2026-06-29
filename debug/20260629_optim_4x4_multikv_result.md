# Optim 4x4 Micro Pipeline Multi-KV State Lifetime

Date: 2026-06-29

Remote run:

- VM: `ic-canopsys` / `host@100.108.220.80`
- Staging path: `/home/host/codex_runs/fa_optim_4x4_multikv_20260629_185641`
- Branch: `optim`

## Problem Fixed

The previous micro slice treated every `start` as a full operator/tile
initialization. That made the slice unsuitable for a real FlashAttention KV
loop:

- row-state was reinitialized on each `start`;
- `o_tile_flat` was cleared on each `start`;
- OACC read old O as zero, so it could not rescale and accumulate prior KV
  tiles.

This meant a second KV block would overwrite the result instead of performing
online-softmax accumulation:

```text
O_new = O_old * rescale + partial_O_current_kv
```

## RTL Contract

`FA_OPTIM_4X4_MICRO_PIPELINE` now has a tile-lifetime input:

- `first_kv_tile = 1`: first KV tile for the current Q tile. Initialize
  row-state and clear OACC output.
- `first_kv_tile = 0`: subsequent KV tile for the same Q tile. Preserve
  row-state and OACC output, skip row-state initialization, and start QK
  directly.

The OACC read path now returns the current stored row from `o_tile_flat` instead
of zero, allowing `FA_OACC_UPDATE_REAL` to consume the previous accumulated O.

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

- Q rows: `4`
- KV tiles: `2 x 16` rows
- Head dimension: `64`
- Q/K pattern: all zero, producing uniform softmax
- V tile 0: `V[k, col] = 0x0100 + k + col`
- V tile 1: `V[k, col] = 0x0200 + k + col`
- Checks:
  - after tile 0, all `4 x 64` O words are checked;
  - after tile 1, all `4 x 64` O words are checked against the accumulated
    two-tile result;
  - per-start counters are checked for both tiles.

Result:

```text
PASS: fa_optim_4x4_micro_pipeline_tb first_cycles=347 second_cycles=344 qk_tasks=128 pv_tasks=128 two_tile=1
```

Counter interpretation:

- `first_cycles = 347`: first 4-row x 16-KV micro tile, including row-state init.
- `second_cycles = 344`: second 4-row x 16-KV micro tile, preserving row-state
  and OACC.
- `qk_tasks = 128`: per started KV tile, one 4x4 QK lane reused across four
  key groups.
- `pv_tasks = 128`: per started KV tile, four 4x4 lanes used for PV from local
  P/V data.

The `347/344` cycle values are not complete `S=256,d=64` operator latency.
They are focused micro-slice measurements for the state-lifetime fix.

## Quantization Note

The two-tile golden check follows the RTL fixed-point sequence rather than an
infinite-precision 32-key average. OACC emits Q4.12, so odd columns retain the
half-Q8.8 step created by splitting the uniform 32-key average across two 16-key
tiles. The smoke bench checks that exact Q4.12 result.

## Current Evidence Boundary

This closes the key functional gap in the previous micro slice: repeated starts
for later KV tiles no longer destroy row-state or OACC state.

Remaining work before a product-level optim claim:

- drive the micro pipeline from a top scheduler over all Q blocks and all KV
  blocks for `S=256,d=64`;
- connect real Q/K/V SRAM macro banks and load/store sequencing;
- keep the shared row-state/OACC lifetime aligned with the outer Q tile loop;
- only then run DC/NAND2 for the landed top-level architecture.

## Artifact Paths

- VCS compile log:
  `/home/host/codex_runs/fa_optim_4x4_multikv_20260629_185641/remote_reports/vcs_micro/compile.log`
- VCS run log:
  `/home/host/codex_runs/fa_optim_4x4_multikv_20260629_185641/remote_reports/vcs_micro/run.log`
