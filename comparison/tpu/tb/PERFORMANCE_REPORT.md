# Comparison TPU Resource And Performance Report

## Scope

This report summarizes the current `comparison/tpu` status after retargeting the
default local matrix RAM width from `128` to `64` to reduce PYNQ-ZU-side memory
pressure.

The current environment does not have `vivado`, so the resource section below is
an analytic estimate for the `A/B/C/D` matrix RAM arrays themselves rather than
a full post-synthesis board utilization report.

## Configurations

Current configuration:

- RTL root: `comparison/tpu/rtl`
- PE size: `16`
- AXI data width: `128`
- RAM data width: `64`
- result file: `comparison/tpu/tb/results/verilator_local_pe16_axi128_ram64_numeric.xml`

Previous local configuration:

- RTL root: `comparison/tpu/rtl`
- PE size: `16`
- AXI data width: `128`
- RAM data width: `128`
- result file: `comparison/tpu/tb/results/verilator_local_pe16_axi128_ram128_numeric.xml`

Vanilla baseline:

- RTL root: `tpu_vanilla/third_party/tpu_vanilla-v2-local/rtl`
- PE size: `8`
- AXI data width: `64`
- RAM data width: `64`
- result file: `comparison/tpu/tb/results/verilator_vanilla_v2_pe8_axi64_ram64_numeric.xml`

Command lines:

```bash
python run.py numeric --sim verilator --pe-size 16 --axi-data-width 128 --ram-data-width 64
python run.py numeric --sim verilator --pe-size 16 --axi-data-width 128 --ram-data-width 128
python run.py numeric --sim verilator --variant vanilla_v2 --rtl-root ../../../../tpu_vanilla/third_party/tpu_vanilla-v2-local/rtl --pe-size 8 --axi-data-width 64 --ram-data-width 64
```

All three runs completed with `62/62` passing numeric cases.

## Resource Estimate

### Matrix RAM Footprint

These numbers cover the four ping-pong matrix RAM groups instantiated by
`tpu_top`:

- `A`: `2 * 16 * 2^8 * RAM_DATA_WIDTH`
- `B`: `2 * 16 * 2^8 * RAM_DATA_WIDTH`
- `C`: `2 * 16 * 2^10 * RAM_DATA_WIDTH`
- `D`: `2 * 16 * 2^10 * RAM_DATA_WIDTH`

| Group | RAM128 bits | RAM64 bits | Delta |
| --- | ---: | ---: | ---: |
| `A` | `1,048,576` | `524,288` | `-50.0%` |
| `B` | `1,048,576` | `524,288` | `-50.0%` |
| `C` | `4,194,304` | `2,097,152` | `-50.0%` |
| `D` | `4,194,304` | `2,097,152` | `-50.0%` |
| Total | `10,485,760` | `5,242,880` | `-50.0%` |

Equivalent storage:

- `RAM128`: `1,310,720` bytes = `1,280 KiB` = `1.25 MiB`
- `RAM64`: `655,360` bytes = `640 KiB`

### BRAM36-Equivalent Estimate

Assuming Xilinx block-RAM inference for these simple dual-port arrays and using
the matrix RAM depths visible in the RTL:

| Group | RAM128 BRAM36 est. | RAM64 BRAM36 est. | Delta |
| --- | ---: | ---: | ---: |
| `A` | `64` | `32` | `-32` |
| `B` | `64` | `32` | `-32` |
| `C` | `128` | `64` | `-64` |
| `D` | `128` | `64` | `-64` |
| Total | `384` | `192` | `-192` |

Interpretation:

- The `ABCD` matrix RAM body is expected to drop by about half.
- The final whole-design BRAM number will be somewhat higher because FIFOs and
  other memories are unchanged.
- Exact LUT/FF/BRAM/timing numbers still need a Vivado run on a machine with
  Xilinx tools.

## Performance Summary

### Current RAM64 vs Previous RAM128

`RAM64` is functionally clean, but it is slower than the old local `RAM128`
configuration because the design now has to replay upper AXI halves when mapping
between `AXI128` and `RAM64`, and the D-store path repacks two `64-bit` RAM
words into one `128-bit` AXI beat.

- compared cases: `62`
- previous total cycles: `500,080`
- current total cycles: `570,020`
- cycle increase: `13.99%`
- mean per-case cycle ratio (`RAM64 / RAM128`): `1.139x`
- median per-case cycle ratio (`RAM64 / RAM128`): `1.089x`

### Current RAM64 vs Vanilla Baseline

- compared cases: `62`
- baseline total cycles: `1,062,230`
- current total cycles: `570,020`
- weighted speedup: `1.863x`
- mean per-case speedup: `1.352x`
- median per-case speedup: `1.338x`

Interpretation:

- The `RAM64` retarget gives a large RAM-footprint reduction and still stays
  clearly ahead of the `vanilla_v2 8x8 / AXI64 / RAM64` baseline.
- The price is a measurable regression relative to the old `16x16 / AXI128 /
  RAM128` local configuration.
- This tradeoff is probably acceptable only if BRAM pressure is the primary
  blocker on PYNQ-ZU deployment.

## Representative Cases

| Case | Vanilla cycles | RAM128 cycles | RAM64 cycles | RAM64 / RAM128 | Vanilla / RAM64 |
| --- | ---: | ---: | ---: | ---: | ---: |
| `test_numeric_01_edge_identity_8_int8` | `1,660` | `1,680` | `1,830` | `1.089x` | `0.907x` |
| `test_numeric_02_edge_identity_16_int8` | `4,390` | `2,650` | `3,280` | `1.238x` | `1.338x` |
| `test_numeric_41_shape_m32n8k16_int8` | `4,710` | `3,060` | `3,690` | `1.206x` | `1.276x` |
| `test_numeric_42_shape_m8n32k16_int8` | `4,710` | `3,130` | `3,760` | `1.201x` | `1.253x` |
| `test_numeric_51_compat_m16n32k32_int8` | `10,470` | `5,210` | `6,480` | `1.244x` | `1.616x` |
| `test_numeric_59_compat_m32n64k64_int8` | `49,700` | `20,300` | `25,390` | `1.251x` | `1.957x` |
| `test_numeric_62_compat_m32n128k128_int8_int32` | `160,260` | `60,200` | `70,350` | `1.169x` | `2.278x` |

## AXI Writeback Traffic

The external AXI writeback beat count remains unchanged between `RAM128` and
`RAM64`, which means the runtime regression is not coming from a wider AXI store
stream. The new `RAM64` glue logic preserves `AXI128` writeback packing.

Examples:

| Case | RAM128 W beats | RAM64 W beats | RAM128 AW | RAM64 AW |
| --- | ---: | ---: | ---: | ---: |
| `test_numeric_02_edge_identity_16_int8` | `64` | `64` | `1` | `1` |
| `test_numeric_42_shape_m8n32k16_int8` | `64` | `64` | `1` | `1` |
| `test_numeric_51_compat_m16n32k32_int8` | `128` | `128` | `1` | `1` |
| `test_numeric_59_compat_m32n64k64_int8` | `512` | `512` | `2` | `2` |
| `test_numeric_62_compat_m32n128k128_int8_int32` | `1024` | `1024` | `4` | `4` |

## Validation Status

- `python run.py smoke --sim verilator`: `3/3` pass
- `python run.py numeric --sim verilator`: `62/62` pass

## Recommendation

For the current repository state:

- If the top priority is fitting the PYNQ-ZU resource budget, this `RAM64`
  version is the right branch to carry forward.
- If more BRAM headroom appears later, the old `RAM128` organization is still
  the better pure-performance point within the same `16x16 / AXI128` family.
