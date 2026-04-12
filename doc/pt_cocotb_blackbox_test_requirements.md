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
  - 场景目录：[pt_case_catalog.py](../sim/cocotb/tests/pt_case_catalog.py)
  - testcase 集合：
    - [test_pt_smoke_cases.py](../sim/cocotb/tests/test_pt_smoke_cases.py)
    - [test_pt_numeric_cases.py](../sim/cocotb/tests/test_pt_numeric_cases.py)
    - [test_pt_qcfg_cases.py](../sim/cocotb/tests/test_pt_qcfg_cases.py)
    - [test_pt_protocol_cases.py](../sim/cocotb/tests/test_pt_protocol_cases.py)
    - [test_pt_backpressure_cases.py](../sim/cocotb/tests/test_pt_backpressure_cases.py)
    - [test_pt_randomized_cases.py](../sim/cocotb/tests/test_pt_randomized_cases.py)
    - [test_pt_guard_boot.py](../sim/cocotb/tests/test_pt_guard_boot.py)
  - 共享黑盒环境：[pt_blackbox_env.py](../sim/cocotb/tests/pt_blackbox_env.py)
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
- cocotb 构建参数由 [run.py](../sim/cocotb/run.py) 注入：
  - `DATA_WIDTH=32`
  - `EXT_ADDR_W=32`
  - `DMA_BEATS_W=16`
  - `LUT_DEPTH=8`
  - `A_BANK_DEPTH=8`
  - `B_BANK_DEPTH=8`
- 尺寸 / profile sweep：
  - `2x2`
  - `4x4`
  - `8x8`
  - 20 个非法维度 guard profile

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
  - `full_pow2_guard_<profile>_seed10`
- `randomized`
  - `randomized_<profile>_4x4_seed<seed>`
  - `randomized_<profile>_8x8_seed<seed>`

## 5. Testcase 与指标要求
### 5.1 统一分组标签
- `典型值测试`
- `边界值测试`
- `异常路径测试`
- `时序扰动测试`
- `随机扰动测试`
- `约束/配置测试`

### 5.2 Testcase 与指标表
| 测试ID | 测试名称 | 分组标签 | 对应用例 | 输入条件 / 前置条件 | 覆盖指标 | 成功判据 | 失败判据 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `PT-BB-001` | PT Blackbox Smoke | `典型值测试` / `边界值测试` | `tests.test_pt_smoke_typical_*` + `tests.test_pt_smoke_boundary_*` | 已完成 `CFG A/B base`、`QCFG per-tensor`；提供 20 组合法矩阵场景 | `CFG/QCFG` 基础流、`miss/hit/M-window`、`ctrl_resp.err/m_buf`、`dma_req`、`m_dma_req`、`m_axis` row-major 导出、completion `irq` | 20 个 smoke 场景在 `smoke_4x4/smoke_8x8/full_4x4_core/full_8x8_core` 中累计 executed `80` 次且无失败 | 任一场景返回值错误、导出 beat 次序错误、DMA 请求数错误或 `irq` 次数错误 |
| `PT-BB-002` | PT Numeric Boundaries | `典型值测试` / `边界值测试` | `tests.test_pt_numeric_typical_*` + `tests.test_pt_numeric_boundary_*` | `identity` 作为 A；20 组 B 输入覆盖零值、常值、饱和、近零和 sign flip | `2x2/4x4/8x8` 数值正确性、量化边界、saturation、rounding tie | 20 个 numeric 场景在 `2x2/4x4/8x8` 上累计 executed `60` 次且全部与参考模型一致 | 任一边界场景出现导出值不一致、遗漏导出或 `ctrl_resp` 异常 |
| `PT-BB-003` | PT QCFG Modes | `典型值测试` / `边界值测试` / `约束/配置测试` | `tests.test_pt_qcfg_typical_*` + `tests.test_pt_qcfg_boundary_*` + `tests.test_pt_qcfg_config_*` | 合法 `QCFG` payload；覆盖 20 组 granularity/scale/profile 组合 | granularity 选择、payload 个数、scale index 映射、导出数值 | 20 个 QCFG 场景在 `4x4/8x8` 上累计 executed `40` 次且全部通过 | QCFG 交互失败、payload 数量不匹配、导出数值与 scale 规则不符 |
| `PT-BB-004` | PT Protocol Errors | `异常路径测试` | `tests.test_pt_protocol_error_*` | 注入控制编码、地址对齐、QCFG 交互、输入流和导出异常 | 错误响应路径、`ctrl_resp` 顺序、`irq` 次数、success resp + export error resp 组合 | 20 个 protocol case 在 `full_4x4_core` 中累计 executed `20` 次且全部通过 | 非法场景未报错、报错类型错误、`ctrl_resp` 顺序错误、`irq` 次数错误 |
| `PT-BB-005` | PT Power-of-two Guard | `约束/配置测试` | `full_pow2_guard_<profile>_seed10` | 20 个不同非法维度 profile 启动仿真 | 顶层参数约束、启动即拒绝非法维度、fatal 文本稳定性 | 20 个 guard profile 均在启动阶段以预期 fatal 退出，且 log 命中 `PT_MD/PT_CE` guard 文本 | 非法维度配置被错误接受、fatal 文本不匹配、或负例结果未被 runner 正确归档 |
| `PT-BB-006` | PT Backpressure | `时序扰动测试` | `tests.test_pt_backpressure_timing_*` | 20 组固定 ready/valid 扰动；按轻/中/重/错相/偏压分组 | 输入侧 / 输出侧回压、导出未结束时排队下一事务 | 20 个 backpressure 场景在 `4x4/8x8` 上累计 executed `40` 次且无超时、无死锁 | 回压导致死锁、导出顺序错误、响应丢失或多余 `irq` |
| `PT-BB-007` | PT Randomized | `随机扰动测试` | `randomized_<profile>_<dim>_seed<seed>` | 10 种 traffic bias x `4x4/8x8`；每个 profile 固定 seed 和权重分布 | 多 seed / profile 混合事务、随机 ready/valid/backpressure、缓存命中、错误注入 | 20 个命名随机 profile 全部通过，且失败可由 profile 名与 seed 完整复现 | 任一 profile 下出现非预期数据/协议 mismatch，或结果不可复现 |

## 6. 结果产物要求
### 6.1 结果目录
- xUnit 结果：`sim/cocotb/results/`
- 测试日志：`sim/cocotb/logs/`
- build 目录：`sim/cocotb/build/`

### 6.2 命名规则
- xUnit：
  - `smoke_<dim>_seed<seed>.xml`
  - `full_pow2_guard_<profile>_seed<seed>.xml`
  - `randomized_<profile>_<dim>_seed<seed>.xml`
- build log：
  - `<suite_name>.build.log`
- test log：
  - `<suite_name>_seed<seed>.test.log`

### 6.3 本轮重跑后的结果基线
- xUnit 文件总数：`45`
- 执行到的 testcase 数：`280`
- skipped 数：`0`
- failure 数：`0`

### 6.4 本轮结果文件清单
- smoke
  - `smoke_4x4_seed10.xml`
  - `smoke_8x8_seed10.xml`
- full
  - `full_2x2_numeric_seed10.xml`
  - `full_4x4_core_seed10.xml`
  - `full_8x8_core_seed10.xml`
  - `full_pow2_guard_<profile>_seed10.xml`
- randomized
  - `randomized_<profile>_4x4_seed<seed>.xml`
  - `randomized_<profile>_8x8_seed<seed>.xml`

## 7. 实际运行结论
### 7.1 smoke
- `smoke_4x4_seed10.xml`：PASS，executed=`20`
- `smoke_8x8_seed10.xml`：PASS，executed=`20`

### 7.2 full
- `full_2x2_numeric_seed10.xml`：PASS，executed=`20`
- `full_4x4_core_seed10.xml`：PASS，executed=`100`
- `full_8x8_core_seed10.xml`：PASS，executed=`80`
- `full_pow2_guard_<profile>_seed10.xml`：`20` 个 profile 文件全 PASS（expected startup fatal；runner synthetic xUnit）

### 7.3 randomized
- `randomized_<profile>_4x4_seed<seed>.xml`：`10` 个 profile 全 PASS
- `randomized_<profile>_8x8_seed<seed>.xml`：`10` 个 profile 全 PASS

## 8. 覆盖边界与未覆盖项
### 8.1 已覆盖
- 黑盒端口级控制流
- A/B DMA 输入协议
- M export 输出协议
- 多尺寸数值正确性
- 量化模式与数值边界
- odd / non-power-of-two 维度约束负例
- `miss/hit/M-window`
- backpressure 组合
- 命名随机 profile 的 traffic bias 覆盖
- 每个黑盒测试项累计 executed 用例数 `>= 20`

### 8.2 当前未单列展开的项
- A/B DMA `mid-stream error` 的独立 directed case
- `dma_done` / `m_dma_done` 成功路径下的长延迟 sweep
- 极端长 control queue 深压测

## 9. 适用与维护要求
- 当 `PT` 顶层接口、cocotb suite 分层、testcase ID 或结果目录规则变化时，本文档必须同步更新。
- 若新增 testcase，必须追加唯一 `PT-BB-xxx` ID，并补充：
  - 分组标签
  - 输入条件
  - 覆盖指标
  - 成功判据
  - 失败判据

## 10. 相关文档
- 通用模板：[blackbox_test_requirements_template.md](./blackbox_test_requirements_template.md)
- 被测模块：[../rtl/pt.v](../rtl/pt.v)
- cocotb 回归入口：[../sim/cocotb/run.py](../sim/cocotb/run.py)
- cocotb 命令入口：[../sim/cocotb/Makefile](../sim/cocotb/Makefile)
- 场景目录：[../sim/cocotb/tests/pt_case_catalog.py](../sim/cocotb/tests/pt_case_catalog.py)
- 共享黑盒环境：[../sim/cocotb/tests/pt_blackbox_env.py](../sim/cocotb/tests/pt_blackbox_env.py)
- 参考模型：[../sim/cocotb/tests/pt_model.py](../sim/cocotb/tests/pt_model.py)

