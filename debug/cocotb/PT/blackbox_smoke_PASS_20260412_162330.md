# PT-BB-001 Blackbox Smoke 测试表

| 字段 | 内容 |
| --- | --- |
| 测试唯一 ID | `PT-BB-001` |
| 测试唯一名称 | `blackbox_smoke` |
| 对应测试用例 | `tests.test_pt_smoke_typical_*` + `tests.test_pt_smoke_boundary_*` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260412_162330` |

## 测试目标
- 验证 `PT` 在严格黑盒视角下的基础工作流是否正确。
- 所有用例都固定检查 `CFG/QCFG -> miss -> hit -> M-window` 主流程。

## 用例分组
| 一级分组 | 二级子组 | 对应用例 | 累计 executed | 覆盖意图 |
| --- | --- | --- | --- | --- |
| `典型值测试` | `dense_pos / sparse_mix / monotonic / checkerboard / cache_reuse / single_hot` | `tests.test_pt_smoke_typical_*` | `40` | 覆盖代表性合法矩阵和主流程命中路径 |
| `边界值测试` | `zero_stripe / identity_drive / dynamic_range / single_hot` | `tests.test_pt_smoke_boundary_*` | `40` | 覆盖零行零列、单位矩阵驱动和合法动态范围边界 |

## 指标映射
- `CFG/QCFG` 基础响应序列
- 首次 `miss` 的 `dma_req`
- cache `hit`
- `M-window` 复用
- `m_dma_req`、`m_axis` row-major 导出
- completion `irq`

## 成功判据
- 每个 smoke 场景都必须按顺序观测到：
  - `0x00000010`
  - `0x00000011`
  - `0x00000020`
  - `0x00000001`
  - `0x40000001`
  - `0x00000003`
- `miss` 路径必须触发 `2` 次 `dma_req`；`hit` 与 `M-window` 路径不得再触发新的 `dma_req`。
- 每个场景都必须完成 `3` 次 `m_dma_req`、`3` 次 completion `irq`，且 `m_dma_req buf` 轮转为 `0 -> 1 -> 0`。
- `4x4` 场景导出 `beats=16`，`8x8` 场景导出 `beats=64`，并保持 row-major 顺序。

## 失败判据
- 关键 `ctrl_resp` 缺失或顺序错误。
- `hit/M-window` 路径出现新的 `dma_req`。
- `dma_req`、`m_dma_req`、`irq` 次数与预期不符。
- 导出 beat 数错误，或出现 `m_axis_tdata mismatch / timeout`。

## 实际结果
- 结果文件：
  - [`smoke_4x4_seed10.xml`](../../../sim/cocotb/results/smoke_4x4_seed10.xml)
  - [`smoke_8x8_seed10.xml`](../../../sim/cocotb/results/smoke_8x8_seed10.xml)
  - [`full_4x4_core_seed10.xml`](../../../sim/cocotb/results/full_4x4_core_seed10.xml)
  - [`full_8x8_core_seed10.xml`](../../../sim/cocotb/results/full_8x8_core_seed10.xml)
- 统计：
  - `PT-BB-001 executed = 80`
  - `PT-BB-001 failed = 0`
