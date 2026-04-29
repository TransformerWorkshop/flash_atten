# FA_V_BUF_PV_REAL

RTL: [`rtl/fa_buffers_real.v`](../../../rtl/fa_buffers_real.v)

`FA_V_BUF_PV_REAL` 将 V load beat 重排成 PV GEMM 友好的读布局。PV 阶段按 `{col_blk, acc_idx}` 读取 512-bit rows。

```text
+--------------------------------------------------------------------------------+
| FA_V_BUF_PV_REAL                                                                |
|                                                                                |
| V load stream from FA_RD_DMA                                                    |
| src_wr_valid, src_word_idx_base, src_word_mask, src_data[127:0]                 |
|        |                                                                       |
|        v                                                                       |
| +------------------+   lane/half select   +--------------------------------+   |
| | write remapper   |--------------------->| masked row buffer              |   |
| | source word idx  |                      | DEPTH=32, ROW_WIDTH=512        |   |
| +------------------+                      | WRITE_GRANULARITY=16           |   |
|                                           +---------------+----------------+   |
|                                                           | rd_en/rd_addr      |
|                                                           v                    |
|                                           rd_valid, rd_data[511:0] -> PV GEMM  |
|                                                                                |
| layout_flat is a simulation/debug mirror.                                       |
+--------------------------------------------------------------------------------+
```

地址与数据重排：

| 映射 | 说明 |
|---|---|
| write address | `{src_word_idx_base[4:3], src_word_idx_base[8:6]}` |
| lane select | `src_word_idx[2:0]` 选择 16 个 32-bit lane 中的低/高 lane |
| half select | `src_word_idx[5]` 决定写 32-bit lane 的低 16 bit 或高 16 bit |
| read address | `{col_blk, pv_issue_addr}`，由 shared core PV mode 生成 |
