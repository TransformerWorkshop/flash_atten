# PT Throughput & Memory Bottleneck Evaluation - 2026-04-12 17:06:01 (CST)

## Summary
- 评估对象分两层：
  - `PT` 当前主路径的 tile 级吞吐率
  - attention 映射下的外存压力与复用收益
- 评估脚本：
  - [pt_perf_model.py](../scripts/pt_perf_model.py)
- 评估口径：
  - 主结论使用 `cycles`、`ops/cycle`、`bytes/op`
  - 不默认给绝对 `TOPS`
  - 若后续提供 `freq-mhz` 与外部带宽，脚本可换算 `latency(ns)`、`GOPS/TOPS`
- 核心结论：
  - 冷 miss 路径外部输入为首要瓶颈
  - hit / `M-window` 复用后，瓶颈从外部 load 转移到片上 `M` 串行写回
  - `4x4` 时复用比例超过 `27.5%`，`8x8` 时复用比例超过 `37.5%`，瓶颈就会从外部输入转移到片上执行

## Evaluation Basis
### RTL facts
- `PT` 当前 `MATMUL` 主路径仅支持 `MNK = FULL/FULL/FULL`。[pt_md.v](../rtl/pt_md.v)
- `GEMM` 的累加深度固定为 `gemm_num_acc = GEMM_X_DIM`。[pt_ce.v](../rtl/pt_ce.v)
- A/B 冷加载 beats：
  - `A = X^2`
  - `B = Y^2`
- M 导出 beats：
  - `X * Y`
- `PT_CE` 内部执行路径分解：
  - issue/dispatch = `1 cycle`
  - `ST_EXEC_START` = `1 cycle`
  - `ST_EXEC_FEED` = `X cycles`
  - GEMM collect/stream turn = `2 cycles`
  - row capture = `X cycles`
  - `M` 串行写回 = `X * Y cycles`
  - response merge = `1 cycle`
- 因此内部执行到 `ctrl_resp` 可见的总周期模型为：
  - `internal_total = X*Y + 2*X + 5`
- `M` 写回使用双视图镜像：
  - A 视图一份
  - B/export 视图一份
  - 因此 `M` 写回片上流量为 `2 * X * Y * word_bytes`

### Log calibration
- 采用 cocotb smoke 日志校准默认协议开销：
  - [`smoke_4x4_seed10.test.log`](../sim/cocotb/logs/smoke_4x4_seed10.test.log)
  - [`smoke_8x8_seed10.test.log`](../sim/cocotb/logs/smoke_8x8_seed10.test.log)
- 默认协议参数：
  - `dma_req_overhead_cycles = 2`
  - `dma_done_latency_cycles = 2`
  - `m_dma_done_latency_cycles = 2`
- 校准结果：
  - `4x4 cold_miss`: 模型给出 `A dma_req -> ctrl_resp = 69 cycles`，与日志 `260ns -> 950ns` 一致
  - `8x8 cold_miss`: 模型给出 `A dma_req -> ctrl_resp = 221 cycles`，与日志 `260ns -> 2470ns` 一致

## Method & Formulas
### Compute
- `MACs_per_tile = X * Y * X`
- `Ops_per_tile = 2 * MACs_per_tile`

### External memory
- `word_bytes = DATA_WIDTH / 8`
- `A_load_beats = X^2`
- `B_load_beats = Y^2`
- `export_beats = X * Y`
- `cold_input_bytes = word_bytes * (X^2 + Y^2)`
- `export_bytes = word_bytes * (X * Y)`
- `cold_total_ext_bytes = word_bytes * (X^2 + Y^2 + X*Y)`
- `hit/m_window_ext_bytes = word_bytes * (X * Y)`

### External phase cycles
- `A_load_cycles = ceil(X^2 / r_in) + req_overhead + dma_done_latency`
- `B_load_cycles = ceil(Y^2 / r_in) + req_overhead + dma_done_latency`
- `input_phase_cycles = A_load_cycles + B_load_cycles`
- `export_phase_cycles = ceil(X*Y / r_out) + req_overhead + m_dma_done_latency`

### Internal execution cycles
- `internal_total = 1 + 1 + X + 2 + X + X*Y + 1`
- 化简后：
  - `internal_total = X*Y + 2X + 5`

### On-chip memory traffic
- `operand_read_bytes = word_bytes * X * (X + Y)`
- `m_writeback_bytes = word_bytes * X * Y * 2`
- `export_read_bytes = word_bytes * X * Y`
- `onchip_total_bytes = operand_read_bytes + m_writeback_bytes + export_read_bytes`

### Scenarios
- `cold_miss`
  - `tile_cycles = input + internal + export`
- `cache_hit`
  - `tile_cycles = internal + export`
- `m_window`
  - `tile_cycles = internal + export`
- `steady_stream_cold`
  - 假设下一 tile 的 cold load 可与当前 tile 的 compute / export 重叠
  - `steady_cycles = max(input, internal, export)`
- `steady_stream_mixed`
  - 默认 `cold_ratio = 0.5`
  - `steady_cycles = max(cold_ratio * input, internal, export)`
  - 脚本支持通过 `--cold-ratio` 评估任意冷启动比例

## Tile-Level Results
### 4x4
| Scenario | To `ctrl_resp` (cycles) | End-to-end tile (cycles) | Sustained cyc/tile | Ops/cycle | Ext bytes/tile | Ext bytes/op | On-chip bytes/op | Overall bottleneck |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `cold_miss` | 69 | 89 | 89 | 1.4382 | 192 | 1.5000 | 2.5000 | `external_input` |
| `cache_hit` | 29 | 49 | 49 | 2.6122 | 64 | 0.5000 | 2.5000 | `internal_execution` |
| `m_window` | 29 | 49 | 49 | 2.6122 | 64 | 0.5000 | 2.5000 | `internal_execution` |
| `steady_stream_cold` | 69 | 89 | 40 | 3.2000 | 192 | 1.5000 | 2.5000 | `external_input` |
| `steady_stream_mixed` (`cold_ratio=0.5`) | 49 | 69 | 29 | 4.4138 | 128 | 1.0000 | 2.5000 | `internal_execution` |

### 8x8
| Scenario | To `ctrl_resp` (cycles) | End-to-end tile (cycles) | Sustained cyc/tile | Ops/cycle | Ext bytes/tile | Ext bytes/op | On-chip bytes/op | Overall bottleneck |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `cold_miss` | 221 | 289 | 289 | 3.5433 | 768 | 0.7500 | 1.2500 | `external_input` |
| `cache_hit` | 85 | 153 | 153 | 6.6928 | 256 | 0.2500 | 1.2500 | `internal_execution` |
| `m_window` | 85 | 153 | 153 | 6.6928 | 256 | 0.2500 | 1.2500 | `internal_execution` |
| `steady_stream_cold` | 221 | 289 | 136 | 7.5294 | 768 | 0.7500 | 1.2500 | `external_input` |
| `steady_stream_mixed` (`cold_ratio=0.5`) | 153 | 221 | 85 | 12.0471 | 512 | 0.5000 | 1.2500 | `internal_execution` |

### Immediate observations
- `4x4 -> 8x8` 时：
  - 单 tile 运算量提升 `8x`
  - 冷 miss end-to-end latency 由 `89` cycles 提升到 `289` cycles，约 `3.25x`
  - steady cold throughput 由 `3.2` ops/cycle 提升到 `7.53` ops/cycle
- 对当前设计而言，tile 增大后：
  - `ops/cycle` 提升
  - 但内部执行中 `M` 写回占比迅速上升

## Internal Bottleneck Analysis
### Stage breakdown
| Tile | issue | start | feed | collect | row_capture | m_writeback | resp | internal_total | internal bottleneck |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `4x4` | 1 | 1 | 4 | 2 | 4 | 16 | 1 | 29 | `m_writeback` |
| `8x8` | 1 | 1 | 8 | 2 | 8 | 64 | 1 | 85 | `m_writeback` |

### Share inside internal execution
| Tile | `gemm_feed` share | `row_capture` share | `m_writeback` share |
| --- | ---: | ---: | ---: |
| `4x4` | `13.79%` | `13.79%` | `55.17%` |
| `8x8` | `9.41%` | `9.41%` | `75.29%` |

### Internal bottleneck conclusion
- A/B 向量供给阶段只需要 `X` cycles：
  - `4x4` 为 `4` cycles
  - `8x8` 为 `8` cycles
- `M` 串行写回需要 `X*Y` cycles：
  - `4x4` 为 `16` cycles
  - `8x8` 为 `64` cycles
- 因此当前设计中：
  - 乘加 feed 不是主瓶颈
  - `M` 串行写回是主内部瓶颈
  - tile 越大，瓶颈越明显地向 `M` 写回集中

## External Memory Analysis
### Cold miss
| Tile | Input beats | Export beats | Total ext bytes | Bytes/op | Ideal input cycles @1 beat/cycle | Effective input cycles | External bottleneck |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `4x4` | 32 | 16 | 192 | 1.5000 | 32 | 40 | `external_input` |
| `8x8` | 128 | 64 | 768 | 0.7500 | 128 | 136 | `external_input` |

### Hit / M-window
| Tile | Input beats | Export beats | Total ext bytes | Bytes/op | Effective export cycles | External bottleneck |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `4x4` | 0 | 16 | 64 | 0.5000 | 20 | `external_export` |
| `8x8` | 0 | 64 | 256 | 0.2500 | 68 | `external_export` |

### External bottleneck conclusion
- 冷 miss 时：
  - 外部输入阶段比导出阶段更长
  - 因此片外瓶颈在 A/B load
- 复用后：
  - A/B 外部输入归零
  - 片外压力只剩导出
  - 片外瓶颈从 `input_load` 转为 `export`
- 但在当前默认参数下，复用路径的总体瓶颈已经不再是片外导出，而是片上 `internal_execution`

## Attention-Level Mapping Analysis
### Path comparison
这里不做完整 FlashAttention 系统建模，只用当前 PT 机制描述上层复用收益。

| Tile | Path | Ext bytes/tile | Steady cyc/tile | Ops/cycle | Overall bottleneck |
| --- | --- | ---: | ---: | ---: | --- |
| `4x4` | no reuse (`steady_stream_cold`) | 192 | 40 | 3.2000 | `external_input` |
| `4x4` | 50% mixed reuse | 128 | 29 | 4.4138 | `internal_execution` |
| `4x4` | pure reuse (`cold_ratio=0`) | 64 | 29 | 4.4138 | `internal_execution` |
| `8x8` | no reuse (`steady_stream_cold`) | 768 | 136 | 7.5294 | `external_input` |
| `8x8` | 50% mixed reuse | 512 | 85 | 12.0471 | `internal_execution` |
| `8x8` | pure reuse (`cold_ratio=0`) | 256 | 85 | 12.0471 | `internal_execution` |

### External traffic reduction
| Tile | no reuse ext bytes | pure reuse ext bytes | Reduction |
| --- | ---: | ---: | ---: |
| `4x4` | 192 | 64 | `66.67%` |
| `8x8` | 768 | 256 | `66.67%` |

### Bottleneck transfer threshold
令 `cold_ratio * input_phase = internal_total`，得到外部输入与内部执行的分界点：

| Tile | `input_phase` | `internal_total` | cold ratio threshold | reuse ratio threshold |
| --- | ---: | ---: | ---: | ---: |
| `4x4` | 40 | 29 | `0.725` | `0.275` |
| `8x8` | 136 | 85 | `0.625` | `0.375` |

解释：
- `4x4`：
  - 当复用比例超过 `27.5%`，整体瓶颈从外部输入转向内部执行
- `8x8`：
  - 当复用比例超过 `37.5%`，整体瓶颈从外部输入转向内部执行

### Attention-level conclusion
- 当前 PT 机制下，复用带来的第一收益是显著降低片外输入 bytes/tile。
- 但随着复用增加，外部 load 不再主导，瓶颈很快转移到片上：
  - `M` 串行写回
  - 以及其绑定的内部执行路径
- 因此对于 attention 上层映射：
  - 提高 tile 复用率能显著减轻外存带宽压力
  - 但若不优化 `M` 写回/导出组织，steady throughput 最终会被片上路径卡住

## Validation Against Logs
### 4x4 cold miss
- cocotb log:
  - `dma_req(A)` at `260ns`
  - `ctrl_resp=0x00000001` at `950ns`
  - 差值 `690ns = 69 cycles`
- 模型：
  - `input_phase = 40`
  - `internal_total = 29`
  - `to_ctrl_resp = 69`
- 结论：
  - 与日志完全对齐

### 8x8 cold miss
- cocotb log:
  - `dma_req(A)` at `260ns`
  - `ctrl_resp=0x00000001` at `2470ns`
  - 差值 `2210ns = 221 cycles`
- 模型：
  - `input_phase = 136`
  - `internal_total = 85`
  - `to_ctrl_resp = 221`
- 结论：
  - 与日志完全对齐

## How To Use
### Example commands
```bash
python3 scripts/pt_perf_model.py --x-dim 4 --y-dim 4 --scenario cold_miss
python3 scripts/pt_perf_model.py --x-dim 8 --y-dim 8 --scenario steady_stream_cold
python3 scripts/pt_perf_model.py --x-dim 8 --y-dim 8 --scenario steady_stream_mixed --cold-ratio 0.25
python3 scripts/pt_perf_model.py --x-dim 8 --y-dim 8 --scenario cold_miss --freq-mhz 1000
```

## Assumptions
- 基于当前 RTL 行为，而不是目标架构愿景。
- 主结论默认使用：
  - `DMA req overhead = 2 cycles`
  - `DMA done latency = 2 cycles`
  - `M DMA done latency = 2 cycles`
  - `ext_in_beats_per_cycle = 1`
  - `ext_out_beats_per_cycle = 1`
- 主结论只针对 square tile：
  - `4x4`
  - `8x8`
- 非方阵输入仍可用脚本评估，但不作为本报告主结论。
- attention 级分析只做到 miss/hit/M-window 的复用收益与瓶颈转移，不延展到总线仲裁、多 tile 并发调度或完整 FlashAttention 系统级 pipeline。

## Final Conclusions
- 当前 PT 的冷 miss 单 tile 吞吐率主要受片外输入限制。
- 一旦引入 cache hit 或 `M-window` 复用，片外输入几乎不再是主瓶颈。
- 当前设计的主内部瓶颈是 `M` 的串行写回，其复杂度为 `O(X*Y)`，而 GEMM feed 只有 `O(X)`。
- 对 `4x4` 和 `8x8`，随着复用增强，瓶颈都会从片外 load 转移到片上写回；而且 tile 越大，这一趋势越明显。
