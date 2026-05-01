# P2 Datapath RTL Light DC Check

Date: 2026-05-01
Remote host: ic-canopsys / `/home/host/Desktop/flash_atten`
Top: `FA_TOP_BASELINE`
Run tag: `20260501_p2_datapath_lightcheck`

## Remote Cleanup

- Cleaned generated DC/Formality artifacts before rerun:
  - `FM_INFO`, `FM_WORK`, `FM_WORK1`, `formality_svf`
  - `synopsys/dc/{reports,results,logs,work}`
  - `synopsys/formality/{reports,results,logs,work}`
  - root generated `*.pvl`, `*.syn`, `*.mr`
  - AppleDouble `._*` files
- Removed stale shadow RTL directory:
  - `synopsys/rtl`
- Updated remote Synopsys design config:
  - `set RTL_SUBDIR rtl`
- Refreshed remote filelists to reference only top-level `rtl/...`.
- Verified no remaining `synopsys/rtl` references in:
  - `synopsys/common/config`
  - `synopsys/common/filelists`
  - `synopsys/dc/flow`
  - `synopsys/formality/flow`

## Light DC Scope

The run intentionally did not execute `compile_ultra` or a full mapping compile.

Executed:

- `analyze -define SYNTHESIS`
- `elaborate FA_TOP_BASELINE`
- `link`
- `source base.sdc`
- `check_design`
- `check_timing`
- `report_reference`
- port/clock/constraint summary reports
- hierarchical elaborated DDC write

The Tcl script hard-fails if:

- `RTL_ROOT` is not `$PROJECT_ROOT/rtl`
- `synopsys/rtl` exists

## Result

Status: PASS for light DC front-end/elaboration check.

- Wrapper return: `rc=0`
- DC log errors: `0`
- DC log warnings: `90`
- Minimum observed available memory: `42907 MiB`
- Maximum observed swap use: `0 MiB`
- Generated DDC: `18M`

Remote status:

```text
[2026-05-01 12:19:35] START dc_light
[2026-05-01 12:23:50] END dc_light rc=0
[2026-05-01 12:23:50] ALL_DONE
```

## Key Reports

Remote report directory:

`/home/host/Desktop/flash_atten/synopsys/dc/reports/FA_TOP_BASELINE`

Generated reports:

- `20260501_p2_datapath_lightcheck_source_manifest.txt` - 921 B
- `20260501_p2_datapath_lightcheck_check_design.rpt` - 92K
- `20260501_p2_datapath_lightcheck_check_timing.rpt` - 545K
- `20260501_p2_datapath_lightcheck_reference.rpt` - 1.7K
- `20260501_p2_datapath_lightcheck_constraint.rpt` - 1.9K
- `20260501_p2_datapath_lightcheck_clock_report.rpt` - 603 B
- `20260501_p2_datapath_lightcheck_ports_inputs_verbose.rpt` - 89K
- `20260501_p2_datapath_lightcheck_ports_outputs_verbose.rpt` - 103K

Remote result:

`/home/host/Desktop/flash_atten/synopsys/dc/results/FA_TOP_BASELINE/FA_TOP_BASELINE_20260501_p2_datapath_lightcheck_elab.ddc`

## Findings

No unresolved reference text was reported by `check_design`.

`report_reference` still shows unmapped/hierarchical references, which is expected for this no-compile light check. It includes one parameterized `FA_CORE_BASELINE...` reference and GTECH/DW-style generic logic.

`check_design` summary still has known pre-compile lint noise:

- Unconnected ports: 41
- Shorted outputs: 79
- Constant outputs: 74
- Cells do not drive: 694
- Empty/black-box-style design: `FA_V_BUF_REAL` reported by LINT-55
- Unloaded nets: 3

`check_timing` completed with clock `core_clk` at 5.00 ns. It reported high-fanout timing estimation noise:

- `FA_TOP_BASELINE` contains 101 high-fanout nets, with fanout 1000 used for delay calculation.

Constraint summary:

- `min_capacitance`: MET
- `max_transition`: MET
- `max_fanout`: MET
- `max_capacitance`: VIOLATED, cost `4003.20`
- `max_delay/setup`: MET

## Interpretation

The P2 RTL passes a lightweight DC front-end check using the canonical top-level `rtl/` source tree. This confirms the RTL can be analyzed, elaborated, linked, constrained, and written as DDC without DC fatal errors.

This is not a replacement for the full DC compile/Formality pass. The remaining findings are mostly pre-existing pre-compile lint/constraint noise, but `max_capacitance` and the high-fanout estimate should stay on the next full compile cleanup list.

## RTL Inspection Notes

Reviewed RTL against the light DC findings.

### `FA_V_BUF_REAL`

Location: `rtl/fa_buffers_real.v`

`FA_V_BUF_REAL` is intentionally simulation/debug-only. Its storage and `tile_flat` output are guarded by `ifndef SYNTHESIS`; under synthesis the module has only input ports and no cells. It is still instantiated by `FA_CORE_BASELINE`, so DC reports:

- `FA_V_BUF_REAL` does not contain any cells or nets, LINT-55
- parent instance `u_v_buf` does not drive any nets, LINT-1

This is backend noise, not a datapath functional bug, because the synthesized PV datapath consumes V through `FA_V_BUF_PV_REAL`. Recommended RTL cleanup:

- Guard the `u_v_buf` instantiation in `FA_CORE_BASELINE` with `ifndef SYNTHESIS`, or
- Remove the synthesized `FA_V_BUF_REAL` path entirely and keep only the debug path in the simulation wrapper.

The first option is lowest risk.

### `FA_QK_PV_ARB` / `FA_QK_PV_STREAM_CTRL`

Location: `rtl/fa_cores_real.v`

DC LINT-31 reports several shorted outputs:

- Q/K read addresses share the same issue address in QK mode.
- P/V lower address bits share the same issue counter in PV mode.
- `gemm_num_acc` upper bits are constants for `32` or `8`.

These are intentional RTL expressions of shared control, not functional shorts. They may remain unless backend netlist readability is the priority.

### `GEMU_V3` / `GEMM_V3` / packer width changes

Locations:

- `rtl/gemu_v3.v`
- `rtl/gemm_v3.v`
- `rtl/fa_cores_real.v`

The P2 datapath width change is structurally coherent:

- GEMU output is `ACC_WIDTH`.
- Shared GEMM group data is `16 * 64 = 1024` bits.
- Result packer consumes `GEMM_ACC_WIDTH = 64`.
- QK output still clamps to Q16.16.
- PV output still rounds/saturates to Q8.8.

DC sign warnings remain mostly because Verilog part-selects and concatenations are unsigned by default. These are warning-noise candidates, not proof of wrong math. Recommended cleanup:

- Add explicit `$signed(...)` on signed slices passed into clamp/round functions.
- Add explicit `$unsigned(...)` when assigning signed saturated values into packed bit vectors.
- Type group indices/constant comparisons in `GEMM_V3` to avoid integer-to-vector sign noise.

### Broader Sign-Warning Distribution

DC warning distribution from the light check:

- `fa_score_post_real.v`: 29
- `fa_row_state_real.v`: 26
- `fa_oacc_update_real.v`: 12
- `fa_cores_real.v`: 8
- `gemu_v3.v`: 5
- `gemm_v3.v`: 5
- `fa_buffers_real.v`: 3
- `fa_p_bypass_real.v`: 1

Most are `VER-318` signed/unsigned conversion warnings. The highest volume is outside the P2 datapath files and should be handled as a separate sign-cast cleanup pass.

### Max Cap / High Fanout

The light run reported:

- `max_capacitance`: violated, cost `4003.20`
- high-fanout estimate: 101 nets

Because this run stops before compile, these reports include unoptimized wide constants and wide pre-mapped control/data nets. Likely RTL contributors:

- OACC 1024-bit full-row write mask/data path in `FA_OACC_BUF_REAL`
- clear/reset broadcast through many register and row-buffer structures
- GEMM/GEMU PE-array shared control fanout

Recommended next backend-oriented RTL cleanup:

- First run a low-effort compile with `set_fix_multiple_port_nets` before judging max-cap root cause.
- If still dominant, split wide OACC masks into 16-bit or 64-bit local enables inside the row buffer.
- Consider local control replication for GEMM PE-array feed/start/clear only if full compile still reports those nets.
