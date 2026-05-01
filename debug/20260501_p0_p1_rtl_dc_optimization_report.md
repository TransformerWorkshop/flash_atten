# FA_TOP_BASELINE P0/P1 RTL 清理与下一轮 DC 方案

日期：2026-05-01

范围：本轮只执行 P0/P1 RTL 修改、轻量 lint 检查和 cocotb 回归；未重新运行 DC，也未重新运行 Formality。

## 结果摘要

- P0 RTL 清理：已完成。
- P0 cocotb 回归：通过，命令为 `make fa_ci REBUILD=1`，执行目录为 `sim/cocotb`。
- P1 RTL 清理：已完成。
- P1 cocotb 回归：通过，命令为 `make fa_ci REBUILD=1`，执行目录为 `sim/cocotb`。
- 常规仿真视图 lint：`verilator --lint-only --Wno-fatal -Irtl rtl/*.v --top-module FA_TOP_BASELINE` 通过。
- 综合视图 lint：`verilator --lint-only --Wno-fatal -DSYNTHESIS -Irtl rtl/*.v --top-module FA_TOP_BASELINE` 通过。

## P0 RTL 修改

- 综合视图剥离 debug 端口：
  - 在 top/core/buffer/score/row/shared-core 层级，把宽 debug 端口和 debug-only 连接用 ``ifndef SYNTHESIS`` 隔离。
  - cocotb 默认不定义 `SYNTHESIS`，所以测试仍可访问现有 debug 探针。
  - DC 使用 `analyze -define SYNTHESIS` 时会看到更小的生产接口，预期显著减少宽 debug 端口引入的 LINT/DRC 噪声。

- Formality array-bound 风险修复：
  - `GEMM_V3`：给动态 `pe_m_data` 读取增加显式索引和范围保护。
  - `FA_ROW_STATE_REAL`：把 4 行 tile 内部迭代索引从 4 bit 缩窄为 2 bit，形成 16 行全局索引时再零扩展。
  - `FA_OACC_UPDATE_REAL`：采用同样的 2 bit 内部 row 索引和零扩展写法。

## P1 RTL 修改

- 降低局部 width/readability lint 噪声：
  - `FA_QK_PV_RESULT_PACKER`：显式化 2 bit block 比较。
  - `FA_SCORE_POST_REAL`：显式化 32 bit global K index 加法。
  - `FA_V_BUF_PV_REAL`：显式化 9 bit source write index 加法。
  - `FA_P_BYPASS_REAL`：显式化 32 bit read-address index 加法。

- AXI-Lite tieoff 可读性：
  - 在生产 top 和 sim top 中，把裸 `3'b000` 的 `awprot/arprot` 常量替换为命名 tieoff wire。

本轮有意暂不合入的剩余 lint 噪声：

- `GEMU_V3` 的 sign-extension 类告警。
- `FA_AXI_RD_MASTER` 的 burst-count width 类告警。

这些更适合作为 P2，因为会触碰更底层的乘加和 DMA 计数表达式。

## 下一轮 DC 优化方案

可将 `debug/20260501_p0_p1_dc_next_run_snippet.tcl` 合入下一次 DC flow。

DRC 清理：

- 继续使用 `analyze -define SYNTHESIS`，确保 debug-only 探针不进入综合视图。
- 保持 `compile_ultra -no_autoungroup`，优先保留层级，方便网表阅读和 Formality 匹配。
- 在 compile 前后各执行一次 `set_fix_multiple_port_nets -all -buffer_constants [current_design]`。
- 重新检查 LINT-28、LINT-32、LINT-33。P0 的 debug 剥离预期主要降低 LINT-28，常量/tie net 修复预期降低 LINT-32 类噪声。

约束与 IO load 完整性：

- compile 前生成 `check_timing`、`report_clock -attributes`、input/output `report_port -verbose`。
- 核对 `base.sdc` 中所有 primary IO 的 delay/load/transition 假设。
- 对 `check_timing` 报出的未约束 AXI、AXI-Lite、control 顶层端口补充 output load 或 input transition。
- 将 max transition 和 max capacitance violation 报告拆开输出，方便后续 DRC triage。

Netlist 可读性：

- 保留层级并执行 `change_names -rules verilog -hierarchy`。
- 同一 run tag 下输出 DDC、Verilog netlist、SDC 和 SVF。
- 保留 RTL 命名 tieoff，避免生产网表中出现 debug fanout 噪声。

Formality 便利性：

- compile 前保持 `set_svf $svf_file`，link 后立即 `set_verification_top`。
- 对 `FA_ROW_STATE_REAL`、`FA_OACC_UPDATE_REAL`、`GEMM_V3`、`FA_QK_PV_SHARED_CORE_REAL` 设置高验证优先级。
- 在 RTL-vs-netlist equivalence 干净前，避免 retiming 和大范围 ungroup。

## 后续 RTL 候选项

- P2-A：显式化 `GEMU_V3` accumulator output 和 lane multiply 的 sign extension/truncation。
- P2-B：在 `FA_AXI_RD_MASTER` 中增加 typed burst-count helper wires，清理剩余 width 告警。
- P2-C：给 CI 增加一个 `-DSYNTHESIS` 的轻量 Verilator lint target，提前捕捉 debug 端口条件化回归。

## 修改文件

- `rtl/fa_buffers_real.v`
- `rtl/fa_core_baseline.v`
- `rtl/fa_cores_real.v`
- `rtl/fa_oacc_update_real.v`
- `rtl/fa_p_bypass_real.v`
- `rtl/fa_row_state_real.v`
- `rtl/fa_score_post_real.v`
- `rtl/fa_top_baseline.v`
- `rtl/fa_top_baseline_sim.v`
- `rtl/gemm_v3.v`
