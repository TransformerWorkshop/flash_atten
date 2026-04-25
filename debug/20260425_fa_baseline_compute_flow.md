# FA Baseline 计算流程说明

- 时间：`2026-04-25`
- 文档目的：
  - 解释当前 baseline attention 的数学流程和 RTL 数据流
  - 说明每一步的数据格式、tile 边界、缓冲区角色和模块职责
  - 使阅读者能够从 `Q/K/V` 一路跟到 `O`

## 1. 计算目标

当前 baseline 计算的是标准 SDPA / FlashAttention 公式：

`O = softmax(QK^T * scale + mask) V`

其中：

- `scale = 1 / sqrt(d)`
- `d = 64`
- `mask` 在 causal 模式下对未来位置生效

本设计采用的不是“先算完整 score，再算完整 P，再乘 V”的传统方式，而是：

- `Q` 固定一个 tile
- `K/V` 按 tile 扫描
- 在线维护每一行的 `m/l`
- 每处理一个 `K/V` tile，就产生一块局部 `P`
- 用这块 `P` 立刻与 `V` 相乘，累积到 `OACC`

这就是当前 baseline 的核心计算思想。

## 2. 计算所用的基本数据格式

### 2.1 输入输出格式

- `Q/K/V/O`：`Q8.8`, 16-bit signed

### 2.2 中间格式

- `score`：`Q16.16`, 32-bit signed
- `m/l/alpha/beta/rescale`：`Q16.16`
- `P`：最终写入 buffer 时为 `Q8.8`

### 2.3 打包规则

- 一个 `32-bit word` 打包两个 `Q8.8`
- `low 16 bits = even index`
- `high 16 bits = odd index`

这个规则在：

- DMA 读入
- buffer 存储
- `QK`
- `PV`
- `OACC update`

之间是统一的。

## 3. tile 组织方式

### 3.1 大小

当前固定：

- `Q/K/V/OACC tile = 16 x 64`
- `score/P tile = 16 x 16`

### 3.2 为什么这样切

因为当前 baseline 锁定：

- `S=256`
- `d=64`

于是：

- 序列维按 16 切成 16 个 block
- head dim 恰好就是 64，不再沿 feature 维进一步切 block

这样：

- `q_blk = 0..15`
- `kv_blk = 0..15`

就覆盖了整个 baseline 问题。

## 4. 总体数据流

当前一轮完整 attention 计算的数据流可以概括为：

1. 读一个 `Q tile`
2. 初始化该 `Q tile` 对应的 16 行 row-state
3. 清零该 `Q tile` 对应的 `OACC`
4. 对每个 `kv_blk`：
   - 读一个 `K tile`
   - 读一个 `V tile`
   - 计算 `QK^T`
   - 做 `scale + mask`
   - 做 online row-state 更新，得到当前 `P tile`
   - 计算 `P * V`
   - 用 `rescale + partial_O` 更新 `OACC`
5. `kv_blk` 全部结束后，把 `OACC` 写回 `O`
6. 继续下一个 `Q tile`

对应的共享核心文件：

- [`rtl/fa_core_baseline.v`](../rtl/fa_core_baseline.v)

## 5. 输入加载阶段

### 5.1 `Q/K/V` 的加载来源

在 core 看来，所有输入都来自抽象 DMA-shell。

也就是：

- `FA_RD_DMA` 负责发出读描述符
- 外部返回按 32-bit word 排列的数据流
- `FA_RD_DMA` 再把这些 word 分发到对应 buffer

对应文件：

- [`rtl/fa_dma_shell.v`](../rtl/fa_dma_shell.v)

### 5.2 `Q/K/V` buffer 的角色

当前主要有：

- `FA_Q_BUF_REAL`
- `FA_K_BUF_REAL`
- `FA_V_BUF_REAL`
- `FA_V_BUF_PV_REAL`

对应文件：

- [`rtl/fa_buffers_real.v`](../rtl/fa_buffers_real.v)

角色分别是：

- `Q_BUF`
  - 保存当前 `q_blk` 的 `16 x 64` tile
  - 为 `QK` 真核提供读取
- `K_BUF`
  - 保存当前 `kv_blk` 的 `16 x 64` tile
  - 为 `QK` 真核提供读取
- `V_BUF`
  - 保存当前 `kv_blk` 的普通 row-major `16 x 64` tile
  - 主要用于可见性和一致性
- `V_BUF_PV_REAL`
  - 保存面向 `PV` 核的二次重排视图
  - 让 `P * V` 的读取模式更自然

### 5.3 为什么 `V` 需要第二视图

`QK` 读取的是：

- `Q[row][word_idx]`
- `K[row][word_idx]`

这是标准 row-major。

但 `PV` 读取的是：

- `P[row][k_pair]`
- `V[o_col_blk][k_pair][lane]`

它更像“按输出列块和 key-pair 组织”的布局。

所以当前设计不是强行让 `PV` 复用普通 `V_BUF`，而是：

- 在加载 `V` 时同时构建 `V_BUF_PV_REAL`

这正是 [`rtl/fa_dma_shell.v`](../rtl/fa_dma_shell.v) 里 `v_pv_wr_*` 那组信号的作用。

## 6. `QK` 计算阶段

### 6.1 功能

`QK` 阶段计算：

- 一个 `16 x 16` score tile

数学上等于：

- `Q[16x64] * K^T[64x16]`

### 6.2 实现模块

- [`rtl/fa_cores_real.v`](../rtl/fa_cores_real.v)
- 模块：`FA_QK_CORE_REAL`

### 6.3 输入输出

输入：

- `Q_BUF` 提供 `q_rd_data`
- `K_BUF` 提供 `k_rd_data`

输出：

- `result_tile_flat[8191:0]`
- 共 256 个 `32-bit` 元素
- 每个元素为 `Q16.16`

### 6.4 计算规则

对每个输出元素：

- `Q8.8 * Q8.8 -> Q16.16`
- 沿 64 维累加
- 最终 clamp 到 32-bit signed `Q16.16`

因此 `QK` 的结果不是概率，而是尚未缩放、尚未 mask 的 score。

## 7. `score_post` 阶段

### 7.1 功能

`score_post` 的作用是把 `QK` 的 raw score 变成“可送入 online softmax 的 masked score”。

具体做两件事：

1. 乘 `scale`
2. 应用 causal mask

### 7.2 实现模块

- [`rtl/fa_score_post_real.v`](../rtl/fa_score_post_real.v)

### 7.3 输入输出

输入：

- `q_blk_idx`
- `kv_blk_idx`
- `causal_en`
- `scale_word`
- `neg_large_word`
- `score_tile_flat`

输出：

- `masked_score_tile_flat`

### 7.4 关键规则

对非 masked 元素：

- `Q16.16 * Q16.16 -> Q32.32`
- round-to-nearest
- 回到 `Q16.16`

对 masked 元素：

- 不做数值运算
- 直接写成 `neg_large_word`

这个 sentinel 设计很重要，因为后面的 `FA_ROW_STATE_REAL` 是直接通过：

- `score_word == neg_large_word`

来判断该位置是否被 mask 的。

## 8. `row_state` 阶段

### 8.1 功能

`row_state` 是整个 baseline attention 的核心算法块。

它做的是：

- 对当前 `16 x 16` masked score tile 做 online softmax 更新
- 维护当前 `Q tile` 的 16 行历史状态
- 输出当前 tile 的：
  - `P tile`
  - `rescale_vec`

### 8.2 实现模块

- [`rtl/fa_row_state_real.v`](../rtl/fa_row_state_real.v)

### 8.3 内部状态

它只保存当前 `q_blk` 的 16 行状态：

- `m_state[16]`
- `l_state[16]`
- `row_seen[16]`

它不会保存完整：

- `256 x 256 score`
- `256 x 256 probability`

这正是 baseline “低中间存储”约束的关键落点。

### 8.4 数学过程

对当前一行：

1. 找当前 tile 的 `tile_row_max`
2. 与历史 `m_old` 比较，得到 `m_new`
3. 计算：
   - `alpha = exp(m_old - m_new)`
   - `beta_j = exp(score_j - m_new)`
4. 计算：
   - `l_new = alpha * l_old + sum(beta_j)`
5. 计算：
   - `p_j = beta_j / l_new`
   - `rescale = alpha * l_old / l_new`
6. 更新：
   - `m_state = m_new`
   - `l_state = l_new`

### 8.5 输出

输出两类结果：

- `p_tile_flat`
  - 当前 `16 x 16` tile 的概率
  - 输出前量化回 `Q8.8`
- `rescale_vec_flat`
  - 每一行一个 `Q16.16`
  - 供 `OACC update` 使用

### 8.6 特殊情况

如果当前 tile 某一行全 masked：

- 且这行已有历史：
  - `p = 0`
  - `rescale = 1.0`
  - 旧 `OACC` 保持
- 且这行没有历史：
  - `p = 0`
  - `rescale = 0`

这保证了 causal 边界情况下 online 累加仍然稳定。

## 9. `P` 缓冲阶段

### 9.1 作用

`FA_P_BUF_REAL` 的作用是把 `row_state` 输出的 `P tile` 暂存下来，供 `PV` 核读取。

对应文件：

- [`rtl/fa_buffers_real.v`](../rtl/fa_buffers_real.v)

### 9.2 数据形状

- `16 x 16`
- `8 words/row`

它不是长期存储，只保存当前 `kv_blk` 对应的概率块。

## 10. `PV` 计算阶段

### 10.1 功能

`PV` 计算：

- `P[16x16] * V[16x64]`

输出：

- 当前 `kv_blk` 对 `O` 的一个 `16 x 64` partial contribution

### 10.2 实现模块

- [`rtl/fa_cores_real.v`](../rtl/fa_cores_real.v)
- 模块：`FA_PV_CORE_REAL`

### 10.3 内部组织

虽然外部看起来一次产出完整 `16 x 64`，但内部并不是单次就做完。

它内部固定有：

- `o_col_blk = 0..3`

也就是：

- 每次处理一个 `16 x 16` 输出子块
- 共做四次
- 最后拼成完整 `16 x 64`

### 10.4 数值规则

对每个子块：

- `Q8.8 * Q8.8 -> Q16.16`
- 沿 16 项累加
- 完成后 round-to-nearest
- saturate 回 `Q8.8`

因此 `PV` 输出的是：

- `partial_o_tile_flat`
- 格式为 `Q8.8`

## 11. `OACC` 更新阶段

### 11.1 功能

`OACC update` 的作用是把：

- 旧的 `OACC`
- 当前 `partial_O`
- `rescale_vec`

合成为新的 `OACC`。

### 11.2 实现模块

- [`rtl/fa_oacc_update_real.v`](../rtl/fa_oacc_update_real.v)

### 11.3 数学规则

对每个元素：

1. 读旧值 `old_oacc`
2. 乘行级 `rescale`
3. round-to-nearest 回 `Q8.8`
4. 加上当前 `partial_o`
5. 做 `Q8.8` 饱和

即：

- `new = sat(round(old * rescale) + partial)`

### 11.4 为什么需要 `rescale`

因为 online softmax 在 `kv_blk` 之间不断更新：

- `m`
- `l`

这意味着旧的 `OACC` 不是永远在同一个归一化尺度上。

所以每次处理新的 `kv_blk` 前，都要先把历史累计结果缩放到新的归一化基准，再加当前块贡献。

## 12. `OACC` buffer 与最终写回

### 12.1 `FA_OACC_BUF_REAL`

`OACC` buffer 负责：

- clear
- row read
- row write
- export read
- snapshot/debug

对应文件：

- [`rtl/fa_buffers_real.v`](../rtl/fa_buffers_real.v)

它保存的是当前 `q_blk` 的完整 `16 x 64` 输出 tile。

### 12.2 写回阶段

当某个 `q_blk` 的 16 个 `kv_blk` 全部处理完成后：

- `FA_WR_DMA` 从 `OACC_BUF_REAL` 逐行导出
- 再通过写描述符 + 写数据流写回 `O_BASE`

对应文件：

- [`rtl/fa_dma_shell.v`](../rtl/fa_dma_shell.v)

## 13. 一个完整 `q_blk` 的计算过程

为了把整体算清楚，可以把单个 `q_blk` 的计算过程按时间展开成：

1. `Q load`
   - 读 `Q[q_blk]`
   - 写入 `Q_BUF`
2. `row init`
   - 初始化 16 行的 `m/l/seen`
3. `OACC clear`
   - 清零当前 `16 x 64` 输出缓冲
4. 对 `kv_blk = 0..15` 重复：
   - `K load`
   - `V load`
   - `QK`
   - `score_post`
   - `row_state`
   - `P load`
   - `PV`
   - `OACC update`
5. `store`
   - 从 `OACC` 导出到内存

这个过程正是 FlashAttention baseline 的 tile 化实现。

## 14. 当前计算流程的设计特点

当前计算流程有几个关键特点：

### 14.1 不存完整 attention matrix

当前只保留：

- 一个 `score/P tile`
- 当前 `Q/K/V tile`
- 当前 `OACC tile`
- 当前 `row_state`

### 14.2 计算与存储是块级耦合的

`QK -> score_post -> row_state -> P -> PV -> OACC update`

是一个围绕单个 `kv_blk` 的闭环，而不是先算完整 softmax 再回头算 `PV`。

### 14.3 数值格式分工清晰

- 点积和 softmax 状态：`Q16.16`
- 概率和输出缓存：`Q8.8`

### 14.4 复用了 PT 系列最值钱的资产

虽然当前 top 不是 `PT_DMA_TOP_V3`，但它确实复用了原仓库最有价值的思路：

- banked local storage
- tile GEMM 子核思路
- DMA fill/export 骨架

## 15. 一句话总结

如果要用一句话总结当前 baseline 的计算流程，可以这样说：

> 当前设计按 `Q tile` 固定、`K/V tile` 扫描的方式运行，在每个 `kv_blk` 上依次完成 `QK -> scale/mask -> online softmax -> PV -> OACC update`，最终把 16 行输出 tile 写回，从而在不存完整 attention matrix 的前提下完成 baseline attention 计算。

