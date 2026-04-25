# FA Baseline 当前状态说明

- 时间：`2026-04-25`
- 仓库：`flash_atten`
- 文档目的：
  - 说明当前 baseline attention 设计已经做到什么程度
  - 说明现有 top、core、接口、验证状态和边界条件
  - 给后续实现、验证、汇报和交接提供统一口径

## 1. 总体结论

当前 baseline 已经不再是“概念原型”或“纯仿真脚本模型”，而是一个以真实 RTL 为主体、以正式交付 top 为目标的 attention baseline 设计。

当前代码已经形成三层结构：

1. `FA_CORE_BASELINE`
   - 共享算子核心
   - 保留抽象 DMA-shell 边界
   - 内部包含完整 baseline attention 数据通路
2. `FA_TOP_BASELINE_SIM`
   - 仿真封装 top
   - 保留 shell-DMA 接口
   - 用于 cocotb 算法回归、模块定位和 debug 可见性
3. `FA_TOP_BASELINE`
   - 正式交付 top
   - 对外提供 `AXI4-Lite + AXI4 read master + AXI4 write master`
   - 用于 formal baseline 接口交付

对应文件：

- [`rtl/fa_core_baseline.v`](../rtl/fa_core_baseline.v)
- [`rtl/fa_top_baseline_sim.v`](../rtl/fa_top_baseline_sim.v)
- [`rtl/fa_top_baseline.v`](../rtl/fa_top_baseline.v)

一句话概括当前状态：

- baseline attention 的核心算法主路径已经基本 RTL 化完成
- sim top 和 formal top 已经分层
- Stage 6 的接口收敛已经落地
- 但正式 AXI top 的完整长时端到端回归还没有在本轮中全部跑完

## 2. 当前 baseline 的目标定义

当前设计对齐的 baseline 是：

- `S = 256`
- `d = 64`
- `batch = 1`
- `head = 1`
- `Q/K/V/O = Q8.8`
- causal / non-causal 均支持
- 不显式存储完整 `256 x 256` attention matrix
- 采用 online softmax 和 tile 化 `K/V`

控制和数据接口定义为：

- 控制面：`AXI4-Lite CSR`
- 数据面：
  - sim top：抽象 DMA shell
  - formal top：`AXI4` master read/write

## 3. 架构分层状态

### 3.1 `FA_CORE_BASELINE`

`FA_CORE_BASELINE` 是当前 baseline 的真实共享核心。

它对上接收：

- `start_pulse`
- `soft_reset_pulse`
- `irq_en`
- `causal_en`
- `q_base/k_base/v_base/o_base`
- `stride_bytes`
- `neg_large`
- `scale`

它对外暴露的是抽象 DMA-shell 语义：

- 读描述符：
  - `rd_desc_valid/ready`
  - `rd_desc_addr`
  - `rd_desc_words`
  - `rd_desc_tag`
- 读数据：
  - `rd_data_valid/ready`
  - `rd_data`
  - `rd_data_last`
- 写描述符：
  - `wr_desc_valid/ready`
  - `wr_desc_addr`
  - `wr_desc_words`
- 写数据：
  - `wr_data_valid/ready`
  - `wr_data`
  - `wr_data_last`

它输出：

- `busy`
- `done`
- `error`
- `cycles`
- `rd_bytes`
- `wr_bytes`
- `irq`

此外它还保留了一组 sim/debug 可见信号，供 `FA_TOP_BASELINE_SIM` 使用：

- `q_tile_flat`
- `k_tile_flat`
- `v_tile_flat`
- `v_pv_layout_flat`
- `p_tile_flat`
- `oacc_tile_flat`
- `qk_result_tile_flat`
- `score_masked_tile_flat`
- `pv_result_tile_flat`
- `row_debug_m_state_flat`
- `row_debug_l_state_flat`
- `row_debug_seen_flat`

### 3.2 `FA_TOP_BASELINE_SIM`

`FA_TOP_BASELINE_SIM` 已经从原来的“全功能 top”收敛成“薄包装”。

它现在主要做三件事：

1. 接 AXI-Lite CSR
2. 实例化 `FA_CORE_BASELINE`
3. 继续暴露 shell-DMA 端口和 debug 可见性

这意味着：

- sim regression 继续可用
- 现有 cocotb 环境不需要因为 Stage 6 重新推倒重写
- 算法验证和接口验证被分离开了

### 3.3 `FA_TOP_BASELINE`

`FA_TOP_BASELINE` 是当前 baseline 的正式交付 top。

它内部实例化：

- `FA_CSR`
- `FA_CORE_BASELINE`
- `FA_AXI_RD_MASTER`
- `FA_AXI_WR_MASTER`

其中：

- `FA_CORE_BASELINE` 仍然只懂抽象 DMA-shell 语义
- `FA_AXI_RD_MASTER / FA_AXI_WR_MASTER` 负责把抽象描述符和字流转换为真实 AXI burst

这使得：

- 算法核心不必被 AXI 细节污染
- sim top 和 formal top 共享同一份核心逻辑
- 后续如果要继续做时序/面积/协议收敛，边界已经比较清晰

## 4. 真实 RTL 覆盖情况

当前 baseline 的核心模块已经基本都是真 RTL：

### 4.1 已真实化的模块

- `QK` 真核
  - [`rtl/fa_cores_real.v`](../rtl/fa_cores_real.v)
  - 模块：`FA_QK_CORE_REAL`
- `PV` 真核
  - [`rtl/fa_cores_real.v`](../rtl/fa_cores_real.v)
  - 模块：`FA_PV_CORE_REAL`
- `score_post`
  - [`rtl/fa_score_post_real.v`](../rtl/fa_score_post_real.v)
- `row_state`
  - [`rtl/fa_row_state_real.v`](../rtl/fa_row_state_real.v)
- `reciprocal`
  - [`rtl/fa_recip_q16_16.v`](../rtl/fa_recip_q16_16.v)
- `OACC update`
  - [`rtl/fa_oacc_update_real.v`](../rtl/fa_oacc_update_real.v)
- `Q/K/V/P/OACC` buffers
  - [`rtl/fa_buffers_real.v`](../rtl/fa_buffers_real.v)
- `tile scheduler`
  - [`rtl/fa_tile_sched.v`](../rtl/fa_tile_sched.v)
- `run lifecycle controller`
  - [`rtl/fa_run_ctrl.v`](../rtl/fa_run_ctrl.v)
- `shell DMA`
  - [`rtl/fa_dma_shell.v`](../rtl/fa_dma_shell.v)
- `formal AXI masters`
  - [`rtl/fa_axi_rd_master.v`](../rtl/fa_axi_rd_master.v)
  - 文件内同时定义 `FA_AXI_RD_MASTER` 和 `FA_AXI_WR_MASTER`

### 4.2 已不再作为主路径的代理

从阶段演进上看，原先的这些代理模块已经不再是当前 baseline 主路径：

- `FA_TILE_GEMM_PROXY`
- `FA_SCORE_POST_PROXY`
- `FA_ROW_STATE_PROXY`
- `FA_OACC_UPDATE_PROXY`

这些模块的历史作用是：

- 在 Stage 1/2 提供可跑通的行为路径
- 在 Stage 3/4/5 逐步被真 RTL 替换

## 5. 数据格式与 tile 约定

当前 baseline 的内部格式已经固定：

### 5.1 元素格式

- `Q/K/V/O/P`：`Q8.8`, signed 16-bit
- `score/m/l/scale/rescale`：`Q16.16`, signed 32-bit

### 5.2 打包方式

- 一个 `32-bit word` 打包两个 `Q8.8`
- `low 16 bits = even element`
- `high 16 bits = odd element`

### 5.3 tile 形状

- `Q/K/V/OACC`
  - `16 x 64`
  - `32 words/row`
  - `512 words/tile`
- `score/P`
  - `16 x 16`
  - `8 words/row`
  - `128 words/tile`

### 5.4 block 遍历固定

- `q_blk = 0..15`
- `kv_blk = 0..15`

也就是说：

- 外层每次处理一个 `16 x 64` 的 `Q` tile
- 内层按 16 个 `K/V` tile 依次累积

## 6. 接口状态

### 6.1 CSR 状态

CSR 已经收敛到 baseline 风格空间，主要包括：

- `CTRL @ 0x00`
- `STATUS @ 0x04`
- `CFG @ 0x08`
- `Q/K/V/O_BASE`
- `STRIDE_BYTES @ 0x34`
- `NEG_LARGE @ 0x38`
- `SCALE @ 0x3C`
- `CYCLES @ 0x40`
- `RD_BYTES @ 0x44`
- `WR_BYTES @ 0x48`

对应文件：

- [`rtl/csr_array.v`](../rtl/csr_array.v)
- [`rtl/fa_csr.v`](../rtl/fa_csr.v)

### 6.2 对齐约束

当前 formal top 明确施加了 16-byte 对齐约束：

- `Q_BASE/K_BASE/V_BASE/O_BASE` 必须 16-byte 对齐
- `STRIDE_BYTES` 必须 16-byte 对齐

如果不满足：

- `FA_CSR` 不会发出有效 `start_pulse`
- `STATUS.ERROR` 会被置位

这是当前 Stage 6 的刻意设计，不支持 unaligned merge / lane shift。

### 6.3 AXI master 状态

当前 AXI 主口实现选择了一个简单、保守、易验证的策略：

- `AXI_DATA_W = 128`
- `INCR` burst only
- `MAX_BURST_BEATS = 16`
- 单描述符单 outstanding

也就是说：

- 一个抽象 read/write descriptor 会被切分成一个或多个 128-bit AXI burst
- core 内部仍然只看到 32-bit word 粒度的数据流

## 7. 验证状态

### 7.1 已确认通过的静态检查

已经确认通过：

- Python 语法检查
- `FA_TOP_BASELINE_SIM` 顶层 `iverilog` elaboration
- `FA_TOP_BASELINE` 顶层 `iverilog` elaboration

### 7.2 已确认通过的回归点

在当前工作状态下，已经重新确认：

- `FA_TOP_BASELINE_SIM` 的 smoke 可通过
- `FA_TOP_BASELINE` 的对齐错误路径可通过

此前阶段里还确认过：

- sim wrapper 的单块功能
- row-state / score-post / OACC update 的定位性测试
- Stage 5 的 OACC 真路径局部验证

### 7.3 还没有完全收口的验证项

当前最主要的未完全收口项是：

- `FA_TOP_BASELINE` 的完整 AXI 长时端到端 regression

原因不是结构未连通，而是：

- Icarus 下这类 full baseline 回归耗时较长
- 当前更适合先按 smoke / 协议点 / 局部功能分层验证

因此当前状态应表述为：

- Stage 6 代码结构已落地
- 正式 top 已建成
- 基础验证已覆盖
- 完整 AXI 长跑还需要继续跑完

## 8. 当前 baseline 的优点

当前设计的主要优点有四个：

### 8.1 核心与接口已经解耦

`FA_CORE_BASELINE` 把 attention 算子核心和外部接口层拆开了。

这带来的好处是：

- sim top 和 formal top 共享一份核心
- 算法修改不需要重写 AXI wrapper
- AXI wrapper 调试也不会污染核心数据通路

### 8.2 路径已经基本真实化

到 Stage 5 为止，attention 主路径已经不再依赖行为代理来完成关键数学。

这意味着：

- 当前设计已经具备“真实硬件 baseline”的雏形
- 后续更多是交付、优化和验证问题，而不是“算子还没实现”

### 8.3 保留了 sim 友好性

虽然已经抽 core 并加了 formal top，但并没有把 sim 环境破坏掉。

这点很关键，因为：

- baseline 算法回归仍需要快速调试入口
- debug 可见信号仍然可以通过 sim top 观察

### 8.4 已经有明确的计数和错误面

当前设计已经有：

- `CYCLES`
- `RD_BYTES`
- `WR_BYTES`
- `STATUS.ERROR`

这使得后续做：

- 性能报告
- 带宽分析
- baseline 汇报

会更顺手。

## 9. 当前 baseline 的限制

当前版本仍然有一些明确限制：

### 9.1 只覆盖 baseline 形状

当前实现是围绕：

- `S=256`
- `d=64`

锁定的。

它不是一个泛化到任意 `S/d` 的可编程 attention accelerator。

### 9.2 AXI 主口实现偏保守

当前 AXI master 不是为极限性能设计的：

- outstanding depth = 1
- burst policy 比较简单
- 没做 unaligned support

它的目标是：

- 先形成正确、清晰、可交付的 baseline top

### 9.3 长时 AXI regression 还未完全闭环

这不是功能一定有问题，而是验证成本还比较高。

后续还需要继续把：

- AXI smoke
- burst split
- backpressure
- full causal

完整跑透。

## 10. 现阶段最准确的状态描述

如果要对外用一句较准确的话描述当前 baseline，我建议这样说：

> 当前 baseline attention 设计已经形成“共享 core + sim wrapper + formal AXI top”的完整三层结构，核心算子路径已基本 RTL 化，CSR/计数/对齐错误路径已收敛，当前主要剩余工作是正式 AXI top 的长时回归、性能评估和交付化收尾。

