# PT-BB-005 QCFG Odd Granularity 测试表

| 字段 | 内容 |
| --- | --- |
| 测试唯一 ID | `PT-BB-005` |
| 测试唯一名称 | `qcfg_odd_granularity` |
| 对应测试用例 | `test_pt_qcfg_odd_granularity` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260412_162330` |

## 测试目标
- 验证 odd 维度下，`/2` granularity 的 QCFG header 会被正确拒绝。

## 测试过程
1. 使用 `3x2` 维度实例运行该 testcase。
2. 对 odd `X_DIM` 发送 `X_WISE_DIV2` 的 QCFG header。
3. 若存在 odd `Y_DIM`，则对 `Y_WISE_DIV2` 也执行同样检查。
4. 观察 `ctrl_resp` 是否立即返回错误。

## 对应指标
- 运行维度固定为 `X_DIM=3, Y_DIM=2`
- 仅 odd `X_DIM` 路径被实际执行
- 预期错误响应值固定为 `0x80000250`
- 预期 `dma_req` 次数 = `0`
- 预期 `m_dma_req` 次数 = `0`

## 测试成功判据
- `full_3x2_protocol_seed10.xml` 中没有 `<failure>`。
- 日志中出现且仅需出现一个关键错误响应：
  - `ctrl_resp=0x80000250`
- 在该 testcase 日志片段中，不能出现后续 `dma_req` 或 `m_dma_req`。

## 测试失败判据
- 未出现 `0x80000250`。
- 出现了 `dma_req` 或 `m_dma_req`，说明非法配置被错误推进到后续流程。
- 结果文件出现 `<failure>`。

## 测试结论
- 本项测试结论为通过。
- 原因是 `3x2` 配置下实际观测到唯一关键错误响应 `0x80000250`，且没有任何 `dma_req` / `m_dma_req` 被触发。

## 实际情况
- 实际执行结果文件：
  - [`full_3x2_protocol_seed10.xml`](../../../sim/cocotb/results/full_3x2_protocol_seed10.xml)
- 对应日志文件：
  - [`full_3x2_protocol_seed10.test.log`](../../../sim/cocotb/logs/full_3x2_protocol_seed10.test.log)
- 代表性实际现象：
  - 日志中实际出现 `ctrl_resp=0x80000250`。
  - 同一 testcase 片段中没有出现 `dma_req` 或 `m_dma_req` 记录。
  - 该结果文件没有 `<failure>`，并记录 `tests.test_pt_blackbox.test_pt_qcfg_odd_granularity passed`。
