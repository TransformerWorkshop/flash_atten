# FA Top Baseline Remote SG/DC NAND2 Archive - 2026-04-27

## Context

- Local repository: `/Users/yucheng/Documents/GitHub/flash_atten`
- Branch: `flash_atten`
- Local HEAD: `2a2e4be fa: stream result tiles by row`
- Remote host: `ic-canopsys` (`host@100.108.220.80`)
- Remote project: `/home/host/Desktop/flash_atten`
- Top: `FA_TOP_BASELINE`
- Requirement checked in this archive: `< 2M` NAND2-equivalent gates.

## Remote SpyGlass

- Flow: `synopsys/spyglass/flow/fa_top_baseline_lint.prj`
- Goal: `lint/lint_rtl`
- Log: `/home/host/Desktop/flash_atten/synopsys/spyglass/logs/fa_top_baseline_lint_20260427_214310.log`
- Report dir: `/home/host/Desktop/flash_atten/synopsys/spyglass/flow/fa_top_baseline_lint/consolidated_reports/FA_TOP_BASELINE_lint_lint_rtl/`
- Result: pass with warnings
  - Errors: `0`
  - Warnings: `96`
  - Infos: `3`
  - Exit code: `0`

## Remote DC Compile

- Flow: `synopsys/dc/flow/fa_top_baseline_compile_current.tcl`
- Command style: top-level `compile_ultra` on `FA_TOP_BASELINE`
- Log: `/home/host/Desktop/flash_atten/synopsys/dc/logs/fa_top_baseline_compile_ultra_20260427_214510.log`
- Reports:
  - `/home/host/Desktop/flash_atten/synopsys/dc/reports/FA_TOP_BASELINE/compile_qor.rpt`
  - `/home/host/Desktop/flash_atten/synopsys/dc/reports/FA_TOP_BASELINE/compile_area.rpt`
  - `/home/host/Desktop/flash_atten/synopsys/dc/reports/FA_TOP_BASELINE/compile_timing.rpt`
  - `/home/host/Desktop/flash_atten/synopsys/dc/reports/FA_TOP_BASELINE/compile_check_design.rpt`
  - `/home/host/Desktop/flash_atten/synopsys/dc/reports/FA_TOP_BASELINE/post_compile_reference.rpt`
- Results:
  - `/home/host/Desktop/flash_atten/synopsys/dc/results/FA_TOP_BASELINE/FA_TOP_BASELINE_compile.ddc`
  - `/home/host/Desktop/flash_atten/synopsys/dc/results/FA_TOP_BASELINE/FA_TOP_BASELINE_compile.v`

### Area

| Item | Area |
|---|---:|
| Combinational area | `517110.524072` |
| Noncombinational area | `174515.556939` |
| Buf/Inv area | `25353.775415` |
| Macro/Black Box area | `713773.046875` |
| Total cell area | `1405399.127886` |

### NAND2 Equivalent

- NAND2 reference queried from DC target library:
  - Cell: `tcbn28hpcplusbwp7t40p140ffg0p99v0c_ccs/ND2D0BWP7T40P140`
  - Area: `0.294`
- Current NAND2 equivalent:
  - `1405399.127886 / 0.294 = 4780269.142`
  - About `4.78M` NAND2
- Requirement target:
  - `< 2M` NAND2
  - Equivalent total cell area target: `< 588000.000`
- Status:
  - Not met
  - Current area is about `2.39x` the target
  - Required reduction from current result: about `817399.128` area units, or about `2.78M` NAND2

### Timing And Design Rules

From `compile_qor.rpt`:

- Setup:
  - WNS: `0.00`
  - TNS: `0.00`
  - Violating paths: `0`
- Hold:
  - WNS: `0.05`
  - TNS: `142.19`
  - Violating paths: `5639`
- Design rules:
  - Nets with violations: `219`
  - Max transition violations: `219`
  - Max cap violations: `0`

Important DC warning:

- `FA_TOP_BASELINE` contains one high-fanout net:
  - `u_core/u_qk_pv_core/u_pv_result_rows/gen_chunk[1].u_sram/clk`
  - `93994` loads
  - DC used fanout number `1000` for delay calculations involving this net.

### Top Area Hotspots

| Hierarchy | Area | Percent | NAND2 equiv approx |
|---|---:|---:|---:|
| `u_core/u_qk_pv_core` | `667983.6045` | `47.5%` | `2.27M` |
| `u_core/u_q_buf` | `206253.8362` | `14.7%` | `0.70M` |
| `u_core/u_k_buf` | `206256.1882` | `14.7%` | `0.70M` |
| `u_core/u_oacc_buf` | `104106.2321` | `7.4%` | `0.35M` |
| `u_core/u_oacc_update` | `64760.0660` | `4.6%` | `0.22M` |
| `u_core/u_v_buf_pv` | `51425.4751` | `3.7%` | `0.17M` |
| `u_core/u_row_state` | `48066.4519` | `3.4%` | `0.16M` |
| `u_core/u_score_post` | `44854.3059` | `3.2%` | `0.15M` |

## Interpretation

- The current top-level DC result is a major reduction from the earlier incomplete `~3,065,011` standard-cell-area checkpoint, but it is still not close enough to the `<2M NAND2` requirement.
- `Macro/Black Box area = 713773.046875`, which alone is about `2.43M` NAND2 using the same `0.294` reference. Therefore the current macro-backed storage footprint already exceeds the target before adding standard-cell logic.
- To reach `<2M NAND2`, the next useful optimization pressure should be on storage footprint and the `u_qk_pv_core` datapath:
  - reduce Q/K/V tile buffering footprint or switch to narrower/deeper banking that maps to smaller available macros;
  - reduce the shared GEMM/GEMU array area or time-multiplex further;
  - reduce OACC and score/row-state intermediate storage;
  - address the high-fanout PV result SRAM clock structure before relying on timing quality.

