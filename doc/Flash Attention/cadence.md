# Cadence 赛题 PDF 整理

来源：`/Users/yucheng/Downloads/cadence.pdf`

说明：该 PDF 无可提取文本层，本文根据页面渲染内容整理为 Markdown。原 PDF 页面显示为管理平台页码 `4/7` 至 `7/7`。

---

## 页首可见方案提示

- 方案B（实用为主）：深度流水线优化 + DMA 与批量加速
- 方案C（全面）：侧信道防护 + 组合操作优化 + 深度流水线优化

---

## 工具支持

Cadence 为本次比赛提供专属云服务器，服务器已预装赛事所需的 Cadence EDA 工具及对应工艺库。本次服务器资源充足，可保证一队一个独立账号。

如需申请使用云服务器，请下载附件表格填写完整后提交，表格下载链接：

```text
https://cpipc.acge.org.cn/sysFile/downFile.do?fileId=40168f675ca64849be72024c9fb94256
```

---

# 赛题二：基于大模型推理的 FlashAttention 高性能硬件加速器 IP 设计

## 一、赛题背景

Transformer 架构已广泛应用于大模型（LLM / VLM）与多模态系统。在典型 Transformer 模型中，计算开销最为显著，同时最为敏感的关键算子之一为 Scaled Dot-Product Attention（SDPA）：

```text
O = softmax(QK^T / sqrt(d) + M) V
```

其中：

- `Q / K / V` 为 Query / Key / Value；
- `D` 为每个 attention head 的维度；
- `M` 为 mask，例如 causal mask。

在朴素实现中，通常会构造 `QK^T`（大小约为 `S x S`）及其 softmax 概率矩阵，从而引入如下问题：

- 带宽瓶颈：大量中间张量的读写使得性能受限于外存 / 显存带宽。
- 存储压力：长序列下（约 `S x S`）中间矩阵难以在片上存储。
- 端侧落地困难：在功耗与 SRAM 受限的 SoC / 加速器上难以高效实现。

FlashAttention 系列工作提出了在线（online）softmax + 分块（tiling）+ 融合数据流的实现范式：在不显式存储约 `S x S` 注意力矩阵的前提下，完成与 SDPA 等价（或在可控近似误差范围内等价）的计算，从而显著降低带宽压力与中间存储开销。

本赛题要求参赛者使用 Cadence EDA 工具链，设计并实现一个可综合的 FlashAttention-style 注意力算子硬件 IP。参赛者需在指定张量规模与接口规范下完成端到端注意力计算，并在正确性、性能（cycles / Fmax）、面积与带宽等维度进行综合评比。

---

# 二、赛题要求

参赛团队需要实现一个可综合 RTL IP，支持在指定输入规模下完成 SDPA / FlashAttention-style attention。

## 2.1 基本功能要求（必选）

### 2.1.1 算法定义（SDPA 计算目标）

设序列长度为 `S`，head 维度为 `d`，输出维度同 `V`。对每个 query 位置 `i`：

```text
score_ij = Q_i · K_j / sqrt(d) + M_ij
P_ij     = exp(score_ij) / sum_{t=0}^{S-1} exp(score_it)
O_i      = sum_{j=0}^{S-1} P_ij V_j
```

### 2.1.2 FlashAttention-style 计算约束

必须体现 FlashAttention-style 的关键思想，并据此验收：

- 禁止显式存储注意力矩阵。
- 必须使用在线（online）softmax。
- 必须分块（tiling）处理 K/V。

### 2.1.3 固定输入规模

为便于统一测试与比较，Baseline 固定如下规模（单 batch、单 head）：

- 序列长度：`S = 256`
- head 维度：`d = 64`
- Q/K/V/O 形状：`[S, d]`
- `batch = 1`
- `head = 1`

### 2.1.4 数据格式（定点）

Baseline 统一采用定点格式，便于可综合、低面积 / 低功耗实现：

- 输入 `Q / K / V`：`Q8.8`（16-bit 有符号定点）
- 累加 / 中间：
  - Dot-product 累加：至少 32-bit（建议 40-bit 以上以降低溢出风险）
  - softmax 路径：允许使用更高位宽或分段缩放
- 输出 `O`：`Q8.8`（16-bit 有符号定点）

### 2.1.5 接口要求

Baseline 统一采用“主机配置 + 加速器 DMA 搬运数据”的模式：

- AXI4-Lite（控制）：
  - 主机写寄存器（基地址 / 参数）
  - 通过 `CTRL.START` 启动
  - 读取 `STATUS` 查询完成
- AXI4 Master + DMA（数据）：
  - 加速器启动后用 DMA 从内存读入 `Q / K / V`
  - 计算完成后把 `O` 写回内存

### 2.1.6 寄存器

Baseline 固定 `S = 256`、`d = 64`。下表仅列出必需寄存器，其余可自行扩展。

| Offset | 名称 | 访问 | 说明 |
|---:|---|:---:|---|
| `0x00` | `CTRL` | R/W | bit0: `START`（写 1 启动）；bit1: `SOFT_RESET`；bit2: `IRQ_EN` |
| `0x04` | `STATUS` | R | bit0: `BUSY`；bit1: `DONE`（写 1 清）；bit2: `ERROR` |
| `0x08` | `CFG` | R/W | bit0: `CAUSAL_EN`（Baseline 必须支持）；bit1: `RESERVED` |
| `0x14` | `Q_BASE_L` | R/W | Q 基地址（低 32） |
| `0x18` | `Q_BASE_H` | R/W | Q 基地址（高 32） |
| `0x1c` | `K_BASE_L` | R/W | K 基地址（低 32） |
| `0x20` | `K_BASE_H` | R/W | K 基地址（高 32） |
| `0x24` | `V_BASE_L` | R/W | V 基地址（低 32） |
| `0x28` | `V_BASE_H` | R/W | V 基地址（高 32） |
| `0x2c` | `O_BASE_L` | R/W | O 基地址（低 32） |
| `0x30` | `O_BASE_H` | R/W | O 基地址（高 32） |
| `0x34` | `STRIDE_BYTES` | R/W | 行 stride（bytes），默认 `d * 2` |
| `0x38` | `NEG_LARGE` | R/W | `-inf` 近似值（Q8.8） |
| `0x3c` | `SCALE` | R/W | `1 / sqrt(d)` 缩放常数 |
| `0x40` | `CYCLES` | R | 本次执行周期数 |

### 2.1.7 存储与资源约束

为体现 FlashAttention-style 的“低中间存储”特性，Baseline 强制约束：

- 禁止存储 score / P 全矩阵。
- 片上中间 buffer 限额（不含输入 / 输出缓存）：
  - 允许缓存一小块 `K / V` tile。
  - 允许每行维护 `m / l / acc` 以及必要流水寄存器。

说明：若参赛者选择把全量 `K / V` 缓存在片上 SRAM 以减少外存带宽，需要在报告中量化带宽收益与 SRAM 代价。

### 2.1.8 正确性验收

- 单向量对齐（必测）：
  - 随机种子生成的 `Q / K / V`（Q8.8）与 golden 输出。
- 误差门限：
  - 与 FP32 golden（同一公式、同一 mask）对比：

```text
mean_abs_error(O) <= 0.03
max_abs_error(O)  <= 0.10
```

若采用不同 exp / 倒数近似，需在文档中说明误差来源。

备注：Baseline 使用定点与近似运算，不要求 bit-exact，以误差门限作为验收标准。

### 2.1.9 测试验证

可采用 SystemVerilog + UVM 或 Python + cocotb。

必须包含：

- AXI4-Lite 寄存器读写与启动 / 完成流程。
- 随机 `Q / K / V` 的端到端验证。
- Causal mask corner case 验证，例如 `i = 0` 行只能看 `j = 0`。

## 2.2 性能要求（必选 Baseline）

### 2.2.1 主频目标

频率越高越好。基于 Cadence Genus 物理综合报告；鼓励进一步 P&R 收敛。

### 2.2.2 面积约束

等效逻辑门数 `<= 200` 万门。

说明：

- 含存储器折算。
- 统一使用 Genus 报告的等效逻辑门数。
- 2-input NAND 等效口径。

### 2.2.3 延迟指标

单次 attention：

```text
S = 256, d = 64, causal
```

执行周期数：

```text
cycles < 300k
```

### 2.2.4 带宽目标

给出 `RD_BYTES / WR_BYTES` 统计与优化分析，例如 tile 缓存、复用等。

## 2.3 可选要求（Bonus 加分项）

### 重要说明

1. 所有 Bonus 必须在 Baseline 通过后开展。
2. 必须基于 Baseline 重新新建独立项目 / 独立版本，例如新建目录或新工程，单独开发、单独验证、单独提交。
3. 不得修改或影响 Baseline 版本的代码与评估结果；Baseline 仍按原要求独立评测。
4. 所有可选项可以在同一个 Bonus 项目中集中实现；该 Bonus 项目必须基于 Baseline 另行开发，并作为独立版本单独评估，包括重新综合 / 重新统计指标。

### Bonus 列表

| Item | 加分项 | 主要内容 |
|---:|---|---|
| 1 | BF16/FP16 版本 | 在相同尺寸下实现 BF16 或 FP16 attention（softmax / exp / 倒数硬件化），并给出误差与性能对比 |
| 2 | 多 head 支持 | 支持 `head = 4 / 8`，接口增加 head 维度与地址 / stride 管理 |
| 3 | 更长序列 | 支持 `S = 512`（或可配置 `S`），并保持不存储约 `S x S` 中间矩阵 |
| 4 | Padding mask | 支持输入有效长度 `L <= S` 的 padding mask，对无效 token 置 `-inf` |
| 5 | 其他定点格式 | 在 Baseline 的 Q8.8 之外，额外支持等价定点格式，如 Q6.10 / Q4.12，并给出误差与性能对比 |
| 6 | Dropout（训练模式） | 在 softmax 后加入 dropout，需明确随机数产生方式与可复现种子 |
| 7 | 更低精度（INT8/FP8 思路） | 参考 FlashAttention-3 的低精度策略，实现块量化 / 分块缩放并给出误差收益 |
| 8 | AXI4-Stream 数据接口 | 在 Baseline（AXI4 Master + DMA）之外，额外提供 AXI4-Stream 输入 / 输出接口，便于与其他 IP 级联 |
| 9 | DMA / 任务队列 | 支持多次 attention 连续执行（队列 / 链式配置），减少主机交互 |

---

# 三、工具支持

Cadence 为本次比赛提供专属云服务器，服务器已预装赛事所需的 Cadence EDA 工具及对应工艺库。本次服务器资源充足，可保证一队一个独立账号。

如需申请使用云服务器，请下载附件表格填写完整后提交，表格下载链接：

```text
https://cpipc.acge.org.cn/sysFile/downFile.do?fileId=40168f675ca64849be72024c9fb94256
```

---

# 四、提交要求

参赛队伍需提交主要材料。

## 4.1 代码与设计文件

### 4.1.1 完整的 RTL 代码

- 完整 RTL 代码（Verilog / SystemVerilog）
- PQC 加速器源代码（ML-DSA + ML-KEM）
- Cadence 工具脚本和约束文件（SDC 格式）

注：PDF 原文在此处出现 “PQC 加速器源代码（ML-DSA + ML-KEM）”，与本 FlashAttention 赛题不完全一致，可能是提交模板残留项。

## 4.2 验证代码

- UVM / cocotb 验证环境
- 测试用例和测试向量
- 仿真脚本

## 4.3 Cadence 工具生成的报告

- 仿真报告和波形文件
- 物理综合报告（面积、时序、功耗）

报名后会提供提交内容参考模板。
