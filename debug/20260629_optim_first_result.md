# Optim SRAM RTL Landing First Result

Date: 2026-06-29

Remote run:

- VM: `ic-canopsys` / `host@100.108.220.80`
- Staging path: `/home/host/codex_runs/fa_optim_20260629_155836`
- Local raw evidence copy: `codex/evidence/20260629_optim_remote_first_result/remote_reports`
- Branch: `optim`

## Scope

This is the first storage-native RTL landing result for the 4x4-SA SRAM direction.
It is module-level evidence for `FA_LOCAL_TILE_SRAM_16X64X16`, plus the target
pipeline model rerun on the EDA VM. It is not yet a full `FA_TOP_BASELINE`
replacement result because the new local tile SRAM scaffold is not wired into
the product top scheduler/datapath.

Current RTL evidence:

- `FA_LOCAL_TILE_SRAM_16X64X16` maps a `16 rows x 16 chunks x 64b` logical tile
  onto one `256x64 1RW` SRAM wrapper.
- The process-neutral wrapper name is still `FA_SKY130_SRAM_256X64_1RW`, but
  under `SYNTHESIS` it instantiates the TSMC28 physical substitute
  `TEM5N28HPCPLVTA256X64M4SWSO`.
- The logical contract is kept at `256x64`, synchronous 1-cycle read, active-high
  write mask at the tile-buffer interface, and active-low `BWEB` at the macro.

Target model evidence:

- `model/fa_sa_sram_pipeline_model.py` was rerun on the VM.
- The model remains target architecture evidence, not current product-top RTL
  performance.

## VCS Smoke

Command shape:

```sh
vcs -full64 -sverilog -timescale=1ns/1ps +v2k +incdir+rtl \
  sim/rtl_smoke/fa_local_tile_sram_tb.v \
  rtl/fa_sram_hard.v rtl/fa_sram_tile_buffers.v \
  -top fa_local_tile_sram_tb \
  -o remote_reports/vcs_smoke/simv
./remote_reports/vcs_smoke/simv
```

Result:

- PASS marker: `PASS: fa_local_tile_sram_tb`
- Finish time: `106000 ps`
- Covered behavior: full 64b write, masked low-32b update, 1-cycle read valid,
  and `clear` dropping `rd_valid`.

## TSMC28 SRAM Views

Existing TSMC28 L1 macro package already contains the same-spec substitute views:

- `TEM5N28HPCPLVTA256X64M4SWSO`
- `TEM5N28HPCPLVTA256X32M4SWSO`

The run compiled both NLDM Liberty files to run-local `.db` files with
`lc_shell -f scripts/fa_compile_tsmc_sram_libs.tcl`.

LC result:

- `256x64` `.db`: generated successfully.
- `256x32` `.db`: generated successfully.
- Warnings: `LBDB-366` on `internal_power_calculation` for both NLDM files.
  This is a library metadata warning and did not block DC linking.

## DC Area

Top:

- `FA_LOCAL_TILE_SRAM_16X64X16`

Library setup:

- Stdcell: TSMC28 7T CCS `ffg0p99v0c`
- SRAM: run-local `tem5n28hpcplvta256x64m4swso_110a_ffg0p99v0c.db`
- Clock period requested: `5.0 ns`

Area result:

| Metric | Value |
|---|---:|
| Number of cells | 232 |
| Macro count | 1 |
| Combinational area | 80.555998 |
| Noncombinational area | 1.862000 |
| Macro/Black Box area | 8399.200195 |
| Total cell area | 8481.618194 |

Reference check:

- DC links one real SRAM macro:
  `TEM5N28HPCPLVTA256X64M4SWSO`
- Macro area from SRAM `.db`: `8399.200195`
- Wrapper/control overhead above the raw macro: about `82.418`

QoR/timing notes:

- `Design WNS: 0.00`, `TNS: 0.00`, violating paths `0`.
- `Design (Hold) WNS: 0.00`, `TNS: 0.00`, violating paths `0`.
- The detailed paths are mostly unconstrained IO paths for this standalone
  module-level compile; treat this as mapped area/elaboration evidence, not
  product timing closure.
- DC warnings in the main log:
  - `UISN-40`: DesignWare synthetic library added.
  - `PWR-428`: unannotated black-box outputs for power propagation.

## Performance Model Rerun

Tile count: `136`

| Scenario | Cycles | SA util | Avg active SA | Feeder util | Row-state util |
|---|---:|---:|---:|---:|---:|
| `qk_only_1_feeder` | 2193 | 0.248 | 0.99 | 0.992 | 0.000 |
| `qk_pv_oacc_48_local_cycles` | 2242 | 0.971 | 3.88 | 0.971 | 0.061 |
| `qk_pv_oacc_64_local_cycles` | 2787 | 0.976 | 3.90 | 0.781 | 0.049 |
| `pv_uses_same_feeder` | 4418 | 0.493 | 1.97 | 0.985 | 0.031 |
| `two_feeders_local_post_gemm` | 2211 | 0.984 | 3.94 | 0.492 | 0.062 |
| `shared_row_state_4cy` | 2245 | 0.969 | 3.88 | 0.969 | 0.242 |
| `shared_row_state_32cy` | 4433 | 0.491 | 1.96 | 0.491 | 0.982 |

Buffer sizing contract from the model:

| Buffer | Scope | Bytes |
|---|---|---:|
| Q operand buffer | shared | 512 |
| K operand buffer | per cluster | 512 |
| V operand buffer | per cluster | 512 |
| P tile buffer | per cluster | 32 |
| Row scale buffer | per cluster | 48 |
| PV partial buffer | per cluster | 512 |
| OACC old buffer | per cluster | 512 |
| OACC new buffer | per cluster | 512 |

Totals:

- Per-cluster local buffer: `2640 B`
- Four clusters local buffers: `10560 B`
- Shared Q buffer: `512 B`
- Task queues: `512 B`
- Total modeled local buffer: `11584 B`

Interpretation:

- One feeder only keeps one 4x4 SA cluster busy during QK-only work.
- If PV/OACC use local buffered operands, the same feeder can support about four
  active clusters because follow-on work no longer reuses the feeder.
- If PV reuses the same feeder, SA utilization drops to about `49%`.
- A short shared row-state pipe can be reused by phase staggering. A long
  `32-cycle` row-state pipe becomes the new bottleneck.

## Gaps Before Product-Level Claim

- The SRAM tile primitive is not yet wired into `FA_TOP_BASELINE`.
- No VM cocotb product-top profile was run because the VM default Python lacks
  `cocotb` and `cocotb_tools`.
- The current performance number is still target-model evidence. Product-level
  RTL performance requires scheduler/datapath integration plus VCS/cocotb or a
  plain-Verilog performance bench.
- Product-level area needs a top compile after the new storage path is connected.
