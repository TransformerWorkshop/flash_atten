# GEMM_V3

RTL: [`rtl/gemm_v3.v`](../../../rtl/gemm_v3.v)

`GEMM_V3` 是参数化 GEMM 阵列。当前 FA baseline 通过 `FA_QK_PV_SHARED_CORE_REAL` 以 `X_DIM=4`、`Y_DIM=16` 使用它，QK/PV 共用同一套 PE array。

```text
+--------------------------------------------------------------------------------+
| GEMM_V3                                                                         |
|                                                                                |
| start, num_acc                                                                  |
| a_valid/a_ready, a[X_DIM * WIDTH]                                               |
| b_valid/b_ready, b[Y_DIM * WIDTH]                                               |
|        |                                                                       |
|        v                                                                       |
| +------------------+                                                            |
| | start gate       | all PE start_ready && ready_tile_count < 2                |
| +--------+---------+                                                            |
|          | start_accept                                                         |
|          v                                                                      |
| +--------------------------------------------------------------------------------+
| | PE array: X_DIM x Y_DIM GEMU_V3                                               |
| |                                                                                |
| |   a row i -> every PE in row i                                                |
| |   b col j -> every PE in col j                                                |
| |   each PE accumulates num_acc packed-lane products                            |
| +--------------------------------------+----------------------------------------+
|                                        | PE output FIFOs                         |
|                                        v                                        |
| +------------------+  grouped output   +------------------------------------+  |
| | stream selector  |------------------>| m_group_data, m_group_idx, m_last   |  |
| | row or column    |                   | m_group_valid/ready                 |  |
| +------------------+                   +------------------------------------+  |
+--------------------------------------------------------------------------------+
```

关键参数：

| 参数 | 含义 |
|---|---|
| `WIDTH` | packed word 宽度，FA 中为 32 |
| `ELEM_WIDTH` | lane 宽度，FA 中为 16 |
| `PACK_LANES` | 每个 word 中的 lane 数，FA 中为 2 |
| `X_DIM/Y_DIM` | PE array 维度 |
| `OUTPUT_BY_ROW` | 输出 group 按行或按列聚合 |

输出流控制：

```text
PE tile done -> ready_tile_count + 1
last group streamed -> ready_tile_count - 1
stream_idx selects current output row/column group
```
