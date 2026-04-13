# PT-BB-003 QCFG Modes 测试表

| 字段 | 内容 |
| --- | --- |
| 测试唯一 ID | `PT-BB-003` |
| 测试唯一名称 | `qcfg_modes` |
| 对应测试用例 | `tests.test_pt_qcfg_typical_*` + `tests.test_pt_qcfg_boundary_*` + `tests.test_pt_qcfg_config_*` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260413` |

## 测试目标
- 验证 `PT` 在不同 `QCFG granularity` 下的配置交互与数值行为。
- 将模式验证拆成典型值、边界值和约束/配置三类。

## 用例分组
| 一级分组 | 二级子组 | 对应用例 | 累计 executed | 覆盖意图 |
| --- | --- | --- | --- | --- |
| `典型值测试` | `per_tensor / x_wise / y_wise / x_div2 / y_div2` | `tests.test_pt_qcfg_typical_*` | `16` | 覆盖 5 种粒度的标准 scale 组合 |
| `边界值测试` | `small_scale / large_scale / sign_flip` | `tests.test_pt_qcfg_boundary_*` | `16` | 覆盖极小/极大 scale 与正负翻转边界 |
| `约束/配置测试` | `payload_count` | `tests.test_pt_qcfg_config_*` | `8` | 覆盖合法 payload 个数与粒度映射边界 |

## 实际结果
- 结果文件：
  - [`full_4x4_core_seed10.xml`](../../../sim/cocotb/results/full_4x4_core_seed10.xml)
  - [`full_8x8_core_seed10.xml`](../../../sim/cocotb/results/full_8x8_core_seed10.xml)
- 统计：
  - `PT-BB-003 executed = 40`
  - `PT-BB-003 failed = 0`
