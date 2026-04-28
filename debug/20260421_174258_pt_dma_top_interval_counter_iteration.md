# PT_DMA_TOP Interval Counter Iteration Report

- Timestamp: `2026-04-21 17:42:58 +0800`
- Branch: `codex-app`
- Commit: `d46b5cc`

## Scope

- Add synth-safe interval counters to `PT_DMA_TOP` so the remaining wrapper overhead can be measured directly instead of inferred from end-to-end cycle deltas.
- Re-run local validation, then repeat remote SpyGlass and remote DC gate checks on `ic-canopsys`.

## Implemented Changes

### RTL

Added three workload-facing interval counters in `PT_DMA_TOP` and exposed them through `PT_DMA_AXIL_CSR`:

- `0x58` `perf_push_to_accept_cycles`
- `0x5C` `perf_accept_to_resp_cycles`
- `0x60` `perf_resp_to_done_cycles`

Implementation notes:

- `push -> accept`
  - tracked with a small synth-safe timestamp queue sized by `CMD_FIFO_DEPTH`
- `accept -> resp`
  - tracked per descriptor slot using accepted command `id`
- `resp -> wr_dma_done`
  - tracked per descriptor slot for export-producing commands

Files:

- `rtl/pt_dma_top.v`
- `rtl/pt_dma_axil_csr.v`

### Cocotb / Software Metrics

- Added counter fields to `PerfCounterSnapshot`
- Added `delta()` and `add()` helpers so metrics can be accumulated cleanly across setup and across `soft_clear`
- Updated verify and multitile bench output to export the new interval counters
- Fixed multitile perf accounting so cases with internal `soft_clear` no longer lose the first segment of counter data

Files:

- `sim/cocotb/tests/pt_dma_top_env.py`
- `app/pt_tiled_gemm/tests/test_pt_tiled_gemm.py`
- `app/pt_tiled_gemm/tests/test_pt_multitile_bench.py`
- `app/pt_tiled_gemm/multitile_runner.py`

## Local Validation

### Functional / Build

- `python3 -m py_compile ...`: `PASS`
- `./scripts/synth_sanity.sh`: `PASS`
- `python3 app/pt_tiled_gemm/run.py verify --target pt_dma_top --sim icarus --submission-mode compact --m 16 --k 64 --n 16`: `PASS`
- `python3 app/pt_tiled_gemm/run.py multitile --target pt_dma_top --sim icarus --submission-mode compact --m-tiles 1,2,4 --n-tiles 1,2,4 --k-tiles 1,2,4`: `PASS`

Updated artifacts:

- `app/pt_tiled_gemm/out/verify_metrics_pt_dma_top_m16_k64_n16.json`
- `app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_icarus_compact.json`

## New Local Bottleneck Quantification

With setup baseline removed and multitile `soft_clear` accumulation fixed, the compact-mode workload counters are:

| Bucket | Done cycles / cmd | Push->Accept / cmd | Accept->Resp / cmd | Resp->Done / cmd |
| --- | ---: | ---: | ---: | ---: |
| `1 cmd` | `207.400` | `1.0` | `139.4` | `67.0` |
| `2 cmds` | `257.250` | `1.0` | `165.25` | `79.0` |
| `4 cmds` | `278.000` | `1.0` | `176.0` | `83.0` |
| `8 cmds` | `300.400` | `1.0` | `185.8` | `92.6` |
| `16 cmds` | `404.562` | `1.0` | `225.0` | `131.0` |

Key interpretation:

- `push -> accept` is effectively negligible:
  - about `1 cycle / command`
- the dominant term is now clearly `accept -> resp`
  - grows from about `139 cycles / command` to about `225 cycles / command`
- `resp -> done` is the second-largest term
  - grows from about `67 cycles / command` to about `131 cycles / command`

So the earlier qualitative conclusion is now directly confirmed by hardware counters:

- the first-order bottleneck is **not** descriptor CSR write count anymore
- the first-order bottleneck is the wrapper-side **post-accept, pre-response** command handling path
- export/writeback remains the secondary bottleneck

Representative cases:

| Shape | Command Count | Push->Accept | Accept->Resp | Resp->Done | Accept->Done |
| --- | ---: | ---: | ---: | ---: | ---: |
| `16x16x64` | `2` | `2` | `254` | `70` | `350` |
| `32x32x32` | `2` | `2` | `450` | `262` | `738` |
| `64x64x64` | `16` | `16` | `3600` | `2096` | `6473` |

## Remote Signoff

### SpyGlass

- Host:
  - `ic-canopsys`
- Status:
  - `PASS`
- Result:
  - `0 error`
  - `215 warnings`

Comparison vs previous iteration:

- previous:
  - `212 warnings`
- current:
  - `215 warnings`
- delta:
  - `+3 warnings`

No new high-severity failure was introduced.

### DC

- Host:
  - `ic-canopsys`
- Stage:
  - `~/Desktop/flash_atten_stage_20260421_155212`
- Log:
  - `synopsys/dc/logs/compile_20260421_173335.log`
- Status:
  - `compile complete`

Final QoR from `compile_qor.rpt`:

- setup:
  - `WNS = 0.00`
  - `TNS = 0.00`
  - `violating paths = 0`
- hold:
  - worst hold violation `-0.12ns`
  - hold TNS `-1119.99`
  - hold violating paths `24249`
- area:
  - `218009.280229`
- design rule:
  - `1` max-cap violation
- high-fanout notes:
  - `u_pt/u_pt_v2/u_quant/rstn`
  - `u_pt/u_pt_v2/gemm_inst/gen_gemu_row[0].gen_gemu_col[2].gemu_unit/fifo_a/clk`

### DC Delta vs Previous Iteration

Previous reference was the earlier remote-signoff report.

- total area:
  - old `215164.438229`
  - new `218009.280229`
  - delta `+2844.842`
  - change `+1.322%`
- front-end area (`u_axil_csr + u_cmd_fifo`):
  - old `1666.0000`
  - new `1700.2020`
  - delta `+34.202`
  - change `+2.053%`
- hold TNS magnitude:
  - old `1088.63`
  - new `1119.99`
  - delta `+31.36`
  - change `+2.881%`

Updated area distribution:

- `u_axil_csr`
  - `1001.3640`
  - about `0.459%` of total
- `u_cmd_fifo`
  - `698.8380`
  - about `0.321%` of total
- front-end subtotal
  - `1700.2020`
  - about `0.780%` of total
- `u_pt`
  - `207794.9362`
  - about `95.313%` of total

Interpretation:

- the added interval counters are still a very small area change
- setup still closes at `5ns`
- hold remains open, just as in the previous remote compile
- QoR movement is modest and still within the previously discussed `5%` guardrail

## Check Design Summary

From `compile_check_design.rpt`:

- Inputs/Outputs:
  - `1071`
  - all visible summary items are `Unconnected ports (LINT-28)`
- Cells:
  - `749`
  - mostly `Connected to power or ground (LINT-32)`
  - plus `Nets connected to multiple pins on same cell (LINT-33)`

Interpretation:

- warning volume is high, but the dominant categories remain structural/reporting style warnings rather than a new functional blocker

## Conclusion

This iteration answered the remaining measurement question cleanly:

- `push -> accept` is not the bottleneck
- `accept -> resp` is the dominant wrapper bottleneck
- `resp -> done` is the secondary bottleneck

That means the next P1 RTL work should focus on reducing repeated per-command work in the wrapper control/response machinery after command accept, not on shaving another write or two from the CSR path.

## Recommended Next Step

Prioritized next optimization target:

1. reduce `accept -> resp` overhead

Likely candidates:

1. simplify descriptor lookup / bookkeeping on accepted commands
2. reduce per-command wrapper-side orchestration before response generation
3. only after that, revisit export-path overlap improvements

Not first priority anymore:

1. further shrinking CSR write count
2. changing PT core ISA
3. widening `PT_SIZE_W`
