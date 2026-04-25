# FA Baseline 控制流程说明

- 时间：`2026-04-25`
- 文档目的：
  - 说明当前 baseline 的控制面、调度面和握手关系
  - 区分 CSR 控制、run 生命周期、tile 级状态机和 AXI/DMA 事务层
  - 帮助阅读者理解“谁在什么时候驱动谁”

## 1. 控制流总览

当前 baseline 的控制流可以拆成四层：

1. `CSR 层`
   - 负责软件可见寄存器和启动条件
2. `Run 生命周期层`
   - 负责 `busy/done/error/cycles`
3. `Tile 调度层`
   - 负责 `q_blk/kv_blk` 遍历和阶段顺序
4. `数据搬运与执行层`
   - 负责具体的 load / compute / store 握手

对应主要模块：

- `FA_CSR`
- `FA_RUN_CTRL`
- `FA_TILE_SCHED`
- `FA_RD_DMA`
- `FA_WR_DMA`
- 各个 compute/buffer 模块

## 2. CSR 控制层

### 2.1 寄存器面

CSR 目前是 baseline 风格寄存器空间：

- `CTRL`
- `STATUS`
- `CFG`
- `Q/K/V/O_BASE`
- `STRIDE_BYTES`
- `NEG_LARGE`
- `SCALE`
- `CYCLES`
- `RD_BYTES`
- `WR_BYTES`

对应文件：

- [`rtl/csr_array.v`](../rtl/csr_array.v)
- [`rtl/fa_csr.v`](../rtl/fa_csr.v)

### 2.2 `FA_CSR` 的职责

`FA_CSR` 不做调度，只做三件事：

1. 把 AXI-Lite 寄存器写入转成内部配置寄存
2. 把 `CTRL.START` / `CTRL.SOFT_RESET` 转成脉冲
3. 把内部状态反映到 `STATUS/CYCLES/RD_BYTES/WR_BYTES`

### 2.3 `start_pulse` 生成规则

当前 `start_pulse` 满足：

- `CTRL.START` 上升沿触发
- 同时必须满足配置合法

在 Stage 6 中增加了配置合法性检查：

- `Q/K/V/O_BASE` 必须 16-byte 对齐
- `STRIDE_BYTES` 必须 16-byte 对齐

如果不满足：

- `config_error = 1`
- `start_pulse` 被抑制
- `STATUS.ERROR` 置位

### 2.4 `soft_reset_pulse` 规则

`soft_reset_pulse` 是 `CTRL.SOFT_RESET` 的上升沿脉冲。

它会清除：

- run active
- done/error sticky
- cycle counter
- byte counters
- 内部运行状态机

## 3. Run 生命周期层

### 3.1 模块

- [`rtl/fa_run_ctrl.v`](../rtl/fa_run_ctrl.v)

### 3.2 输入

`FA_RUN_CTRL` 主要看这些事件：

- `start_pulse`
- `soft_reset_pulse`
- `run_complete_pulse`
- `run_error_pulse`

### 3.3 输出

它维护：

- `run_active`
- `busy`
- `done_sticky`
- `error_sticky`
- `cycles`

### 3.4 生命周期规则

启动：

- `start_pulse && !run_active`
  - 置 `run_active = 1`
  - 清 `done/error`
  - `cycles = 0`

运行中：

- 每拍 `cycles++`

正常结束：

- 收到 `run_complete_pulse`
  - `run_active = 0`
  - `done_sticky = 1`

错误结束：

- 收到 `run_error_pulse`
  - `run_active = 0`
  - `error_sticky = 1`

### 3.5 error 来源

当前 error 主要来自两类：

1. core 内的运行错误
   - 例如 shell read last 错误
2. formal top 的 AXI 适配层错误
   - `RRESP != OKAY`
   - `BRESP != OKAY`
   - burst 结束条件错误

在 `FA_TOP_BASELINE` 里，这些 AXI error 会先进入：

- `rd_axi_error_pulse`
- `wr_axi_error_pulse`

然后：

- 一方面进入 `axi_error_sticky_r`
- 另一方面通过 `ext_error_pulse` 送入 `FA_CORE_BASELINE`

## 4. Tile 调度层

### 4.1 模块

- [`rtl/fa_tile_sched.v`](../rtl/fa_tile_sched.v)

### 4.2 调度层的核心职责

`FA_TILE_SCHED` 不管数据内容，只管时序顺序。

它要回答的问题是：

- 现在轮到哪个 `q_blk`
- 现在轮到哪个 `kv_blk`
- 当前应该发起 `load / init / clear / qk / score / row / pv / oacc / store` 中的哪个阶段

### 4.3 主要状态

状态机固定为：

- `ST_IDLE`
- `ST_Q_LOAD_REQ`
- `ST_Q_LOAD_WAIT`
- `ST_ROW_INIT_REQ`
- `ST_ROW_INIT_WAIT`
- `ST_OACC_CLEAR_REQ`
- `ST_OACC_CLEAR_WAIT`
- `ST_K_LOAD_REQ`
- `ST_K_LOAD_WAIT`
- `ST_V_LOAD_REQ`
- `ST_V_LOAD_WAIT`
- `ST_QK_REQ`
- `ST_QK_WAIT`
- `ST_SCORE_REQ`
- `ST_SCORE_WAIT`
- `ST_ROW_UPDATE_REQ`
- `ST_ROW_UPDATE_WAIT`
- `ST_PV_REQ`
- `ST_PV_WAIT`
- `ST_OACC_UPDATE_REQ`
- `ST_OACC_UPDATE_WAIT`
- `ST_STORE_REQ`
- `ST_STORE_WAIT`

### 4.4 每个 `q_blk` 的固定流程

一个 `q_blk` 的完整控制顺序是：

1. 发 `Q load`
2. 发 `row init`
3. 发 `OACC clear`
4. 对每个 `kv_blk`：
   - `K load`
   - `V load`
   - `QK`
   - `score`
   - `row update`
   - `PV`
   - `OACC update`
5. 发 `store`

### 4.5 block 计数器更新规则

`kv_blk`

- 初始是 0
- 每完成一次 `OACC update` 后加 1
- 到 15 后进入 `store`

`q_blk`

- 每完成一次 `store` 后加 1
- 到 15 时产生 `run_complete_pulse`

### 4.6 握手规则

调度器统一采用：

- `*_req_valid`
- `*_req_ready`
- `*_done_pulse`

三段式控制。

也就是说：

1. 调度器在 `REQ` 状态拉高 `valid`
2. 等对端 `ready`
3. 进入 `WAIT`
4. 等对端 `done_pulse`
5. 再切到下一阶段

这让模块内部 latency 可以变化，而不会破坏上层顺序。

## 5. Core 内部子模块控制关系

### 5.1 `row_update_done_pulse` 的特殊处理

这里有一个重要细节：

- `FA_ROW_STATE_REAL` 产出 `p_tile_flat`
- `FA_P_BUF_REAL` 要先把这块 `P` 接收下来

因此 core 内部没有直接把 `row_state.done_pulse` 交给调度器，而是：

- `row_update_ready = row_state_ready && p_buf_load_ready`
- `row_update_done_pulse = p_buf_load_done_pulse`

这意味着对调度器而言：

- “row update 完成”不是 `row_state` 内部算完的那一拍
- 而是 `P tile` 已经正式装入 `P_BUF` 的那一拍

这能避免后续 `PV` 提前启动。

### 5.2 `OACC update` 的控制关系

`FA_OACC_UPDATE_REAL` 与 `OACC_BUF_REAL` 之间是行级交互：

- `oacc_row_rd_en/addr`
- `oacc_row_rd_valid/data`
- `oacc_row_wr_en/addr/data`

对调度器而言，它仍然只看到：

- `oacc_update_valid`
- `oacc_update_ready`
- `oacc_update_done_pulse`

### 5.3 `store` 的控制关系

`store_req_valid` 发给 `FA_WR_DMA`。

`FA_WR_DMA` 会在内部进一步做：

1. 写描述符
2. 逐行从 `OACC` 导出
3. 送出写数据流

最后再通过 `done_pulse` 告知调度器一整个 `store` 已完成。

## 6. 读路径控制流

### 6.1 `FA_RD_DMA`

`FA_RD_DMA` 是 shell/DMA 读路径控制器。

它有三种 load kind：

- `LOAD_KIND_Q`
- `LOAD_KIND_K`
- `LOAD_KIND_V`

### 6.2 内部状态

它的状态比较简单：

- `ST_IDLE`
- `ST_DESC`
- `ST_DATA`

### 6.3 工作过程

当调度器发起 load：

1. `req_valid` 到来
2. 锁存：
   - `req_kind`
   - `req_q_blk`
   - `req_kv_blk`
3. 计算 block 地址
4. 发出读描述符
5. 进入 `ST_DATA`
6. 接收 512 个 32-bit word
7. 每个 word 映射到：
   - `qkv_wr_row`
   - `qkv_wr_lane`
8. 如果是 `V`
   - 同时生成 `v_pv_wr_*`

### 6.4 完成和错误

正常：

- 第 512 个 word 且 `rd_data_last=1`
  - `done_pulse=1`

错误：

- 未到结尾提前 `rd_data_last`
- 到结尾却没有 `rd_data_last`

这类错误会形成 `rd_error_pulse`，再送到 `FA_RUN_CTRL`。

## 7. 写路径控制流

### 7.1 `FA_WR_DMA`

`FA_WR_DMA` 负责把一个 `q_blk` 的最终输出 tile 写回。

### 7.2 内部状态

它的状态是：

- `ST_IDLE`
- `ST_DESC`
- `ST_REQ_ROW`
- `ST_WAIT_ROW`
- `ST_DATA`

### 7.3 工作过程

当调度器发 `store_req_valid`：

1. 计算当前 `q_blk` 的 `O` 写回地址
2. 发写描述符
3. 从 `OACC_BUF_REAL` 请求第 0 行
4. 等 row data 返回
5. 连续送出该行 32 个 word
6. 换下一行
7. 到第 15 行第 31 个 word 时：
   - `wr_data_last=1`
   - `done_pulse=1`

### 7.4 调度层看到的语义

调度器不关心 row 级细节，只关心：

- 请求接收没接收
- store 完没完成

因此 `store` 对上层来说是一个单事务。

## 8. Formal AXI top 的控制流

### 8.1 顶层结构

在 [`rtl/fa_top_baseline.v`](../rtl/fa_top_baseline.v) 中：

- `FA_CSR` 负责软件侧寄存器
- `FA_CORE_BASELINE` 负责抽象算子执行
- `FA_AXI_RD_MASTER` 负责 read descriptor -> AXI read burst
- `FA_AXI_WR_MASTER` 负责 write descriptor/data -> AXI write burst

### 8.2 `FA_AXI_RD_MASTER`

它的职责是：

1. 接一条抽象读描述符
2. 把 `rd_desc_words` 转成多个 128-bit read burst
3. 接收 AXI `RDATA`
4. 重新拆成 32-bit word 流给 core

关键固定策略：

- `WORDS_PER_BEAT = 4`
- `MAX_BURST_BEATS = 16`
- `ARSIZE = 128-bit`
- 单 outstanding

### 8.3 `FA_AXI_WR_MASTER`

它的职责是：

1. 接一条抽象写描述符
2. 接收 core 送来的 32-bit word 流
3. 每四个 word 打成一个 128-bit `WDATA`
4. 发 AXI write burst
5. 等 `BRESP`

同样固定：

- 每拍 128-bit
- burst 最长 16 beat
- 单 outstanding

### 8.4 AXI 错误控制

如果出现：

- `RRESP != OKAY`
- `BRESP != OKAY`
- `RLAST` 与预期不一致

则：

- 对应 AXI wrapper 产生 `error_pulse`
- `FA_TOP_BASELINE` 把它记入 `axi_error_sticky_r`
- 同时通过 `ext_error_pulse` 反馈到 core

最终用户可在 `STATUS.ERROR` 看到错误结果。

## 9. Byte counter 控制

在 `FA_CORE_BASELINE` 中有：

- `rd_bytes_r`
- `wr_bytes_r`

### 9.1 计数规则

当前计数不是统计 AXI beat，而是统计抽象 shell 接口上的有效 payload：

- 每当 `rd_data_valid && rd_data_ready`
  - `rd_bytes += 4`
- 每当 `wr_data_valid && wr_data_ready`
  - `wr_bytes += 4`

### 9.2 清零时机

它们会在以下时机清零：

- `clear`
- `soft_reset_pulse`
- `start_pulse`

这意味着：

- 一次 run 的带宽统计是自洽的

## 10. Sim top 与 formal top 的控制差异

### 10.1 相同点

两者共享：

- 同一个 `FA_CORE_BASELINE`
- 同一套调度器
- 同一套算子主路径
- 同一套 `busy/done/error/cycles/rd_bytes/wr_bytes` 语义

### 10.2 不同点

`FA_TOP_BASELINE_SIM`

- 外部直接提供 shell-DMA 端口
- 更适合 cocotb 构造 memory model
- 保留大量 debug 可见性

`FA_TOP_BASELINE`

- 外部提供 AXI4 master
- 适合正式交付
- 不对外暴露内部 debug 观测线

## 11. 当前控制流设计的特点

### 11.1 分层清楚

CSR、run 生命周期、tile 调度、DMA/AXI 适配是分开的。

### 11.2 上层不依赖具体 latency

调度器依赖的是：

- `ready`
- `done_pulse`

而不是固定 cycle 数。

### 11.3 shell 语义与 AXI 语义已解耦

core 只理解“描述符 + word stream”，不理解 AXI burst 细节。

### 11.4 错误传播路径清晰

无论错误来自：

- CSR 配置
- shell read/write
- AXI protocol

最终都能收敛到：

- `STATUS.ERROR`
- `irq`
- `run_active` 被拉低

## 12. 一句话总结

如果要用一句话描述当前 baseline 的控制流程，可以这样说：

> 软件先通过 CSR 配置一次 run，`FA_RUN_CTRL` 拉起生命周期，`FA_TILE_SCHED` 以固定顺序驱动 `Q load -> row init -> OACC clear -> (K load -> V load -> QK -> score -> row -> PV -> OACC) x 16 -> store`，而 sim top 或 AXI top 只是在 core 外围分别提供 shell-DMA 或 AXI burst 适配。

