# PT Coverage 覆盖率报告

| 字段 | 内容 |
| --- | --- |
| 报告名称 | `coverage` |
| 生成方式 | `make -C sim/cocotb coverage` |
| 仿真后端 | `Verilator` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260416` |

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
| `line(raw)` | `2267 / 2378 = 95.33%` |
| `line(adjusted)` | `2267 / 2378 = 95.33%` |
| `branch(adjusted)` | `111290 / 188212 = 59.13%` |
| `expr(adjusted)` | `598 / 635 = 94.17%` |
| `toggle` | `106422 / 182326 = 58.37%` |
| `user` | `0 / 0 = 0.00%` |

## Residual 分类

| 分类 | 数量 |
| --- | --- |
| `instrumentation_noise` | `340` |
| `test_gap` | `152634` |

## PT Wrapper And v2 Files

| 文件 | line(adj) | expr(adj) | toggle | user |
| --- | --- | --- | --- | --- |
| `pt.v` | `37 / 41 (90.24%)` | `0 / 0 (0.00%)` | `1048 / 1574 (66.58%)` | `0 / 0 (0.00%)` |
| `pt_dispatch.v` | `21 / 21 (100.00%)` | `0 / 0 (0.00%)` | `630 / 836 (75.36%)` | `0 / 0 (0.00%)` |
| `pt_dispatch_v2.v` | `158 / 162 (97.53%)` | `46 / 46 (100.00%)` | `1732 / 2148 (80.63%)` | `0 / 0 (0.00%)` |
| `pt_malloc.v` | `446 / 479 (93.11%)` | `202 / 208 (97.12%)` | `2620 / 5676 (46.16%)` | `0 / 0 (0.00%)` |
| `pt_md.v` | `74 / 77 (96.10%)` | `0 / 0 (0.00%)` | `7916 / 13060 (60.61%)` | `0 / 0 (0.00%)` |
| `pt_md_v2.v` | `497 / 523 (95.03%)` | `208 / 220 (94.55%)` | `11929 / 22024 (54.16%)` | `0 / 0 (0.00%)` |
| `pt_ce.v` | `49 / 52 (94.23%)` | `0 / 0 (0.00%)` | `5664 / 13232 (42.81%)` | `0 / 0 (0.00%)` |
| `pt_ce_v2.v` | `400 / 422 (94.79%)` | `24 / 24 (100.00%)` | `8036 / 21348 (37.64%)` | `0 / 0 (0.00%)` |

## 重点未覆盖点

### expr
- `gemu.v:116` `(clear==0 && fifo_m_ready==0) => 0`
- `pt_malloc.v:221` `(slot_found==0 && (lut_valid[si[2:0]])==1 && ((lut_id[si[2:0]]) == malloc_cmd_id)==1) => 1`
- `pt_malloc.v:221` `(slot_found==0 && (lut_valid[si[2:0]])==1 && ((lut_id[si[2:0]]) == malloc_cmd_id)==1) => 1`
- `pt_malloc.v:225` `(free_found==0 && (lut_valid[si[2:0]])==0) => 1`
- `pt_malloc.v:225` `(free_found==0 && (lut_valid[si[2:0]])==0) => 1`
- `pt_malloc.v:627` `((malloc_cmd_kind == 2'h0)==1 && cmd_need_a_fill==0 && cmd_need_b_fill==0) => 1`
- `pt_malloc.v:627` `((malloc_cmd_kind == 2'h0)==1 && cmd_need_a_fill==0 && cmd_need_b_fill==0) => 1`
- `pt_md_v2.v:277` `(dma_error==1) => 1`

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
