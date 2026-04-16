# PT Tiled Application

这个目录提供一个相对独立的小型 CLI，用来分析和验证基于当前 PT primitive 的 tiled GEMM。

当前 app 包名已经从更早期的 shape-specific 形式 `pt_mnk16x64x16` 泛化为 `pt_tiled_gemm`，以表达它面向一般 tiled GEMM 问题，而不是单一固定 shape。

当前 PT 的原生 primitive 固定为：

- `16x16x16` full-tile `MATMUL`
- `per_tensor scale`
- 可选 `MATADD` 链式归约

因此 app 不再只服务某一个固定 shape，而是支持更多 `M/K/N` 组合，但有一个明确前提：

- `M`、`K`、`N` 都必须是 `16` 的倍数

## 支持的能力

- `recommend`
  - 对任意合法 `M/K/N` 输出 tiled 分解和算法推荐
- `verify`
  - 运行 app 本地 cocotb tests，验证该 `M/K/N` 的 tiled 流程
- `report`
  - 生成 Markdown 报告，并把 verify 的 measured 数据回灌到推荐结果

## CLI

推荐算法：

```bash
python3 app/pt_tiled_gemm/run.py recommend --m 16 --k 64 --n 16
python3 app/pt_tiled_gemm/run.py recommend --m 32 --k 32 --n 16
python3 app/pt_tiled_gemm/run.py recommend --m 32 --k 64 --n 32 --json
```

运行验证：

```bash
python3 app/pt_tiled_gemm/run.py verify --m 16 --k 64 --n 16 --sim icarus
python3 app/pt_tiled_gemm/run.py verify --m 16 --k 32 --n 16 --sim icarus
python3 app/pt_tiled_gemm/run.py verify --m 32 --k 32 --n 16 --sim verilator
```

生成报告：

```bash
python3 app/pt_tiled_gemm/run.py report --m 16 --k 64 --n 16 --sim icarus
python3 app/pt_tiled_gemm/run.py report --m 32 --k 32 --n 16 --sim icarus
```

## 默认输出

不同 shape 会写到不同文件，避免互相覆盖：

- metrics
  - `app/pt_tiled_gemm/out/verify_metrics_m<M>_k<K>_n<N>.json`
- report
  - `app/pt_tiled_gemm/out/report_m<M>_k<K>_n<N>.md`
- cocotb build/logs/results
  - `app/pt_tiled_gemm/out/cocotb/m<M>_k<K>_n<N>/...`

## 候选算法

- `host_reduce_direct_tiled_matmul`
  - 所有 partial 都直接 `MATMUL`
  - 导出后由 host 精确累加
- `host_reduce_load_then_matmul`
  - 每个 partial 先 `LOAD` 再 `MATMUL`
  - 导出后由 host 精确累加
- `pt_matadd_reduce`
  - 对每个输出 tile，partial GEMM 后用 `MATADD` 在 PT 内归约

补充说明：

- `verify` 的 testbench 当前还会额外测一个内部 path：`host_reduce_direct_pipelined`
- 这个 path 已经有 measured cycles，但 `recommend/report` 还没有把它纳入 planner 的候选排名

## 输出风格

`recommend` 和 `verify` 默认走更清晰的终端文本输出：

- Problem Summary
- Tile Summary
- Tile Ranges
- Candidate Comparison Table
- Unsupported Paths

如果需要机器可读数据：

- `recommend --json`
- `verify --json`

## 最近一次回归结果

最近一次完整回归基线仍是 `2026-04-15`，覆盖了基础功能、压力、随机、扩展、性能、coverage 和 app 级 verify。

在此基础上，`2026-04-16` 又补跑了：

- `sim/cocotb/run.py perf --sim icarus`
- app 级 `verify`：
  - `m16_k16_n16`
  - `m32_k16_n32`
  - `m32_k32_n32`
  - `m48_k32_n32`

| Suite / Flow | Simulator | Result | Notes / Artifacts |
| --- | --- | --- | --- |
| `smoke` | `icarus` | `PASS` | `4x4` + `8x8` 共 `16/16` 通过；包含新增 `multi-k` 用例 |
| `full` | `icarus` | `PASS` | `2x2/4x4/8x8` 共 `40/40` 通过；另有 `20` 个 power-of-two guard 用例按 expected-fail 匹配 |
| `ci` | `icarus` | `PASS` | core + stress 共 `50/50` 通过；另有 `20` 个 power-of-two guard 用例按 expected-fail 匹配 |
| `perf` | `icarus` | `PASS` | `legacy/upgrade x 4x4/8x8` 共 `12/12` 通过，日志位于 `sim/cocotb/logs/perf_*` |
| `randomized` | `icarus` | `PASS` | `20/20` profile-seed 组合通过，日志位于 `sim/cocotb/logs/randomized_*` |
| `extended` | `icarus` | `PASS` | `24/24` profile-seed 组合通过，日志位于 `sim/cocotb/logs/extended_*` |
| `soak` | `icarus` | `PASS` | `24/24` profile-seed 组合通过，日志位于 `sim/cocotb/logs/soak_*` |
| `coverage` | `verilator` | `PASS` | 共 `70/70` 通过；覆盖率产物见 `sim/cocotb/coverage/coverage/` |
| `app verify m16_k32_n16` | `icarus` | `PASS` | `4/4` 通过，见 `app/pt_tiled_gemm/out/verify_metrics_m16_k32_n16.json` |
| `app verify m16_k64_n16` | `icarus` | `PASS` | `4/4` 通过，见 `app/pt_tiled_gemm/out/verify_metrics_m16_k64_n16.json` |
| `app verify m16_k16_n16` | `icarus` | `PASS` | `5/5` 通过；`direct / pipelined / pt_matadd` 都是 `117` cycles |
| `app verify m32_k16_n32` | `icarus` | `PASS` | `5/5` 通过；`direct / pipelined / pt_matadd` 都是 `471` cycles |
| `app verify m32_k32_n32` | `icarus` | `FAIL` | `3/5` 通过；`direct=943`、`pipelined=639`、`pt_matadd_reduce` 失败 |
| `app verify m48_k32_n32` | `icarus` | `FAIL` | `1/5` 通过；fresh `ctrl_id` 流程已碰到 `LUT_DEPTH=8` 容量边界 |

补充说明：

- `coverage` 在 `icarus` 下无法直接使用当前 runner 的 `--coverage --assert` 构建参数，因此本次 coverage 回归使用 `verilator` 执行。
- 当前 `16x16` 宽配置的 perf one-off 也已补跑通过：
  - `sim/cocotb/results/perf_current_16x16_seed10.xml`
  - `sim/cocotb/logs/perf_current_16x16_seed10.test.log`
- 该 one-off 对应当前 `16x16` wide 配置的低层 timing 口径：
  - cache-hit `ctrl_accept -> ctrl_resp = 41` cycles
  - cold-miss `ctrl_accept -> ctrl_resp = 81` cycles
  - export `m_dma_req -> m_axis_tlast = 33` cycles
- 当前 app 流的已知限制：
  - 当软件为每个 partial 分配新的 `ctrl_id` 时，默认 `LUT_DEPTH=8` 会形成实际容量上限
  - `32x32x32` 的 `pt_matadd_reduce` 已经会碰到这个限制
  - `48x32x32` 连 `direct/pipelined` host-reduce 路径也会碰到这个限制
- 当前 `32x32x32` 的最好实测路径其实是 `host_reduce_direct_pipelined`
  - `639` cycles
  - 相比 plain `direct` 的 `943` cycles 快 `1.476x`
- 详细重评笔记见：
  - `debug/20260416_pt_current_version_reassessment.md`
- coverage 汇总文件位于：
  - `sim/cocotb/coverage/coverage/summary.txt`
  - `sim/cocotb/coverage/coverage/coverage_metrics.json`
  - `sim/cocotb/coverage/coverage/functional_coverage.md`
- 代表性日志：
  - `sim/cocotb/logs/ci_4x4_core_seed10.test.log`
  - `sim/cocotb/logs/ci_8x8_core_seed10.test.log`
  - `sim/cocotb/logs/perf_upgrade_8x8_seed10.test.log`
  - `sim/cocotb/logs/randomized_balanced_mix_8x8_seed810.test.log`
  - `sim/cocotb/logs/extended_qcfg_heavy_8x8_seed210.test.log`
  - `sim/cocotb/logs/soak_qcfg_heavy_8x8_seed210.test.log`
  - `sim/cocotb/logs/coverage_core_8x8_seed10.test.log`
