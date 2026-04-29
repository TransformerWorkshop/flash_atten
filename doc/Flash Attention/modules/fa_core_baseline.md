# FA_CORE_BASELINE

RTL: [`rtl/fa_core_baseline.v`](../../../rtl/fa_core_baseline.v)

`FA_CORE_BASELINE` 是 Flash Attention 主数据通路，连接运行控制、tile 调度、读写 DMA、片上 buffer、共享 QK/PV GEMM、online softmax 和 OACC 更新。

```text
+----------------------------------------------------------------------------------+
| FA_CORE_BASELINE                                                                  |
|                                                                                  |
| Control:                                                                         |
|   CSR/config -> FA_RUN_CTRL <-> FA_TILE_SCHED -> stage valid/ready/done pulses   |
|                                                                                  |
| Load and storage:                                                                 |
|   rd_desc/rd_beat <-> FA_RD_DMA -> Q_BUF, K_BUF, V_BUF, V_BUF_PV                 |
|                                                                                  |
| QK and softmax:                                                                   |
|   Q_BUF + K_BUF -> FA_QK_PV_SHARED_CORE_REAL(QK mode) -> 4-row QK blocks         |
|        -> FA_SCORE_POST_REAL -> 4-row masked blocks + valid -> FA_ROW_STATE_REAL |
|        -> p_tile_flat and rescale_vec_flat                                       |
|                                                                                  |
| PV and accumulation:                                                              |
|   p_tile_flat -> FA_P_BYPASS_REAL ----+                                          |
|                                       v                                          |
|   V_BUF_PV -----------------------> FA_QK_PV_SHARED_CORE_REAL(PV mode)           |
|                                      | 4-row PV partial blocks                    |
|                                      v                                           |
|   rescale_vec_flat -------------> FA_OACC_UPDATE_REAL <-> FA_OACC_BUF_REAL       |
|                                                                                  |
| Store:                                                                            |
|   FA_OACC_BUF_REAL export rows -> FA_WR_DMA -> wr_desc/wr_data                   |
+----------------------------------------------------------------------------------+
```

关键路径：

| 路径 | 说明 |
|---|---|
| 控制路径 | `FA_RUN_CTRL` 管理 run lifecycle；`FA_TILE_SCHED` 发出每个阶段的 valid/ready/done 请求 |
| 读路径 | `FA_RD_DMA` 生成 Q/K/V descriptor，并把 128-bit beat 拆写入 Q/K/V buffer |
| QK 路径 | Q/K buffer 供数给共享 GEMM，QK score 以 4-row block 直接进入 score post |
| softmax 路径 | score post 执行 scale/mask 并输出显式 valid mask，row state 按 4-row block 更新 `m/l` 并输出完整 `p_tile` 与 `rescale_vec` |
| PV/OACC 路径 | P bypass 和 V PV layout 供 PV GEMM，PV partial 以 4-row block 进入 OACC update，执行 `old * rescale + PV` |
| 写路径 | OACC buffer 导出 O rows，`FA_WR_DMA` 生成写 descriptor 和 packed data |

调度语义：`FA_TILE_SCHED` 仍保留 `QK -> SCORE -> ROW_UPDATE -> PV -> OACC_UPDATE` 的阶段边界；baseline 内部用 4 个 block 完成计数把 streaming 子阶段折叠成原有的 done pulse。因此外部阶段顺序不变，但 QK/PV 结果取出与 score/OACC 后处理已经流水化。
