# PT Cocotb 黑盒测试要求规范

## 1. 文档目的
- 本文档用于定义 `PT` 模块的标准化黑盒测试要求。
- 本文档面向：
  - 验证工程师
  - 设计工程师
  - 回归维护人员
- 本文档以当前仓库中已实现并已重跑通过的 `cocotb + iverilog` 验证体系为基准，不重新定义 RTL 语义。

## 2. 被测对象
- 被测模块：[`PT`](../rtl/pt.v)
- 验证方式：严格黑盒
  - 仅驱动/观察顶层端口
  - 不读取内部层级信号
  - 不读取内部 SRAM / FIFO / 状态机
- 参考实现与入口：
  - 回归入口：[run.py](../sim/cocotb/run.py)
  - 执行入口：[Makefile](../sim/cocotb/Makefile)
  - testcase 集合：[test_pt_blackbox.py](../sim/cocotb/tests/test_pt_blackbox.py)
  - 参考模型：[pt_model.py](../sim/cocotb/tests/pt_model.py)

## 3. 测试环境要求
### 3.1 软件环境
- Python：`3.12.4`
- cocotb：`2.0.1`
- 仿真器：`Icarus Verilog 12.0 (stable)`
- `pytest`：非必需
  - 当前环境未安装 `pytest`
  - 不影响 cocotb 回归执行

### 3.2 仿真环境
- 默认仿真后端：`icarus`
- 顶层模块：`PT`
- 默认 timescale：`1ns / 1ps`
- cocotb 构建参数由 [`run.py`](../sim/cocotb/run.py) 注入：
  - `DATA_WIDTH=32`
  - `EXT_ADDR_W=32`
  - `DMA_BEATS_W=16`
  - `LUT_DEPTH=8`
  - `A_BANK_DEPTH=8`
  - `B_BANK_DEPTH=8`
- 尺寸 sweep：
  - `2x2`
  - `3x2`
  - `4x4`
  - `8x8`

## 4. 回归入口与执行命令
### 4.1 标准命令
```bash
make -C sim/cocotb clean
make -C sim/cocotb smoke
make -C sim/cocotb full
make -C sim/cocotb randomized
```

### 4.2 可选参数
```bash
make -C sim/cocotb smoke SIM=icarus
make -C sim/cocotb full SEED=10
make -C sim/cocotb randomized WAVES=1 VERBOSE=1
```

### 4.3 分层定义
- `smoke`
  - `smoke_4x4`
  - `smoke_8x8`
- `full`
  - `full_2x2_numeric`
  - `full_4x4_core`
  - `full_8x8_core`
  - `full_3x2_protocol`
- `randomized`
  - `randomized_4x4_seed10..19`
  - `randomized_8x8_seed10..19`

## 5. Testcase 与指标要求
| 测试ID | 测试名称 | 对应用例 | 输入条件 / 前置条件 | 覆盖指标 | 成功判据 | 失败判据 |
| --- | --- | --- | --- | --- | --- | --- |
| `PT-BB-001` | PT Blackbox Smoke | `test_pt_smoke` | 已完成 `CFG A/B base`、`QCFG per-tensor`；提供合法 row-major A/B tile | `CFG/QCFG` 基础流、`miss/hit/M-window`、`ctrl_resp.err/m_buf`、`dma_req`、`m_dma_req`、`m_axis` row-major 导出、completion `irq` | `miss/hit/M-window` 三条路径均返回预期 `ctrl_resp`，导出数据顺序正确，DMA 请求数与 `irq` 次数符合预期 | 任一事务返回值错误、导出 beat 次序错误、DMA 请求数错误、`irq` 次数错误 |
| `PT-BB-002` | PT Numeric Boundaries | `test_pt_numeric_boundaries` | `identity` 作为 A；B 输入覆盖零值、常值、上下饱和和 tie rounding 场景 | `2x2/4x4/8x8` 数值正确性、量化边界、saturation、rounding tie | 每个边界场景导出矩阵与参考模型完全一致 | 任一边界场景出现导出值不一致、遗漏导出或 `ctrl_resp` 异常 |
| `PT-BB-003` | PT QCFG Modes | `test_pt_qcfg_modes` | 合法 `QCFG` payload；覆盖 `PER_TENSOR/X_WISE/Y_WISE/X_WISE_DIV2/Y_WISE_DIV2` | granularity 选择、payload 个数、scale index 映射、导出数值 | 每种 granularity 下 `QCFG` 交互成功且导出数值与参考模型一致 | QCFG 交互失败、payload 数量不匹配、导出数值与 scale 规则不符 |
| `PT-BB-004` | PT Protocol Errors | `test_pt_protocol_errors` | 注入非法 `MNK`、非对齐 offset、非法 QCFG、wrong `tuser`、A/B DMA error、M export DMA error | 错误响应路径、`ctrl_resp` 顺序、`irq` 次数、success resp + export error resp 组合 | 每类非法场景都进入预期错误路径，`ctrl_resp` 与 `irq` 行为符合设计预期 | 非法场景未报错、报错类型错误、`ctrl_resp` 顺序错误、`irq` 次数错误 |
| `PT-BB-005` | PT QCFG Odd Granularity | `test_pt_qcfg_odd_granularity` | odd `X_DIM` 或 odd `Y_DIM` 的 `/2` granularity header | odd 维度下 `/2` granularity 非法拒绝 | odd 维度下 `X/Y_WISE_DIV2` header 被明确拒绝并返回错误响应 | odd 维度下非法 granularity 被错误接受或未返回错误响应 |
| `PT-BB-006` | PT Backpressure | `test_pt_backpressure` | 对 `dma_req_ready`、`m_dma_req_ready`、`m_axis_tready`、`s_axis_valid` 注入时序扰动 | 输入侧 / 输出侧回压、导出未结束时排队下一事务 | 回压存在时事务仍按协议完成，导出顺序、响应和 `irq` 数正确 | 回压导致死锁、导出顺序错误、响应丢失或多余 `irq` |
| `PT-BB-007` | PT Randomized | `test_pt_randomized` | 固定 seed；混合 legal/hit/M-window/QCFG/invalid/wrong_tuser/export_error | 多 seed 混合事务、随机 ready/valid/backpressure、缓存命中、错误注入 | 所有 seed 全部通过，且失败可由 seed 完整复现 | 任一 seed 下出现非预期数据/协议 mismatch，或结果不可复现 |

## 6. 结果产物要求
### 6.1 结果目录
- xUnit 结果：`sim/cocotb/results/`
- 测试日志：`sim/cocotb/logs/`
- build 目录：`sim/cocotb/build/`

### 6.2 命名规则
- xUnit：
  - `<suite_name>_seed<seed>.xml`
- build log：
  - `<suite_name>.build.log`
- test log：
  - `<suite_name>_seed<seed>.test.log`

### 6.3 本轮重跑后的结果基线
- xUnit 文件总数：`26`
- 执行到的 testcase 数：`34`
- skipped 数：`148`
- failure 数：`0`

### 6.4 本轮结果文件清单
- smoke
  - `smoke_4x4_seed10.xml`
  - `smoke_8x8_seed10.xml`
- full
  - `full_2x2_numeric_seed10.xml`
  - `full_3x2_protocol_seed10.xml`
  - `full_4x4_core_seed10.xml`
  - `full_8x8_core_seed10.xml`
- randomized
  - `randomized_4x4_seed10..19.xml`
  - `randomized_8x8_seed10..19.xml`

## 7. 实际运行结论
### 7.1 smoke
- `smoke_4x4_seed10.xml`：PASS
- `smoke_8x8_seed10.xml`：PASS

### 7.2 full
- `full_2x2_numeric_seed10.xml`：PASS
- `full_3x2_protocol_seed10.xml`：PASS
- `full_4x4_core_seed10.xml`：PASS
- `full_8x8_core_seed10.xml`：PASS

### 7.3 randomized
- `randomized_4x4_seed10..19.xml`：全 PASS
- `randomized_8x8_seed10..19.xml`：全 PASS

## 8. 覆盖边界与未覆盖项
### 8.1 已覆盖
- 黑盒端口级控制流
- A/B DMA 输入协议
- M export 输出协议
- 多尺寸数值正确性
- 量化模式与数值边界
- `miss/hit/M-window`
- backpressure 组合
- 多 seed 伪随机混合事务

### 8.2 当前未单列展开的项
- A/B DMA `mid-stream error` 的独立 directed case
- `dma_done` / `m_dma_done` 成功路径下的长延迟 sweep
- 极端长 control queue 深压测

## 9. 适用与维护要求
- 当 `PT` 顶层接口、cocotb suite 分层、testcase ID 或结果目录规则变化时，本文档必须同步更新。
- 若新增 testcase，必须追加唯一 `PT-BB-xxx` ID，并补充：
  - 输入条件
  - 覆盖指标
  - 成功判据
  - 失败判据

## 10. 相关文档
- 通用模板：[blackbox_test_requirements_template.md](./blackbox_test_requirements_template.md)
- 被测模块：[../rtl/pt.v](../rtl/pt.v)
- cocotb 回归入口：[../sim/cocotb/run.py](../sim/cocotb/run.py)
- cocotb 命令入口：[../sim/cocotb/Makefile](../sim/cocotb/Makefile)
- testcase 集合：[../sim/cocotb/tests/test_pt_blackbox.py](../sim/cocotb/tests/test_pt_blackbox.py)
- 参考模型：[../sim/cocotb/tests/pt_model.py](../sim/cocotb/tests/pt_model.py)
