# PT-BB-004 Protocol Errors 测试表

| 字段 | 内容 |
| --- | --- |
| 测试唯一 ID | `PT-BB-004` |
| 测试唯一名称 | `protocol_errors` |
| 对应测试用例 | `test_pt_protocol_errors` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260412_162330` |

## 测试目标
- 验证 `PT` 在黑盒视角下的错误路径是否按协议返回正确响应。
- 覆盖控制侧、A/B DMA 侧和 M export 侧的典型错误场景。

## 测试过程
1. 配置基础 `CFG` 和 `QCFG PER_TENSOR`。
2. 依次注入以下错误：
   - 非法 `MNK`
   - 非 row 对齐 offset
   - 非法 QCFG header
   - QCFG payload ID 错配
   - A/B DMA `wrong_tuser`
   - A/B DMA `error`
   - M export DMA `error`
3. 对每个错误场景检查：
   - `ctrl_resp.err`
   - `ctrl_resp` 顺序
   - `irq` 次数
   - 成功响应后再出现 export error 的组合路径

## 对应指标
- 非法 `MNK`：
  - 预期 `ctrl_resp = 0x80000200`
  - 预期新增 `dma_req = 0`
  - 预期 `irq` 增量 = `1`
- 非 row 对齐 offset：
  - 预期 `ctrl_resp = 0x80000201`
  - 预期新增 `dma_req = 0`
  - 预期 `irq` 增量 = `1`
- 非法 QCFG header：
  - 预期 `ctrl_resp = 0x80000202`
  - 预期 `irq` 增量 = `1`
- QCFG payload ID 错配：
  - 预期 `ctrl_resp = 0x80000203`
  - 预期 `irq` 增量 = `1`
- A/B DMA `wrong_tuser`：
  - 预期至少出现 `1` 次 `dma_req`
  - 预期 `ctrl_resp = 0x80000206`
  - 预期新增 `m_dma_req = 0`
  - 预期 `irq` 增量 = `1`
- A/B DMA `error`：
  - 预期至少出现 `1` 次 `dma_req`
  - 预期 `ctrl_resp = 0x80000207`
  - 预期新增 `m_dma_req = 0`
  - 预期 `irq` 增量 = `1`
- M export DMA `error`：
  - 预期先出现 `ctrl_resp = 0x00000208`
  - 再出现 `ctrl_resp = 0x80000208`
  - 预期新增 `m_dma_req = 1`
  - 预期 `irq` 增量 = `2`

## 测试成功判据
- 结果文件中没有 `<failure>`。
- 日志里必须按场景出现以下响应：
  - `0x80000200`
  - `0x80000201`
  - `0x80000202`
  - `0x80000203`
  - `0x80000206`
  - `0x80000207`
  - `0x00000208`
  - `0x80000208`
- `0x00000208` 必须先于 `0x80000208` 出现。
- `wrong_tuser` 和 `A/B DMA error` 场景都不能继续产生 `m_dma_req`。
- export error 场景必须产生且仅产生 `1` 次 `m_dma_req buf=0 id=0x00000208 beats=16`。

## 测试失败判据
- 任一预期错误响应缺失。
- `0x80000206` 或 `0x80000207` 后又出现后续成功导出事务。
- `0x80000208` 出现在 `0x00000208` 之前。
- export error 场景没有产生 `m_dma_req`，或产生了多于 `1` 次 `m_dma_req`。
- 结果文件存在 `<failure>`。

## 测试结论
- 本项测试结论为通过。
- 原因是本轮 `4x4` protocol error 回归中，8 个关键响应值都被完整观测到，且 export error 场景满足“先成功响应、后错误响应、只导出 1 次”的定量判据。

## 实际情况
- 实际执行结果文件：
  - [`full_4x4_core_seed10.xml`](../../../sim/cocotb/results/full_4x4_core_seed10.xml)
- 对应日志文件：
  - [`full_4x4_core_seed10.test.log`](../../../sim/cocotb/logs/full_4x4_core_seed10.test.log)
- 代表性实际现象：
  - 日志中实际出现以下控制返回值：
    - `0x80000200`
    - `0x80000201`
    - `0x80000202`
    - `0x80000203`
    - `0x80000206`
    - `0x80000207`
    - `0x00000208`
    - `0x80000208`
  - 在 export error 场景中，日志实际出现：
    - `m_dma_req buf=0 id=0x00000208 beats=16`
    - 先 `ctrl_resp=0x00000208`
    - 后 `ctrl_resp=0x80000208`
  - 本轮该 testcase 没有出现 `<failure>`，也没有出现额外的错误导出事务。
