# FA hard macro SRAM replacement report

Date: 2026-04-26

## Macro selection

Selected hard macro: `TEM5N28HPCPLVTA64X64M4SWSO` (`tem5n28hpcplvta64x64m4swso_110a` family).

The wrapper keeps the existing one-cycle synchronous SRAM contract and maps to the hard macro under `SYNTHESIS`. Behavioral simulation uses the same 64-bit, bit-write-mask semantics.

## Instance table

| Buffer | Logical organization | Implementation | 64x64 macro instances |
| --- | --- | --- | ---: |
| Q tile buffer | 4 banks x 512-bit rows x depth 8 | 4 row buffers, 8 chunks each | 32 |
| K tile buffer | 4 banks x 512-bit rows x depth 8 | 4 row buffers, 8 chunks each | 32 |
| V tile shadow buffer | 4 banks x 512-bit rows x depth 8 | 4 row buffers, 8 chunks each | 32 |
| V PV-layout buffer | 512-bit rows x depth 32 | 8 chunks | 8 |
| P buffer | 512-bit rows x depth 8 | 8 chunks | 8 |
| O accumulator row-read copy | 1024-bit rows x depth 16 | 16 chunks | 16 |
| O accumulator export-read copy | 1024-bit rows x depth 16 | 16 chunks | 16 |
| Total | - | - | 144 |

## Verification summary

| Area | Command or test | Result |
| --- | --- | --- |
| Python syntax | `python3 -m py_compile ...` | PASS |
| RTL syntax | `iverilog -g2012 -I rtl -s FA_TOP_BASELINE_SIM -o /tmp/fa_top_baseline_sim_check.out rtl/*.v` | PASS |
| Synthesis macro path syntax | `iverilog -g2012 -DSYNTHESIS -I rtl -s FA_TOP_BASELINE_SIM -o /tmp/fa_top_baseline_sim_synth_check.out rtl/*.v` | PASS |
| Directed SRAM mapping | 7-test Icarus group: V-PV layout, Q/K/V mapping, QK core, PV core, OACC export coherence | PASS, 7/7 |
| Numeric, single Q/single KV noncausal | Verilator `test_fa_numeric_single_q_single_kv_noncausal` | PASS |
| Numeric, single Q/full KV causal | Verilator `test_fa_numeric_single_q_full_kv_causal` | Known pre-existing threshold miss: `mean_err=0.03118550985041098` vs limit `0.03` |
| Performance profile | Verilator `test_fa_baseline_profile` | PASS |
| Rowstate micro-profile | Icarus `test_fa_baseline_rowstate_latency_samples` | PASS |

## Performance samples

Profile JSON: `debug/20260426_fa_baseline_profile_hardmacro.json`

Rowstate JSON: `debug/20260426_fa_baseline_rowstate_hardmacro.json`

Key sampled cycles:

| Stage | Cycles |
| --- | ---: |
| q_load | 130 |
| k_load | 130 |
| v_load | 130 |
| row_init | 2 |
| oacc_clear | 17 |
| qk | 53 |
| score_post | 18 |
| row_update future_masked | 43 |
| row_update diagonal/history | 91 |
| pv | 110 |
| oacc_update | 66 |
| store | 562 |
| scheduler overlap total | 96144 |
| serial extrapolated total | 158704 |

Rowstate micro-profile:

| Case | Row state cycles | Row update cycles |
| --- | ---: | ---: |
| masked | 33 | 42 |
| valid | 81 | 90 |
