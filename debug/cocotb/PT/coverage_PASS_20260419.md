# PT Coverage 覆盖率报告

| 字段 | 内容 |
| --- | --- |
| 报告名称 | `coverage` |
| 生成方式 | `make -C sim/cocotb coverage` |
| 仿真后端 | `Verilator` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260419` |

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
| `line(raw)` | `2466 / 2645 = 93.23%` |
| `line(adjusted)` | `2443 / 2541 = 96.14%` |
| `branch(adjusted)` | `97979 / 165993 = 59.03%` |
| `expr(adjusted)` | `590 / 599 = 98.50%` |
| `toggle` | `92407 / 159408 = 57.97%` |
| `user` | `0 / 0 = 0.00%` |

## Residual 分类

| 分类 | 数量 |
| --- | --- |
| `instrumentation_noise` | `358` |
| `test_gap` | `134764` |

## PT Wrapper And v2 Files

| 文件 | line(adj) | expr(adj) | toggle | user |
| --- | --- | --- | --- | --- |
| `pt.v` | `37 / 41 (90.24%)` | `0 / 0 (0.00%)` | `674 / 998 (67.54%)` | `0 / 0 (0.00%)` |
| `pt_dispatch.v` | `0 / 0 (0.00%)` | `0 / 0 (0.00%)` | `0 / 0 (0.00%)` | `0 / 0 (0.00%)` |
| `pt_dispatch_v2.v` | `166 / 170 (97.65%)` | `46 / 46 (100.00%)` | `1776 / 2192 (81.02%)` | `0 / 0 (0.00%)` |
| `pt_malloc.v` | `523 / 524 (99.81%)` | `192 / 192 (100.00%)` | `2686 / 6496 (41.35%)` | `0 / 0 (0.00%)` |
| `pt_md.v` | `0 / 0 (0.00%)` | `0 / 0 (0.00%)` | `0 / 0 (0.00%)` | `0 / 0 (0.00%)` |
| `pt_md_v2.v` | `562 / 596 (94.30%)` | `188 / 188 (100.00%)` | `12095 / 25692 (47.08%)` | `0 / 0 (0.00%)` |
| `pt_ce.v` | `0 / 0 (0.00%)` | `0 / 0 (0.00%)` | `0 / 0 (0.00%)` | `0 / 0 (0.00%)` |
| `pt_ce_v2.v` | `562 / 592 (94.93%)` | `72 / 76 (94.74%)` | `9367 / 27440 (34.14%)` | `0 / 0 (0.00%)` |

## 重点未覆盖点

### expr
- `gemu.v:117` `(clear==0 && fifo_m_ready==0) => 0`
- `pt_ce_v2.v:648` `(DRAIN_FULL_WIDTH==1 && launch_or_shadow_fire==1) => 1`
- `pt_ce_v2.v:648` `(DRAIN_FULL_WIDTH==1 && launch_or_shadow_fire==1) => 1`
- `pt_ce_v2.v:648` `(DRAIN_FULL_WIDTH==1 && launch_or_shadow_fire==1) => 1`
- `pt_ce_v2.v:648` `(DRAIN_FULL_WIDTH==1 && launch_or_shadow_fire==1) => 1`
- `pt_top_v2.v:622` `(ce_resp_valid==1 && ce_resp[31]==1) => 1`
- `pt_top_v2.v:622` `(ce_resp_valid==1 && ce_resp[31]==1) => 1`
- `pt_top_v2.v:622` `(ce_resp_valid==1 && ce_resp[31]==1) => 1`

### toggle
- `gema.v:10` `in_ready:1->0`
- `gema.v:10` `in_ready:1->0`
- `gema.v:11` `lhs_data[108]:0->1`
- `gema.v:11` `lhs_data[108]:1->0`
- `gema.v:11` `lhs_data[109]:0->1`
- `gema.v:11` `lhs_data[109]:1->0`
- `gema.v:11` `lhs_data[110]:0->1`
- `gema.v:11` `lhs_data[110]:1->0`

### user
- 当前 user coverage 点已全部命中。
