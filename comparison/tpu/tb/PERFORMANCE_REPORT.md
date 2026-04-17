# Comparison TPU Performance Report

## Scope

This report summarizes the end-to-end cocotb numeric regression performance of
the current `comparison/tpu` configuration after the true `16x16` RTL upgrade.

## Configurations

Current configuration:

- RTL root: `comparison/tpu/rtl`
- PE size: `16`
- AXI data width: `128`
- RAM data width: `128`
- result file: `comparison/tpu/tb/results/verilator_eval_pe16_pe16_axi128_ram128_numeric.xml`

Baseline configuration:

- RTL root: `tpu_vanilla/third_party/tpu_vanilla-v2-local/rtl`
- PE size: `8`
- AXI data width: `64`
- RAM data width: `64`
- result file: `comparison/tpu/tb/results/verilator_eval_vanilla_v2_pe8_axi64_ram64_numeric.xml`

Command lines:

```bash
python run.py numeric --sim verilator --variant eval_pe16 --pe-size 16 --axi-data-width 128 --ram-data-width 128
python run.py numeric --sim verilator --variant eval_vanilla_v2 --rtl-root ../../../../tpu_vanilla/third_party/tpu_vanilla-v2-local/rtl --pe-size 8 --axi-data-width 64 --ram-data-width 64
```

Both runs completed with `62/62` passing numeric cases.

## Summary

- compared cases: `62`
- baseline total cycles: `106223`
- current total cycles: `50008`
- weighted speedup: `2.124x`
- mean per-case speedup: `1.547x`
- median per-case speedup: `1.657x`

Interpretation:

- Small `8x8` cases see little benefit because the wider datapath is underused.
- `16x16` and larger cases show consistent gains.
- Larger compat cases benefit the most because the `16x16` datapath and wider
  writeback path reduce both compute and store pressure.

## Representative Cases

| Case | Baseline cycles | Current cycles | Speedup |
| --- | ---: | ---: | ---: |
| `test_numeric_01_edge_identity_8_int8` | `166` | `168` | `0.988x` |
| `test_numeric_02_edge_identity_16_int8` | `439` | `265` | `1.657x` |
| `test_numeric_41_shape_m32n8k16_int8` | `471` | `306` | `1.539x` |
| `test_numeric_42_shape_m8n32k16_int8` | `471` | `313` | `1.505x` |
| `test_numeric_51_compat_m16n32k32_int8` | `1047` | `521` | `2.010x` |
| `test_numeric_59_compat_m32n64k64_int8` | `4970` | `2030` | `2.448x` |
| `test_numeric_62_compat_m32n128k128_int8_int32` | `16026` | `6020` | `2.662x` |

## Bucketed View

| Bucket | Cases | Mean speedup | Median speedup |
| --- | ---: | ---: | ---: |
| `8x8` | `25` | `1.063x` | `0.988x` |
| `16x16` | `15` | `1.685x` | `1.657x` |
| `shape` | `4` | `1.629x` | `1.637x` |
| `compat` | `18` | `2.087x` | `1.980x` |

## Writeback Effects

The wider writeback path cuts store traffic roughly in half for the larger
cases. Examples:

| Case | Baseline W beats | Current W beats | Baseline AW | Current AW |
| --- | ---: | ---: | ---: | ---: |
| `test_numeric_02_edge_identity_16_int8` | `128` | `64` | `1` | `1` |
| `test_numeric_42_shape_m8n32k16_int8` | `128` | `64` | `1` | `1` |
| `test_numeric_51_compat_m16n32k32_int8` | `256` | `128` | `1` | `1` |
| `test_numeric_59_compat_m32n64k64_int8` | `1024` | `512` | `4` | `2` |
| `test_numeric_62_compat_m32n128k128_int8_int32` | `2048` | `1024` | `8` | `4` |

## Caveat

This comparison is intentionally end-to-end and measures the shipped
configuration, so the gain combines:

- the true `16x16` compute path
- the wider `128-bit` AXI/RAM datapath
- the reduced number of writeback beats and bursts

It is therefore the most relevant number for deployment of the current
`comparison/tpu` configuration, but it is not an isolated PE-array-only
microbenchmark.
