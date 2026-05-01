# Performance, Precision, Coverage Re-evaluation

- Date: 2026-05-01
- RTL baseline: current working tree after removing sim-only RTL wrappers and running debug/tests directly on synthesizable RTL tops.
- DC/Formality: not rerun in this pass.

## Summary

| Area | Result | Assessment |
|---|---:|---|
| RTL performance profile, causal full run | 85,531 scheduled cycles | Healthy; profile still well below the 300k cycle target. |
| RTL performance profile, serial stage sum | 155,712 cycles | Main costs remain K/V load, PV, QK, and store. |
| Normal precision, worst sampled case | mean 0.022474, max 0.042657 | Passes current mean <= 0.03 and max <= 0.10 thresholds. |
| Extreme precision diagnostic | 13/16 cases fail threshold | Expected adversarial stress behavior; dominated by QK saturation and OACC Q4.12 range. |
| RTL extreme precision cocotb | 2/2 pass | RTL matches the expected failure-mode model. |
| Functional coverage | 32/46 bins, 69.57% | Coverage model now exposes stale descriptor/stream bins after moving to AXI top. |
| Line code coverage, FA_TOP_BASELINE AXI suite | 1994/2442 lines, 81.65% | Acceptable top-level line coverage for current smoke/full AXI suite. |

## Performance

Command:

```bash
python3 scripts/fa_baseline_profile.py
```

Outputs:

- `debug/archive/backend/20260501_fa_baseline_profile_summary.md`
- `debug/archive/backend/20260501_fa_baseline_profile_causal.json`
- `debug/archive/backend/20260501_fa_baseline_rowstate_profile.json`

Top contributors from the serial profile:

| Stage | Per invocation | Count | Total | Share |
|---|---:|---:|---:|---:|
| k_load | 267 | 136 | 36,312 | 23.32% |
| v_load | 267 | 136 | 36,312 | 23.32% |
| pv | 229 | 136 | 31,144 | 20.00% |
| qk | 157 | 136 | 21,352 | 13.71% |
| row_update | n/a | 136 | 11,968 | 7.69% |
| store | 674 | 16 | 10,784 | 6.93% |

Notes:

- Scheduled full-run estimate is 85,531 cycles after modeled overlap.
- Row-state subtotal is 11,968 cycles; direct `FA_ROW_STATE_REAL` microbench reports 88 cycles for valid/history blocks and 40 cycles for future-masked blocks.
- P-load remains bypassed and modeled as 0 cycles.

## Precision

Commands:

```bash
python3 scripts/fa_precision_analysis.py --case single_tile_noncausal
python3 scripts/fa_precision_analysis.py --case single_q_full_kv_causal --q-row-start 0 --q-row-start 112 --q-row-start 240
python3 scripts/fa_extreme_precision_analysis.py --random-cases 10 --top 8 --out-dir debug
python3 sim/cocotb/run.py fa_extreme_precision --rebuild
```

Normal precision results:

| Case | q row start | Total mean | Total max | Pass |
|---|---:|---:|---:|---|
| single_tile_noncausal | 0 | 0.003252 | 0.008083 | yes |
| single_q_full_kv_causal | 0 | 0.006241 | 0.014877 | yes |
| single_q_full_kv_causal | 112 | 0.013960 | 0.025750 | yes |
| single_q_full_kv_causal | 240 | 0.022474 | 0.042657 | yes |

Extreme diagnostic:

- Report: `debug/archive/backend/20260501_fa_extreme_precision_report.md`
- 16 adversarial/random-amplitude cases evaluated.
- 13/16 exceed the nominal precision thresholds.
- Worst cases remain tied to QK saturation/scale and OACC quantization range, not to wrapper removal.
- RTL cocotb `fa_extreme_precision` passed both targeted tests.

## Coverage

Functional coverage command:

```bash
make fa_functional_coverage REBUILD=1
```

Functional coverage output:

- `sim/cocotb/coverage/functional/functional_coverage.json`
- `sim/cocotb/coverage/functional/functional_coverage.md`
- Result: 32/46 bins, 69.57%, 28 raw reports.

Missing functional bins:

- CSR: `csr.alignment_error`, `csr.byte_counters_exact`, `csr.start_while_busy`
- DMA descriptor/protocol: `dma.descriptor_counts_exact`, `dma.descriptor_order_qkv`, `protocol.no_extra_dma_after_done`, `protocol.read_fault_early_last`, `protocol.read_fault_missing_final_last`
- Old stream-flow model: `stream.constant_ready`, `stream.read_data_backpressure`, `stream.read_desc_backpressure`, `stream.valid_hold`, `stream.write_data_backpressure`, `stream.write_desc_backpressure`

Interpretation:

- The AXI bins are mostly covered after switching top-level tests to `FA_TOP_BASELINE`.
- The remaining descriptor/stream bins are from the old descriptor-level test model. They should either be redefined as internal-monitor bins on the synthesizable RTL hierarchy or retired from the top-level coverage target.

Line code coverage command:

```bash
make fa_code_coverage COVERAGE_MODE=line REBUILD=1 CODE_COVERAGE_SUITES='fa_full_axi fa_p_bypass fa_shared_gemm fa_oacc_update fa_rowstate_profile'
```

Line code coverage by suite:

| Suite | Covered | Lines | Line coverage |
|---|---:|---:|---:|
| fa_full_axi | 1,994 | 2,442 | 81.65% |
| fa_p_bypass | 13 | 13 | 100.00% |
| fa_shared_gemm | 287 | 301 | 95.35% |
| fa_oacc_update | 161 | 165 | 97.58% |
| fa_rowstate_profile | 590 | 612 | 96.41% |

## Recommended Next Steps

1. Rebaseline the functional coverage model around synthesizable RTL entry points:
   - Keep AXI, CSR, numeric shape, row-state, and submodule bins.
   - Replace old descriptor/stream bins with AXI-master-facing and internal hierarchy monitor bins.
2. Add direct AXI tests for `csr.start_while_busy`, exact byte counters, and AXI error/fault paths to recover meaningful top-level coverage.
3. Track extreme precision as diagnostic, not pass/fail, unless the numeric spec is widened or QK/OACC formats change.
