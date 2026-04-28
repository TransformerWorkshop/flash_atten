# Flash Attention Bonus 方案成本收益分析

本文基于 `cadence.pdf` 中 2.3 可选要求整理，目标是给出 Flash Attention bonus 项目的可实施路线、成本、收益、风险和验证口径。Bonus 项目不应修改 baseline 版本；所有 bonus 需要在 baseline 通过后，从 baseline 新建独立版本或独立工程，单独开发、验证、综合并提交。

## 1. 基线与假设

当前 baseline：

- Top：`FA_TOP_BASELINE`
- Shape：`S=256`、`d=64`、`batch=1`、`head=1`
- 数据格式：Q/K/V/O 为 Q8.8，内部包含 Q16.16 row-state 与 Q4.12 OACC
- 接口：AXI4-Lite CSR + AXI4 Master DMA
- 关键结构：online softmax、K/V tiling、P bypass、shared 4x16 GEMM
- 实测完整 cycles：
  - causal：`91,011`
  - non-causal：`161,091`
- 最近有效 DC 面积：约 `1.854M` NAND2 equivalent

Bonus 假设：

- Bonus 不受 baseline 的 `<2M` NAND2 面积限制，但仍应报告面积、时序、功耗或至少面积/时序趋势。
- Bonus 项目可以为了功能或性能增加硬件，例如多 GEMM、并行 head、更多 buffer、stream wrapper、task queue。
- Baseline 评估结果必须保持独立；bonus 不应改变 baseline 的 RTL、测试和报告口径。
- 所有 bonus 都需要重新跑功能回归、精度统计、cycles/GOPS 统计，以及独立综合/时序报告。

## 2. 评分项列表

| Item | Bonus | PDF 要求摘要 |
|---:|---|---|
| 1 | BF16/FP16 版本 | 相同尺寸下实现 BF16 或 FP16 attention，硬件化 softmax/exp/倒数，并给出误差与性能对比 |
| 2 | 多 head 支持 | 支持 `head=4/8`，接口增加 head 维度与地址/stride 管理 |
| 3 | 更长序列 | 支持 `S=512` 或可配置 `S`，并保持不存储约 `SxS` 中间矩阵 |
| 4 | Padding mask | 支持输入有效长度 `L<=S`，对无效 token 置 `-inf` |
| 5 | 其他定点格式 | 在 baseline Q8.8 外支持等价定点格式，如 Q6.10/Q4.12，并给出误差与性能对比 |
| 6 | Dropout 训练模式 | 在 softmax 后加入 dropout，明确随机数生成方式与可复现 seed |
| 7 | 更低精度 | 参考 FlashAttention-3 的 INT8/FP8 思路，实现块量化/分块缩放并给出误差收益 |
| 8 | AXI4-Stream 数据接口 | 在 baseline AXI4 Master+DMA 外额外提供 AXI4-Stream 输入/输出接口，便于与其他 IP 级联 |
| 9 | DMA/任务队列 | 支持多次 attention 连续执行，队列/链式配置，减少主机交互 |

## 3. 成本与收益口径

成本按 5 个维度估算：

- RTL：新增或重构 RTL 的复杂度。
- 验证：golden model、directed tests、random regression、corner cases。
- PPA：面积、时序、功耗、DRC 的额外压力。
- 集成：CSR/AXI/软件驱动/文档变化。
- 风险：数值、协议、调度或测试闭环的不确定性。

等级定义：

| 等级 | 解释 |
|---|---|
| 低 | 局部 RTL 改动，1-3 天可完成 first-pass，回归范围可控 |
| 中 | 需要新增模块或接口，3-7 天 first-pass，需要成体系回归 |
| 高 | 涉及核心调度或数值路径，1-2 周以上，需大量 directed/random 测试 |
| 很高 | 接近新架构或新数值系统，开发和验证均为独立项目级别 |

收益按 4 个维度估算：

- 功能覆盖：是否直接命中 PDF bonus 项。
- 展示价值：是否能体现 Flash Attention 硬件设计能力。
- 性能/系统价值：是否提升吞吐、降低主机交互或扩展可用场景。
- 文档价值：是否容易量化指标并形成对比报告。

## 4. 总览优先级

| 推荐顺序 | Bonus | 成本 | 收益 | 风险 | 推荐结论 |
|---:|---|---|---|---|---|
| 1 | Padding mask | 低-中 | 中-高 | 低 | 最适合先做，和 causal mask 同类，容易验证 |
| 2 | 多 head 支持 | 中 | 高 | 中 | 加分明确，可先做串行 head，后做并行 head |
| 3 | 更长序列 `S=512` | 中-高 | 高 | 中-高 | 体现 Flash Attention 价值，但调度/地址/counter 改动多 |
| 4 | DMA/任务队列 | 中 | 中-高 | 中 | 系统工程感强，不碰核心数值路径 |
| 5 | AXI4-Stream 接口 | 中 | 中 | 中 | 适合 wrapper 化实现，便于和其他 IP 级联 |
| 6 | 其他定点格式 | 低-中 | 中 | 中 | 成本低，适合作为量化对比文档项 |
| 7 | BF16/FP16 | 高 | 高 | 高 | 含金量高，但数值单元和时序压力大 |
| 8 | INT8/FP8 | 高-很高 | 高 | 很高 | 研究性强，需量化策略和误差证明 |
| 9 | Dropout | 中-高 | 低-中 | 中 | 偏训练模式，当前推理型 FA 优先级最低 |

如果只做 2-3 个 bonus，建议选择：

1. Padding mask
2. 多 head 支持
3. 更长序列 `S=512`

如果希望系统展示更完整，可以再加：

4. DMA/任务队列
5. AXI4-Stream 接口

如果希望强调数值/算法探索，再加：

6. 其他定点格式
7. BF16/FP16 或 INT8/FP8

## 5. Bonus 1：BF16/FP16 版本

### 5.1 目标

在 `S=256, d=64` 相同尺寸下，实现 BF16 或 FP16 attention，至少完成 QK、scale/mask、softmax、PV 和 O 输出，并与 baseline Q8.8 做误差、cycles、GOPS、面积和时序对比。

### 5.2 推荐实现路线

建议优先 BF16，而不是 FP16：

- BF16 指数位与 FP32 相同，动态范围更大，softmax 溢出风险较低。
- BF16 mantissa 短，乘法器比 FP16 精度低但实现相对直接。
- FP16 需要更注意 exp、reciprocal、subnormal、overflow/underflow 策略。

实现路线：

1. 新建 `FA_TOP_BF16_BONUS` 或 `FA_TOP_FP16_BONUS`，不要替换 baseline top。
2. 外部 Q/K/V/O 数据格式改为 BF16 或 FP16 packed words。
3. GEMM 侧新增 BF16/FP16 multiply + accumulate。
4. Row-state 保留高精度内部格式，建议 softmax 内部用 FP32-like 或 Q-format 高位定点。
5. exp/reciprocal 可采用 LUT + piecewise approximation 或调用自研近似模块。
6. 输出转换回 BF16/FP16。

### 5.3 RTL 改动

| 区域 | 改动 |
|---|---|
| buffer | 数据 lane 从 Q8.8 解释改为 BF16/FP16 |
| GEMM | 新增浮点乘法、累加、规范化/舍入 |
| score post | scale/mask 支持浮点或统一转高精度定点 |
| row-state | exp/reciprocal 需要重新定标或浮点化 |
| OACC | 可改为 FP32-like accumulator，最后输出 BF16/FP16 |
| CSR | 增加 `DATA_FORMAT` 或 bonus top 固定格式 |

### 5.4 验证计划

- Python golden 使用 FP32 attention。
- 增加 BF16/FP16 quantization golden。
- 覆盖 causal/non-causal、极小/极大输入、全相等 score、单 hot score。
- 报告：
  - mean/max error vs FP32
  - cycles
  - GOPS
  - area/timing
  - 与 Q8.8 baseline 的误差和性能对比

### 5.5 成本收益

| 项目 | 评价 |
|---|---|
| RTL 成本 | 高 |
| 验证成本 | 高 |
| 面积/时序成本 | 高，浮点乘加、exp、reciprocal 会显著增大面积 |
| 收益 | 高，数值格式 bonus 含金量高，文档可展示充分对比 |
| 主要风险 | softmax 数值稳定性、浮点舍入、Fmax、综合面积 |

### 5.6 建议

只在已有 baseline 和低成本 bonus 完成后推进。若时间有限，做 BF16 单格式即可，不建议 BF16/FP16 同时做。

## 6. Bonus 2：多 head 支持

### 6.1 目标

支持 `head=4/8`，接口增加 head 维度、head stride、base 地址管理。输出应覆盖所有 head 的 O 矩阵。

### 6.2 实现路线

分两级实现：

| 级别 | 实现 | 成本 | 性能 |
|---|---|---|---|
| 串行 multi-head | 单个 FA core 循环处理每个 head | 中 | 总 cycles 约随 head 数线性增加 |
| 并行 multi-head | 复制多个 FA core 或多个 GEMM/row-state 组 | 高 | 吞吐提升，面积大幅增加 |

Bonus 不受 baseline 面积限制，因此最终可展示两个版本：

- `head=4 serial`：低风险功能版。
- `head=4 parallel` 或 `2-core interleaved`：性能展示版。

### 6.3 RTL/接口改动

CSR 扩展：

| 寄存器 | 说明 |
|---|---|
| `NUM_HEADS` | 支持 `1/4/8` |
| `HEAD_STRIDE_BYTES` | 相邻 head 的 Q/K/V/O 地址跨度 |
| `BATCH_STRIDE_BYTES` | 可预留，当前 batch=1 |
| `CURRENT_HEAD` | debug/status |

地址生成：

```text
q_head_base = q_base + head_idx * head_stride_bytes
k_head_base = k_base + head_idx * head_stride_bytes
v_head_base = v_base + head_idx * head_stride_bytes
o_head_base = o_base + head_idx * head_stride_bytes
```

调度：

- 在原 Q block loop 外增加 head loop。
- 每个 head 完成后清 row-state/OACC/counters 或累加 head-level counters。
- `done` 在全部 head 完成后置位。

### 6.4 验证计划

- `head=1` 与 baseline 结果一致。
- `head=4` 每个 head 使用不同 seed，逐 head golden compare。
- `head=8` descriptor count、byte counters、cycles 统计。
- 验证 head stride 非连续布局。
- backpressure + multi-head full run。

### 6.5 成本收益

| 项目 | 评价 |
|---|---|
| RTL 成本 | 中，串行版主要改调度和地址 |
| 验证成本 | 中，需要多 head memory layout golden |
| 面积/时序成本 | 串行低，并行高 |
| 收益 | 高，直接扩展到真实 Transformer head 维度 |
| 主要风险 | 地址/stride 错误、counter 口径、soft reset 中断 head loop |

### 6.6 建议

第一版做串行 multi-head，确保功能和文档稳定；如果时间允许，再做双 core 或四 core 并行版本作为性能加分。

## 7. Bonus 3：更长序列

### 7.1 目标

支持 `S=512` 或可配置 `S`，并保持不存储约 `SxS` score/P 中间矩阵。

### 7.2 设计选择

| 方案 | 说明 | 成本 | 推荐度 |
|---|---|---|---|
| 固定 `S=512` bonus top | 新建 top，参数固定为 512 | 中 | 高 |
| `S=256/512` CSR 可配置 | 增加 `SEQ_LEN` CSR，调度循环动态结束 | 中-高 | 高 |
| 任意 `S<=512` | 需要处理尾 tile、padding mask、非 16 对齐 | 高 | 中 |

推荐先做 `S=256/512` 双模式，tile 仍固定 16 行。

### 7.3 RTL 改动

- `SEQ_LEN` 从常量变为 `seq_blocks = seq_len / 16`。
- Q block loop 和 KV block loop 从 16 扩展到 32。
- causal skip 判断从固定 4-bit block index 扩展到 5-bit。
- 地址生成支持更大 offset。
- counters 扩展，避免 cycles/bytes 溢出。
- score/row-state/OACC tile 大小不变，仍按 16 行处理。

### 7.4 性能估算

如果保持相同 datapath，non-causal 工作量约随 `S^2` 增长：

```text
S=512 / S=256 => 4x tile 数
```

causal 有效 tile 数：

```text
S=256: 16*17/2 = 136 tiles
S=512: 32*33/2 = 528 tiles
```

causal tile 数约 `3.88x`。如果当前 causal `91,011 cycles`，直接放大估计约 `350k cycles` 级别。Bonus 不一定受 baseline `300k` 限制，但应报告 cycles；若希望 S512 仍好看，需要：

- 增加 GEMM 并行度，例如 4x16 -> 8x16 或 16x16。
- 加宽 AXI 或增强 K/V cache。
- 更激进地 overlap load/compute/store。

### 7.5 验证计划

- `S=256` regression 保持一致。
- `S=512` causal/non-causal golden compare。
- `S=512` descriptor count：
  - non-causal K/V tiles：`32*32*2`
  - causal K/V tiles：`528*2`
- 末尾 tile：如果只支持 256/512，则无 partial tile；若支持任意 S，需要额外测试。
- cycles、RD/WR bytes、GOPS 报告。

### 7.6 成本收益

| 项目 | 评价 |
|---|---|
| RTL 成本 | 中-高 |
| 验证成本 | 高，仿真时间明显增加 |
| 面积/时序成本 | 中；若加并行度则高 |
| 收益 | 高，最能体现 Flash Attention 不存 `SxS` 的优势 |
| 主要风险 | 调度循环参数化、长仿真耗时、S512 cycles 偏高 |

### 7.7 建议

做固定 `S=512` 或 `S=256/512` 双模式。若面积不限制，可以把 bonus top 的 GEMM 从 4x16 恢复到 8x16 或 16x16，以抵消 S512 的周期增长。

## 8. Bonus 4：Padding Mask

### 8.1 目标

支持有效长度 `L <= S`。当 `j >= L` 时，KV token 无效，score 置为 `-inf`。对输出侧，如果 `i >= L`，可选择输出 0 或按文档定义为无效行；建议输出 0 并在文档中声明。

### 8.2 RTL 改动

CSR 扩展：

| 寄存器 | 说明 |
|---|---|
| `VALID_LEN` | 有效 token 数，范围 `1..S` |
| `MASK_MODE` | bit0 causal，bit1 padding，可选 |

score post 改动：

```text
invalid_k = global_k_idx >= valid_len
invalid_q = global_q_idx >= valid_len
causal_invalid = causal_en && global_k_idx > global_q_idx
masked = invalid_k || invalid_q || causal_invalid
```

调度优化可选：

- 若 `kv_blk_start >= valid_len`，可跳过整个 KV tile。
- 若 `q_blk_start >= valid_len`，可跳过整个 Q block 并直接 store zero，或不写该块。

### 8.3 验证计划

- `L=256` 与 baseline 完全一致。
- `L=1`：只有第一个 token 有效。
- `L=17`：跨 tile 边界。
- `L=240`：最后一个 Q block 部分无效。
- causal + padding 同时开启。
- non-causal + padding。
- byte counter：如果只 mask 不跳过，bytes 不变；如果跳过 tile，需要更新 expected count。

### 8.4 成本收益

| 项目 | 评价 |
|---|---|
| RTL 成本 | 低-中 |
| 验证成本 | 中 |
| 面积/时序成本 | 低，主要是比较器和 mask 逻辑 |
| 收益 | 中-高，真实模型常用 variable length/padding |
| 主要风险 | invalid Q 行输出语义、tile skip 后 descriptor count |

### 8.5 建议

这是最适合优先实现的 bonus。第一版只在 score post 做 mask，不做 tile skip，保证低风险；第二版再增加 padding tile skip，报告 bandwidth/cycles 收益。

## 9. Bonus 5：其他定点格式

### 9.1 目标

除 baseline Q8.8 外，额外支持 Q6.10、Q4.12 等等价定点格式，并给出误差与性能对比。

### 9.2 推荐格式

| 格式 | 范围 | 精度 | 适用性 |
|---|---:|---:|---|
| Q8.8 | 大 | 中 | baseline |
| Q6.10 | 中 | 较高 | 推荐，输入动态范围仍较宽 |
| Q4.12 | 小 | 高 | 当前 OACC 已使用，适合小幅输入 |

### 9.3 RTL 改动

两种实现方式：

| 方式 | 说明 | 推荐 |
|---|---|---|
| 多 top 固定格式 | `FA_TOP_Q610_BONUS`、`FA_TOP_Q412_BONUS` | 第一版推荐 |
| CSR 动态格式 | `DATA_FORMAT` 选择小数位、scale/rounding | 第二版可做 |

关键点：

- 输入 unpack 的小数位解释改变。
- QK scale 需要随格式重新定标。
- probability 与 row-state 可保持原内部格式。
- OACC 当前 Q4.12 可复用，但输入为 Q4.12 时要重新分析输出饱和。

### 9.4 验证计划

- 每个格式跑同一批 random seed。
- 统一与 FP32 golden 比较。
- 输出表：
  - mean/max error
  - saturation count
  - cycles
  - area delta
  - 推荐输入 amplitude

### 9.5 成本收益

| 项目 | 评价 |
|---|---|
| RTL 成本 | 低-中 |
| 验证成本 | 中 |
| 面积/时序成本 | 低 |
| 收益 | 中，容易形成漂亮对比表 |
| 主要风险 | 输入范围过大导致 Q4.12 饱和，误差不好看 |

### 9.6 建议

作为快速 bonus 很划算。优先做 Q6.10；Q4.12 可利用现有 OACC 经验，但要限制测试输入范围并清楚说明。

## 10. Bonus 6：Dropout 训练模式

### 10.1 目标

在 softmax 后加入 dropout：

```text
P_drop = mask_dropout(P) / keep_prob
O = P_drop V
```

需要明确随机数生成方式与可复现 seed。

### 10.2 RTL 改动

CSR 扩展：

| 寄存器 | 说明 |
|---|---|
| `DROPOUT_EN` | 是否启用 dropout |
| `DROPOUT_KEEP_PROB` | keep probability，定点表示 |
| `DROPOUT_SEED` | RNG seed |

数据路径：

- 在 row-state 输出 P 后，对每个 P lane 生成随机 keep/drop bit。
- drop 时 P=0，keep 时 P 乘 `1/keep_prob`。
- dropout mask 需要可复现，建议 LFSR 或 xorshift。

### 10.3 验证计划

- 固定 seed 下 RTL dropout mask 与 Python model 对齐。
- `dropout_en=0` 与 baseline 一致。
- `keep_prob=1.0` 与 baseline 一致。
- 统计 dropout keep ratio。
- causal + dropout、non-causal + dropout。

### 10.4 成本收益

| 项目 | 评价 |
|---|---|
| RTL 成本 | 中 |
| 验证成本 | 中-高 |
| 面积/时序成本 | 中 |
| 收益 | 低-中，偏训练模式，当前推理 IP 展示价值有限 |
| 主要风险 | 随机序列可复现、误差门限变化、概率缩放溢出 |

### 10.5 建议

优先级最低。只有当想强调训练态 attention 或已完成其他高价值 bonus 后再做。

## 11. Bonus 7：更低精度 INT8/FP8

### 11.1 目标

参考 FlashAttention-3 的低精度策略，实现 INT8 或 FP8 attention，使用块量化/分块缩放，并给出误差和性能收益。

### 11.2 推荐实现路线

优先 INT8，后 FP8：

- INT8 硬件简单，乘加可复用较小 MAC。
- FP8 需要处理格式选择，如 E4M3/E5M2、scale、饱和与特殊值。

INT8 路线：

1. Q/K/V 外部 INT8 或 packed INT8。
2. 每个 tile 或每行提供 scale。
3. QK 使用 INT8xINT8 accumulate 到 INT32。
4. score 转 Q16.16 或 FP-like 内部格式进入 softmax。
5. PV 使用 P 与 INT8 V，输出按 scale 还原。

### 11.3 CSR/内存布局

需要新增：

- Q/K/V scale base 地址，或固定 scale buffer。
- quantization mode。
- per-tensor/per-row/per-tile scale 选择。

### 11.4 验证计划

- Python quantization golden。
- 对比 Q8.8 baseline 和 FP32 golden。
- 报告：
  - error vs FP32
  - bytes reduction
  - cycles/GOPS
  - area/power trend
  - saturation/clip rate

### 11.5 成本收益

| 项目 | 评价 |
|---|---|
| RTL 成本 | 高-很高 |
| 验证成本 | 很高 |
| 面积/时序成本 | 中到高，MAC 变小但 scale/convert/control 增加 |
| 收益 | 高，低精度是 attention 加速热点 |
| 主要风险 | 误差失控、scale 管理复杂、测试空间大 |

### 11.6 建议

作为研究型 bonus。若时间有限，不建议和 BF16/FP16 同时做；二者选一个方向即可。

## 12. Bonus 8：AXI4-Stream 数据接口

### 12.1 目标

在 baseline AXI4 Master+DMA 之外，额外提供 AXI4-Stream 输入/输出接口，使 FA IP 可以和其他 IP 级联。

### 12.2 架构方案

推荐做 wrapper，不改 core：

```text
AXI4-Stream in -> stream-to-buffer loader -> FA core shell ports
FA core store -> buffer-to-stream exporter -> AXI4-Stream out
```

保留原 CSR 控制，新增 stream mode：

- `INPUT_MODE=DMA/STREAM`
- `OUTPUT_MODE=DMA/STREAM`

### 12.3 RTL 改动

| 区域 | 改动 |
|---|---|
| input stream | 接收 Q/K/V stream，按 tile 或矩阵顺序写入内部 buffer |
| output stream | 将 O 输出为 stream |
| flow control | 支持 `tvalid/tready/tlast/tkeep` |
| metadata | 可选使用 `tuser` 标记 Q/K/V/O 或 head/block |
| CSR | 增加 stream mode 与 stream status |

### 12.4 验证计划

- stream-only input/output full run。
- DMA input + stream output。
- stream input + DMA output。
- backpressure on stream in/out。
- malformed `tlast` 或 early/late packet error。

### 12.5 成本收益

| 项目 | 评价 |
|---|---|
| RTL 成本 | 中 |
| 验证成本 | 中 |
| 面积/时序成本 | 中，主要是 stream adapter/FIFO |
| 收益 | 中，系统集成展示价值高 |
| 主要风险 | packet framing、backpressure、和 DMA mode 共存 |

### 12.6 建议

适合作为工程化 bonus。优先 wrapper 化，不要改 core datapath。

## 13. Bonus 9：DMA/任务队列

### 13.1 目标

支持多次 attention 连续执行，通过队列或链式配置减少主机交互。

### 13.2 架构方案

两种方案：

| 方案 | 说明 | 成本 | 推荐 |
|---|---|---|---|
| CSR task FIFO | 主机向寄存器窗口写入多个 task descriptor | 中 | 第一版推荐 |
| linked-list DMA | 从内存读取 task descriptor 链 | 中-高 | 第二版 |

Task descriptor 包含：

- Q/K/V/O base
- stride
- causal/padding/mode
- valid length
- optional head count
- optional next descriptor pointer

### 13.3 RTL 改动

- 新增 task queue。
- `FA_RUN_CTRL` 支持 auto-start next task。
- counters 需要 per-task 或 accumulated 两种口径。
- `STATUS` 增加 queue empty/full、task done count、current task id。
- 可选 IRQ coalescing：每 N 个 task 或 queue empty 才触发 IRQ。

### 13.4 验证计划

- 连续 2/4/8 个 attention task。
- 不同 causal mode 混排。
- task queue full/empty。
- 中途 soft reset。
- task error 后停止或跳过策略。
- per-task output golden compare。

### 13.5 成本收益

| 项目 | 评价 |
|---|---|
| RTL 成本 | 中 |
| 验证成本 | 中-高 |
| 面积/时序成本 | 低-中 |
| 收益 | 中-高，明显减少主机交互，系统展示好 |
| 主要风险 | 多 task 状态清理、error recovery、counter 口径 |

### 13.6 建议

适合与 multi-head 或 padding mask 组合。第一版做小深度 CSR FIFO 即可，不必直接上 linked-list DMA。

## 14. 组合实施路线

### 14.1 低风险功能包

目标：用最小 RTL 风险拿到多个 bonus。

包含：

1. Padding mask
2. 其他定点格式 Q6.10
3. DMA/task FIFO

优点：

- 不需要重做核心 GEMM/softmax 架构。
- 大部分验证可复用现有 cocotb 环境。
- 文档能给出功能、cycles、bytes、误差对比。

缺点：

- 性能提升有限，偏功能扩展。

### 14.2 模型规模扩展包

目标：体现 Flash Attention 可扩展性。

包含：

1. Multi-head serial `head=4/8`
2. `S=512`
3. Padding mask

优点：

- 最贴近真实 Transformer attention。
- 展示“不存 SxS”的价值。

缺点：

- 仿真时间和 golden 计算时间增加。
- cycles 可能明显升高，需要解释或加并行硬件。

### 14.3 高性能并行包

目标：bonus 不受面积限制，换取更高 GOPS。

包含：

1. GEMM 从 4x16 扩到 8x16 或 16x16。
2. 多 head 并行或双 core interleave。
3. 更宽 AXI 或更强 K/V cache。

优点：

- cycles/GOPS 数据会明显好看。
- 能展示面积-性能权衡。

缺点：

- DC/时序/DRC 成本高。
- 需要清楚说明这是 bonus 独立版本，不影响 baseline 面积。

### 14.4 数值格式研究包

目标：展示数据格式和误差分析能力。

包含：

1. Q6.10/Q4.12
2. BF16 或 INT8
3. 完整 error/perf/area 对比表

优点：

- 文档价值高。
- 可结合 `scripts/fa_precision_analysis.py` 扩展。

缺点：

- BF16/INT8 会拉高验证复杂度。

## 15. 推荐最终计划

### 第一阶段：快速可交付

| 顺序 | 项目 | 目标 |
|---:|---|---|
| 1 | Padding mask | 新增 `VALID_LEN`，完成 mask 语义和 directed tests |
| 2 | Q6.10 定点格式 | 增加固定格式 bonus top 或 CSR mode，输出误差对比 |
| 3 | DMA/task FIFO | 支持多 task 连续执行，减少 host start/poll |

验收：

- Full causal/non-causal regression 通过。
- Padding `L=1/17/240/256` 通过。
- Q6.10 mean/max error 表。
- 多 task 2/4/8 连续运行通过。
- SpyGlass 0 error，DC 记录面积/时序。

### 第二阶段：高价值扩展

| 顺序 | 项目 | 目标 |
|---:|---|---|
| 4 | Multi-head serial | 支持 `head=4/8`，逐 head golden compare |
| 5 | S512 | 支持 `S=512`，保持不存 `SxS` |
| 6 | AXI4-Stream wrapper | 提供 stream 输入/输出模式 |

验收：

- `head=4/8` full run。
- `S=512` causal/non-causal 或至少 causal full run。
- Stream backpressure tests。
- cycles/RD_BYTES/WR_BYTES/GOPS 报告。

### 第三阶段：冲刺项

| 顺序 | 项目 | 目标 |
|---:|---|---|
| 7 | BF16 | BF16 attention first-pass，误差/性能/面积对比 |
| 8 | INT8/FP8 | 块量化低精度实验 |
| 9 | Dropout | 训练模式功能展示 |

验收：

- 独立 golden model。
- 明确误差来源。
- 报告格式对比、面积和 cycles。

## 16. 文档与提交要求

每个 bonus 独立目录或独立 top 建议包含：

- RTL：`FA_TOP_<BONUS_NAME>` 或 `bonus/<name>/rtl`
- 测试：`sim/cocotb/tests/test_fa_bonus_<name>.py`
- 脚本：precision/profile/report 生成脚本
- 文档：`doc/Flash Attention/bonus_<name>.md`
- 报告：
  - correctness
  - mean/max error
  - cycles/GOPS
  - RD_BYTES/WR_BYTES
  - SpyGlass
  - DC area/timing/power if available

每个 bonus commit 建议粒度：

```text
fa-bonus: add padding mask support
fa-bonus: add q6.10 fixed-point mode
fa-bonus: add task queue execution
fa-bonus: add multi-head scheduler
fa-bonus: add s512 schedule
```

## 17. 结论

从投入产出比看，最推荐先做 `Padding mask`、`Multi-head serial` 和 `S=512`。它们和题面 bonus 的匹配度高，且能体现 Flash Attention 的核心价值：变长 mask、多 head attention、长序列不存 `SxS` 中间矩阵。

如果希望在不受面积限制的 bonus 中突出性能，可以另建高性能 top，把 GEMM 并行度提高到 8x16 或 16x16，再和 multi-head/S512 组合，给出面积换吞吐的对比。BF16/INT8/FP8 更适合作为后续冲刺项，收益高但验证和数值风险也最高。
