# FA_RD_DMA

RTL: [`rtl/fa_dma_shell.v`](../../../rtl/fa_dma_shell.v)

`FA_RD_DMA` 是 core 内部读搬运单元。它接收调度器的 Q/K/V load 请求，生成外部读 descriptor，并把返回的 128-bit beat 拆写到 tile buffers。

```text
+--------------------------------------------------------------------------------+
| FA_RD_DMA                                                                       |
|                                                                                |
| load request from scheduler                                                     |
| req_valid, req_kind, req_q_blk, req_kv_blk, req_head_idx                        |
| q_base/k_base/v_base, stride_bytes, head_stride_bytes                           |
|        |                                                                       |
|        v                                                                       |
| +----------------+   desc addr/words/tag   +-------------------------------+   |
| | address select |------------------------>| rd_desc_* to top read master   |   |
| | Q/K/V block    |                         | tag: Q=1, K=2, V=3            |   |
| +-------+--------+                         +-------------------------------+   |
|         |                                                                      |
|         | rd_beat_* from top read master                                        |
|         v                                                                      |
| +----------------+ qkv_wr_*     +------------------------------------------+   |
| | beat unpack    |------------->| Q/K/V tile buffers                       |   |
| | word index     |              | row_idx, local_addr, word_mask, data      |   |
| +-------+--------+              +------------------------------------------+   |
|         |                                                                      |
|         | V loads only                                                         |
|         v                                                                      |
| +----------------+ v_pv_src_*  +-------------------------------------------+  |
| | V mirror path  |------------>| FA_V_BUF_PV_REAL                           |  |
| +----------------+             +-------------------------------------------+  |
|                                                                                |
| done_pulse when all 512 32-bit words are accepted.                             |
| error_pulse on misalignment or read beat protocol mismatch.                    |
+--------------------------------------------------------------------------------+
```

FSM：

```text
ST_IDLE --req_valid--> ST_DESC --rd_desc_ready--> ST_DATA
ST_DATA --512 words received and rd_beat_last--> ST_IDLE + done_pulse
ST_DATA --bad word count / bad last / misalignment--> ST_IDLE + error_pulse
```

关键映射：

| 字段 | 说明 |
|---|---|
| `rd_desc_words` | 固定 `512` 个 32-bit words，即一个 `16 x 64` tile |
| `qkv_wr_row_idx` | `word_idx[8:5]`，tile 内 16 行 |
| `qkv_wr_local_addr` | `word_idx[4:2]`，每行 32 words 按 4-word beat 写入 |
| `qkv_wr_word_mask` | 由 `rd_beat_word_count` 转换成 4-bit word mask |
