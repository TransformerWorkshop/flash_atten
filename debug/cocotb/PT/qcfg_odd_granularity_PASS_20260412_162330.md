# PT-BB-005 Power-of-two Guard 测试表

| 字段 | 内容 |
| --- | --- |
| 测试唯一 ID | `PT-BB-005` |
| 测试唯一名称 | `power_of_two_guard` |
| 对应测试用例 | `full_pow2_guard_<profile>_seed10` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260412_162330` |

## 测试目标
- 验证 `PT` 在非法维度配置下会在仿真启动阶段立即拒绝配置。
- 用 20 个不同 profile 替代“同一 `3x2` 配置重复换 seed”的旧设计。

## 用例分组
| 一级分组 | 二级子组 | 对应用例 | 累计 executed | 覆盖意图 |
| --- | --- | --- | --- | --- |
| `约束/配置测试` | `odd-X only` | `full_pow2_guard_odd_x_only_*_seed10.xml` | `2` | 仅 X 为奇数 |
| `约束/配置测试` | `odd-Y only` | `full_pow2_guard_odd_y_only_*_seed10.xml` | `2` | 仅 Y 为奇数 |
| `约束/配置测试` | `both odd` | `full_pow2_guard_both_odd_*_seed10.xml` | `3` | X/Y 同时为奇数 |
| `约束/配置测试` | `non-power even` | `full_pow2_guard_non_pow_even_*_seed10.xml` | `5` | 偶数但不是 2 的幂 |
| `约束/配置测试` | `small invalid` | `full_pow2_guard_small_invalid_*_seed10.xml` | `4` | 小尺寸非法组合 |
| `约束/配置测试` | `asymmetric invalid` | `full_pow2_guard_asym_invalid_*_seed10.xml` | `4` | 非对称非法组合 |

## 指标映射
- 顶层参数约束
- 启动即拒绝非法维度
- `PT_MD/PT_CE` fatal 文本稳定性
- runner expected-fail 归档正确性

## 成功判据
- 20 个非法维度 profile 都必须在仿真启动阶段终止，而不是进入正常事务执行。
- 每个原始 `test.log` 都必须同时命中：
  - `PT_MD requires power-of-two GEMM_X_DIM/GEMM_Y_DIM`
  - `PT_CE requires power-of-two GEMM_X_DIM/GEMM_Y_DIM`
- 同一 log 中不得出现 `ctrl_resp`、`dma_req` 或 `m_dma_req`。
- runner 必须将该预期启动失败归档为 synthetic PASS xUnit。

## 失败判据
- 任一非法维度 profile 被错误接受并进入正常事务阶段。
- 缺少 `PT_MD` 或 `PT_CE` 任一 fatal 文本。
- 结果被 runner 归档为真正 failure，或未写出 expected-fail synthetic xUnit。

## 实际结果
- 结果文件模式：
  - `full_pow2_guard_odd_x_only_x3_y2_seed10.xml`
  - `full_pow2_guard_non_pow_even_x6_y4_seed10.xml`
  - `full_pow2_guard_asym_invalid_x12_y8_seed10.xml`
  - 其余同类 profile 共 `20` 个
- 统计：
  - `PT-BB-005 executed = 20`
  - `PT-BB-005 failed = 0`
