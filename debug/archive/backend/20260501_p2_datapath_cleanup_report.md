# FA_TOP_BASELINE P2 Datapath Cleanup Report

日期：2026-05-01

范围：执行 P2-A/P2-B RTL 修改；未重新运行 DC，也未重新运行 Formality。

## 修改摘要

- `GEMU_V3`
  - 将输出 `m` 从固定 `4*WIDTH` 改为实际 accumulator 宽度 `ACC_WIDTH`。
  - 将 scalar multiply 和 packed lane multiply 的 sign extension/truncation 显式化。
  - 移除 `ACC_WIDTH -> 4*WIDTH` 的隐式输出扩展。

- `GEMM_V3`
  - 将 `pe_m_data`、`group_word`、`m_group_data` 从 `4*WIDTH` 宽度改为 `ACC_WIDTH` 宽度。
  - 保持 valid/ready、stream index、group ordering 不变。

- `FA_QK_PV_RESULT_PACKER` / `FA_QK_PV_SHARED_CORE_REAL`
  - 将 shared GEMM 到 result packer 的 group bus 从 16 lane * 128 bit 收窄为 16 lane * 64 bit。
  - 在 result packer 边界执行 q16/q88 饱和转换。
  - 保持外部 `qk_block_data`、`pv_block_data`、debug tile 输出格式不变。

- `FA_AXI_RD_MASTER` / `FA_AXI_WR_MASTER`
  - 增加 typed helper：`ceil_words_to_beats`、`burst_len_from_beats`、`addr_after_burst`。
  - 将 burst length、burst word count、address step 的 unsized integer 算术替换为显式宽度表达式。
  - 保持 AXI handshake 和 burst 行为不变。

## 验证结果

- 常规仿真视图 lint 通过且无 warning：
  - `verilator --lint-only --Wno-fatal -Irtl rtl/*.v --top-module FA_TOP_BASELINE`
- 综合视图 lint 通过且无 warning：
  - `verilator --lint-only --Wno-fatal -DSYNTHESIS -Irtl rtl/*.v --top-module FA_TOP_BASELINE`
- cocotb 全回归通过：
  - `make fa_ci REBUILD=1`

## 预期收益

- 消除 P1 后剩余的 GEMU sign-extension 和 AXI burst-count width lint 噪声。
- shared GEMM 内部结果 bus 从 2048 bit 降到 1024 bit，减少不必要的层级端口宽度和中间连线宽度。
- 下一轮 DC 报告中，GEMU/GEMM 相关可读性噪声应明显下降；实际 max transition 改善幅度仍需 DC 确认。

## 后续建议

- 下一次 DC/Formality 先基于本 P2 版本跑一轮，确认 LINT/DRC、WNS、max transition 变化。
- 如果 WNS 仍主要集中在 `FA_OACC_UPDATE_REAL`，再进入 P3 的 OACC 分拍更新方案。
- 如果 max transition 仍主要集中在 `FA_SCORE_POST_REAL`，再评估 ScorePost 4-lane 分拍方案。

## 修改文件

- `rtl/gemu_v3.v`
- `rtl/gemm_v3.v`
- `rtl/fa_cores_real.v`
- `rtl/fa_axi_rd_master.v`
