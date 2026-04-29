# FA_Q_BUF_REAL

RTL: [`rtl/fa_buffers_real.v`](../../../rtl/fa_buffers_real.v)

`FA_Q_BUF_REAL` 保存当前 Q tile，并向 QK 计算路径提供 512-bit row reads。它是 `FA_REG_TILE_BUF_REAL` 的轻量 wrapper。

```text
+--------------------------------------------------------------+
| FA_Q_BUF_REAL                                                |
|                                                              |
| beat_write_* from FA_RD_DMA                                  |
| beat_write_valid, row_idx, local_addr, word_mask, data[127:0]|
|        |                                                     |
|        v                                                     |
| +----------------------+                                     |
| | FA_REG_TILE_BUF_REAL |                                     |
| | 16 rows x 32 words   |                                     |
| | 32-bit packed words  |                                     |
| +----------+-----------+                                     |
|            | qk_rd_en/qk_rd_addr                             |
|            v                                                 |
| qk_rd_valid, qk_rd_data[511:0] -> FA_QK_PV_SHARED_CORE_REAL  |
|                                                              |
| tile_flat is kept for debug/test visibility.                 |
+--------------------------------------------------------------+
```

读写粒度：

| 端口 | 粒度 | 用途 |
|---|---:|---|
| write | 128-bit beat，4 个 32-bit words | Q tile load |
| read | 512-bit row slice | QK GEMM 输入 A |
