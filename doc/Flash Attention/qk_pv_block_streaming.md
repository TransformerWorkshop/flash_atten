# QK/PV Block Streaming 技术方案

本文记录从完整 result row buffer 改为 4-row block streaming 的方案、接口、面积和时序估算。

## 目标

原方案在 shared QK/PV core 后保存完整结果：

```text
QK result buffer: 16 rows x 512 bits  =  8192 bits
PV result buffer: 16 rows x 1024 bits = 16384 bits
```

这些 buffer 很宽，带来寄存器/宏面积、读 mux、写 mask 和局部 fanout 压力。新的方案让 shared core 边算边输出 block：

```text
QK block: 4 rows x 16 cols x 32-bit score = 2048 bits
PV block: 4 rows x 64 cols x 16-bit partial = 4096 bits
```

## 数据流

```text
+----------------------+       qk_block        +----------------------+
| FA_QK_PV_SHARED_CORE |---------------------->| FA_SCORE_POST_REAL   |
| QK mode, row_blk 0..3| valid/ready,row_base  | scale + causal mask  |
+----------+-----------+                       +----------+-----------+
           |                                              |
           |                  masked_score_block + valid   v
           |                                      +----------------------+
           |                                      | FA_ROW_STATE_REAL    |
           |                                      | 4-row online update  |
           |                                      +----------+-----------+
           |                                                 |
           | p_tile/rescale                                  |
           v                                                 v
+----------------------+       pv_block        +----------------------+
| FA_QK_PV_SHARED_CORE |---------------------->| FA_OACC_UPDATE_REAL  |
| PV mode, row_blk 0..3| valid/ready,row_base  | 4-row OACC update    |
+----------------------+                       +----------------------+
```

`FA_TILE_SCHED` 的外部阶段语义不变。baseline 内部用 block done counter 把 4 个 streaming block 折叠成原来的 `score_done_pulse`、`row_update_done_pulse` 和 `oacc_update_done_pulse`。

`FA_QK_PV_SHARED_CORE_REAL` 内部已拆分成三个子模块：

| 子模块 | 功能 |
|---|---|
| `FA_QK_PV_ARB` | QK/PV 请求仲裁、GEMM A/B 输入选择与 `num_acc` 选择 |
| `FA_QK_PV_STREAM_CTRL` | stream FSM、读地址、GEMM start/feed、backpressure 处理 |
| `FA_QK_PV_RESULT_PACKER` | GEMM output group 到 QK/PV block 的打包，以及 resp/done/debug mirror |

## CDC 边界

本次 RTL 没有引入异步跨时钟域；所有新增接口仍在 core clock 下用 valid/ready 握手。这样变更最小，回归风险低。

如果后续物理实现需要跨时钟域降 fanout，可把下面两个边界替换为 2-entry async FIFO，而不改计算模块内部：

```text
qk_block_valid/ready/data/row_base
pv_block_valid/ready/data/row_base
```

建议 FIFO 深度为 2：1 个 entry 给消费者，1 个 entry 吸收 producer/consumer 的相位差。深度 1 也能工作，但更容易把 GEMM 输出 ready 拉到关键路径。

## 面积估算

| 项目 | 估算 |
|---|---:|
| 移除 QK/PV result row buffer 原始位数 | `24576` bits |
| 新增 QK/PV block 输出寄存器 | `6144` bits |
| 新增 score/row/OACC block latch | 约 `8192-10240` bits |
| 净寄存器位数变化 | 约减少 `4k-10k` bits |
| 直接 cell area 收益 | 约 `10k-25k` cell area |
| 若后续移除综合 debug full-tile 镜像 | 额外约 `5k-15k` cell area |

收益主要不只是 bit 数减少，还包括去掉 `512b/1024b` result row read mux、行读地址解码和宽写 mask fanout。基于旧 row-buffer 方向文档中 `QK/PV result row buffer saving = 30k-50k` 的量级，本次因新增 block latch 抵消一部分，保守按 `10k-25k` cell area 估算；最终需要 DC 更新确认。

## 时序估算

| 路径 | 影响 |
|---|---|
| GEMM -> result buffer 写 | 变为 GEMM -> block packer，写入宽度从整 tile row buffer 降为当前 block |
| result row buffer 读 mux | 主路径移除，score/OACC 直接消费 block |
| ready backpressure | block 未被消费时 stream controller 暂停下一块读取 |
| 额外 bubble | 最坏每个 QK/PV block 之间 1 cycle |
| Fmax 风险 | ready 信号可能穿过 consumer ready；可用 2-entry FIFO 切断 |

性能成本很小：每个有效 KV tile QK 4 个 block、PV 4 个 block，最坏新增约 `8` cycles/tile。即 causal `136` 个有效 tile 时约 `1088` cycles，non-causal `256` 个有效 tile 时约 `2048` cycles，仍远低于 `300k` 全运行 cycle 目标。

## 当前验证

已覆盖：

```text
iverilog FA_TOP_BASELINE
fa_shared_gemm focused tests
fa_baseline QK/score/row/PV focused tests
fa_full causal/noncausal end-to-end tests
fa_baseline single-Q full-KV backpressure test
fa_oacc_update standalone tests
```
