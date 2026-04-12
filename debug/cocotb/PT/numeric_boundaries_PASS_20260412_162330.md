# PT-BB-002 Numeric Boundaries 测试表

| 字段 | 内容 |
| --- | --- |
| 测试唯一 ID | `PT-BB-002` |
| 测试唯一名称 | `numeric_boundaries` |
| 对应测试用例 | `test_pt_numeric_boundaries` |
| 当前状态 | `PASS` |
| 文档时间戳 | `20260412_162330` |

## 测试目标
- 验证 `PT` 在不同尺寸下的数值正确性与量化边界行为。
- 重点覆盖零值、常值、上/下饱和和 rounding tie。

## 测试过程
1. 使用 `identity` 作为 A 矩阵，保证输出主要由 B 与量化规则决定。
2. 构造五组 B 输入场景：
   - `zero`
   - `ones`
   - `upper_sat`
   - `lower_sat`
   - `round_tie`
3. 对每组场景配置对应 `QCFG`。
4. 在 `2x2`、`4x4`、`8x8` 三个尺寸实例中执行 `MATMUL` 并导出结果。
5. 将导出矩阵与参考模型按 row-major 逐项比对。

## 对应指标
- 尺寸覆盖：
  - `2x2`：每次导出 `4` 个元素
  - `4x4`：每次导出 `16` 个元素
  - `8x8`：每次导出 `64` 个元素
- 场景覆盖：
  - `zero`
  - `ones`
  - `upper_sat`
  - `lower_sat`
  - `round_tie`
- 事务指标：
  - 每个尺寸实例都应执行 `5` 次 `QCFG`
  - 每个尺寸实例都应执行 `5` 次 `MATMUL`
  - 每个尺寸实例都应执行 `5` 次导出
- 数值指标：
  - 导出矩阵每个元素都与参考模型逐项一致
  - `m_axis` 顺序必须是 row-major

## 测试成功判据
- `full_2x2_numeric_seed10.xml`、`full_4x4_core_seed10.xml`、`full_8x8_core_seed10.xml` 都没有 `<failure>`。
- 每个尺寸实例都完成 `5` 组边界场景，顺序为：
  - `zero`
  - `ones`
  - `upper_sat`
  - `lower_sat`
  - `round_tie`
- `4x4` 与 `8x8` 日志中，`QCFG` 响应依次出现：
  - `0x00000041`
  - `0x00000042`
  - `0x00000043`
  - `0x00000044`
  - `0x00000045`
- `4x4` 与 `8x8` 日志中，`MATMUL` 响应依次出现：
  - `0x00000081`
  - `0x40000082`
  - `0x00000083`
  - `0x40000084`
  - `0x00000085`
- 每个尺寸实例中，所有导出元素都与参考模型一一匹配：
  - `2x2` 共校验 `5 × 4 = 20` 个元素
  - `4x4` 共校验 `5 × 16 = 80` 个元素
  - `8x8` 共校验 `5 × 64 = 320` 个元素

## 测试失败判据
- 任一结果文件出现 `<failure>`。
- 任一尺寸实例没有执行完 5 组场景。
- 任一 `QCFG` 或 `MATMUL` 响应缺失、顺序错误或数值错误。
- 任一导出元素与参考模型不一致。
- 任一导出不是 row-major 顺序。
- 出现饱和方向错误或 rounding tie 行为与当前实现语义不一致。

## 测试结论
- 本项测试结论为通过。
- 原因是 `2x2`、`4x4`、`8x8` 三个尺寸实例都完成了 `5` 组边界场景，总计校验 `420` 个导出元素，且没有发生任何 xUnit failure、协议错误或数值 mismatch。

## 实际情况
- 实际执行结果文件：
  - [`full_2x2_numeric_seed10.xml`](../../../sim/cocotb/results/full_2x2_numeric_seed10.xml)
  - [`full_4x4_core_seed10.xml`](../../../sim/cocotb/results/full_4x4_core_seed10.xml)
  - [`full_8x8_core_seed10.xml`](../../../sim/cocotb/results/full_8x8_core_seed10.xml)
- 对应日志文件：
  - [`full_2x2_numeric_seed10.test.log`](../../../sim/cocotb/logs/full_2x2_numeric_seed10.test.log)
  - [`full_4x4_core_seed10.test.log`](../../../sim/cocotb/logs/full_4x4_core_seed10.test.log)
  - [`full_8x8_core_seed10.test.log`](../../../sim/cocotb/logs/full_8x8_core_seed10.test.log)
- 代表性实际现象：
  - `4x4` 日志中实际出现 `QCFG` 响应 `0x41..0x45`，随后出现 `MATMUL` 响应 `0x81/0x82/0x83/0x84/0x85`，其中带高位缓冲区位的响应为 `0x40000082`、`0x40000084`。
  - `8x8` 日志中也出现同样的 `QCFG` 和 `MATMUL` 响应序列。
  - 三个结果文件都没有 `<failure>`，日志中没有出现数值 mismatch、导出顺序错误或 timeout。
