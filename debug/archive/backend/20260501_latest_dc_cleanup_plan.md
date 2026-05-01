# Latest ic-canopsys DC Cleanup Plan - 2026-05-01

## Source And Baseline

- Remote host checked: `ic-canopsys`
- Remote project: `/home/host/Desktop/flash_atten`
- Latest completed run: `20260501_a36424a_svfearly_memguard`
- Run status: DC completed at `2026-05-01 03:43:32`; Formality completed at `2026-05-01 08:34:12`; `ALL_DONE`
- Local report bundle: `debug/20260501_a36424a_svfearly_memguard_remote/`
- Top: `FA_TOP_BASELINE`
- Clock target: `core_clk`, `5.000 ns`
- DC version: `T-2022.03-SP2`

QoR from latest DC:

| Item | Result |
| --- | ---: |
| Setup WNS/TNS | `0.00 / 0.00 ns` |
| Setup violating paths | `0` |
| Hold violating paths | `2`, both rounded `0.00 ns` precision cases |
| Total cell area | `469150.206845` |
| NAND2 equivalent, using `0.294` | about `1.596M` |
| 2M NAND2 area target | `588000` |
| Area margin | about `404k` NAND2 |
| Leaf cells | `559306` |
| Sequential cells | `109399` |
| Macro count | `0` |

This run is functionally a good synthesis baseline: timing and area are in target range. The cleanup problem is now mostly report hygiene plus a narrow max-transition tail.

## 1. DRC Cleanup

Latest DRC summary:

| DRC class | Count | Notes |
| --- | ---: | --- |
| Max transition | `37` nets | Total reported slack `-0.04`; each row is printed as `0.25 / 0.25`, so rerun with more significant digits before judging margin. |
| Max capacitance | `0` nets | `compile_max_cap_violators.rpt` is clean. |
| Min capacitance | `23` nets | All are top outputs at `0.00 / 0.00`; this is an IO-load modeling gap, not an RTL capacitance problem. |
| Max leakage power | violated | Constraint is effectively `0`, so this should be replaced with a real budget or removed from cleanup gating. |

Max-transition grouping:

| Region | Count | Representative nets | Likely cause | Fix priority |
| --- | ---: | --- | --- | --- |
| `u_core/u_qk_pv_core/u_gemm/*/gemu_unit` | `34` | `n469`, `n470`, `n475`-`n485` under replicated GEMU units | GEMU finish/control terms around `acc_done`, `tile_done`, `m_valid_r`, and `m_data_r <= accm` still drive wide mux/update cones after the `ACC_WIDTH=64` improvement. | P0 |
| `u_core/u_oacc_buf/u_mem` | `2` | `n18926`, `n18929` | 1024-bit row buffer write/read mask control inside `FA_MASKED_ROWBUF_REG_REAL_ROW_WIDTH1024_DEPTH16_WRITE_GRANULARITY16`. | P1 |
| `u_core/u_row_state` | `1` | `n49006` | Scalar row commit state/control still gates a wide 16-column update path. | P1 |

Recommended sequence:

1. Add a high-precision DRC report first:
   - Set report significant digits to at least 4 before `report_constraint`.
   - Emit a machine-readable transition table with net, driver pin, load pin count, transition, required, slack, and hierarchical owner.
   - Gate the cleanup on real negative slack, not the rounded `0.00` rows.

2. Fix GEMU without changing protocol latency:
   - In `rtl/gemu_v3.v`, split the finish path into local chunk enables, for example `finish_fire_q[0..3]`, rather than one `acc_done && !m_valid_r` term feeding the whole result update cone.
   - Split `m_data_r <= accm` and related reset/valid updates into 16-bit or 32-bit chunks so DC has structural replication it will not immediately collapse.
   - If DC merges the replicated controls, add a targeted synthesis keep/dont-touch only on those local finish nets.
   - Acceptance target: GEMU max-transition count drops from `34` to `0`, with setup still clean and area still under `588000`.

3. Fix OACC buffer tail:
   - Partition the 1024-bit OACC row storage into smaller banks, for example 4 x 256-bit or 8 x 128-bit banks, with bank-local write enable, mask, and read mux control.
   - Keep the external `FA_OACC_BUF_REAL` interface unchanged.
   - This is better than asking DC to buffer one huge row-control cone, because the structure is visible to both synthesis and later physical implementation.

4. Fix row-state tail:
   - Replicate row commit controls per 4-column group in `FA_ROW_STATE_REAL`.
   - Keep scalar state updates separate from per-column probability/output updates where possible.
   - If the single net persists, add one local registered commit-enable stage only after confirming the no-latency split is insufficient.

5. Treat clock fanout as pre-CTS modeling:
   - DC reports one high-fanout clock net with `109399` loads and uses fanout `1000` for delay calculation.
   - Do not solve this by random RTL clock buffering. Mark the clock network explicitly as ideal for synthesis and leave real clock buffering to CTS.

## 2. Constraint And IO Load Completeness

Current constraint stack:

- `base.sdc` sources `clocks.sdc` and `io_delay_placeholder.sdc`.
- `clocks.sdc` creates `core_clk` at `5.000 ns`.
- Setup/hold uncertainty: `0.100 / 0.050 ns`.
- Generic IO delay: `0.500 ns` on `[all_inputs]` and `[all_outputs]`.
- Generic input transition: `0.050 ns` on `[all_inputs]`.
- Design rules: `set_max_transition 0.250 [current_design]`, `set_max_capacitance 0.200 [current_design]`.
- `io_delay_placeholder.sdc` is still empty.

Gaps to close:

1. Exclude clocks and async controls from generic IO timing:
   - Current `[all_inputs]` includes `clk`, `rstn`, and `clear`.
   - Build named collections: `clk_ports`, `async_ports`, `data_inputs`, `data_outputs`.
   - Apply IO delay only to data/interface ports; keep reset/clear as false paths or recovery/removal checks, depending on intended reset handling.

2. Replace placeholder IO timing with interface classes:
   - AXI-Lite slave: `s_axil_*`
   - AXI master read/write address/data/response channels: `m_axi_*`
   - Interrupt: `irq`
   - Clock/reset/control: `clk`, `rstn`, `clear`
   - Use separate input/output delay budgets per channel once the integration envelope is known.

3. Add driver/load modeling:
   - Inputs currently have `set_input_transition`, but no `set_driving_cell`.
   - Outputs currently have no `set_load`; this directly explains the 23 min-cap rows on top outputs such as `irq`, `m_axi_arburst`, `m_axi_arlen`, `m_axi_arsize`, `m_axi_awburst`, `m_axi_awlen`, `m_axi_awsize`, `s_axil_bresp`, and `s_axil_rresp`.
   - Add a conservative `set_load` per output class. Until SoC integration numbers exist, use a documented placeholder based on one or more standard-cell input pin loads, then tag it as non-signoff.

4. Add completeness gates:
   - Report ports with no input delay, no output delay, no load, or no driving model.
   - Fail the DC run if any non-clock/non-reset top-level data port is unconstrained.
   - Emit a small IO coverage report next to `compile_constraint_summary.rpt`.

Suggested SDC shape:

```tcl
set clk_ports   [get_ports clk]
set async_ports [get_ports {rstn clear}]
set data_inputs [remove_from_collection [all_inputs] [add_to_collection $clk_ports $async_ports]]
set data_outputs [all_outputs]

create_clock -name core_clk -period 5.000 $clk_ports
set_clock_uncertainty -setup 0.100 [get_clocks core_clk]
set_clock_uncertainty -hold  0.050 [get_clocks core_clk]
set_clock_transition 0.100 [get_clocks core_clk]
set_ideal_network $clk_ports

set_input_delay  0.500 -clock core_clk $data_inputs
set_output_delay 0.500 -clock core_clk $data_outputs
set_driving_cell -lib_cell BUFFD4BWP7T40P140 $data_inputs
set_load [load_of tcbn28hpcplusbwp7t40p140ffg0p99v0c_ccs/INVD1BWP7T40P140/I] $data_outputs

set_false_path -from $async_ports
set_max_transition 0.250 [current_design]
set_max_capacitance 0.200 [current_design]
```

The exact cells and delay/load numbers should be replaced by SoC integration values. The immediate objective is to remove accidental zero-load optimism and stop min-cap noise from hiding real IO modeling gaps.

## 3. Netlist Readability Noise Cleanup

Current netlist state on ic-canopsys:

| Item | Current value |
| --- | ---: |
| Netlist | `/home/host/Desktop/flash_atten/synopsys/dc/results/FA_TOP_BASELINE/FA_TOP_BASELINE_compile.v` |
| Netlist lines | `1108220` |
| Modules | `98` |
| Lines containing `assign` | `954` |
| Lines containing `SYNOPSYS_UNCONNECTED_` | `5136` |

Writer warnings from final compile:

| Warning | Count / location |
| --- | --- |
| `VO-4` assign/tran statements written | present |
| `VO-11` auto-added unconnected nets | `4096` in GEMM, `676` in `FA_QK_PV_SHARED_CORE_REAL`, `200` in core, `12` in top, `1` in row-state by log |
| `check_design` LINT-28 | `290126` unconnected ports |
| `check_design` LINT-32 | `8467` constant power/ground connections |
| `check_design` LINT-33 | `1` multiple pins on same cell |

Cleanup plan:

1. Remove intentional unused outputs at RTL boundaries:
   - Do not leave wide generated submodule ports open when only part of a result is consumed.
   - Add named dummy wires for intentional unused bits, or parameterize away unused result lanes.
   - Biggest target is GEMM/GEMU result plumbing: it accounts for the majority of `SYNOPSYS_UNCONNECTED_` noise.

2. Synthesis-guard debug-only buses:
   - Wide debug/status ports that are not part of the gate-level deliverable should be inside `ifndef SYNTHESIS` or tied to explicit named constants.
   - This should reduce both LINT-28 and Formality undriven/unread-point noise.

3. Fix feedthrough and constant-port style before writeout:
   - Keep `set_fix_multiple_port_nets -all -buffer_constants`, but apply it hierarchically, not only at the top design.
   - Add a final `change_names -rules verilog -hierarchy` before `write_file`.
   - Save a name map for debug and Formality traceability.

4. Separate signoff and debug netlists:
   - Signoff netlist: cleaned names, no debug-only buses, minimized feedthrough assigns, explicit unused ties.
   - Debug netlist: hierarchy-preserving and SVF-friendly, allowed to retain more names for correlation.

5. Add noise metrics to the run:
   - Count `SYNOPSYS_UNCONNECTED_`, `assign`, `LINT-28`, `LINT-32`, and `LINT-33` after every compile.
   - Treat `SYNOPSYS_UNCONNECTED_` count as a cleanup KPI; first target is below `500`, final target is near zero except for deliberately documented unused pins.

## Validation Matrix

| Step | Must pass |
| --- | --- |
| Local RTL sanity | `./scripts/synth_sanity.sh` and relevant cocotb smoke/regression tests |
| DC rerun | setup WNS/TNS `0`, max cap `0`, max transition `0`, area `< 588000` |
| Constraint audit | no data input without delay/driver; no data output without delay/load |
| Netlist audit | sharply reduced `SYNOPSYS_UNCONNECTED_`; no unexpected `VO-4/VO-11`; no new unresolved references |
| Formality | no failing points; reduce current `3165` unverified points by addressing undriven/unread/debug noise |

## Recommended Next Patch Order

1. Constraint/reporting patch: high-precision DRC reports plus IO coverage report.
2. RTL patch 1: GEMU finish-control replication/chunking.
3. RTL patch 2: OACC row buffer banking and row-state commit-control replication.
4. Netlist hygiene patch: remove open debug/result ports and apply hierarchical multi-port-net/name cleanup.
5. Remote rerun on ic-canopsys and compare against this baseline.
