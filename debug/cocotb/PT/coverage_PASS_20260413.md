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
| `line(raw)` | `1369 / 1396 = 98.07%` |
| `line(adjusted)` | `1369 / 1392 = 98.35%` |
| `expr(raw)` | `275 / 293 = 93.86%` |
| `expr(adjusted)` | `275 / 281 = 97.86%` |
| `toggle` | `61405 / 73594 = 83.44%` |
| `user` | `92 / 92 = 100.00%` |

## 相比上次运行的变化

| 指标 | Covered Delta | Percent Delta |
| --- | --- | --- |
| `line_adj` | `+0` | `+0.00%` |
| `expr_adj` | `+0` | `+0.00%` |
| `toggle` | `+0` | `+0.00%` |
| `user` | `+0` | `+0.00%` |

## PT Core Files

| 文件 | line(adj) | expr(adj) | toggle | user |
| --- | --- | --- | --- | --- |
| `pt.v` | `134 / 138 (97.10%)` | `5 / 5 (100.00%)` | `5829 / 6820 (85.47%)` | `0 / 0 (0.00%)` |
| `pt_md.v` | `637 / 644 (98.91%)` | `183 / 188 (97.34%)` | `7103 / 11484 (61.85%)` | `62 / 62 (100.00%)` |
| `pt_ce.v` | `234 / 237 (98.73%)` | `32 / 32 (100.00%)` | `2194 / 2884 (76.07%)` | `30 / 30 (100.00%)` |

## 不可达点排除

- [`pt_md.v`](../../../rtl/pt_md.v) `325/326/333/334`：对应 `X/Y_DIV2 + odd-dim` 的 `qcfg_hdr_err` 路径，已被顶层 power-of-two guard 永久拦截。
- [`pt_md.v`](../../../rtl/pt_md.v) `is_pow2(value<=0)`：仅在非法 elaboration 参数下成立，不属于合法 PT 配置空间。
- [`pt_ce.v`](../../../rtl/pt_ce.v) `is_pow2(value<=0)`：仅在非法 elaboration 参数下成立，不属于合法 PT 配置空间。
- [`pt_ce.v`](../../../rtl/pt_ce.v) `gemm_a_ready/gemm_b_ready == 0`：在 `ST_EXEC_FEED` 的合法 GEMM 握手下不可出现，作为第二批 confirmed unreachable expr 点处理。

## 重点未覆盖点

### expr
- `pt_md.v:375` `((lut_valid[li[2:0]])==1 && ((lut_id[li[2:0]]) == cur_id)==1 && lut_found==0) => 1`
- `pt_md.v:375` `((lut_valid[li[2:0]])==1 && ((lut_id[li[2:0]]) == cur_id)==1 && lut_found==0) => 1`
- `pt_md.v:736` `(ce_resp[31]==1) => 0`
- `pt_md.v:736` `(ce_resp[31]==1) => 0`
- `pt_md.v:775` `(cmd_b_row_aligned==0) => 1`
- `sram.v:35` `(en_b==1 && we_b==1) => 1`

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
