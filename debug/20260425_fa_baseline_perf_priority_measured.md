# FA Baseline 性能瓶颈与修改优先级

- 时间：`2026-04-25`
- 依据：
  - [`20260425_fa_baseline_profile_summary.md`](./20260425_fa_baseline_profile_summary.md)
  - [`20260425_fa_baseline_profile_causal.json`](./20260425_fa_baseline_profile_causal.json)
  - [`20260425_fa_baseline_rowstate_profile.json`](./20260425_fa_baseline_rowstate_profile.json)
- 口径：
  - `FA_TOP_BASELINE_SIM`
  - `S=256, d=64, causal`
  - 先对 `Q/K/V/QK/PV/OACC/store` 做早期 tile 的 RTL latency 采样
  - 再按 scheduler 的确定性触发次数外推全流程周期
  - `row_update` 额外用 `FA_ROW_STATE_REAL` 微基准修正 `masked` / `valid` 两类 tile latency

## 1. 总结论

当前 baseline 的 **估算总周期约为 `481,904 cycles`**。

这比 `<300k cycles` 的目标高出：

- **`181,904 cycles`**

当前最大的真实瓶颈不是 `score_post`、不是 `store`、也不是 `CSR`，而是：

1. `K load`
2. `V load`
3. `row_update`
4. `PV`
5. `QK`

## 2. 模块级拆账

| 模块 | 总周期 | 占比 | 结论 |
| --- | ---: | ---: | --- |
| `K load` | `131,584` | `27.31%` | S |
| `V load` | `131,584` | `27.31%` | S |
| `row_update` | `84,736` | `17.58%` | A |
| `PV` | `52,736` | `10.94%` | A |
| `QK` | `38,144` | `7.92%` | B |
| `OACC update` | `20,992` | `4.36%` | B |
| `store` | `8,992` | `1.87%` | C |
| `Q load` | `8,224` | `1.71%` | C |
| `score_post` | `4,608` | `0.96%` | C |
| `oacc_clear` | `272` | `0.06%` | D |
| `row_init` | `32` | `0.01%` | D |

补充：

- `K/V load` 合计 **`263,168 cycles`**，占 **`54.62%`**
- `row_update` 内部：
  - `future_masked`：`42 cycles/tile`
  - `history/diagonal(valid)`：`586 cycles/tile`
- `row_update` 真正重的是 `valid tile` 上的 `row_state + reciprocal`

## 3. 关键发现

### 3.1 最重瓶颈是读带宽，不是算子

当前 `32-bit word/cycle` 的读路径让 `Q/K/V` 每次 tile load 都是：

- `514 cycles`

其中最痛的是 `K/V` 被重复装入：

- `256` 次 `K load`
- `256` 次 `V load`

这单项就吞掉了总预算的一半以上。

### 3.2 `row_update` 比之前静态估算更明确

直接微基准得到：

- `masked row_update = 42 cycles`
- `valid row_update = 586 cycles`

因此 causal 模式下：

- `future-masked tile` 不重
- 真正该优化的是 `history + diagonal` 这 `136` 个有效 tile

### 3.3 `PV/QK` 已经不算头号矛盾，但仍然值得排队优化

当前实测：

- `PV = 206 cycles/tile`
- `QK = 149 cycles/tile`

它们不是第一顺位，但在大瓶颈处理后会成为下一层热点。

## 4. 修改优先级

这里的排序不是“单看收益最大”，而是综合：

- 风险
- 成本
- 收益
- 对 `<300k cycles` 目标的帮助

### Priority 1: 扩读带宽 / 减 `K/V/Q` load 周期

- 目标模块：
  - `FA_RD_DMA`
  - `FA_AXI_RD_MASTER`
  - `Q/K/V buffer write path`
- 建议方向：
  - 从 `32-bit/cycle` 提升到 `64-bit` 或 `128-bit/cycle`
  - 减少单 tile 的纯数据搬运拍数
- 收益：
  - `2x` 读宽约可省 **`135,696 cycles`**
  - `4x` 读宽约可省 **`203,280 cycles`**
- 风险：中低
- 成本：中
- 为什么排第 1：
  - 命中 **54.62%** 的最大瓶颈
  - 不改 attention 数学语义
  - 属于接口/搬运层改造，边界相对清晰
  - 如果做到约 `128-bit/cycle`，**单项就足以把总周期压到 `278,624`，直接进入 `<300k`**

### Priority 2: 优化 `row_update` 的 valid-tile 路径

- 目标模块：
  - `FA_ROW_STATE_REAL`
  - `FA_RECIP_Q16_16`
- 建议方向：
  - 降低 per-row reciprocal 等待
  - 提高 row 级并行度
  - 或把 reciprocal 从“每行串行等待”改成更深流水 / 更短 latency
- 收益：
  - 如果把 valid tile `586 -> 42 cycles`，约可省 **`73,984 cycles`**
- 风险：中高
- 成本：中高
- 为什么排第 2：
  - 是第二个真正有量级的热点
  - 但会碰 online softmax 数值路径，验证风险明显高于 DMA 宽化
  - 作为与 `2x` 读宽配套的第二步非常合适：
    - `2x 读宽 + row_update 优化` 估算可到 **`272,224 cycles`**

### Priority 3: `PV` 提速

- 目标模块：
  - `FA_PV_CORE_REAL`
  - `P/V read feed`
- 建议方向：
  - 提高 feed 宽度
  - 减少 `ISSUE/WAIT_RD/FEED` 回合数
- 收益：
  - 若近似做到 `2x`，约可省 **`24,576 cycles`**
- 风险：中
- 成本：中
- 为什么排第 3：
  - 占比已到 **10.94%**
  - 性能收益明确
  - 风险低于 `row_update` 数值改造

### Priority 4: `QK` 提速

- 目标模块：
  - `FA_QK_CORE_REAL`
  - `Q/K read feed`
- 建议方向：
  - 与 `PV` 类似，减少 feed 轮次和 collect 开销
- 收益：
  - 若近似做到 `2x`，约可省 **`18,176 cycles`**
- 风险：中
- 成本：中
- 为什么排第 4：
  - 比 `PV` 更轻
  - 但仍是稳定热点

### Priority 5: `OACC update` 提速

- 目标模块：
  - `FA_OACC_UPDATE_REAL`
  - `OACC row read/write`
- 建议方向：
  - 合并读改写节拍
  - 降低逐行串行开销
- 收益：
  - 若近似做到 `2x`，约可省 **`10,240 cycles`**
- 风险：中低
- 成本：中
- 为什么排第 5：
  - 它不是最大项
  - 更像第三梯队优化

### Priority 6: 写回、`Q load`、`score_post` 等尾项

- 这些模块都不是主矛盾
- 单独优化对总周期改善有限
- 适合作为主路径优化完成后的补边工作

## 5. 高收益但高风险的架构选项

### Strategic Option: `K/V` 跨 `q_blk` 复用

- 思路：
  - 不再让 `q_blk` 外层、`kv_blk` 内层每轮都重新装 `K/V`
  - 让一个 `K/V tile` 被多个 `q_blk` 复用
- 理论收益：
  - 约可省 **`246,720 cycles`**
  - 单项即可把总周期压到约 **`235,184 cycles`**
- 但问题是：
  - 需要重排调度顺序
  - 可能需要同时保留多个 `q_blk` 的 `row_state / OACC`
  - 会显著扩大状态和控制复杂度
- 结论：
  - **纯收益角度它最强**
  - **综合风险/成本角度它不该作为第一刀**
  - 更适合作为第二阶段架构重构，而不是当前最先落地的改动

## 6. 建议执行顺序

如果目标是尽快把当前版本推进到 `<300k cycles`，建议顺序是：

1. 先做 **读带宽提升**
2. 再做 **valid-tile `row_update` 优化**
3. 然后补 **`PV`**
4. 再补 **`QK`**

如果目标是追求更低的极限周期，而可以接受较大的控制重构，再考虑：

5. **`K/V` 跨 `q_blk` 复用**

## 7. 最终判断

当前 RTL 的优先级不应该按“哪个模块最复杂”排，而应该按“谁占总周期最多、又能在可控风险下尽快改掉”排。

所以最合理的结论是：

- **第一优先级：读路径宽化**
- **第二优先级：`row_update` valid-tile 路径**
- **第三优先级：`PV`**
- **第四优先级：`QK`**
- **高收益架构备选：`K/V` 复用**
