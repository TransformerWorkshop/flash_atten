# FA_OACC_UPDATE_REAL

RTL: [`rtl/fa_oacc_update_real.v`](../../../rtl/fa_oacc_update_real.v)

`FA_OACC_UPDATE_REAL` 对每行执行 online softmax 的 O accumulator 更新：旧 OACC 乘 rescale 后加上当前 PV partial。当前 baseline 使用 `USE_PARTIAL_BLOCK_INPUT=1`，每次从 shared core 接收 4-row PV partial block，并对对应 4 行 OACC 读改写。

```text
+--------------------------------------------------------------------------------+
| FA_OACC_UPDATE_REAL                                                             |
|                                                                                |
| req_valid                                                                       |
| req_row_base, partial_o_block_flat, rescale_vec_flat                            |
|        |                                                                       |
|        v                                                                       |
| +------------------+  row reads       +------------------------------------+   |
| | row walker       |----------------->| OACC buffer row read               |   |
| | 4 local rows     |                  | oacc_row_rd_*                      |   |
| |                  |----------------->| optional legacy partial row read   |   |
| +--------+---------+                  | partial_row_rd_*                   |   |
|          |                            +----------------+-------------------+   |
|          |                                             |                       |
|          v                                             v                       |
| +------------------+                                                            |
| | per-element math | old_q412 -> Q16.16                                         |
| | 64 lanes/row     | old * rescale + partial_q88                                |
| | round/saturate   | Q16.16 -> Q4.12                                            |
| +--------+---------+                                                            |
|          |                                                                     |
|          v                                                                     |
| oacc_row_wr_en, oacc_row_wr_addr, oacc_row_wr_data[1023:0]                      |
| resp_valid, done_pulse                                                          |
+--------------------------------------------------------------------------------+
```

更新公式：

```text
old_q16     = q412_to_q16(old_oacc)
scaled_old  = old_q16 * rescale_vec[row]
partial_q16 = q88_to_q16(pv_partial)
next_q16    = scaled_old + partial_q16
next_oacc   = q16_to_q412(next_q16)
```

FSM：

```text
ST_IDLE --req_valid--> ST_ROW_REQ
ST_ROW_REQ issues OACC row read and optional legacy partial row read
ST_ROW_WAIT waits for row data
ST_ROW_WRITE writes updated row
after local row 3 in block mode, or row 15 in full-tile mode -> ST_DONE
```

Block addressing:

```text
actual_row_idx = req_row_base + local_row_idx
partial_o_block_flat is packed as 4 rows x 64 Q8.8 lanes
OACC read/write addresses use actual_row_idx
```
