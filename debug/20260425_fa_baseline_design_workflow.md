# FA Baseline 设计与实现工作流程说明

- 时间：`2026-04-25`
- 文档目的：
  - 复盘当前 baseline 是如何一步步设计出来的
  - 说明为什么采用“并行新 top + 分阶段替换代理”的路线
  - 给后续继续迭代、复用或扩展的人一个清晰的工程工作流

## 1. 设计工作的起点

本项目的 attention baseline 不是从零白纸开始，而是从一个已有仓库出发：

- 仓库里已有 `PT_V3`
- 已有 `PT_DMA_TOP / PT_DMA_TOP_V3`
- 已有 `PT_DMA_TOP_V3_SHELL_SIM`

因此最早的设计工作不是“直接写代码”，而是先回答一个架构问题：

**是继续扩 `PT_DMA_TOP_V3`，还是新建一个 attention-native top？**

这个问题决定了后面所有工作流。

## 2. 前期调研阶段

### 2.1 目标

前期调研做的事情主要有三类：

1. 从题面 PDF 中提炼 baseline 要求
2. 看仓库里哪些模块有复用价值
3. 比较不同方案的成本、风险和收益

### 2.2 产出

这部分工作的总结文档是：

- [`debug/20260424_attention_operator_space_sop.md`](./20260424_attention_operator_space_sop.md)

### 2.3 核心结论

前期调研最后收敛到几个关键判断：

1. 题面要的是 attention-native operator space，不是 PT 低层 opcode space
2. `PT_DMA_TOP_V3` 的控制语义偏 descriptor mailbox，不适合作为最终 baseline top
3. 最有复用价值的是：
   - banked memory / SRAM 骨架
   - DMA fill/export 思路
   - tile GEMM 子核思路
4. 最不适合直接复用的是：
   - `PT_DISPATCH`
   - `PT_MALLOC`
   - `PT_DMA_TOP_V3` 的控制语义

这一步本质上是把“能不能做”转成“该怎么做”。

## 3. 方案选择阶段

前面调研后，其实出现过几条可选路线：

- 只改接口
- 用 wrapper 强拆 attention 成 PT 指令
- 混合内核
- 并行新顶层
- 仿真壳先行

最后选择的是：

**并行新顶层 + 分阶段真实化**

原因很直接：

### 3.1 为什么不是继续扩 `PT_DMA_TOP_V3`

因为它的问题不在于“代码写得不够多”，而在于抽象层级不对。

`PT_DMA_TOP_V3` 更像：

- 低层矩阵算子 wrapper

而 baseline attention 需要的是：

- `Q/K/V/O` 语义
- row-state 语义
- online softmax 语义
- causal 语义

如果硬把这些全塞进原有 PT wrapper，最终会得到：

- 控制面很乱
- 验证面很大
- 可解释性很差

### 3.2 为什么不是“一次把所有 RTL 全写完”

因为 attention baseline 不是单一模块，而是一条长链路：

- CSR
- scheduler
- DMA
- buffers
- `QK`
- `score_post`
- `row_state`
- `PV`
- `OACC update`
- writeback

如果一次性全做：

- 定位问题很难
- 数值 bug 与协议 bug 会混在一起
- 工程风险太高

因此设计工作流选择了：

**先把系统骨架建起来，再逐阶段把代理换成真 RTL。**

## 4. 分阶段工作流总览

当前 baseline 是按 Stage 1 到 Stage 6 逐步推进的。

### 4.1 Stage 1-2

目标：

- 先把新算子框架建起来
- 用 behavioral RTL 代理跑通 baseline 闭环

主要动作：

- 新建 `FA_TOP_BASELINE_SIM`
- 新建 `FA_CSR / FA_RUN_CTRL / FA_TILE_SCHED / FA_RD_DMA / FA_WR_DMA`
- 建本地 buffers
- 用 proxy 代替尚未实现的算子块

这一阶段的价值不是“最终交付”，而是：

- 先锁住接口
- 先锁住 tile traversal
- 先锁住验证环境

### 4.2 Stage 3

目标：

- 把 `QK/PV` 从行为代理换成真实硬件主路径

主要动作：

- 引入 `FA_QK_CORE_REAL`
- 引入 `FA_PV_CORE_REAL`
- 补 `V_BUF_PV_REAL`
- 把 buffer 组织改成真实主路径

这一阶段解决的是：

- attention 最重的两段矩阵计算不再是 proxy

### 4.3 Stage 4

目标：

- 把 `score_post + row_state` 真实化

主要动作：

- 引入 `FA_SCORE_POST_REAL`
- 引入 `FA_ROW_STATE_REAL`
- 引入 `FA_RECIP_Q16_16`
- 用 LUT 实现 `exp`

这一阶段解决的是：

- baseline 最关键的 online softmax 状态机真正下沉 RTL

### 4.4 Stage 5

目标：

- 把 `OACC update` 真实化

主要动作：

- 引入 `FA_OACC_UPDATE_REAL`
- 把 `OACC_BUF_REAL` 扩成真实 row read/write/export 主路径

这一阶段做完后，attention 主数据通路就已经基本全真 RTL。

### 4.5 Stage 6

目标：

- 做接口收敛和交付化

主要动作：

- 抽出 `FA_CORE_BASELINE`
- 保留 `FA_TOP_BASELINE_SIM`
- 新增 `FA_TOP_BASELINE`
- 新增 `FA_AXI_RD_MASTER / FA_AXI_WR_MASTER`
- 加 `RD_BYTES / WR_BYTES`
- 加对齐错误控制

这一阶段的重点不是算法，而是：

- 结构收敛
- formal top 建立
- sim top / formal top 分层

## 5. 为什么这个工作流有效

### 5.1 先锁边界，再换实现

这个工作流的核心原则是：

> 先把模块边界和验证边界锁住，再逐个替换内部实现。

这比“先把代码写出来再想怎么测”稳得多。

### 5.2 代理模块必须也是 RTL

设计过程中刻意避免了一个危险做法：

- 不让 cocotb 直接驱动内部算法输出

而是要求代理也写成 RTL 模块。

这样带来的好处是：

- 后续替换是 module-for-module
- 调度器和握手协议从第一天起就是真的

### 5.3 系统模块优先于算法模块

整个流程里，优先做真的不是 softmax，而是：

- top shell
- scheduler
- DMA
- buffers

原因是：

- 这些模块一旦接口长歪，后面返工成本最高
- 算法模块即使一开始先代理，后面也能较平滑地替换

### 5.4 避免“一步到位”的大爆炸风险

通过 stage 化推进，每一阶段都有明确“冻结项”：

- 数据格式
- tile 形状
- 控制协议
- 接口命名
- 验收测试

这样每个阶段结束时都能留下可运行、可交接的状态。

## 6. 当前工作流中的复用策略

整个设计流程不是“全新重写”，而是有明确复用边界。

### 6.1 被复用的资产

高价值复用主要集中在：

- `PT_MEM_BANK`
- `PT_M_MEM`
- `GEMM_V3 / GEMU_V3` 的阵列思路
- DMA fill/export 骨架

### 6.2 不复用的部分

刻意不复用的是：

- `PT_DISPATCH`
- `PT_MALLOC`
- `PT_DMA_TOP_V3` 的 operator/control 语义

### 6.3 为什么这样切

因为原仓库里真正成熟且通用的是：

- 数据路径底座

而不是：

- attention 顶层控制语义

工作流里正是沿着这个边界，做了“复用底座、重建语义”的选择。

## 7. 当前工作流中的验证方法

### 7.1 验证不是等最后一起做

整个过程不是“代码写完再测”，而是每阶段都带验证：

- Stage 1/2
  - smoke
  - 单块功能
  - full baseline causal/non-causal
- Stage 3
  - `QK` tile test
  - `PV` tile test
  - `V_BUF_PV` layout test
- Stage 4
  - `score_post` 定位测试
  - `row_state` 定位测试
- Stage 5
  - `OACC update` 定位测试
- Stage 6
  - sim wrapper smoke
  - AXI alignment error
  - AXI suite 接入

### 7.2 为什么要做定位性测试

因为 attention baseline 是长链路。

如果只有端到端测试：

- 数值一旦错，几乎无法快速判断是：
  - `QK`
  - `score`
  - `row_state`
  - `PV`
  - `OACC`
  - DMA
  - 调度

所以工作流里一直要求：

- 每替换一个大模块，就补一组定位测试

### 7.3 sim top 与 formal top 双轨并行

Stage 6 的关键验证方法是：

- `FA_TOP_BASELINE_SIM`
  - 保持算法回归主入口
- `FA_TOP_BASELINE`
  - 单独做协议/接口验证

这比只保留一个 top 稳得多。

## 8. 设计工作流里的关键工程原则

当前 baseline 的工作流里，有几个非常关键的工程原则。

### 8.1 保持问题可定位

每个阶段只改一类问题：

- Stage 3 主要改 compute
- Stage 4 主要改 online softmax
- Stage 5 主要改 OACC
- Stage 6 主要改接口与交付

这样问题才可定位。

### 8.2 不轻易改已冻结的外部协议

一旦某阶段把：

- CSR map
- tile layout
- valid/ready 规则
- shell DMA 语义

锁住，后面就尽量不动。

否则测试环境和文档都要重写。

### 8.3 sim 可见性与 formal 交付分离

sim top 保留：

- `tile_flat`
- row-state debug
- 中间 tile 可见性

formal top 则隐藏这些信号。

这是很典型、也很正确的工作流做法。

### 8.4 验证优先于“看起来更完整”

Stage 6 中，即使 formal AXI top 已经建成，也没有为了“看起来完全结束”而强行宣称所有长跑验证都闭环。

这个工作流强调的是：

- 代码结构落地是一个里程碑
- 验证完全闭环是另一个里程碑

两者要区分。

## 9. 当前工作流带来的最终结果

经过这套流程，当前 baseline 已经形成：

1. 一份可共享的 core
2. 一份继续做算法回归的 sim top
3. 一份正式交付的 AXI top
4. 一套分阶段积累下来的 cocotb 测试资产
5. 一条清晰的后续路线：
   - 完整 AXI 长跑回归
   - 性能/面积评估
   - 优化和收尾

这说明当前工作流是成功的。

## 10. 如果后面继续推进，推荐沿用的流程

后续如果继续做：

- AXI 长跑验证
- 性能优化
- 多 head
- 更长序列
- 更大位宽/不同数据格式

仍然建议沿用当前这套工作流：

1. 先明确需求变化
2. 先判断复用边界
3. 先锁接口
4. 先补最小可运行骨架
5. 再逐模块真实化
6. 每步都配套定位测试

不要回退成：

- 一次性大改
- 写完再测
- 只靠端到端 case 定位

## 11. 一句话总结

如果要用一句话总结当前 baseline 的设计工作流，可以这样说：

> 当前 baseline 是按“先调研和选型，再搭新 top 框架，再用代理锁住接口与验证环境，再分阶段把 `QK/PV`、`score/row_state`、`OACC` 逐个真实化，最后再抽共享 core 并补 formal AXI top”的路线推进的，这条路线的核心价值在于可定位、可复用、可验证和可交付。

