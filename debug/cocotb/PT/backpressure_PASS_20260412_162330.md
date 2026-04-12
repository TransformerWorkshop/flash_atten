# PT-BB-006 Backpressure 测试表

| 字段 | 内容 |
| --- | --- |
| 测试唯一 ID | `PT-BB-006` |
| 测试唯一名称 | `backpressure` |
| 对应测试用例 | `tests.test_pt_backpressure_timing_*` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260412_162330` |

## 测试目标
- 验证 `PT` 在输入侧和输出侧回压存在时仍能保持协议正确性和导出顺序。
- 将回压设计成 20 个稳定的命名 profile，而不是无语义 bit 序列编号。

## 用例分组
| 一级分组 | 二级子组 | 对应用例 | 累计 executed | 覆盖意图 |
| --- | --- | --- | --- | --- |
| `时序扰动测试` | `轻度回压` | `tests.test_pt_backpressure_timing_light_*` | `8` | 覆盖轻微空洞与轻度错相 |
| `时序扰动测试` | `中度回压` | `tests.test_pt_backpressure_timing_medium_*` | `8` | 覆盖中等强度输入/输出偏压 |
| `时序扰动测试` | `重度回压` | `tests.test_pt_backpressure_timing_heavy_*` | `8` | 覆盖高占空比回压 |
| `时序扰动测试` | `相位错位回压` | `tests.test_pt_backpressure_timing_phase_shift_*` | `4` | 覆盖 DMA / export 领先或错位 |
| `时序扰动测试` | `输入侧偏压` | `tests.test_pt_backpressure_timing_input_*` | `6` | 覆盖 `dma_req/s_axis` 受限 |
| `时序扰动测试` | `输出侧偏压` | `tests.test_pt_backpressure_timing_output_*` | `6` | 覆盖 `m_dma_req/m_axis` 受限 |

## 指标映射
- `dma_req_ready`
- `m_dma_req_ready`
- `m_axis_tready`
- `s_axis_valid`
- 两笔事务在回压下的响应、导出和 `irq`

## 成功判据
- 每个 backpressure 场景都必须完成两笔事务，且按顺序观测到：
  - `ctrl_resp=0x00000301`
  - `ctrl_resp=0x40000302`
- 每个场景都必须只发起 `2` 次 `m_dma_req`，且 buffer 顺序固定为 `buf=0 -> buf=1`。
- `4x4` 场景每笔导出 `beats=16`，`8x8` 场景每笔导出 `beats=64`。
- 每个场景都必须完成 `2` 次导出完成与 `2` 次 `irq`，并保持导出顺序正确。
- 日志中不能出现 `ctrl_resp timeout`、`export_done timeout`、`m_axis_tdata mismatch` 或 deadlock 现象。

## 失败判据
- 缺少任一笔成功 `ctrl_resp`，或顺序不是 `0x00000301 -> 0x40000302`。
- `m_dma_req` 次数不是 `2`，或 `buf` 顺序不是 `0 -> 1`。
- `beats` 数与当前维度不符。
- 任一场景未完成两次导出、两次 `irq`，或出现 `timeout / mismatch / deadlock`。

## 实际结果
- 结果文件：
  - [`full_4x4_core_seed10.xml`](../../../sim/cocotb/results/full_4x4_core_seed10.xml)
  - [`full_8x8_core_seed10.xml`](../../../sim/cocotb/results/full_8x8_core_seed10.xml)
- 统计：
  - `PT-BB-006 executed = 40`
  - `PT-BB-006 failed = 0`
