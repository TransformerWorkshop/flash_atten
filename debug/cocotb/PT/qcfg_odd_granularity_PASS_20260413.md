# PT-BB-005 Power-of-two Guard 测试表

| 字段 | 内容 |
| --- | --- |
| 测试唯一 ID | `PT-BB-005` |
| 测试唯一名称 | `power_of_two_guard` |
| 对应测试用例 | `full_pow2_guard_<profile>_seed10` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260413` |

## 测试目标
- 验证 `PT` 在非法维度配置下会在仿真启动阶段立即拒绝配置。
- 用 `20` 个不同 profile 覆盖 odd / non-power-of-two 非法维度组合。

## 用例分组
| 一级分组 | 二级子组 | 对应用例 | 累计 executed | 覆盖意图 |
| --- | --- | --- | --- | --- |
| `约束/配置测试` | `odd-X only / odd-Y only / both odd / non-power even / small invalid / asymmetric invalid` | `full_pow2_guard_<profile>_seed10.xml` | `20` | 覆盖所有非法维度 profile |

## 实际结果
- 结果文件模式：
  - `full_pow2_guard_odd_x_only_x3_y2_seed10.xml`
  - `full_pow2_guard_non_pow_even_x6_y4_seed10.xml`
  - `full_pow2_guard_asym_invalid_x12_y8_seed10.xml`
  - 其余同类 profile 共 `20` 个
- 统计：
  - `PT-BB-005 executed = 20`
  - `PT-BB-005 failed = 0`
