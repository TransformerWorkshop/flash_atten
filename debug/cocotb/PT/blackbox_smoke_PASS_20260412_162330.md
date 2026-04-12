# PT-BB-001 Blackbox Smoke 测试表

| 字段 | 内容 |
| --- | --- |
| 测试唯一 ID | `PT-BB-001` |
| 测试唯一名称 | `blackbox_smoke` |
| 对应测试用例 | `test_pt_smoke` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260412_162330` |

## 测试目标
- 验证 `PT` 在严格黑盒视角下的基础工作流是否正确。
- 覆盖 `CFG/QCFG` 基础配置、首次 `miss`、cache `hit`、`M-window` 复用三条主路径。

## 测试过程
1. 通过 `CFG` 写入 A/B base 地址。
2. 通过 `QCFG PER_TENSOR` 配置默认量化比例。
3. 发送合法 row-major A/B tile，触发首次 `MATMUL miss`。
4. 复用同一 `id + offset`，验证 cache `hit`。
5. 使用 `build_mwin_off()` 指定 `M-window`，验证 `A<-M/B<-M` 黑盒复用。
6. 对每个阶段检查：
   - `ctrl_resp`
   - `dma_req`
   - `m_dma_req`
   - `m_axis`
   - `irq`

## 对应指标
- `CFG/QCFG` 响应序列：
  - `0x00000010`（A_BASE）
  - `0x00000011`（B_BASE）
  - `0x00000020`（PER_TENSOR QCFG）
- `miss` 路径事务序列：
  - `dma_req tuser=1 ext=0x00001000 beats=X*Y`
  - `dma_req tuser=2 ext=0x00002000 beats=X*Y`
  - `ctrl_resp=0x00000001`
  - `m_dma_req buf=0 id=0x00000001 beats=X*Y`
- `hit` 路径事务序列：
  - 无新的 `dma_req`
  - `ctrl_resp=0x40000001`
  - `m_dma_req buf=1 id=0x00000001 beats=X*Y`
- `M-window` 路径事务序列：
  - 无新的 `dma_req`
  - `ctrl_resp=0x00000003`
  - `m_dma_req buf=0 id=0x00000003 beats=X*Y`
- 计数指标：
  - 每个尺寸实例总 `dma_req` 次数 = `2`
  - 每个尺寸实例总 `m_dma_req` 次数 = `3`
  - 每个尺寸实例总 completion `irq` 次数 = `3`
  - `4x4` 时 `X*Y=16`
  - `8x8` 时 `X*Y=64`
- `m_axis` 导出顺序：
  - 每个导出事务按 row-major 输出
  - 第 `n` 个 beat 对应结果矩阵的第 `n` 个 row-major 元素

## 测试成功判据
- `smoke_4x4_seed10.xml` 与 `smoke_8x8_seed10.xml` 都没有 `<failure>`。
- `4x4` 实例必须出现且仅出现以下关键 `ctrl_resp`：
  - `0x00000010`
  - `0x00000011`
  - `0x00000020`
  - `0x00000001`
  - `0x40000001`
  - `0x00000003`
- `8x8` 实例必须出现与上面相同的 `ctrl_resp` 序列。
- `4x4` 实例必须出现：
  - `2` 次 `dma_req`
  - `3` 次 `m_dma_req`
  - `m_dma_req` 的 `beats` 分别为 `16, 16, 16`
- `8x8` 实例必须出现：
  - `2` 次 `dma_req`
  - `3` 次 `m_dma_req`
  - `m_dma_req` 的 `beats` 分别为 `64, 64, 64`
- `hit` 与 `M-window` 两条路径都不能再出现新的 `dma_req`。
- 每个尺寸实例 completion `irq` 次数必须等于 `3`。

## 测试失败判据
- 任一结果文件中出现 `<failure>`。
- 任一尺寸实例中：
  - 缺少任意一个关键 `ctrl_resp`
  - `ctrl_resp` 次序不是 `0x10 -> 0x11 -> 0x20 -> 0x00000001 -> 0x40000001 -> 0x00000003`
- `4x4` 中 `dma_req` 次数不等于 `2`，或任一 `beats` 不等于 `16`。
- `8x8` 中 `dma_req` 次数不等于 `2`，或任一 `beats` 不等于 `64`。
- `m_dma_req` 的 `buf` 轮转不是 `0 -> 1 -> 0`。
- `hit` / `M-window` 路径出现新的 `dma_req`。
- `irq` 次数不等于 `3`。
- `m_axis` 导出出现 beat 数错误、row-major 顺序错误或 `tuser[buf]` 错误。

## 测试结论
- 本项测试结论为通过。
- 原因是 `4x4` 与 `8x8` 两个实例都满足以下量化判据：
  - `ctrl_resp` 序列完整且顺序固定
  - `dma_req` 次数固定为 `2`
  - `m_dma_req` 次数固定为 `3`
  - `m_dma_req buf` 轮转为 `0 -> 1 -> 0`
  - `4x4` 导出 beat 数为 `16`
  - `8x8` 导出 beat 数为 `64`
  - 没有任何 xUnit failure

## 实际情况
- 实际执行结果文件：
  - [`smoke_4x4_seed10.xml`](../../../sim/cocotb/results/smoke_4x4_seed10.xml)
  - [`smoke_8x8_seed10.xml`](../../../sim/cocotb/results/smoke_8x8_seed10.xml)
- 对应日志文件：
  - [`smoke_4x4_seed10.test.log`](../../../sim/cocotb/logs/smoke_4x4_seed10.test.log)
  - [`smoke_8x8_seed10.test.log`](../../../sim/cocotb/logs/smoke_8x8_seed10.test.log)
- 代表性实际现象：
  - `4x4` 实例日志中实际观测到：
    - `ctrl_resp=0x00000010`
    - `ctrl_resp=0x00000011`
    - `ctrl_resp=0x00000020`
    - `dma_req tuser=1 ext=0x00001000 beats=16`
    - `dma_req tuser=2 ext=0x00002000 beats=16`
    - `ctrl_resp=0x00000001`
    - `m_dma_req buf=0 id=0x00000001 beats=16`
    - `ctrl_resp=0x40000001`
    - `m_dma_req buf=1 id=0x00000001 beats=16`
    - `ctrl_resp=0x00000003`
    - `m_dma_req buf=0 id=0x00000003 beats=16`
  - `8x8` 实例日志中实际观测到相同的响应顺序，但 `beats` 都扩展为 `64`。
  - 两个实例都记录了 `tests.test_pt_blackbox.test_pt_smoke passed`，没有出现 timeout、mismatch 或 failure。
