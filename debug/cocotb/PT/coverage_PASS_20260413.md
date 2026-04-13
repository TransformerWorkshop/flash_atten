# PT Coverage 覆盖率报告

| 字段 | 内容 |
| --- | --- |
| 报告名称 | `coverage` |
| 生成方式 | `make -C sim/cocotb coverage` |
| 仿真后端 | `Verilator` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260413` |

## 产物
- 覆盖汇总：[`coverage_types.md`](../../../sim/cocotb/coverage/coverage/coverage_types.md)
- metrics：[`coverage_metrics.json`](../../../sim/cocotb/coverage/coverage/coverage_metrics.json)
- lcov：[`coverage.info`](../../../sim/cocotb/coverage/coverage/coverage.info)
- raw data：[`coverage.dat`](../../../sim/cocotb/coverage/coverage/coverage.dat)

## 总体统计

| 指标 | 数值 |
| --- | --- |
| `line(raw)` | `1562 / 1592 = 98.12%` |
| `line(adjusted)` | `1560 / 1589 = 98.17%` |
| `expr(raw)` | `281 / 293 = 95.90%` |
| `expr(adjusted)` | `281 / 289 = 97.23%` |
| `toggle` | `68835 / 90954 = 75.68%` |
| `user` | `100 / 100 = 100.00%` |

## 相比上次运行的变化

| 指标 | Covered Delta | Percent Delta |
| --- | --- | --- |
| `line_adj` | `+248` | `+7.37%` |
| `expr_adj` | `+48` | `+14.31%` |
| `toggle` | `+16030` | `+4.80%` |
| `user` | `+18` | `+10.87%` |

## PT Core Files

| 文件 | line(adj) | expr(adj) | toggle | user |
| --- | --- | --- | --- | --- |
| `pt.v` | `147 / 151 (97.35%)` | `5 / 5 (100.00%)` | `6362 / 8500 (74.85%)` | `0 / 0 (0.00%)` |
| `pt_md.v` | `678 / 691 (98.12%)` | `191 / 198 (96.46%)` | `7987 / 12336 (64.75%)` | `62 / 62 (100.00%)` |
| `pt_ce.v` | `319 / 322 (99.07%)` | `26 / 26 (100.00%)` | `5730 / 9528 (60.14%)` | `38 / 38 (100.00%)` |

## 不可达点排除

- [`pt_md.v`](../../../rtl/pt_md.v) `325/326/333/334`：对应 `X/Y_DIV2 + odd-dim` 的 `qcfg_hdr_err` 路径，已被顶层 power-of-two guard 永久拦截。
- [`pt_md.v`](../../../rtl/pt_md.v) `is_pow2(value<=0)`：仅在非法 elaboration 参数下成立，不属于合法 PT 配置空间。
- [`pt_ce.v`](../../../rtl/pt_ce.v) `is_pow2(value<=0)`：仅在非法 elaboration 参数下成立，不属于合法 PT 配置空间。
- [`pt_ce.v`](../../../rtl/pt_ce.v) `gemm_a_ready/gemm_b_ready == 0`：在 `ST_EXEC_FEED` 的合法 GEMM 握手下不可出现，作为第二批 confirmed unreachable expr 点处理。

## 重点未覆盖点

### expr
- `pt_md.v:382` `((lut_valid[li[2:0]])==1 && ((lut_id[li[2:0]]) == cur_id)==1 && lut_found==0) => 1`
- `pt_md.v:382` `((lut_valid[li[2:0]])==1 && ((lut_id[li[2:0]]) == cur_id)==1 && lut_found==0) => 1`
- `pt_md.v:766` `(ce_resp[31]==1) => 0`
- `pt_md.v:766` `(ce_resp[31]==1) => 0`
- `pt_md.v:813` `(cmd_b_row_aligned==0) => 1`
- `pt_md.v:822` `(cmd_matadd_legal==0) => 1`
- `pt_md.v:822` `(cmd_matadd_legal==0) => 1`
- `sram.v:37` `(en_b==1 && we_b==1) => 1`

### toggle
- `csr_bank.v:26` `pcsr_a_base[0]:0->1`
- `csr_bank.v:26` `pcsr_a_base[0]:1->0`
- `csr_bank.v:26` `pcsr_a_base[10]:0->1`
- `csr_bank.v:26` `pcsr_a_base[10]:1->0`
- `csr_bank.v:26` `pcsr_a_base[11]:0->1`
- `csr_bank.v:26` `pcsr_a_base[11]:1->0`
- `csr_bank.v:26` `pcsr_a_base[13]:0->1`
- `csr_bank.v:26` `pcsr_a_base[13]:1->0`

### user
- 当前 user coverage 点已全部命中。
