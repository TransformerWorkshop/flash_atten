# PT-BB-006 Backpressure 测试表

| 字段 | 内容 |
| --- | --- |
| 测试唯一 ID | `PT-BB-006` |
| 测试唯一名称 | `backpressure` |
| 对应测试用例 | `test_pt_backpressure` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260412_162330` |

## 测试目标
- 验证 `PT` 在输入侧、输出侧和请求侧回压存在时，仍能保持事务正确性与无死锁。

## 测试过程
1. 使用 `SequencePattern` 对以下端口注入时序扰动：
   - `dma_req_ready = [0, 0, 1, 1, 0, 1, 1, 1]`
   - `m_dma_req_ready = [0, 1, 0, 1, 1, 0, 1, 1]`
   - `m_axis_tready = [1, 1, 0, 0, 0, 1, 0, 1, 1, 1]`
   - `s_axis_valid = [0, 1, 1, 0, 1, 0, 1, 1, 1]`
2. 在 `4x4` 与 `8x8` 两个尺寸实例中，各执行两笔连续 `MATMUL`。
3. 第一笔导出尚未完全结束时，继续向 DUT 提交第二笔事务。
4. 检查以下定量结果：
   - 第一笔 `ctrl_resp`
   - 第二笔 `ctrl_resp`
   - `dma_req` 次数
   - `m_dma_req` 次数
   - `irq` 次数
   - 是否在 `12000` 仿真周期超时前完成

## 对应指标
- `4x4` 实例：
  - 第一笔 `ctrl_resp = 0x00000301`
  - 第二笔 `ctrl_resp = 0x40000302`
  - `dma_req` 次数 = `4`
  - `m_dma_req` 次数 = `2`
  - `irq` 次数 = `2`
- `8x8` 实例：
  - 第一笔 `ctrl_resp = 0x00000301`
  - 第二笔 `ctrl_resp = 0x40000302`
  - `dma_req` 次数 = `4`
  - `m_dma_req` 次数 = `2`
  - `irq` 次数 = `2`
- 两个实例中，第二笔事务都必须在第一笔回压存在时被排队并最终导出
- `wait_export_done(2, 12000)` 必须成功，即两个导出都在 `12000` 周期窗口内完成

## 测试成功判据
- `full_4x4_core_seed10.xml` 与 `full_8x8_core_seed10.xml` 都没有 `<failure>`。
- 两个尺寸实例都观测到：
  - 第一笔 `ctrl_resp=0x00000301`
  - 第二笔 `ctrl_resp=0x40000302`
- 两个尺寸实例都观测到：
  - `dma_req` 共 `4` 次（A/B 各两次）
  - `m_dma_req` 共 `2` 次
  - `irq` 共 `2` 次
- 两个实例都在 `12000` 周期门限内完成 `2` 次导出。

## 测试失败判据
- 任一实例没有出现 `0x00000301` 和 `0x40000302` 两个完成响应。
- 任一实例 `dma_req` 次数不等于 `4`。
- 任一实例 `m_dma_req` 次数不等于 `2`。
- 任一实例 `irq` 次数不等于 `2`。
- 任一实例在 `12000` 周期内未完成两次导出。
- 任一结果文件出现 `<failure>`。

## 测试结论
- 本项测试结论为通过。
- 原因是 `4x4` 和 `8x8` 两个实例都满足固定的回压模式，并仍然完成了 `2` 笔事务、`4` 次 DMA load 请求、`2` 次 export 请求和 `2` 次 completion `irq`，且均未超时。

## 实际情况
- 实际执行结果文件：
  - [`full_4x4_core_seed10.xml`](../../../sim/cocotb/results/full_4x4_core_seed10.xml)
  - [`full_8x8_core_seed10.xml`](../../../sim/cocotb/results/full_8x8_core_seed10.xml)
- 对应日志文件：
  - [`full_4x4_core_seed10.test.log`](../../../sim/cocotb/logs/full_4x4_core_seed10.test.log)
  - [`full_8x8_core_seed10.test.log`](../../../sim/cocotb/logs/full_8x8_core_seed10.test.log)
- 代表性实际现象：
  - `4x4` 日志中实际出现：
    - `ctrl_resp=0x00000301`
    - `m_dma_req buf=0 id=0x00000301 beats=16`
    - `ctrl_resp=0x40000302`
    - `m_dma_req buf=1 id=0x00000302 beats=16`
    - 对应总 `dma_req` 数为 `4`
  - `8x8` 日志中实际出现：
    - `ctrl_resp=0x00000301`
    - `m_dma_req buf=0 id=0x00000301 beats=64`
    - `ctrl_resp=0x40000302`
    - `m_dma_req buf=1 id=0x00000302 beats=64`
    - 对应总 `dma_req` 数为 `4`
  - 两个结果文件都没有 `<failure>`，也没有出现 timeout 现象。
