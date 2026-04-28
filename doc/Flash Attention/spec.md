# 摘 要

本项目面向大模型推理中的 Scaled Dot-Product Attention，设计并实现了一个 Flash Attention-style 的硬件加速 IP。设计目标是在不显式存储完整注意力矩阵的前提下，完成 `O = softmax(QK^T / sqrt(d) + M) V` 的端到端计算，并支持 causal 与 non-causal 两种模式。当前 RTL 以 `FA_TOP_BASELINE` 为顶层，固定支持 `SEQ_LEN=256`、`HEAD_DIM=64`、`16x16` tile 调度，通过 AXI4-Lite CSR 配置，通过 128-bit AXI master 读写外部 Q/K/V/O 数据。核心方案采用在线 softmax、分块 QK/PV 计算、OACC 累加与输出回写，并围绕面积约束完成了 OACC Q4.12 压缩、P buffer 旁路、QK/PV 共享 4x16 GEMM、future causal tile 跳过和 Q tile 预取等优化。验证方面，cocotb 回归覆盖 CSR、DMA、端到端 causal/non-causal、背压、soft reset、数值精度和性能计数；当前采样精度满足 `mean_err <= 0.03`、`max_err <= 0.10`。200MHz 下实测完整运行 cycles 为 causal `91,011`、non-causal `161,091`，均小于 `300k` 目标；最近有效顶层 DC 结果为 `545,044.935124` 标准单元面积，约 `1,853,894` NAND2 等效门，满足 `<2M` NAND2 面积约束。

关键词：Flash Attention; online softmax; 硬件加速器; AXI; 面积优化

---

# 1 赛题理解与需求分解

## 1.1 赛题理解与需求目标

### 1.1.1 赛题理解

赛题要求设计一个可综合的 Flash Attention-style 注意力计算硬件 IP。目标算子为 SDPA/FlashAttention，输入为 Q、K、V 矩阵和 mask/causal 配置，输出为 O 矩阵。相比直接计算并存储完整 `SxS` attention matrix，Flash Attention 的核心思想是按 tile 流式处理 Q/K/V，在片上维护每行的 online softmax 状态，从而减少片上存储压力并降低外部访存量。

当前实现选择固定问题规模：`S=256`、`d=64`、Q/KV tile 均为 `16` 行。设计重点为：

- 正确实现 causal 与 non-causal attention。
- 在 `<=300k cycles` 的时序预算内完成一次完整运算。
- 在 `<2M` NAND2 等效逻辑门面积约束内实现可综合顶层。
- 保持 AXI4-Lite/AXI master 接口可集成、可测试、可回归。

### 1.1.2 设计目标

- 功能目标：支持 `SEQ_LEN=256`、`HEAD_DIM=64` 的完整 Flash Attention 计算，支持 causal/non-causal 模式，提供 AXI4-Lite CSR 配置和 AXI master 访存接口。
- 性能目标：完整一次 FA 运算 cycles `<=300k`；目标主频 `200MHz`。
- 面积目标：顶层面积 `<2M` NAND2 等效逻辑门，含综合可见存储结构。
- 功耗目标：________
- 可验证性目标：cocotb 端到端 golden compare 通过；精度阈值 `mean_err <= 0.03`、`max_err <= 0.10`；顶层 SpyGlass 无 error；关键 RTL 可通过 Verilator/iverilog 编译检查。

## 1.2 需求分解与方案映射

| 需求项 | 设计分解 | 实现路径 | 验证路径 |
|---|---|---|---|
| SDPA/Flash Attention 功能 | QK、scale/mask、online softmax、PV、OACC update、store | `FA_CORE_BASELINE` 内部调度各计算阶段 | `fa_full`、`fa_baseline` 端到端数值测试 |
| causal/non-causal 模式 | CSR 配置 `causal_en`，调度器跳过 future tile，score post 执行 mask | `FA_CSR`、`FA_TILE_SCHED`、`FA_SCORE_POST_REAL` | causal/non-causal full cases、descriptor count cases |
| 片上存储控制 | Q/K/V tile buffer、row-state、OACC、result row buffer | `fa_buffers_real.v`、`FA_ROW_STATE_REAL`、`FA_P_BYPASS_REAL` | buffer directed tests、protocol tests |
| 面积约束 | 压缩 OACC、移除 P buffer、共享并缩小 GEMM、减少宽调试路径 | Q4.12 OACC、P bypass、shared 4x16 `GEMM_V3` | DC area report、SpyGlass lint |
| 性能约束 | tile 流水调度、Q prefetch、future causal tile skip | `FA_TILE_SCHED` | `ADDR_CYCLES` 实测、`fa_baseline_profile.py` |
| 外部接口 | AXI4-Lite CSR + 128-bit AXI read/write master | `FA_TOP_BASELINE`、`fa_dma_shell.v` | AXI full tests、CSR tests、backpressure tests |

## 1.3 指标约束与达成路径

### 1.3.1 面积

面积目标为 `<2M` NAND2 等效门。最近有效顶层 DC checkpoint：

- Top：`FA_TOP_BASELINE`
- Cell area：`545,044.935124`
- NAND2 reference area：`0.294`
- NAND2 equivalent：`1,853,894`
- 目标裕量：约 `146,106` NAND2

主要面积优化策略：

- OACC 内部存储由 32-bit 表示压缩为 16-bit Q4.12，导出时再转换为外部 Q8.8 打包格式。
- 主路径移除独立 P buffer SRAM，由 `FA_P_BYPASS_REAL` 直接从 row-state 的 probability tile 切片供给 PV。
- QK 与 PV 共用一个 GEMM 阵列，避免两套大面积 MAC 阵列并存。
- GEMM 阵列缩小为 4x16，通过串行 row block 换取面积下降。
- 对浅而宽的 tile/result buffer 优先使用寄存器结构；已评估当前 SRAM macro 对这些 buffer 不是面积优势方案。
- 排除综合路径中的宽调试 mirror，削减 reset/clear fanout。

### 1.3.2 速度与时序

目标主频为 `200MHz`，对应时钟周期 `5.00ns`。最近有效顶层 DC 结果显示 setup 收敛：

- Setup WNS/TNS：`0.00 / 0.00`
- Setup violating paths：`0`
- 主要剩余 DRC 风险：GEMM clock/reset fanout 与 result row buffer 周边 max-transition。

完整端到端实测性能：

| 模式 | Cycles | 200MHz 时间 | 说明 |
|---|---:|---:|---|
| causal | `91,011` | `455.055 us` | 跳过 future causal tiles，处理 `136/256` 个 KV tiles |
| non-causal | `161,091` | `805.455 us` | 处理全部 `256/256` 个 KV tiles |

### 1.3.3 功耗

________

### 1.3.4 安全性与鲁棒性

本赛题不涉及安全协议或加密安全。当前设计的鲁棒性处理包括：

- CSR 检查 Q/K/V/O base 与 stride 的 16-byte 对齐；配置错误会置位 `STATUS.error` 并抑制 start pulse。
- AXI read/write error pulse 会进入 core/top error sticky 状态。
- 支持 top-level `clear` 与 CSR `soft_reset`。
- 端到端测试覆盖背压、soft reset、descriptor 顺序和 byte counter。

### 1.3.5 验证与覆盖率目标

验证目标：

- 基本功能：CSR 配置、start/done/busy/error、IRQ、soft reset。
- 数据通路：Q/K/V load、QK、score post、row-state online softmax、P bypass、PV、OACC update、store。
- 数值正确性：与 Python golden model 对齐，`mean_err <= 0.03`、`max_err <= 0.10`。
- 性能正确性：完整运行 cycles `<300k`。
- Lint：顶层 SpyGlass `0 error`。

代码覆盖率目标：________

功能覆盖率目标：________

---

# 2 算法/协议与模式支持

## 2.1 算法/协议定义与 Golden 模型

### 2.1.1 算法/协议定义与处理流程

目标算法为：

```text
score_ij = Q_i · K_j / sqrt(d) + M_ij
P_ij     = exp(score_ij) / sum_t exp(score_it)
O_i      = sum_j P_ij * V_j
```

其中 `d=64`。在 causal 模式下，当 `j > i` 时 `M_ij` 为负大数，使未来 token 对当前行不可见；non-causal 模式下所有 KV 行可见。

硬件处理流程为：

1. 以 16 行为一个 Q block，共 16 个 Q block。
2. 对每个 Q block 初始化 row-state 与 OACC。
3. 扫描 16 个 KV block；causal 模式下跳过完整 future-masked KV tile。
4. 对有效 KV tile 执行 `QK -> scale/mask -> online softmax row update -> P bypass -> PV -> OACC update`。
5. 每个 Q block 完成后将 OACC 导出并写回 O 矩阵。

### 2.1.2 软件参考模型

Golden model 使用 Python 实现，主要位于：

- `sim/cocotb/tests/fa_baseline_env.py`
- `sim/cocotb/tests/fa_baseline_case_utils.py`
- `scripts/fa_precision_analysis.py`

参考模型使用浮点 attention 作为基准，并在精度分析中复现 RTL 的 Q8.8/Q16.16/Q4.12 量化路径，以拆分输入量化、row-state、PV 量化和 OACC 量化误差。

### 2.1.3 输入输出与数据范围分析

| 项目 | 当前约定 |
|---|---|
| Q/K/V/O 外部格式 | 每个 32-bit word 打包两个 16-bit lane |
| 外部矩阵规模 | `256 x 64` |
| 每行外部字节数 | `64 * 2 = 128 bytes` |
| CSR base/stride 对齐 | 16-byte aligned |
| 测试输入 | cocotb 中使用固定 seed 生成 Q8.8 随机矩阵 |
| 异常输入 | 未对 NaN/Inf 建模；当前定点格式不支持 IEEE 浮点异常 |

## 2.2 数值格式与关键算子设计

### 2.2.1 数据格式选择

| 数据 | 格式/位宽 | 说明 |
|---|---|---|
| Q/K/V 外部输入 | packed Q8.8, 16-bit lane | 每 32-bit word 两个 lane |
| QK/score 中间状态 | Q16.16 相关定点路径 | scale/mask/row-state 使用 |
| softmax probability tile | Q8.8 近似存储/传递 | `p_tile_flat` 为 16-bit lane 打包 |
| row-state `m/l/rescale` | Q16.16 | online softmax 状态与 OACC rescale |
| OACC 内部 | Q4.12, 16-bit | 面积优化后的内部累计存储 |
| O 外部输出 | packed Q8.8 | OACC 导出时舍入/饱和到 Q8.8 |

### 2.2.2 误差与溢出控制

误差来源包括：

- Q/K/V 输入 Q8.8 量化。
- QK scale 与 exp/reciprocal 定点近似。
- softmax probability Q8.8 量化。
- OACC Q4.12 内部存储量化。
- 输出 Q8.8 repack。

控制策略：

- 使用 Q16.16 保存 row-state 的 `m`、`l` 与 rescale。
- OACC 写回前执行 round-to-nearest 和 saturation。
- 对负大 mask 使用 CSR `NEG_LARGE` 配置。
- 精度分析脚本对误差分层统计，当前 sampled full-KV causal worst case 为 `mean=0.022474`、`max=0.042657`。

### 2.2.3 关键算子设计方案

| 算子 | 硬件实现 | 说明 |
|---|---|---|
| QK GEMM | shared 4x16 `GEMM_V3` | `num_acc=32`，覆盖 64 lane packed dot |
| score post | `FA_SCORE_POST_REAL` | scale 与 causal/non-causal mask |
| online softmax | `FA_ROW_STATE_REAL` | 维护每行 `m/l`，输出 probability tile 与 rescale vector |
| P bypass | `FA_P_BYPASS_REAL` | 将 row-state 输出切片供 PV 读取，替代 P SRAM |
| PV GEMM | shared 4x16 `GEMM_V3` | `num_acc=8`，按列块序列化 |
| OACC update | `FA_OACC_UPDATE_REAL` | `O_new = O_old * rescale + PV_partial` |

## 2.3 模式支持与扩展能力

### 2.3.1 性能优化

- causal 模式跳过完整 future-masked KV tile，减少无效 QK/PV/row-state/OACC 工作。
- Q tile 在 store 阶段预取，隐藏下一 Q block 的部分 load 延迟。
- QK/PV 通过共享 GEMM 降面积；通过调度保持外部行为不变。
- P buffer bypass 移除 P-load 子阶段。
- K/V load 与后续计算阶段存在 opportunistic overlap。

### 2.3.2 模式支持与可配置性

| 模式/参数 | 当前支持情况 |
|---|---|
| causal | 支持，CSR `CFG[0]` |
| non-causal | 支持，CSR `CFG[0]=0` |
| sequence length | 固定 `256` |
| head dimension | 固定 `64` |
| tile rows | 固定 `16` |
| 外部地址 | Q/K/V/O base 可配置，64-bit |
| stride | 可配置，需 16-byte 对齐 |

### 2.3.3 其他亮点

- 不显式存储完整 `SxS` attention matrix。
- 在面积目标下使用共享小 GEMM，以时间换面积。
- 使用 CSR counters 输出 cycles/read bytes/write bytes，便于性能归因。
- 端到端测试同时检查数值、协议和 byte counter。

---

# 3 数字模块硬件实现方案

## 3.1 总体架构与接口设计

### 3.1.1 总体实现架构

顶层模块为 `FA_TOP_BASELINE`，主要由三部分组成：

| 模块 | RTL | 作用 |
|---|---|---|
| CSR front end | `FA_CSR` / `csr_array` | AXI4-Lite 配置、状态、计数器、start/soft reset/IRQ |
| Core datapath | `FA_CORE_BASELINE` | 调度 Q/K/V load、QK、softmax、PV、OACC、store |
| DMA shell | `fa_dma_shell.v` | 将 core descriptor 转换为 128-bit AXI read/write transaction |

核心数据流：

```text
AXI read -> Q/K/V buffers -> QK -> score/mask -> online softmax
         -> P bypass -> PV -> OACC update -> OACC export -> AXI write
```

### 3.1.2 接口协议与总线功能

| 接口 | 协议 | 说明 |
|---|---|---|
| `s_axil_*` | AXI4-Lite slave | 软件配置和状态读取 |
| `m_axi_ar*` / `m_axi_r*` | AXI4 read master | 读取 Q/K/V tile |
| `m_axi_aw*` / `m_axi_w*` / `m_axi_b*` | AXI4 write master | 写回 O tile |
| `irq` | level/pulse style status output | 由 `irq_en` 与 done/error 状态产生 |
| `clk/rstn/clear` | 同步时钟/复位控制 | `rstn` 低有效，`clear` 为运行期清除 |

### 3.1.3 外部寄存器描述

| Offset | 名称 | 访问属性 | 说明 |
|---:|---|:---:|---|
| `0x00` | `CTRL` | R/W | bit0 `start`，bit1 `soft_reset`，bit2 `irq_en` |
| `0x04` | `STATUS` | R | bit0 `busy`，bit1 `done`，bit2 `error` |
| `0x08` | `CFG` | R/W | bit0 `causal_en` |
| `0x14` | `Q_BASE_L` | R/W | Q base address low 32 bits |
| `0x18` | `Q_BASE_H` | R/W | Q base address high 32 bits |
| `0x1c` | `K_BASE_L` | R/W | K base address low 32 bits |
| `0x20` | `K_BASE_H` | R/W | K base address high 32 bits |
| `0x24` | `V_BASE_L` | R/W | V base address low 32 bits |
| `0x28` | `V_BASE_H` | R/W | V base address high 32 bits |
| `0x2c` | `O_BASE_L` | R/W | O base address low 32 bits |
| `0x30` | `O_BASE_H` | R/W | O base address high 32 bits |
| `0x34` | `STRIDE_BYTES` | R/W | 行 stride，需 16-byte 对齐 |
| `0x38` | `NEG_LARGE` | R/W | causal mask 负大数 |
| `0x3c` | `SCALE` | R/W | QK scale，默认按 `1/sqrt(64)` 配置 |
| `0x40` | `CYCLES` | R | core run cycle counter |
| `0x44` | `RD_BYTES` | R | AXI read payload bytes |
| `0x48` | `WR_BYTES` | R | AXI write payload bytes |

## 3.2 关键模块实现与优化

### 3.2.1 关键架构与调度策略

`FA_TILE_SCHED` 负责按 Q block/KV block 发起各阶段请求。一个 Q block 的基本阶段为：

1. Q load
2. row-state init
3. OACC clear
4. 对每个 KV tile 执行 K/V load、QK、score post、row update、PV、OACC update
5. O store
6. 下一个 Q block

causal 模式下，如果整个 KV tile 都在当前 Q tile 的未来位置，则调度器跳过该 KV tile 的计算阶段。store 阶段可预取下一 Q tile。

### 3.2.2 关键计算单元实现

| 计算单元 | 模块 | 设计说明 |
|---|---|---|
| GEMM PE array | `GEMM_V3` / `GEMU_V3` | packed lane 乘加，当前共享阵列为 4x16 |
| Shared QK/PV wrapper | `FA_QK_PV_SHARED_CORE_REAL` | mode 选择 QK 或 PV 输入，复用同一 GEMM |
| Score post | `FA_SCORE_POST_REAL` | 对 QK 结果执行 scale 与 mask |
| Exp/reciprocal | `FA_ROW_STATE_REAL`、`FA_RECIP_Q16_16` | 支撑 online softmax |
| OACC update | `FA_OACC_UPDATE_REAL` | rescale old OACC 并加上 PV partial |

### 3.2.3 存储与数据搬运设计

| 存储/搬运单元 | 说明 |
|---|---|
| Q buffer | 保存当前 Q tile，供 QK 读取 |
| K buffer | 保存当前 K tile，供 QK 读取 |
| V/PV buffer | 保存 V tile，并按 PV 所需布局读出 |
| P bypass | 不落独立 P SRAM，直接从 row-state `p_tile_flat` 切出 PV 读取 slice |
| OACC buffer | 内部 16-bit Q4.12 存储，导出为 Q8.8 packed words |
| QK/PV result row buffers | 保存共享 GEMM 输出，供后级 row-state/OACC 读取 |
| Read DMA | 根据 Q/K/V descriptor 读取 128-bit AXI beats |
| Write DMA | 根据 O descriptor 写回 128-bit AXI beats |

### 3.2.4 控制通路与状态机

| 控制模块 | 作用 |
|---|---|
| `FA_RUN_CTRL` | 管理 busy/done/error/cycles，响应 start、soft reset 和 error pulse |
| `FA_TILE_SCHED` | 管理 tile-level 阶段顺序、causal skip、Q prefetch |
| DMA shell FSM | 管理 AXI descriptor、beat 接收/发送和 error pulse |
| CSR control | 生成 start pulse、soft reset pulse、config error |

回压策略：各阶段采用 valid/ready 或 done pulse 形式串接；AXI read/write 侧遵循 AXI ready/valid；测试覆盖 read/write backpressure。

### 3.2.5 接口信号列表

| 信号名 | 位宽 | 方向 | 说明 |
|---|---:|:---:|---|
| `clk` | 1 | I | core/CSR/AXI 时钟 |
| `rstn` | 1 | I | 低有效复位 |
| `clear` | 1 | I | 运行期清除 |
| `s_axil_awaddr` | 7 | I | AXI4-Lite write address |
| `s_axil_awvalid` | 1 | I | AXI4-Lite write address valid |
| `s_axil_awready` | 1 | O | AXI4-Lite write address ready |
| `s_axil_wdata` | 32 | I | AXI4-Lite write data |
| `s_axil_wstrb` | 4 | I | AXI4-Lite byte strobe |
| `s_axil_wvalid` | 1 | I | AXI4-Lite write data valid |
| `s_axil_wready` | 1 | O | AXI4-Lite write data ready |
| `s_axil_bresp` | 2 | O | AXI4-Lite write response |
| `s_axil_bvalid` | 1 | O | AXI4-Lite write response valid |
| `s_axil_bready` | 1 | I | AXI4-Lite write response ready |
| `s_axil_araddr` | 7 | I | AXI4-Lite read address |
| `s_axil_arvalid` | 1 | I | AXI4-Lite read address valid |
| `s_axil_arready` | 1 | O | AXI4-Lite read address ready |
| `s_axil_rdata` | 32 | O | AXI4-Lite read data |
| `s_axil_rresp` | 2 | O | AXI4-Lite read response |
| `s_axil_rvalid` | 1 | O | AXI4-Lite read data valid |
| `s_axil_rready` | 1 | I | AXI4-Lite read data ready |
| `m_axi_araddr` | 64 | O | AXI read address |
| `m_axi_arlen` | 8 | O | AXI read burst length |
| `m_axi_arsize` | 3 | O | AXI read beat size |
| `m_axi_arburst` | 2 | O | AXI read burst type |
| `m_axi_arvalid` | 1 | O | AXI read address valid |
| `m_axi_arready` | 1 | I | AXI read address ready |
| `m_axi_rdata` | 128 | I | AXI read data |
| `m_axi_rresp` | 2 | I | AXI read response |
| `m_axi_rlast` | 1 | I | AXI read last beat |
| `m_axi_rvalid` | 1 | I | AXI read data valid |
| `m_axi_rready` | 1 | O | AXI read data ready |
| `m_axi_awaddr` | 64 | O | AXI write address |
| `m_axi_awlen` | 8 | O | AXI write burst length |
| `m_axi_awsize` | 3 | O | AXI write beat size |
| `m_axi_awburst` | 2 | O | AXI write burst type |
| `m_axi_awvalid` | 1 | O | AXI write address valid |
| `m_axi_awready` | 1 | I | AXI write address ready |
| `m_axi_wdata` | 128 | O | AXI write data |
| `m_axi_wstrb` | 16 | O | AXI write byte strobe |
| `m_axi_wlast` | 1 | O | AXI write last beat |
| `m_axi_wvalid` | 1 | O | AXI write data valid |
| `m_axi_wready` | 1 | I | AXI write data ready |
| `m_axi_bresp` | 2 | I | AXI write response |
| `m_axi_bvalid` | 1 | I | AXI write response valid |
| `m_axi_bready` | 1 | O | AXI write response ready |
| `irq` | 1 | O | interrupt/status output |

## 3.3 其他子模块设计

### 3.3.1 配置与控制模块

`FA_CSR` 封装 `csr_array`，提供寄存器读写、start/soft reset 边沿检测、配置错误检查和 IRQ enable。`start_pulse` 仅在 `CTRL.start` 上升沿且配置合法时产生。

### 3.3.2 数据路径模块

数据路径由 tile buffer、共享 GEMM、score post、row-state、P bypass、OACC update、OACC buffer 和 DMA shell 组成。核心路径按 tile 串行推进，在行内/列内使用 packed lane 并行。

### 3.3.3 辅助模块

辅助模块包括：

- cycle/read bytes/write bytes 计数器。
- row-state profile simulation wrapper。
- synthesis/simulation 分离的 top wrapper。
- 调试 flat signal，仅在仿真或非综合路径使用。

---

# 4 验证方案与正确性结果

## 4.1 验证目标与通过准则

| 项目 | 通过准则 |
|---|---|
| RTL 编译 | `python3 -m py_compile`、iverilog/Verilator 构建通过 |
| 端到端功能 | causal 与 non-causal full cases golden compare 通过 |
| 数值精度 | `mean_err <= 0.03`，`max_err <= 0.10` |
| 性能 | 完整运算 cycles `<300k` |
| 协议 | CSR、descriptor count、byte counter、backpressure 测试通过 |
| Lint | 顶层 SpyGlass `0 error` |

## 4.2 验证环境

### 4.2.1 验证工具与脚本

| 工具/脚本 | 用途 |
|---|---|
| cocotb + Verilator | RTL 动态仿真 |
| Python golden model | attention 数值参考 |
| `sim/cocotb/run.py` | 回归入口 |
| `scripts/fa_precision_analysis.py` | 精度分层分析 |
| `scripts/fa_baseline_profile.py` | 性能 profile |
| iverilog | RTL 编译 sanity |
| SpyGlass | lint |
| Synopsys DC | 逻辑综合、面积和时序 |

### 4.2.2 验证平台架构

cocotb testbench 包含：

- AXI4-Lite driver：配置 CSR、轮询状态、读取 counter。
- AXI memory model：保存 Q/K/V/O 数据，响应 read/write master transaction。
- Descriptor monitor：记录 Q/K/V/O descriptor 顺序、数量和字节数。
- Scoreboard：将 RTL 输出 O 与 Python golden result 比较。
- Backpressure generator：对 AXI read/write channel 注入 ready/valid stall。

### 4.2.3 测试集设计

| 测试类型 | 覆盖内容 |
|---|---|
| smoke tests | reset、start、done、基本读写 |
| CSR tests | register map、alignment error、soft reset、IRQ |
| numeric directed tests | single Q/single KV、single Q/full KV、causal/non-causal |
| full end-to-end tests | full causal、full non-causal、soft reset |
| AXI tests | descriptor order、byte counters、backpressure |
| module tests | row-state、OACC update、P bypass、shared GEMM |
| performance tests | stage profile、cycles counter、GOPS measurement |

## 4.3 正确性验证结果

### 4.3.1 基本功能验证

已通过的关键本地检查：

```bash
python3 -m py_compile sim/cocotb/tests/test_fa_baseline.py scripts/fa_precision_analysis.py scripts/fa_baseline_profile.py
iverilog -g2012 -I rtl -s FA_TOP_BASELINE_SIM -o /tmp/fa_top_baseline_sim_check.out rtl/*.v
iverilog -g2012 -DSYNTHESIS -I rtl -s FA_TOP_BASELINE -o /tmp/fa_top_baseline_synth_check.out rtl/*.v
```

关键端到端回归：

```bash
python3 sim/cocotb/run.py fa_full --testcase test_fa_baseline_full_causal_end_to_end,test_fa_baseline_full_noncausal_and_soft_reset --rebuild
python3 sim/cocotb/run.py fa_baseline --testcase test_fa_numeric_single_q_single_kv_noncausal,test_fa_numeric_single_q_full_kv_causal --rebuild
```

### 4.3.2 边界与异常场景验证

已覆盖：

- causal future tile skip 后的 descriptor 数量。
- AXI read/write backpressure。
- CSR soft reset 后再次运行。
- 配置未对齐导致 `STATUS.error`。
- OACC rescale 为 0/1 的 directed cases。

未覆盖/待补充：________

### 4.3.3 随机回归验证

cocotb 测试使用固定 seed 的随机 Q/K/V 矩阵，覆盖多组 amplitude 与 causal/non-causal 配置。随机种子数量、覆盖率统计：________

## 4.4 接口验证结果

### 4.4.1 配置接口

CSR register map、start pulse、soft reset、IRQ enable、alignment config error 已通过 cocotb directed tests。

### 4.4.2 数据接口

AXI read/write descriptor order、payload byte counters、backpressure 和 full end-to-end memory model 已通过 cocotb tests。当前实测完整运算 byte counters：

| 模式 | Read bytes / desc | Write bytes / desc |
|---|---:|---:|
| causal | `589,824 / 288` | `32,768 / 16` |
| non-causal | `1,081,344 / 528` | `32,768 / 16` |

## 4.5 覆盖率与问题闭环

### 4.5.1 代码覆盖率

________

### 4.5.2 功能覆盖率

________

### 4.5.3 问题分析与修复记录

| 问题 | 修复方式 | 回归结果 |
|---|---|---|
| OACC 面积过大 | 内部存储压缩到 Q4.12 | 精度采样满足 `mean<=0.03`、`max<=0.10` |
| P buffer 面积与 P-load 延迟 | 用 `FA_P_BYPASS_REAL` 旁路 row-state 输出 | P bypass directed test 与 full tests 通过 |
| QK/PV 双 GEMM 面积过大 | 共享同一 `GEMM_V3` | shared GEMM tests 与 full tests 通过 |
| GEMM 仍为面积热点 | 缩小为 4x16 并串行化 | DC 面积降至约 `1.854M` NAND2 |
| causal 无效 tile 浪费 cycles | 调度器跳过完整 future causal tile | causal full-run 实测 `91,011` cycles |
| store 后 Q load 暴露延迟 | store 阶段预取下一 Q tile | full regression 通过 |

---

# 5 PPA 结果与指标达成

## 5.1 工具与环境配置

| 项目 | 配置 |
|---|---|
| 远端主机 | `ic-canopsys` |
| 远端工作区 | `~/Desktop/flash_atten` |
| SpyGlass top | `FA_TOP_BASELINE` |
| SpyGlass project | `synopsys/spyglass/flow/fa_top_baseline_lint.prj` |
| DC top | `FA_TOP_BASELINE` |
| DC flow | `synopsys/dc/flow/fa_top_baseline_compile_current_8core_20260428_113000_gemm4x16_synrtl_8core_clean.tcl` |
| 目标频率 | `200MHz` / `5.00ns` |
| NAND2 reference area | `0.294` |

## 5.2 面积结果

最近有效顶层 DC 结果：

| 模块 | 面积/门数 | 备注 |
|---|---:|---|
| `FA_TOP_BASELINE` | `545,044.935124` cell area | 约 `1,853,894` NAND2 |
| `u_core/u_qk_pv_core` | `200,404.6102` cell area | 最大子层级，约 36.8% top |
| `u_core/u_qk_pv_core/u_gemm` | `126,954.0018` cell area | 4x16 shared GEMM |
| `u_core/u_oacc_update` | `64,340.5280` cell area | OACC rescale/add |
| `u_core/u_row_state` | `47,347.6220` cell area | online softmax |
| `u_core/u_oacc_buf` | `46,295.0042` cell area | Q4.12 OACC buffer |
| `u_core/u_v_buf_pv` | `44,006.2142` cell area | V/PV buffer |
| `u_core/u_k_buf` | `43,857.6462` cell area | K tile buffer |
| `u_core/u_q_buf` | `43,855.7842` cell area | Q tile buffer |
| `u_core/u_score_post` | `43,240.4420` cell area | scale/mask datapath |

## 5.3 时序结果

| 模式 | 目标频率 | 实际频率/Fmax | Slack | 备注 |
|---|---:|---:|---:|---|
| DC setup | `200MHz` | ________ | `0.00ns` WNS | setup closed，TNS `0.00` |
| DC hold | `200MHz` | ________ | `0.00ns` summary | 仍有 near-zero hold paths 记录 |
| DRC | `200MHz` | ________ | ________ | `60` max-transition violations，主要为高 fanout GEMM clock net |

## 5.4 功耗结果

| 项目 | 数值 | 备注 |
|---|---:|---|
| 静态功耗 | ________ | ________ |
| 动态功耗 | ________ | ________ |
| 总功耗 | ________ | ________ |

## 5.5 指标达成与 PPA 权衡分析

### 指标达成

| 指标 | 目标 | 当前结果 | 状态 |
|---|---:|---:|---|
| causal 完整 cycles | `<300k` | `91,011` | 达成 |
| non-causal 完整 cycles | `<300k` | `161,091` | 达成 |
| 面积 | `<2M` NAND2 | `1,853,894` NAND2 | 达成 |
| setup timing | `200MHz` | WNS/TNS `0.00/0.00` | 达成 |
| 精度 mean error | `<=0.03` | worst sampled `0.022474` | 达成 |
| 精度 max error | `<=0.10` | worst sampled `0.042657` | 达成 |
| SpyGlass | `0 error` | `0 error / 93 warnings / 3 infos` | 达成，有 warnings |

### 吞吐率

200MHz 下实测 GOPS：

| 模式 | Count basis | Counted ops | Ops/cycle | GOPS @200MHz |
|---|---|---:|---:|---:|
| causal | math-effective triangular ops | `8,421,376` | `92.531` | `18.506` |
| causal | RTL executed tile ops | `8,912,896` | `97.932` | `19.586` |
| causal | dense-equivalent ops | `16,777,216` | `184.343` | `36.869` |
| non-causal | math-effective / RTL / dense ops | `16,777,216` | `104.147` | `20.829` |

### PPA 权衡

当前设计主要选择是以适量增加串行计算换取面积下降：

- 共享 4x16 GEMM 显著降低面积，是满足 `<2M` NAND2 的关键，但降低了峰值并行度。
- causal future tile skip 和 Q prefetch 抵消部分串行化性能损失，使完整运行 cycles 仍远低于 `300k`。
- OACC Q4.12 和 P bypass 主要降低存储面积；代价是更严格的数值验证和 PV 输入路径时序关注。
- 主要剩余风险集中在 GEMM clock/reset fanout、result row buffer 周边 DRC、near-zero hold paths，以及尚未完成的功耗评估。

---
