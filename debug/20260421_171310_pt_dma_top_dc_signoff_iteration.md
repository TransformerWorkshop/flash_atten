# PT_DMA_TOP DC Signoff Iteration Report

- Timestamp: `2026-04-21 17:13:10 +0800`
- Branch: `codex-app`
- Commit: `d46b5cc`

## Scope

- Close the remote signoff loop for the current `PT_DMA_TOP` front-end upgrade.
- Combine final remote DC status with the local post-optimization bottleneck analysis.

## Remote Environment

- VM source:
  - `/Users/yucheng/Documents/Network/vm.txt`
- Remote target:
  - `ic-canopsys`
  - host `100.108.220.80`
  - user `host`
- Remote staging workspace:
  - `~/Desktop/flash_atten_stage_20260421_155212`

## Signoff Status

### SpyGlass

- Status: `PASS`
- Result:
  - `0 error`
  - `212 warnings`
- Scope:
  - isolated `PT_DMA_TOP` lint project in remote stage

### DC

- Status: `compile complete`
- Top:
  - `PT_DMA_TOP`
- Main compile log:
  - `synopsys/dc/logs/compile_20260421_161408.log`
- Generated outputs:
  - `synopsys/dc/results/PT_DMA_TOP/PT_DMA_TOP_compile.ddc`
  - `synopsys/dc/results/PT_DMA_TOP/PT_DMA_TOP_compile.v`
  - `synopsys/dc/reports/PT_DMA_TOP/compile_qor.rpt`
  - `synopsys/dc/reports/PT_DMA_TOP/compile_area.rpt`
  - `synopsys/dc/reports/PT_DMA_TOP/compile_timing.rpt`
  - `synopsys/dc/reports/PT_DMA_TOP/check_design.rpt`

## DC QoR Summary

From `compile_qor.rpt`:

- clock period:
  - `5.00ns`
- setup:
  - `WNS = 0.00`
  - `TNS = 0.00`
  - `violating paths = 0`
- hold:
  - `worst hold violation = -0.12`
  - `total hold violation = -1088.63`
  - `hold violating paths = 23458`
- design rules:
  - `nets with violations = 1`
  - `max cap violations = 1`
  - `max transition violations = 0`
- area:
  - `cell area = 215164.438229`
  - `combinational area = 75358.668088`
  - `noncombinational area = 37838.192016`
  - `macro/black box area = 101967.578125`
- cell count:
  - `leaf cells = 150669`
  - `sequential cells = 21711`
  - `combinational cells = 128958`
  - `macro count = 32`

## Area Distribution

From `compile_area.rpt`:

- `u_pt`:
  - area `207679.1982`
  - `96.521%` of total
- `u_axil_csr`:
  - area `966.7700`
  - `0.449%` of total
- `u_cmd_fifo`:
  - area `699.2300`
  - `0.325%` of total
- front-end subtotal (`u_axil_csr + u_cmd_fifo`):
  - `1666.0000`
  - `0.774%` of total

Interpretation:

- The current compact path and perf-counter related front-end logic remain very small compared with the PT core.
- This is encouraging for further P1 work: there is still room to restructure wrapper launch logic without threatening total area first.

## Timing Interpretation

### Positive

- Setup closed at the current `5ns` target.
- The new wrapper/front-end logic did not cause an obvious setup failure in this compile.

### Risks

- Hold is not clean:
  - `-0.12` WHS
  - `-1088.63` hold TNS
  - `23458` hold violations
- There is still `1` max-cap violation.
- The timing report also flags two high-fanout nets used with capped fanout assumptions:
  - `u_pt/u_pt_v2/u_quant/rstn`
  - `u_pt/u_pt_v2/gemm_inst/gen_gemu_row[0].gen_gemu_col[2].gemu_unit/fifo_a/clk`

Conclusion:

- For this iteration, DC compile is usable as a structural gate.
- It is not yet a clean timing signoff result because hold cleanup remains open.

## Check Design Summary

From `check_design.rpt`:

- Inputs/Outputs warnings: `415`
  - unconnected ports: `190`
  - feedthrough: `1`
  - shorted outputs: `165`
  - constant outputs: `59`
- Cell warnings: `151`
  - cells do not drive: `74`
  - tied to power/ground: `74`
  - same-cell multi-pin nets: `3`
- Net warnings: `65`
  - unloaded nets: `65`

Interpretation:

- The report is warning-heavy, but the visible examples are still dominated by expected unused/unloaded logic patterns, generated naming, and wrapper/core unused observability points.
- There is no evidence in this report alone of a new catastrophic structural issue introduced by compact submit mode.

## Updated Bottleneck View

This iteration confirms the earlier local performance result:

- `shadow_delta` removes most of the useful CSR waste.
- `compact` reduces writes further, but only gives marginal GOPS gain over `shadow_delta`.

The native `PT` comparison narrows the residual bottleneck to the wrapper pre-response path:

| Bucket | `PT_DMA_TOP compact - PT` done delta / cmd | `PT_DMA_TOP compact - PT` resp delta / cmd |
| --- | ---: | ---: |
| `1 cmd` | `-2.000` | `5.000` |
| `2 cmds` | `9.500` | `13.000` |
| `4 cmds` | `15.250` | `17.000` |
| `8 cmds` | `18.125` | `19.000` |
| `16 cmds` | `40.188` | `40.625` |

The `done - resp` tail is nearly constant and slightly better than native PT:

- about `-7 cycles` vs native `PT` across all measured cases

So the remaining P1 target is not export completion. It is the repeated launch/accept/response tax in the wrapper.

## Priority After This Iteration

### Keep

- `shadow_delta` as the practical software-side improvement path
- `compact` as the clean reduced-write wrapper path
- current safety rule:
  - no live-slot reuse in PT core
  - no unsafe `ctrl_id` reuse

### Next Hardware Focus

The next P1 optimization should target measurement and reduction of:

1. descriptor push to PT accept latency
2. PT accept to wrapper response latency
3. descriptor bookkeeping / response enqueue path

Current observability status:

- existing perf counters are already wired through RTL, cocotb env, verify metrics, and multitile bench plumbing
- they currently provide event counts only:
  - AXI-Lite writes
  - command pushes
  - PT accepts
  - response enqueues
  - write-DMA done
  - compact commits
- they do **not** yet expose interval cycle measurements between those events

Implication:

- the next instrumentation step should add interval-oriented counters or timestamps
- otherwise the remaining wrapper pre-response tax still has to be inferred indirectly from end-to-end cycle deltas

Not first priority now:

1. further trimming CSR writes
2. export tail tuning
3. PT core datapath changes

## Recommended Next Actions

1. Use the new counters and/or add narrower interval counters for:
   - push-to-accept
   - accept-to-response
   - response-enqueue-to-`wr_dma_done`
2. Re-run `legacy / shadow_delta / compact` on representative cases:
   - `16x16x64`
   - `32x32x32`
   - `64x64x64`
3. If the interval counters confirm the hypothesis, the next RTL attempt should reduce command launch bookkeeping rather than descriptor register writes.
4. Any next RTL iteration must again pass:
   - SpyGlass RTL check
   - remote DC compile on `ic-canopsys`

## Artifacts

- Local bottleneck report:
  - `debug/20260421_163946_pt_dma_top_bottleneck_iteration.md`
- Native PT sweep:
  - `app/pt_tiled_gemm/out/multitile_sweep_pt_icarus_shadow_delta.json`
- Wrapper comparison:
  - `app/pt_tiled_gemm/out/pt_dma_top_submission_mode_compare.md`
