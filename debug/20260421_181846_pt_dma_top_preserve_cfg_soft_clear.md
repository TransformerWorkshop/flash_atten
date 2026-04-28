# PT_DMA_TOP Preserve-Config Soft-Clear Iteration

- Timestamp: `2026-04-21 18:18:46 +0800`
- Branch: `codex-app`
- Commit baseline: `9285433`

## Scope

- Reduce the long-schedule penalty seen after crossing `LUT_DEPTH=8`.
- Keep `soft_clear` safe for residency flush, but stop paying the full base/QCFG re-setup tax after every safe segment boundary.

## Change

### RTL

`soft_clear` now preserves static CSR configuration while still clearing runtime state:

- preserved:
  - `CSR_BANK` base registers
  - quantization configuration
- cleared:
  - runtime execution state
  - descriptor / residency-related runtime state
  - datapath / FIFO / response transient state

Files:

- `rtl/pt.v`
- `rtl/pt_top_v2.v`
- `rtl/pt_dma_top.v`

Implementation shape:

- `PT` / `PT_V2` gained an explicit `soft_clear`
- `runtime_clear = clear || soft_clear`
- most PT submodules now use `runtime_clear`
- `CSR_BANK` still only sees hard `clear`

### Model / Bench

- `PTBlackBoxModel.reset_runtime_state()` now supports preserving config
- `PT_DMA_TOP` soft-clear model keeps A/B base and quant config alive
- multitile bench skips re-running `setup_bases_and_passthrough_qcfg()` after wrapper soft clear

Files:

- `sim/cocotb/tests/pt_model.py`
- `sim/cocotb/tests/pt_dma_top_env.py`
- `sim/cocotb/tests/pt_blackbox_env.py`
- `app/pt_tiled_gemm/tests/test_pt_multitile_bench.py`
- `app/pt_tiled_gemm/multitile_runner.py`

## Local Validation

- `python3 -m py_compile ...`: `PASS`
- `./scripts/synth_sanity.sh`: `PASS`
- native PT spot check:
  - `python3 app/pt_tiled_gemm/run.py verify --target pt --sim icarus --submission-mode shadow_delta --m 16 --k 32 --n 16`
  - result: `PASS`
- wrapper compact full sweep:
  - `python3 app/pt_tiled_gemm/run.py multitile --target pt_dma_top --sim icarus --submission-mode compact --m-tiles 1,2,4 --n-tiles 1,2,4 --k-tiles 1,2,4`
  - result: `27/27 PASS`

Updated artifact:

- `app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_icarus_compact.json`

## Performance Effect

The improvement is concentrated exactly where expected: the `> LUT_DEPTH` long schedule case.

### `64x64x64`

- previous:
  - `6473 cycles`
  - `80.996 ops/cycle`
- current:
  - `6133 cycles`
  - `85.486 ops/cycle`
- delta:
  - `-340 cycles`
  - `+5.253%` throughput uplift

### Residual `other` Cost

This iteration mainly targets the extra residual previously attributed to `soft_clear + re-setup`.

Per-command `other` bucket:

| Bucket | Previous other/cmd | Current other/cmd |
| --- | ---: | ---: |
| `1 cmd` | `0.0` | `0.0` |
| `2 cmds` | `12.0` | `12.0` |
| `4 cmds` | `18.0` | `18.0` |
| `8 cmds` | `21.0` | `21.0` |
| `16 cmds` | `47.562` | `26.312` |

Total `other` for `64x64x64`:

- previous:
  - `761`
- current:
  - `421`
- delta:
  - `-340`

So the measured gain is almost exactly explained by eliminating the repeated post-clear config setup tax.

### Updated Compact Breakdown

| Bucket | done/cmd | push->accept | accept->resp | resp->done | other |
| --- | ---: | ---: | ---: | ---: | ---: |
| `1 cmd` | `207.400` | `1.0` | `139.4` | `67.0` | `0.0` |
| `2 cmds` | `257.250` | `1.0` | `165.25` | `79.0` | `12.0` |
| `4 cmds` | `278.000` | `1.0` | `176.0` | `83.0` | `18.0` |
| `8 cmds` | `300.400` | `1.0` | `185.8` | `92.6` | `21.0` |
| `16 cmds` | `383.312` | `1.0` | `225.0` | `131.0` | `26.312` |

Interpretation:

- the segmentation-boundary tax was real and is now reduced
- after this fix, the primary bottleneck returns to:
  - `accept -> resp`
- and the secondary bottleneck remains:
  - `resp -> done`

## Remote Signoff

### SpyGlass

- status:
  - `PASS`
- result:
  - `0 error`
  - `215 warnings`
- delta vs previous iteration:
  - no change in warning count

### DC

- status:
  - `compile complete`
- log:
  - `synopsys/dc/logs/compile_20260421_181002.log`

Final QoR:

- setup:
  - `WNS = 0.00`
  - `TNS = 0.00`
  - `violating paths = 0`
- hold:
  - worst hold `-0.12ns`
  - hold TNS `-1120.12`
  - hold violations `24246`
- area:
  - `217966.454228`

### DC Delta vs Previous Iteration

Previous remote DC reference:

- area:
  - old `218009.280229`
  - new `217966.454228`
  - delta `-42.826001`
  - change about `-0.020%`
- hold TNS magnitude:
  - old `1119.99`
  - new `1120.12`
  - delta `+0.13`
  - effectively flat

Front-end area remains tiny:

- `u_axil_csr`
  - `1001.0700`
- `u_cmd_fifo`
  - `698.8380`
- subtotal
  - `1699.9080`
  - about `0.780%` of total

Interpretation:

- this optimization improved long-schedule performance without materially hurting QoR
- setup still closes
- hold is still open, but this iteration did not meaningfully worsen it

## Reassessed Priority After This Fix

This iteration removed a meaningful part of the long-schedule segmentation tax.

Remaining priority is now even clearer:

1. reduce `accept -> resp`
2. reduce `resp -> done`
3. only then revisit any remaining segmentation overhead

The `soft_clear` configuration-preservation optimization was worthwhile, but it does not replace the need to attack the main command-path bottleneck.
