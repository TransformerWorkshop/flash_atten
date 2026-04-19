# PT Coverage 覆盖率报告

| 字段 | 内容 |
| --- | --- |
| 报告名称 | `coverage` |
| 生成方式 | `make -C sim/cocotb coverage` |
| 仿真后端 | `Verilator` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260415` |

## 产物
- 覆盖汇总：[`coverage_types.md`](../../../sim/cocotb/coverage/coverage/coverage_types.md)
- metrics：[`coverage_metrics.json`](../../../sim/cocotb/coverage/coverage/coverage_metrics.json)
- 功能覆盖：[`functional_coverage.md`](../../../sim/cocotb/coverage/coverage/functional_coverage.md)
- residual：[`residual_uncovered.md`](../../../sim/cocotb/coverage/coverage/residual_uncovered.md)
- lcov：[`coverage.info`](../../../sim/cocotb/coverage/coverage/coverage.info)
- raw data：[`coverage.dat`](../../../sim/cocotb/coverage/coverage/coverage.dat)

## 总体统计

| 指标 | 数值 |
| --- | --- |
| `line(raw)` | `2080 / 2169 = 95.90%` |
| `line(adjusted)` | `2080 / 2169 = 95.90%` |
| `branch(adjusted)` | `109239 / 186500 = 58.57%` |
| `expr(adjusted)` | `628 / 676 = 92.90%` |
| `toggle` | `104714 / 181362 = 57.74%` |
| `user` | `0 / 0 = 0.00%` |

## Residual 分类

| 分类 | 数量 |
| --- | --- |
| `instrumentation_noise` | `533` |
| `low_value_bit_toggle` | `167` |
| `test_gap` | `153346` |

## PT Wrapper And v2 Files

| 文件 | line(adj) | expr(adj) | toggle | user |
| --- | --- | --- | --- | --- |
| `pt.v` | `37 / 41 (90.24%)` | `0 / 0 (0.00%)` | `1024 / 1574 (65.06%)` | `0 / 0 (0.00%)` |
| `pt_dispatch.v` | `19 / 19 (100.00%)` | `0 / 0 (0.00%)` | `586 / 828 (70.77%)` | `0 / 0 (0.00%)` |
| `pt_dispatch_v2.v` | `160 / 164 (97.56%)` | `52 / 52 (100.00%)` | `1656 / 2140 (77.38%)` | `0 / 0 (0.00%)` |
| `pt_malloc.v` | `429 / 459 (93.46%)` | `188 / 194 (96.91%)` | `2500 / 5620 (44.48%)` | `0 / 0 (0.00%)` |
| `pt_md.v` | `71 / 74 (95.95%)` | `0 / 0 (0.00%)` | `7377 / 13036 (56.59%)` | `0 / 0 (0.00%)` |
| `pt_md_v2.v` | `480 / 507 (94.67%)` | `204 / 228 (89.47%)` | `11190 / 21984 (50.90%)` | `0 / 0 (0.00%)` |
| `pt_ce.v` | `48 / 50 (96.00%)` | `0 / 0 (0.00%)` | `6413 / 13216 (48.52%)` | `0 / 0 (0.00%)` |
| `pt_ce_v2.v` | `252 / 255 (98.82%)` | `72 / 76 (94.74%)` | `10526 / 21280 (49.46%)` | `0 / 0 (0.00%)` |

## 重点未覆盖点

### expr
- `pt_ce_v2.v:331` `((wi >= store_chunk_base_r)==0) => 0`
- `pt_ce_v2.v:331` `((wi >= store_chunk_base_r)==0) => 0`
- `pt_ce_v2.v:331` `((wi >= store_chunk_base_r)==0) => 0`
- `pt_ce_v2.v:331` `((wi >= store_chunk_base_r)==0) => 0`
- `pt_malloc.v:208` `(slot_found==0 && (lut_valid[si[2:0]])==1 && ((lut_id[si[2:0]]) == malloc_cmd_id)==1) => 1`
- `pt_malloc.v:208` `(slot_found==0 && (lut_valid[si[2:0]])==1 && ((lut_id[si[2:0]]) == malloc_cmd_id)==1) => 1`
- `pt_malloc.v:212` `(free_found==0 && (lut_valid[si[2:0]])==0) => 1`
- `pt_malloc.v:212` `(free_found==0 && (lut_valid[si[2:0]])==0) => 1`

### toggle
- `csr_bank.v:29` `quant_inv_scale[0]:0->1`
- `csr_bank.v:29` `quant_inv_scale[0]:1->0`
- `csr_bank.v:29` `quant_inv_scale[103]:0->1`
- `csr_bank.v:29` `quant_inv_scale[103]:1->0`
- `csr_bank.v:29` `quant_inv_scale[104]:0->1`
- `csr_bank.v:29` `quant_inv_scale[104]:1->0`
- `csr_bank.v:29` `quant_inv_scale[107]:0->1`
- `csr_bank.v:29` `quant_inv_scale[107]:1->0`

### user
- 当前 user coverage 点已全部命中。
