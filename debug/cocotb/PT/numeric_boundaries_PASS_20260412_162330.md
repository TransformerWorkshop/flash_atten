# PT-BB-002 Numeric Boundaries 测试表

| 字段 | 内容 |
| --- | --- |
| 测试唯一 ID | `PT-BB-002` |
| 测试唯一名称 | `numeric_boundaries` |
| 对应测试用例 | `tests.test_pt_numeric_typical_*` + `tests.test_pt_numeric_boundary_*` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260412_162330` |

## 测试目标
- 验证 `PT` 在不同尺寸下的数值正确性与量化边界行为。
- 将数值场景明确拆分为典型值和边界值两类。

## 用例分组
| 一级分组 | 二级子组 | 对应用例 | 累计 executed | 覆盖意图 |
| --- | --- | --- | --- | --- |
| `典型值测试` | `zero / const / sign_mix / sparse / shape / monotonic` | `tests.test_pt_numeric_typical_*` | `24` | 覆盖零值、常值、符号混合、稀疏和低范围代表值 |
| `边界值测试` | `saturation / saturation_threshold / rounding / near_zero / small_scale / sign_flip / large_payload` | `tests.test_pt_numeric_boundary_*` | `36` | 覆盖饱和、round-tie、近零量化和 scale sign flip 边界 |

## 指标映射
- `2x2/4x4/8x8` 数值正确性
- 量化边界
- saturation
- rounding tie
- near-zero quantization

## 成功判据
- 每个 numeric 场景都必须完成一次合法 `QCFG` 与一次合法 `MATMUL`，并成功导出完整结果矩阵。
- `2x2` 场景每次导出 `4` 个元素，`4x4` 每次导出 `16` 个元素，`8x8` 每次导出 `64` 个元素。
- 所有导出元素都必须与参考模型逐项一致，尤其覆盖：
  - 零值 / 常值
  - 正负号翻转
  - saturation 边界
  - round-tie 边界
  - near-zero quantization
- 日志中不能出现 `m_axis_tdata mismatch`、`ctrl_resp mismatch` 或 timeout。

## 失败判据
- 任一 numeric 场景缺少 `QCFG` 成功响应或 `MATMUL` 成功响应。
- 导出元素个数与当前维度不符。
- 任一导出元素与参考模型不一致，或边界场景的饱和 / round-tie 语义错误。
- 出现 `mismatch`、`timeout` 或导出顺序错误。

## 实际结果
- 结果文件：
  - [`full_2x2_numeric_seed10.xml`](../../../sim/cocotb/results/full_2x2_numeric_seed10.xml)
  - [`full_4x4_core_seed10.xml`](../../../sim/cocotb/results/full_4x4_core_seed10.xml)
  - [`full_8x8_core_seed10.xml`](../../../sim/cocotb/results/full_8x8_core_seed10.xml)
- 统计：
  - `PT-BB-002 executed = 60`
  - `PT-BB-002 failed = 0`
