# PT-BB-004 Protocol Errors 测试表

| 字段 | 内容 |
| --- | --- |
| 测试唯一 ID | `PT-BB-004` |
| 测试唯一名称 | `protocol_errors` |
| 对应测试用例 | `tests.test_pt_protocol_error_*` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260412_162330` |

## 测试目标
- 验证 `PT` 在黑盒视角下的错误路径是否按协议返回正确响应。
- 20 个 case 全部归入 `异常路径测试`，并按异常来源细分。

## 用例分组
| 一级分组 | 二级子组 | 对应用例 | 累计 executed | 覆盖意图 |
| --- | --- | --- | --- | --- |
| `异常路径测试` | `控制编码异常` | `tests.test_pt_protocol_error_control_*` | `4` | 覆盖 `MNK/scale` 非法编码 |
| `异常路径测试` | `地址/对齐异常` | `tests.test_pt_protocol_error_align_*` | `4` | 覆盖 A/B offset 非对齐 |
| `异常路径测试` | `QCFG 交互异常` | `tests.test_pt_protocol_error_qcfg_*` | `4` | 覆盖非法 qtype 与 payload ID 错配 |
| `异常路径测试` | `输入流异常` | `tests.test_pt_protocol_error_stream_*` | `5` | 覆盖 wrong `tuser` 和 before-stream DMA error |
| `异常路径测试` | `导出异常` | `tests.test_pt_protocol_error_export_*` | `3` | 覆盖 export DMA error 与二次响应 |

## 指标映射
- 错误响应路径
- `ctrl_resp` 顺序
- `irq` 次数
- success resp + export error resp 组合

## 成功判据
- `控制编码异常` 与 `地址/对齐异常` 场景必须在不产生导出事务的前提下被立即拒绝，并只增加 `1` 次 `irq`。
- `QCFG 交互异常` 场景必须在 QCFG 阶段被拒绝，且不能进入后续导出。
- `输入流异常` 场景必须至少触发一次输入 DMA 行为，但不得产生导出事务，并只增加 `1` 次 `irq`。
- `导出异常` 场景必须先出现一次成功 `ctrl_resp` 和一次导出请求，再出现一次错误响应，且总 `irq` 增量为 `2`。
- 日志中不能出现与场景意图不符的额外成功导出或错误路径串扰。

## 失败判据
- 非法场景未被拒绝，或拒绝发生在错误阶段。
- 本应无导出的场景出现 `m_dma_req` 或导出数据。
- export error 场景未出现“先成功、后报错”的两阶段行为。
- `irq` 次数、`ctrl_resp` 顺序或错误路径与场景定义不符。

## 实际结果
- 结果文件：
  - [`full_4x4_core_seed10.xml`](../../../sim/cocotb/results/full_4x4_core_seed10.xml)
- 统计：
  - `PT-BB-004 executed = 20`
  - `PT-BB-004 failed = 0`
