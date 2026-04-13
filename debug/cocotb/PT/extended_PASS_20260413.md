# PT-BB-010 Extended 多 Seed 测试表

| 字段 | 内容 |
| --- | --- |
| 测试唯一 ID | `PT-BB-010` |
| 测试唯一名称 | `extended` |
| 对应用例 | `extended_<profile>_seed<seed>` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260413` |

## 测试目标
- 对代表性随机 profile 进行默认多 seed 基线重跑，验证 `PT` 在较长时间窗口下的稳定性与可复现性。
- 将较重的随机 sweep 与主 `full` 回归分层，避免主回归耗时继续膨胀。

## 用例矩阵
| profile | 维度 | seeds | 结果文件数 | 覆盖意图 |
| --- | --- | --- | --- | --- |
| `balanced_mix_4x4` | `4x4` | `10/110/210` | `3` | 均衡流量 |
| `qcfg_heavy_4x4` | `4x4` | `10/110/210` | `3` | QCFG 偏置 |
| `invalid_heavy_4x4` | `4x4` | `10/110/210` | `3` | 非法事务偏置 |
| `cache_reuse_heavy_4x4` | `4x4` | `10/110/210` | `3` | cache reuse 偏置 |
| `balanced_mix_8x8` | `8x8` | `10/110/210` | `3` | 均衡流量 |
| `qcfg_heavy_8x8` | `8x8` | `10/110/210` | `3` | QCFG 偏置 |
| `invalid_heavy_8x8` | `8x8` | `10/110/210` | `3` | 非法事务偏置 |
| `cache_reuse_heavy_8x8` | `8x8` | `10/110/210` | `3` | cache reuse 偏置 |

## 成功判据
- `8` 个 profile 在 `3` 个默认 seed 上全部独立执行并生成结果文件。
- `24` 个 xUnit 文件全部无 `failure` / `skipped`。
- profile 名与 seed 能唯一定位一次失败并复现。

## 实际结果
- 结果文件总数：`24`
- executed testcase 数：`24`
- failed：`0`
- 结果文件示例：
  - [`extended_balanced_mix_4x4_seed10.xml`](../../../sim/cocotb/results/extended_balanced_mix_4x4_seed10.xml)
  - [`extended_balanced_mix_4x4_seed110.xml`](../../../sim/cocotb/results/extended_balanced_mix_4x4_seed110.xml)
  - [`extended_balanced_mix_4x4_seed210.xml`](../../../sim/cocotb/results/extended_balanced_mix_4x4_seed210.xml)
  - [`extended_qcfg_heavy_8x8_seed210.xml`](../../../sim/cocotb/results/extended_qcfg_heavy_8x8_seed210.xml)

## 结论
- `extended` 默认多 seed 基线已从干净目录完整重跑并保持全绿。
- 代表性 `balanced/qcfg/invalid/cache_reuse` profile 在 `4x4/8x8 x 3 seeds` 组合下未出现 `ctrl_resp mismatch`、`m_axis_tdata mismatch`、`timeout` 或 AssertionError。
