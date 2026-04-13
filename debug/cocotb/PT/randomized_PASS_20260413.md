# PT-BB-007 Randomized 测试表

| 字段 | 内容 |
| --- | --- |
| 测试唯一 ID | `PT-BB-007` |
| 测试唯一名称 | `randomized` |
| 对应测试用例 | `randomized_<profile>_<dim>_seed<seed>` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260413` |

## 测试目标
- 验证 `PT` 在多 profile、多 seed、混合事务与随机时序扰动下的稳定性与可复现性。
- 保持 `20` 个命名 traffic bias profile 的独立结果文件与复现性。

## 用例分组
| 一级分组 | 二级子组 | 对应用例 | 累计 executed | 覆盖意图 |
| --- | --- | --- | --- | --- |
| `随机扰动测试` | `balanced_mix / legal_heavy / hit_heavy / mwindow_heavy / qcfg_heavy / error_heavy / wrong_tuser_heavy / export_error_heavy / backpressure_heavy / cache_reuse_heavy` | `randomized_<profile>_<dim>_seed<seed>` | `20` | 覆盖命名 traffic bias 组合 |

## 实际结果
- 结果文件模式：
  - [`randomized_balanced_mix_4x4_seed410.xml`](../../../sim/cocotb/results/randomized_balanced_mix_4x4_seed410.xml)
  - [`randomized_backpressure_heavy_8x8_seed818.xml`](../../../sim/cocotb/results/randomized_backpressure_heavy_8x8_seed818.xml)
  - 其余命名 profile 文件共 `20` 个
- 统计：
  - `PT-BB-007 executed = 20`
  - `PT-BB-007 failed = 0`
