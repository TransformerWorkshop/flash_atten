# PT-BB-001 Blackbox Smoke 测试表

| 字段 | 内容 |
| --- | --- |
| 测试唯一 ID | `PT-BB-001` |
| 测试唯一名称 | `blackbox_smoke` |
| 对应测试用例 | `tests.test_pt_smoke_typical_*` + `tests.test_pt_smoke_boundary_*` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260413` |

## 测试目标
- 验证 `PT` 在严格黑盒视角下的基础工作流是否正确。
- 所有用例都固定检查 `CFG/QCFG -> miss -> hit -> M-window` 主流程。

## 用例分组
| 一级分组 | 二级子组 | 对应用例 | 累计 executed | 覆盖意图 |
| --- | --- | --- | --- | --- |
| `典型值测试` | `dense_pos / sparse_mix / monotonic / checkerboard / cache_reuse / single_hot` | `tests.test_pt_smoke_typical_*` | `40` | 覆盖代表性合法矩阵和主流程命中路径 |
| `边界值测试` | `zero_stripe / identity_drive / dynamic_range / single_hot` | `tests.test_pt_smoke_boundary_*` | `40` | 覆盖零行零列、单位矩阵驱动和合法动态范围边界 |

## 实际结果
- 结果文件：
  - [`smoke_4x4_seed10.xml`](../../../sim/cocotb/results/smoke_4x4_seed10.xml)
  - [`smoke_8x8_seed10.xml`](../../../sim/cocotb/results/smoke_8x8_seed10.xml)
  - [`full_4x4_core_seed10.xml`](../../../sim/cocotb/results/full_4x4_core_seed10.xml)
  - [`full_8x8_core_seed10.xml`](../../../sim/cocotb/results/full_8x8_core_seed10.xml)
- 统计：
  - `PT-BB-001 executed = 80`
  - `PT-BB-001 failed = 0`
