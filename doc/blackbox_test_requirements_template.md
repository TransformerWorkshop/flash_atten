# 黑盒测试要求模板

## 1. 文档目的
- 本文档用于定义某个模块的标准化黑盒测试要求。
- 适用对象：
  - 验证工程师
  - 设计工程师
  - 回归维护人员
- 说明：
  - 本模板为模块无关模板；
  - 已落地示例可参考 [PT Cocotb 黑盒测试要求规范](./pt_cocotb_blackbox_test_requirements.md)。

## 2. 被测对象
- 被测模块：`<DUT_NAME>`
- 验证方式：严格黑盒 / 弱黑盒 / 接口黑盒
- 黑盒边界定义：
  - 是否允许读取内部层级信号
  - 是否允许读取内部 memory
  - 是否允许调试期使用白盒钩子
- 参考入口：
  - 回归入口：`<RUNNER_FILE>`
  - 命令入口：`<MAKEFILE_OR_SCRIPT>`
  - testcase 集合：`<TEST_FILE>`
  - 参考模型：`<MODEL_FILE>`

## 3. 测试环境要求
### 3.1 软件环境
- Python：`<PYTHON_VERSION>`
- cocotb / UVM / pytest / 其他框架：`<FRAMEWORK_VERSION>`
- 仿真器：`<SIMULATOR_NAME_AND_VERSION>`
- 其他依赖：
  - `<DEPENDENCY_1>`
  - `<DEPENDENCY_2>`

### 3.2 仿真环境
- 默认仿真后端：`<SIM_BACKEND>`
- 顶层模块：`<TOPLEVEL>`
- timescale：`<TIMESCALE>`
- 参数覆盖方式：
  - `<PARAM_1>`
  - `<PARAM_2>`
- 尺寸 / 配置 sweep：
  - `<CFG_1>`
  - `<CFG_2>`

## 4. 回归入口与执行命令
### 4.1 标准命令
```bash
<clean command>
<smoke command>
<full command>
<randomized command>
```

### 4.2 可选参数
```bash
<command with seed override>
<command with waves>
<command with verbose>
```

### 4.3 分层定义
- `smoke`
  - `<smoke_cfg_1>`
  - `<smoke_cfg_2>`
- `full`
  - `<full_cfg_1>`
  - `<full_cfg_2>`
- `randomized`
  - `<random_cfg_1>`
  - `<random_cfg_2>`

## 5. Testcase 与指标要求
| 测试ID | 测试名称 | 对应用例 | 输入条件 / 前置条件 | 覆盖指标 | 成功判据 | 失败判据 |
| --- | --- | --- | --- | --- | --- | --- |
| `<MOD-BB-001>` | `<name>` | `<testcase>` | `<input/precondition>` | `<coverage>` | `<success criteria>` | `<failure criteria>` |
| `<MOD-BB-002>` | `<name>` | `<testcase>` | `<input/precondition>` | `<coverage>` | `<success criteria>` | `<failure criteria>` |
| `<MOD-BB-003>` | `<name>` | `<testcase>` | `<input/precondition>` | `<coverage>` | `<success criteria>` | `<failure criteria>` |

### 5.1 推荐 testcase 维度
- 基础功能：
  - `<basic case>`
- 数值边界：
  - `<numeric boundary case>`
- 协议错误：
  - `<protocol error case>`
- 时序 / backpressure：
  - `<timing case>`
- 随机扰动：
  - `<random case>`

## 6. 结果产物要求
### 6.1 结果目录
- xUnit / junit：`<RESULT_DIR>`
- 日志目录：`<LOG_DIR>`
- build 目录：`<BUILD_DIR>`

### 6.2 命名规则
- 结果文件：
  - `<suite_name>_seed<seed>.xml`
- build log：
  - `<suite_name>.build.log`
- test log：
  - `<suite_name>_seed<seed>.test.log`

### 6.3 结果统计要求
- 应至少统计：
  - result files 总数
  - executed testcase 数
  - skipped 数
  - failed 数
- 建议格式：
  - `result_files = <N>`
  - `executed = <N>`
  - `skipped = <N>`
  - `failed = <N>`

## 7. 实际运行结论
### 7.1 smoke
- `<smoke_result_1>`
- `<smoke_result_2>`

### 7.2 full
- `<full_result_1>`
- `<full_result_2>`

### 7.3 randomized
- `<random_result_1>`
- `<random_result_2>`

## 8. 覆盖边界与未覆盖项
### 8.1 已覆盖
- `<covered_item_1>`
- `<covered_item_2>`
- `<covered_item_3>`

### 8.2 当前未覆盖或未单列展开项
- `<gap_1>`
- `<gap_2>`
- `<gap_3>`

## 9. 适用与维护要求
- 当以下任一项变化时，本文档必须同步更新：
  - 顶层接口
  - suite 分层
  - testcase 列表
  - 结果目录规则
- 若新增 testcase，必须追加唯一测试 ID，并补充：
  - 输入条件
  - 覆盖指标
  - 成功判据
  - 失败判据

## 10. 参考文档
- 已落地示例：[pt_cocotb_blackbox_test_requirements.md](./pt_cocotb_blackbox_test_requirements.md)
- DUT 规格：`<SPEC_LINK>`
- 回归入口：`<RUNNER_LINK>`
- testcase 文件：`<TEST_FILE_LINK>`
- 参考模型：`<MODEL_FILE_LINK>`
