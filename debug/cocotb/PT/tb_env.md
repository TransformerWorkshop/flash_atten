# PT Cocotb 测试环境说明

## 1. 被测对象
- 被测模块：[`PT`](../../../rtl/pt.v)
- 验证方式：严格黑盒
- 黑盒边界：
  - 仅驱动/观察 `PT` 顶层端口
  - 不读取内部层级信号
  - 不读取内部 SRAM、FIFO 或状态机

## 2. 软件环境
- Python：`3.12.4`
- cocotb：`2.0.1`
- 仿真器：`Icarus Verilog 12.0 (stable)`
- `pytest`：未安装
  - 当前 cocotb 回归可正常运行
  - 日志中会提示 `pytest not found`，但不影响执行结果

## 3. 仿真环境
- 默认仿真后端：`icarus`
- 顶层模块：`PT`
- 默认 timescale：`1ns / 1ps`
- cocotb 回归入口：[`run.py`](../../../sim/cocotb/run.py)
- cocotb 命令入口：[`Makefile`](../../../sim/cocotb/Makefile)
- testcase 集合：[`test_pt_blackbox.py`](../../../sim/cocotb/tests/test_pt_blackbox.py)
- 参考模型：[`pt_model.py`](../../../sim/cocotb/tests/pt_model.py)

## 4. 参数与尺寸 sweep
- 默认参数来自 [`run.py`](../../../sim/cocotb/run.py)：
  - `DATA_WIDTH=32`
  - `EXT_ADDR_W=32`
  - `DMA_BEATS_W=16`
  - `LUT_DEPTH=8`
  - `A_BANK_DEPTH=8`
  - `B_BANK_DEPTH=8`
- 尺寸覆盖：
  - `2x2`
  - `3x2`
  - `4x4`
  - `8x8`

## 5. 回归入口命令
```bash
make -C sim/cocotb clean
make -C sim/cocotb smoke
make -C sim/cocotb full
make -C sim/cocotb randomized
```

## 6. 结果与日志目录
- xUnit 结果目录：[`sim/cocotb/results/`](../../../sim/cocotb/results)
- build / test 日志目录：[`sim/cocotb/logs/`](../../../sim/cocotb/logs)
- 构建目录：[`sim/cocotb/build/`](../../../sim/cocotb/build)

## 7. 当前结果基线
- 结果文件总数：`26`
- 实际执行 testcase 数：`34`
- skipped 数：`148`
- failure 数：`0`

## 8. 必要参考文档
- PT 专用规范：[pt_cocotb_blackbox_test_requirements.md](../../../doc/pt_cocotb_blackbox_test_requirements.md)
- 通用模板：[blackbox_test_requirements_template.md](../../../doc/blackbox_test_requirements_template.md)
- 总结文档：[summary_20260412_162330.md](./summary_20260412_162330.md)
- 被测模块顶层：[`pt.v`](../../../rtl/pt.v)
- cocotb runner：[`run.py`](../../../sim/cocotb/run.py)
- cocotb 命令入口：[`Makefile`](../../../sim/cocotb/Makefile)
- cocotb testcase：[`test_pt_blackbox.py`](../../../sim/cocotb/tests/test_pt_blackbox.py)
- cocotb 参考模型：[`pt_model.py`](../../../sim/cocotb/tests/pt_model.py)
