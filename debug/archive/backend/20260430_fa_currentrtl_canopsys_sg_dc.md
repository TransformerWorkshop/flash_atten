# FA Current RTL Canopsys SpyGlass/DC Run - 2026-04-30

## Context

- Local repository: `/Users/yucheng/Documents/GitHub/flash_atten`
- Local HEAD synced to remote RTL: `d613450`
- Remote host: `ic-canopsys`
- Remote project: `/home/host/Desktop/flash_atten`
- Top: `FA_TOP_BASELINE`
- Request target: `200MHz`, check against `2M` NAND2-equivalent gate target.
- Action taken before runs: synced local `rtl/` into remote `/home/host/Desktop/flash_atten/synopsys/rtl/` without deleting remote-only support RTL.

## Remote SpyGlass

- Flow: `/home/host/Desktop/flash_atten/synopsys/spyglass/flow/fa_top_baseline_lint.prj`
- File list: `/home/host/Desktop/flash_atten/synopsys/spyglass/flow/fa_top_baseline_only.f`
- Goal: `lint/lint_rtl`
- Log: `/home/host/Desktop/flash_atten/synopsys/spyglass/logs/fa_top_baseline_lint_20260430_004550_currentrtl.log`
- Consolidated reports:
  `/home/host/Desktop/flash_atten/synopsys/spyglass/flow/fa_top_baseline_lint/consolidated_reports/FA_TOP_BASELINE_lint_lint_rtl/`
- Result: completed with warnings, exit code `0`

| Stage | Errors | Warnings | Infos |
| --- | ---: | ---: | ---: |
| Command-line read | 0 | 0 | 0 |
| Design Read | 0 | 1 | 2 |
| Blackbox Resolution | 0 | 0 | 0 |
| SGDC Checks | 0 | 0 | 0 |
| Policy lint | 0 | 89 | 2 |
| Policy starc2005 | 0 | 28 | 0 |
| Total | 0 | 118 | 4 |

## Remote DC Compile

- Flow: `/home/host/Desktop/flash_atten/synopsys/dc/flow/fa_top_baseline_compile_current_8core_20260428_113000_gemm4x16_synrtl_8core_clean.tcl`
- Log: `/home/host/Desktop/flash_atten/synopsys/dc/logs/fa_top_baseline_compile_ultra_20260430_004807_currentrtl.log`
- Constraint stack: `base.sdc` sources `clocks.sdc` and `io_delay_placeholder.sdc`
- Clock constraint in `clocks.sdc`: `create_clock -name core_clk -period 5.000`, i.e. `200MHz`
- Compile command in flow: `compile_ultra -no_autoungroup`
- Remote archive of previous fixed report/result dirs:
  `/home/host/Desktop/flash_atten/synopsys/dc/archive/20260430_004807_currentrtl/`

### Status

DC completed analyze/elaboration/link and started top-level `compile_ultra`, then failed during `Beginning Pass 1 Mapping` with:

```text
Error: Insufficient virtual memory. Please increase swap space, or reduce other processes on this host. (OPT-1603)
Fatal: Internal system error, cannot recover.
```

Runtime snapshot captured by DC:

```text
/home/host/Desktop/flash_atten/synopsys/dc/work/current/crte_000010453.txt
```

Observed memory pressure in the run log shortly before fatal:

```text
Mem: 31G total, 27G used, 227M free, 4.0G buff/cache, 3.8G available
Swap: 7.9G total, 264K used
```

The DC process was no longer running when checked after the fatal exit. Per request, no lighter compile flow was selected and no old process cleanup was performed.

## Report Freshness

Fresh files from this DC attempt:

| Path | Timestamp |
| --- | --- |
| `/home/host/Desktop/flash_atten/synopsys/dc/reports/FA_TOP_BASELINE/check_design.rpt` | Apr 30 00:55 |
| `/home/host/Desktop/flash_atten/synopsys/dc/reports/FA_TOP_BASELINE/unresolved_refs.rpt` | Apr 30 00:55 |

The following fixed-path compile reports remain from the previous Apr 28 run and are not valid as results for this Apr 30 current-RTL attempt:

| Path | Timestamp |
| --- | --- |
| `/home/host/Desktop/flash_atten/synopsys/dc/reports/FA_TOP_BASELINE/compile_qor.rpt` | Apr 28 12:12 |
| `/home/host/Desktop/flash_atten/synopsys/dc/reports/FA_TOP_BASELINE/compile_area.rpt` | Apr 28 12:12 |
| `/home/host/Desktop/flash_atten/synopsys/dc/reports/FA_TOP_BASELINE/compile_timing.rpt` | Apr 28 12:12 |
| `/home/host/Desktop/flash_atten/synopsys/dc/reports/FA_TOP_BASELINE/compile_check_design.rpt` | Apr 28 12:12 |
| `/home/host/Desktop/flash_atten/synopsys/dc/reports/FA_TOP_BASELINE/post_compile_reference.rpt` | Apr 28 12:12 |

## NAND2 Target Status

- SpyGlass: pass with warnings, `0` errors.
- DC: no fresh post-compile area/timing/QoR reports were produced because `compile_ultra` fataled in mapping.
- Current Apr 30 run therefore does not produce a fresh NAND2-equivalent gate count.
- The `2M` NAND2 target is not re-confirmed by this run.

## 48G VM DC Rerun - 2026-04-30 16:16 CST

### Setup

- VM memory after reboot/config change: `46G` visible to Linux, `7.9G` swap.
- Remote run tag: `20260430_161604_full_ultra_area_timing_48g_rerun`
- Flow reused:
  `/home/host/Desktop/flash_atten/synopsys/dc/flow/fa_top_baseline_compile_20260430_153143_full_ultra_area_timing_48g.tcl`
- Log:
  `/home/host/Desktop/flash_atten/synopsys/dc/logs/fa_top_baseline_compile_20260430_161604_full_ultra_area_timing_48g_rerun.log`
- Memory monitor:
  `/home/host/Desktop/flash_atten/synopsys/dc/logs/fa_top_baseline_compile_20260430_161604_full_ultra_area_timing_48g_rerun_mem.log`
- Archive of previous fixed report/result dirs:
  `/home/host/Desktop/flash_atten/synopsys/dc/archive/20260430_161604_full_ultra_area_timing_48g_rerun/`
- Local RTL hashes matched remote `/home/host/Desktop/flash_atten/synopsys/rtl/` for the current local `rtl/` files before the run.
- Local `./scripts/synth_sanity.sh` passed before the DC run completed.

### Constraints Used

- `base.sdc` sourced `clocks.sdc` and `io_delay_placeholder.sdc`.
- Clock: `create_clock -name core_clk -period 5.000`, i.e. `200MHz`.
- Clock uncertainty: setup `0.100`, hold `0.050`.
- Generic IO delay: input/output `0.500`.
- Design rule constraints: `set_max_transition 0.250`, `set_max_capacitance 0.200`.
- Area target in DC script:
  `set_max_area 588000`, equivalent to `2,000,000 * 0.294` NAND2 area.

### Completion

DC completed successfully:

```text
==== FA_TOP_BASELINE compile complete ====
Memory usage for this session 3159 Mbytes.
Memory usage for this session including child processes 9002 Mbytes.
CPU usage for this session 7921 seconds ( 2.20 hours ).
Elapsed time for this session 2759 seconds ( 0.77 hours ).
```

No `Error:`, `Fatal:`, or `OPT-1603` occurred in the rerun log. Swap remained `0B` used in the memory monitor.

Fresh report/result timestamps:

| File | Timestamp |
| --- | --- |
| `compile_qor.rpt` | Apr 30 17:01 |
| `compile_area.rpt` | Apr 30 17:01 |
| `compile_timing.rpt` | Apr 30 17:01 |
| `compile_check_design.rpt` | Apr 30 17:01 |
| `post_compile_reference.rpt` | Apr 30 17:01 |
| `FA_TOP_BASELINE_compile.ddc` | Apr 30 17:02 |
| `FA_TOP_BASELINE_compile.v` | Apr 30 17:02 |

### Timing

From `compile_qor.rpt`:

| Item | Result |
| --- | ---: |
| Clock period | `5.00 ns` |
| Critical path length | `4.90 ns` |
| Setup WNS | `0.00 ns` |
| Setup TNS | `0.00 ns` |
| Setup violating paths | `0` |
| Hold WNS | `0.00 ns` |
| Hold TNS | `0.00 ns` |
| Hold violating paths | `2` |

The top reported setup paths in `compile_timing.rpt` are MET at `0.00 ns`, mainly from `u_core/u_oacc_update/*` registers into `oacc_row_wr_data_reg[*]`.

### Area And NAND2

From `compile_area.rpt`:

| Item | Area |
| --- | ---: |
| Combinational area | `296542.904462` |
| Noncombinational area | `197738.128305` |
| Buf/Inv area | `11413.961741` |
| Macro/Black Box area | `0.000000` |
| Total cell area | `494281.032767` |

NAND2 equivalent using `0.294` area per NAND2:

- `494281.032767 / 0.294 = 1681228.003`, about `1.68M` NAND2.
- Target: `< 2.00M` NAND2, equivalent area `< 588000`.
- Margin: `93718.967233` area units, about `318772` NAND2.
- Status: meets the 2M NAND2 area target in this DC run.

Largest area blocks:

| Hierarchy | Area | Percent |
| --- | ---: | ---: |
| `u_core/u_qk_pv_core` | `143718.5679` | `29.1%` |
| `u_core/u_qk_pv_core/u_gemm` | `126889.5178` | `25.7%` |
| `u_core/u_oacc_update` | `76046.7259` | `15.4%` |
| `u_core/u_oacc_buf` | `46338.4182` | `9.4%` |
| `u_core/u_oacc_buf/u_mem` | `44681.8262` | `9.0%` |
| `u_core/u_q_buf` | `43855.9802` | `8.9%` |
| `u_core/u_k_buf` | `43853.5302` | `8.9%` |

### Remaining Caveats

- QoR reports `49` nets with violations, all `Max Trans Violations`; `Max Cap Violations` is `0`.
- DC reports one high-fanout clock net:
  `u_core/u_qk_pv_core/u_gemm/gen_gemu_row[3].gen_gemu_col[15].gemu_unit/clk`
  with `114513` loads. DC uses fanout `1000` for delay calculations involving this net.
- `compile_check_design.rpt` has `0` errors and `284732` warnings, dominated by `LINT-28` unconnected ports (`280843`) and `LINT-32` constant nets (`3889`).
- Verilog writeout emitted `VO-11` warnings for auto-added `SYNOPSYS_UNCONNECTED_` nets; review naming/connection cleanup before signoff-quality netlist handoff.
