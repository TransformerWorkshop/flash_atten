# PT Coverage Report

| Field | Value |
| --- | --- |
| Report name | `coverage` |
| Generation path | `make -C sim/cocotb coverage` |
| Simulator | `Verilator` |
| Status | `PASS` |
| Timestamp | `20260415` |

## Artifacts

- Coverage type summary: [`coverage_types.md`](../../../sim/cocotb/coverage/coverage/coverage_types.md)
- Metrics: [`coverage_metrics.json`](../../../sim/cocotb/coverage/coverage/coverage_metrics.json)
- Functional coverage: [`functional_coverage.md`](../../../sim/cocotb/coverage/coverage/functional_coverage.md)
- Residual uncovered report: [`residual_uncovered.md`](../../../sim/cocotb/coverage/coverage/residual_uncovered.md)
- LCOV info: [`coverage.info`](../../../sim/cocotb/coverage/coverage/coverage.info)
- Raw coverage data: [`coverage.dat`](../../../sim/cocotb/coverage/coverage/coverage.dat)

## Overall Metrics

| Metric | Value |
| --- | --- |
| `line(raw)` | `2072 / 2161 = 95.88%` |
| `line(adjusted)` | `2072 / 2161 = 95.88%` |
| `branch(adjusted)` | `108951 / 185900 = 58.61%` |
| `expr(adjusted)` | `628 / 676 = 92.90%` |
| `toggle` | `104434 / 180770 = 57.77%` |
| `user` | `0 / 0 = 0.00%` |

## Residual Classification

| Classification | Count |
| --- | ---: |
| `instrumentation_noise` | `525` |
| `low_value_bit_toggle` | `167` |
| `test_gap` | `152730` |

## PT Wrapper And v2 Files

| File | line(adj) | expr(adj) | toggle | user |
| --- | --- | --- | --- | --- |
| `pt.v` | `37 / 41 (90.24%)` | `0 / 0 (0.00%)` | `1024 / 1574 (65.06%)` | `0 / 0 (0.00%)` |
| `pt_dispatch.v` | `19 / 19 (100.00%)` | `0 / 0 (0.00%)` | `586 / 828 (70.77%)` | `0 / 0 (0.00%)` |
| `pt_dispatch_v2.v` | `158 / 162 (97.53%)` | `52 / 52 (100.00%)` | `1568 / 2052 (76.41%)` | `0 / 0 (0.00%)` |
| `pt_malloc.v` | `427 / 457 (93.44%)` | `188 / 194 (96.91%)` | `2404 / 5532 (43.46%)` | `0 / 0 (0.00%)` |
| `pt_md.v` | `71 / 74 (95.95%)` | `0 / 0 (0.00%)` | `7377 / 13036 (56.59%)` | `0 / 0 (0.00%)` |
| `pt_md_v2.v` | `480 / 507 (94.67%)` | `204 / 228 (89.47%)` | `11190 / 21984 (50.90%)` | `0 / 0 (0.00%)` |
| `pt_ce.v` | `48 / 50 (96.00%)` | `0 / 0 (0.00%)` | `6405 / 13216 (48.46%)` | `0 / 0 (0.00%)` |
| `pt_ce_v2.v` | `248 / 251 (98.80%)` | `72 / 76 (94.74%)` | `10470 / 20864 (50.18%)` | `0 / 0 (0.00%)` |

## Representative Residuals

### expr

- `pt_ce_v2.v:327` `((wi >= store_chunk_base_r)==0) => 0`
- `pt_malloc.v:207` `(slot_found==0 && (lut_valid[si[2:0]])==1 && ((lut_id[si[2:0]]) == malloc_cmd_id)==1) => 1`
- `pt_malloc.v:211` `(free_found==0 && (lut_valid[si[2:0]])==0) => 1`

### toggle

- `csr_bank.v:29` `quant_inv_scale[0]:0->1`
- `csr_bank.v:29` `quant_inv_scale[103]:0->1`
- `csr_bank.v:29` `quant_inv_scale[104]:0->1`
- `csr_bank.v:29` `quant_inv_scale[107]:0->1`

### user

- All current user coverage points are covered.
