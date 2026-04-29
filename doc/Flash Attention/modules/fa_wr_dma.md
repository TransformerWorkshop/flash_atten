# FA_WR_DMA

RTL: [`rtl/fa_dma_shell.v`](../../../rtl/fa_dma_shell.v)

`FA_WR_DMA` 是 core 内部写搬运单元。它接收 store 请求，从 OACC buffer 导出 16 行 O 数据，并生成写 descriptor 和 32-bit packed write stream。

```text
+--------------------------------------------------------------------------------+
| FA_WR_DMA                                                                       |
|                                                                                |
| store request from scheduler                                                    |
| req_valid, req_q_blk, req_head_idx, o_base, stride_bytes, head_stride_bytes      |
|        |                                                                       |
|        v                                                                       |
| +----------------+  wr_desc_*  +-------------------------------------------+   |
| | O address gen  |------------>| top write master                           |   |
| | 16-row tile    |             | wr_desc_addr, wr_desc_words=512            |   |
| +-------+--------+             +-------------------------------------------+   |
|         |                                                                      |
|         | row export read                                                      |
|         v                                                                      |
| +----------------+  oacc_exp_rd_*  +--------------------------------------+    |
| | row walker     |---------------->| FA_OACC_BUF_REAL export port          |    |
| | row 0..15      |<----------------| 1024-bit row, packed Q8.8 pairs       |    |
| +-------+--------+                 +--------------------------------------+    |
|         |                                                                      |
|         | 32 words per row                                                     |
|         v                                                                      |
| +----------------+  wr_data/wr_data_last  +-------------------------------+   |
| | word streamer  |----------------------->| top write master               |   |
| +----------------+                        +-------------------------------+   |
|                                                                                |
| done_pulse after row 15 word 31 is accepted.                                   |
+--------------------------------------------------------------------------------+
```

FSM：

```text
ST_IDLE --req_valid--> ST_DESC --wr_desc_ready--> ST_REQ_ROW
ST_REQ_ROW -> ST_WAIT_ROW --oacc_exp_rd_valid--> ST_DATA
ST_DATA streams 32 words for the row
  -> next row ST_REQ_ROW
  -> after final word of row 15: ST_IDLE + done_pulse
```

输出约定：

| 输出 | 说明 |
|---|---|
| `wr_desc_words` | 固定 `512` 个 32-bit words |
| `wr_data` | 从 `oacc_exp_rd_data[(word_idx * 32) +: 32]` 输出 |
| `wr_data_last` | row 15 且 word 31 时置位 |
