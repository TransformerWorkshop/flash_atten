# FA_QK_PV_SHARED_CORE_REAL

RTL: [`rtl/fa_cores_real.v`](../../../rtl/fa_cores_real.v)

`FA_QK_PV_SHARED_CORE_REAL` 复用同一个 4x16 `GEMM_V3` 阵列完成 QK 和 PV 两类计算。综合主路径不再保存完整 QK/PV result row buffer，而是按 4 行 block 流出：QK 每块 `4 x 16 x 32b = 2048b`，PV 每块 `4 x 64 x 16b = 4096b`。`qk_result_tile_flat` 与 `pv_result_tile_flat` 仅作为仿真/debug 镜像保留。

当前 RTL 将控制与打包拆成独立子模块：

| 子模块 | 职责 |
|---|---|
| `FA_QK_PV_REQ_ARB` | 仲裁 QK/PV 请求，QK 优先，生成 `qk_req_ready/pv_req_ready` 与 fire pulse |
| `FA_QK_PV_STREAM_CTRL` | 维护 mode、`row_blk/col_blk`、issue/feed counters，驱动 Q/K/P/V 读端口和 GEMM valid/start/ready |
| `FA_QK_PV_RESULT_PACKER` | 将 GEMM output group 打包成 QK/PV 4-row block，维护 resp/done，并保留仿真 debug flat mirror |

```text
+--------------------------------------------------------------------------------+
| FA_QK_PV_SHARED_CORE_REAL                                                       |
|                                                                                |
| qk_req_valid / pv_req_valid                                                     |
|        |                                                                       |
|        v                                                                       |
| +------------------+ mode select +-----------------------------------------+   |
| | FA_QK_PV_REQ_ARB |------------>| FA_QK_PV_STREAM_CTRL                   |   |
| | QK has priority  |             | issue_count, feed_count, row_blk,col_blk |   |
| +------------------+             +-------------------+---------------------+   |
|                                                       |                         |
|                                                       v                         |
| QK mode: q/k reads                         +-------------------------------+   |
| q_rd_en/q_rd_addr -> Q buffer              | GEMM_V3                       |   |
| k_rd_en/k_rd_addr -> K buffer              | X_DIM=4, Y_DIM=16             |   |
|                                            | num_acc=32 for QK             |   |
| PV mode: p/v reads                         | num_acc=8 for PV              |   |
| p_rd_en/p_rd_addr -> P bypass              +---------------+---------------+   |
| v_rd_en/v_rd_addr -> V PV buffer                           |                   |
|                                                            v                   |
|                                            +-------------------------------+   |
|                                            | FA_QK_PV_RESULT_PACKER         |   |
|                                            | QK block: 4 x 16 score words   |   |
|                                            | PV block: 4 x 64 partial lanes |   |
|                                            +---------------+---------------+   |
|                                                            |                   |
|                          qk_block_valid/ready/data/row_base                    |
|                          pv_block_valid/ready/data/row_base                    |
|                          qk_resp_valid/qk_done_pulse                           |
|                          pv_resp_valid/pv_done_pulse                           |
+--------------------------------------------------------------------------------+
```

模式差异：

| 模式 | 输入 A | 输入 B | `num_acc` | 输出 |
|---|---|---|---:|---|
| QK | Q rows from `FA_Q_BUF_REAL` | K rows from `FA_K_BUF_REAL` | 32 | four `4x16` Q16.16 score blocks |
| PV | P rows from `FA_P_BYPASS_REAL` | V rows from `FA_V_BUF_PV_REAL` | 8 | four `4x64` Q8.8 partial O blocks |

矩阵形状：

```text
QK: Q[16 x 64] * K^T[64 x 16] -> score[16 x 16]
    GEMM shape per row block: 4 x 16, repeated for row_blk 0..3

PV: P[16 x 16] * V[16 x 64] -> partial_O[16 x 64]
    GEMM shape per row/col block: 4 x 16, col_blk 0..3 are packed into one 4 x 64 block
```

FSM：

```text
ST_IDLE --qk_req/pv_req--> ST_STREAM
ST_STREAM issues buffer reads and feeds GEMM
ST_COLLECT waits for GEMM groups
QK emits one block after each row_blk 0..3
PV emits one block after each row_blk, after collecting col_blk 0..3
QK/PV response fires after the final block of the tile
```

封装边界：

```text
REQ_ARB:
  stream_idle + outstanding resp/block flags + qk_req_valid/pv_req_valid
  -> qk_req_ready/pv_req_ready + qk_req_fire/pv_req_fire

STREAM_CTRL:
  request fire + source valid + GEMM ready + block backpressure
  -> buffer read enables, GEMM start/feed, mode/row_blk/col_blk

RESULT_PACKER:
  GEMM output group + mode/row_blk/col_blk
  -> qk_block/pv_block, qk_resp/pv_resp, debug flat mirrors
```

面积取向：QK 与 PV 共享一套小 GEMM 阵列，并移除综合主路径中的 QK/PV result row buffers。代价是 QK/PV 串行执行，且 block valid 未被消费时 stream controller 会暂停下一块读取，最坏每个 block 增加 1 个 bubble。
