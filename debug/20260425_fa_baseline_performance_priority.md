# FA Baseline 模块级性能评级与优化优先级分析

- 时间：`2026-04-25`
- 仓库：`flash_atten`
- 目的：
  - 对当前 baseline attention 设计做模块级性能拆账
  - 给出瓶颈评级
  - 给出修改优先级
  - 分析每一类优化的成本、风险和收益

## 1. 分析口径

本报告不是 gate-level profile，也不是来自波形上的精确 cycle trace，而是：

- 以当前 RTL 状态机逐拍分析为基础
- 结合 baseline 固定 shape：
  - `S = 256`
  - `d = 64`
  - `q_blk = 0..15`
  - `kv_blk = 0..15`
- 假设：
  - `ready` 恒高
  - shell/DMA 每拍传 1 个 `32-bit word`
  - buffer 读延迟 1 拍
  - 没有额外 AXI backpressure

因此这是一份：

- **结构性能预算**

它可以用来判断：

- 哪些模块最该优先改
- 哪些模块看起来“很重”但实际上不值得优先动

## 2. 当前 baseline 的总周期预算

按当前 RTL 结构估算：

- 当前 `causal baseline` 理想总周期大约是：
  - **`454,576 cycles`**

这个数字的重要意义是：

- 它明显高于题面 `<300k cycles` 的目标
- 说明当前版本虽然功能链路已经基本完整，但性能上还需要优化

## 3. 模块级性能统计

下表按模块/阶段拆分当前理想周期预算。

| 模块/阶段 | 主要 RTL | 单次理想周期 | 触发次数 | 总周期 | 占比 | 性能评级 |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| `Q load` | `FA_RD_DMA` | 513 | 16 | 8,208 | 1.8% | C |
| `K load` | `FA_RD_DMA` | 513 | 256 | 131,328 | 28.9% | S |
| `V load` | `FA_RD_DMA` | 513 | 256 | 131,328 | 28.9% | S |
| `QK` | `FA_QK_CORE_REAL` | 114 | 256 | 29,184 | 6.4% | B |
| `score_post` | `FA_SCORE_POST_REAL` | 17 | 256 | 4,352 | 1.0% | C |
| `row_update` 总计 | `FA_ROW_STATE_REAL + FA_P_BUF_REAL` | 见下 | 256 | 82,304 | 18.1% | A |
| `PV` | `FA_PV_CORE_REAL` | 165 | 256 | 42,240 | 9.3% | A |
| `OACC update` | `FA_OACC_UPDATE_REAL` | 65 | 256 | 16,640 | 3.7% | B |
| `store` | `FA_WR_DMA` | 545 | 16 | 8,720 | 1.9% | C |
| `row init` | `FA_ROW_STATE_REAL` | 1 | 16 | 16 | ~0 | D |
| `OACC clear` | `FA_OACC_BUF_REAL` | 16 | 16 | 256 | 0.1% | D |

### 3.1 直接结论

最大的时间消耗来自：

1. `K load`
2. `V load`
3. `row_update`
4. `PV`
5. `QK`

也就是说，当前系统最重的瓶颈不是写回，不是 CSR，也不是 `score_post`，而是：

- **反复读入 `K/V`**
- **online softmax 状态维护**
- **`PV` 计算**

## 4. 各模块的结构性耗时来源

### 4.1 `FA_RD_DMA`

对应文件：

- [`rtl/fa_dma_shell.v`](../rtl/fa_dma_shell.v)

#### 当前耗时来源

每次 tile 读入固定：

- `1` 拍发 descriptor
- `512` 拍收 `512` 个 word

所以：

- 单次 `Q/K/V load = 513 cycles`

#### 为什么 `K/V` 是 S 级瓶颈

因为：

- `Q` 只读 16 次
- 但 `K` 和 `V` 各要读 256 次

总计：

- `K load + V load = 262,656 cycles`
- 占总预算约 **57.8%**

这是当前最大的性能来源。

### 4.2 `FA_QK_CORE_REAL`

对应文件：

- [`rtl/fa_cores_real.v`](../rtl/fa_cores_real.v)

#### 当前耗时来源

它每个 tile 需要：

- `32` 次 feed
- 每次：
  - `ISSUE`
  - `WAIT_RD`
  - `FEED`
- 外加 GEMM 内部出结果的 collect

按当前结构估算：

- 单 tile 约 `114 cycles`

#### 评价

`QK` 不是最重热点，但也不是可以忽略的部分。

它占比约：

- **6.4%**

属于：

- **B 级**

### 4.3 `FA_SCORE_POST_REAL`

对应文件：

- [`rtl/fa_score_post_real.v`](../rtl/fa_score_post_real.v)

#### 当前耗时来源

它按行顺序跑：

- 16 行
- 每行 1 拍
- 最后 `resp_valid`

所以：

- 单 tile 约 `17 cycles`

#### 评价

`score_post` 是功能上必要，但性能上不重。

占比只有：

- **1.0%**

属于：

- **C 级**

### 4.4 `FA_ROW_STATE_REAL`

对应文件：

- [`rtl/fa_row_state_real.v`](../rtl/fa_row_state_real.v)
- [`rtl/fa_recip_q16_16.v`](../rtl/fa_recip_q16_16.v)

#### 当前耗时来源

这是当前算法控制面里最重的一块。

对一个有效 row：

- `ROW_PREP`
- `ROW_EXP`
- `ROW_DIV_WAIT`
  - reciprocal 固定 `32 cycles`
- `ROW_COMMIT`

如果这一行有有效 score，则单行约：

- `35 cycles`

16 行总计约：

- `560 cycles`

再加 `P_BUF` 装载：

- `8 cycles`

所以一个“有效 tile”的 `row_update` 大约是：

- **`569 cycles`**

#### causal 下的特殊性

在 `causal` 模式里，`q_blk < kv_blk` 的 tile 会整块 future-masked。

这种 tile 下：

- 每行都会走“无有效值”分支
- 不触发 reciprocal
- 整个 tile 大约只要：
  - `33 + 8 = 41 cycles`

#### 当前总占比

当前 `causal` 下：

- 有效 tile：136 个
- 完全 masked tile：120 个

所以 `row_update` 总计约：

- **82,304 cycles**

占比：

- **18.1%**

属于：

- **A 级**

### 4.5 `FA_PV_CORE_REAL`

对应文件：

- [`rtl/fa_cores_real.v`](../rtl/fa_cores_real.v)

#### 当前耗时来源

`PV` 内部固定：

- `o_col_blk = 0..3`

每个子块：

- `8` 次 feed
- 每次有：
  - `ISSUE`
  - `WAIT_RD`
  - `FEED`
- 再等 collect

单个 `o_col_blk` 约：

- `41 cycles`

四个子块合计：

- **`165 cycles/tile`**

#### 当前总占比

- `165 * 256 = 42,240 cycles`
- 占比约 **9.3%**

属于：

- **A 级**

### 4.6 `FA_OACC_UPDATE_REAL`

对应文件：

- [`rtl/fa_oacc_update_real.v`](../rtl/fa_oacc_update_real.v)

#### 当前耗时来源

它按行顺序做：

- `ROW_REQ`
- `ROW_WAIT`
- `ROW_CALC`
- `ROW_WRITE`

每行约：

- `4 cycles`

16 行后再 `DONE`

总计约：

- **`65 cycles/tile`**

#### 当前总占比

- `65 * 256 = 16,640 cycles`
- 占比约 **3.7%**

属于：

- **B 级**

### 4.7 `FA_WR_DMA`

对应文件：

- [`rtl/fa_dma_shell.v`](../rtl/fa_dma_shell.v)

#### 当前耗时来源

每次写回一个 `q_blk`：

- `1` 拍 descriptor
- `16` 行
- 每行：
  - `REQ_ROW`
  - `WAIT_ROW`
  - `32` 拍输出

总计约：

- **`545 cycles/store`**

但只触发 16 次，总占比不高。

#### 当前总占比

- `8,720 cycles`
- 占比约 **1.9%**

属于：

- **C 级**

## 5. 最关键的系统级发现：完全无效 tile 还在白跑

### 5.1 问题本身

当前 `causal` 模式下：

- 当 `q_blk < kv_blk` 时
- 这一整个 `16 x 16` score tile 都会被 mask 掉

也就是说：

- 这个 tile 对最终输出没有任何新增贡献

但是当前调度器 [FA_TILE_SCHED](/Users/yucheng/Documents/GitHub/flash_atten/rtl/fa_tile_sched.v) 仍然会完整执行：

- `K load`
- `V load`
- `QK`
- `score_post`
- `row_update`
- `PV`
- `OACC update`

### 5.2 白跑成本

一个这样的 fully-masked tile 目前大约仍会消耗：

- `K load`: 513
- `V load`: 513
- `QK`: 114
- `score_post`: 17
- `row_update`: 41
- `PV`: 165
- `OACC update`: 65

合计约：

- **`1428 cycles/tile`**

### 5.3 当前 baseline 下的数量

对 `q_blk = 0..15`：

- 完全无效 tile 数量是上三角：
  - `15 + 14 + ... + 1 = 120`

### 5.4 可节省总周期

如果整块跳过：

- `120 * 1428 = 171,360 cycles`

新总周期约变成：

- `454,576 - 171,360 = 283,216 cycles`

这个结果非常关键，因为：

- 它直接把当前 baseline 拉进题面 `<300k cycles` 的目标范围

## 6. 性能评级

这里给一个更偏工程决策的评级：

- `S`
  - 最大瓶颈，且优化收益巨大
- `A`
  - 明显热点，值得高优先级处理
- `B`
  - 中等热点，可作为第二梯队
- `C`
  - 结构存在但收益较低
- `D`
  - 几乎不值得优先碰

### 6.1 当前评级结果

| 模块/阶段 | 性能评级 | 说明 |
| --- | --- | --- |
| `K load` | S | 高频触发，绝对大头 |
| `V load` | S | 高频触发，绝对大头 |
| `row_update` | A | 当前算法控制面第一大热点 |
| `PV` | A | 计算热点，结构明确 |
| `QK` | B | 中等热点 |
| `OACC update` | B | 中等热点，易优化 |
| `Q load` | C | 只做 16 次，不是主要问题 |
| `store` | C | 总占比不高 |
| `score_post` | C | 不重 |
| `row init` | D | 可忽略 |
| `OACC clear` | D | 可忽略 |

## 7. 修改优先级

### P0：`FA_TILE_SCHED` 增加 causal fully-masked tile 跳过

对应模块：

- [`rtl/fa_tile_sched.v`](../rtl/fa_tile_sched.v)

#### 做法

当：

- `causal_en = 1`
- `kv_blk > q_blk`

时直接跳过：

- `K load`
- `V load`
- `QK`
- `score`
- `row`
- `PV`
- `OACC`

#### 收益

- 约节省 **171,360 cycles**
- 直接把理想总周期拉到约 `283,216`

#### 成本

- 低到中

#### 风险

- 低

#### 为什么优先级最高

因为它：

- 不动数值路径
- 不动数据格式
- 不动 buffer
- 不动 AXI
- 只动调度控制

但收益却是全局最大的。

### P1：扩大读入宽度，降低 `K/V load`

对应模块：

- [`rtl/fa_dma_shell.v`](../rtl/fa_dma_shell.v)
- [`rtl/fa_axi_rd_master.v`](../rtl/fa_axi_rd_master.v)
- [`rtl/fa_core_baseline.v`](../rtl/fa_core_baseline.v)

#### 做法

让 core 内部不再只按：

- `32-bit word/cycle`

读入，而是改成更宽：

- 例如 `128-bit/cycle`

#### 收益

理论收益极高，因为：

- `K load + V load` 占当前总周期接近 58%

#### 成本

- 高

#### 风险

- 高

#### 风险来源

因为这会牵一串东西：

- shell 接口
- AXI wrapper
- buffer 写入口
- cocotb memory model

### P2：优化 `FA_ROW_STATE_REAL`

对应模块：

- [`rtl/fa_row_state_real.v`](../rtl/fa_row_state_real.v)
- [`rtl/fa_recip_q16_16.v`](../rtl/fa_recip_q16_16.v)

#### 做法

优先考虑：

- 更快 reciprocal
- 多行并行
- 减少 per-row 固定控制开销

#### 收益

- 高

在 `P0` 做完以后，`row_update` 会变成更显著的热点。

#### 成本

- 中到高

#### 风险

- 中到高

#### 风险来源

这块最容易影响：

- `mean_abs_error`
- `max_abs_error`

因为它直接控制 online softmax 数值。

### P3：优化 `FA_PV_CORE_REAL`

对应模块：

- [`rtl/fa_cores_real.v`](../rtl/fa_cores_real.v)

#### 做法

可以考虑：

- 增加 `o_col_blk` 并行度
- 减少 feed/collect 控制开销
- 提高 `P/V` 读取并发

#### 收益

- 中高

#### 成本

- 中到高

#### 风险

- 中

### P4：优化 `FA_QK_CORE_REAL`

对应模块：

- [`rtl/fa_cores_real.v`](../rtl/fa_cores_real.v)

#### 收益

- 中

#### 成本

- 中到高

#### 风险

- 中

#### 原因

`QK` 虽然是重要算子，但按当前占比还排不到前二。

### P5：优化 `FA_OACC_UPDATE_REAL`

对应模块：

- [`rtl/fa_oacc_update_real.v`](../rtl/fa_oacc_update_real.v)

#### 收益

- 中低

#### 成本

- 中

#### 风险

- 低到中

#### 特点

这是一个“好改但收益一般”的模块。

### P6：优化 `FA_WR_DMA`

对应模块：

- [`rtl/fa_dma_shell.v`](../rtl/fa_dma_shell.v)

#### 收益

- 低

#### 成本

- 中

#### 风险

- 低

#### 原因

写回只占不到 2%。

### P7：优化 `FA_SCORE_POST_REAL`

对应模块：

- [`rtl/fa_score_post_real.v`](../rtl/fa_score_post_real.v)

#### 收益

- 很低

#### 成本

- 低到中

#### 风险

- 低

#### 原因

它只占 1%，不是当前瓶颈。

## 8. 成本、风险和收益总表

| 优化项 | 成本 | 风险 | 收益 |
| --- | --- | --- | --- |
| `FA_TILE_SCHED` 跳过 fully-masked tile | 低-中 | 低 | 极高 |
| 读入改宽到 128b core-side | 高 | 高 | 极高 |
| `FA_ROW_STATE_REAL` 加速 reciprocal / 并行行处理 | 中-高 | 中-高 | 高 |
| `FA_PV_CORE_REAL` 并行化 | 中-高 | 中 | 中高 |
| `FA_QK_CORE_REAL` 并行化 | 中-高 | 中 | 中 |
| `FA_OACC_UPDATE_REAL` 并行化 | 中 | 低-中 | 中低 |
| `FA_WR_DMA` 优化 | 中 | 低 | 低 |
| `FA_SCORE_POST_REAL` 优化 | 低-中 | 低 | 很低 |

## 9. 推荐的修改顺序

如果目标是尽快把 baseline 拉进题面性能目标，我建议按这个顺序做：

1. `FA_TILE_SCHED`
   - 跳过 `causal` 下 fully-masked future tiles
2. `FA_ROW_STATE_REAL`
   - 优先优化 reciprocal 和行级串行瓶颈
3. `FA_RD_DMA / FA_AXI_RD_MASTER / core ingress`
   - 扩大读入宽度
4. `FA_PV_CORE_REAL`
5. `FA_QK_CORE_REAL`
6. `FA_OACC_UPDATE_REAL`
7. `FA_WR_DMA`
8. `FA_SCORE_POST_REAL`

## 10. 最终建议

当前 baseline 最值得优先改的并不是 `QK/PV` 算术核，而是：

- **调度器**
- **row-state**
- **读入带宽**

最关键的一句话是：

> 如果只做一个优化，先做 `FA_TILE_SCHED` 的 causal fully-masked tile 跳过；这是当前收益最大、风险最低、最可能直接把 baseline 拉进目标周期的修改。

