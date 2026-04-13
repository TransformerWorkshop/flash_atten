# PT-BB-004 Protocol Errors 测试表

| 字段 | 内容 |
| --- | --- |
| 测试唯一 ID | `PT-BB-004` |
| 测试唯一名称 | `protocol_errors` |
| 对应测试用例 | `tests.test_pt_protocol_error_*` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260413` |

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

## 实际结果
- 结果文件：
  - [`full_4x4_core_seed10.xml`](../../../sim/cocotb/results/full_4x4_core_seed10.xml)
- 统计：
  - `PT-BB-004 executed = 20`
  - `PT-BB-004 failed = 0`
