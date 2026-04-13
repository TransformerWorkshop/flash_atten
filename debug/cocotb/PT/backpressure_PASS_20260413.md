# PT-BB-006 Backpressure 测试表

| 字段 | 内容 |
| --- | --- |
| 测试唯一 ID | `PT-BB-006` |
| 测试唯一名称 | `backpressure` |
| 对应测试用例 | `tests.test_pt_backpressure_timing_*` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260413` |

## 测试目标
- 验证 `PT` 在输入侧和输出侧回压存在时仍能保持协议正确性和导出顺序。
- 将回压设计成稳定的命名 profile，而不是无语义 bit 序列编号。

## 用例分组
| 一级分组 | 二级子组 | 对应用例 | 累计 executed | 覆盖意图 |
| --- | --- | --- | --- | --- |
| `时序扰动测试` | `轻度回压` | `tests.test_pt_backpressure_timing_light_*` | `8` | 覆盖轻微空洞与轻度错相 |
| `时序扰动测试` | `中度回压` | `tests.test_pt_backpressure_timing_medium_*` | `8` | 覆盖中等强度输入/输出偏压 |
| `时序扰动测试` | `重度回压` | `tests.test_pt_backpressure_timing_heavy_*` | `8` | 覆盖高占空比回压 |
| `时序扰动测试` | `相位错位回压` | `tests.test_pt_backpressure_timing_phase_shift_*` | `4` | 覆盖 DMA / export 领先或错位 |
| `时序扰动测试` | `输入侧偏压` | `tests.test_pt_backpressure_timing_input_*` | `6` | 覆盖 `dma_req/s_axis` 受限 |
| `时序扰动测试` | `输出侧偏压` | `tests.test_pt_backpressure_timing_output_*` | `6` | 覆盖 `m_dma_req/m_axis` 受限 |

## 实际结果
- 结果文件：
  - [`full_4x4_core_seed10.xml`](../../../sim/cocotb/results/full_4x4_core_seed10.xml)
  - [`full_8x8_core_seed10.xml`](../../../sim/cocotb/results/full_8x8_core_seed10.xml)
- 统计：
  - `PT-BB-006 executed = 40`
  - `PT-BB-006 failed = 0`
