# Functional Coverage Model Update

Date: 2026-05-01

## Scope

Updated the functional coverage model to match the current synthesizable `FA_TOP_BASELINE` AXI top-level verification flow.

This pass does not modify RTL.

## Changes

- Rebased active coverage bins around current AXI/CSR/top-level behavior.
- Moved removed descriptor-harness and stream-harness bins to legacy status:
  - `dma.descriptor_counts_exact`
  - `dma.descriptor_order_qkv`
  - `protocol.no_extra_dma_after_done`
  - `protocol.read_fault_early_last`
  - `protocol.read_fault_missing_final_last`
  - `stream.*`
  - duplicate legacy `csr.alignment_error`
- Legacy bins are still accepted in old raw reports, but are excluded from the active coverage denominator.
- Added active AXI protocol bins:
  - `axi.no_extra_after_done`
  - `axi.read_fault_early_last`
  - `axi.read_fault_missing_final_last`
- Added current AXI-top tests/hits for:
  - exact `RD_BYTES` / `WR_BYTES`
  - no extra AXI traffic or byte-counter change after `DONE`
  - start command while busy
  - early AXI `RLAST` fault
  - missing final AXI `RLAST` fault
- Removed duplicate `fa_full` alias from the default functional coverage suite list; `fa_full_axi` already targets `FA_TOP_BASELINE`.

## Verification

Commands run:

```bash
python3 -m py_compile sim/cocotb/run.py sim/cocotb/tests/*.py scripts/fa_functional_coverage_report.py
python3 scripts/fa_functional_coverage_report.py --check-model-only
python3 run.py fa_baseline_axi --testcase test_fa_baseline_axi_byte_counters_exact,test_fa_baseline_axi_no_extra_after_done,test_fa_baseline_axi_start_while_busy_is_ignored --rebuild
python3 run.py fa_baseline_axi --testcase test_fa_baseline_axi_read_fault_early_last_sets_error,test_fa_baseline_axi_read_fault_missing_final_last_sets_error --rebuild
make fa_functional_coverage REBUILD=1
```

Results:

| Item | Result |
|---|---:|
| Active bins | `37` |
| Hit bins | `37` |
| Functional coverage | `100.00%` |
| Raw reports | `24` |
| Unknown hits | `0` |
| Legacy hits excluded | `0` |

Remaining active missing bins: none.

## Interpretation

The previous `32/46 = 69.57%` result mixed current AXI-top coverage with stale descriptor/stream coverage targets. The updated `37/37 = 100.00%` result is a clean baseline for the synthesizable RTL flow.

The final two gaps were closed by AXI memory-agent fault injection for malformed read `RLAST` behavior. Both cases drive `STATUS.ERROR` through the current `FA_AXI_RD_MASTER` detection path.
