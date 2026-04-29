# FA_OACC_BUF_REAL

RTL: [`rtl/fa_buffers_real.v`](../../../rtl/fa_buffers_real.v)

`FA_OACC_BUF_REAL` 保存当前 Q tile 的 O accumulator。内部使用 16-bit Q4.12，每行 64 个元素；导出时转换为 packed Q8.8。

```text
+--------------------------------------------------------------------------------+
| FA_OACC_BUF_REAL                                                                |
|                                                                                |
| clear_req_valid / load_valid                                                    |
|        |                                                                       |
|        v                                                                       |
| +------------------+  clear/load row loop  +-------------------------------+   |
| | control FSM      |---------------------->| masked row buffer             |   |
| | IDLE/CLEAR/LOAD  |                       | 16 rows x 1024 bits           |   |
| +-------+----------+                       | Q4.12 internal storage        |   |
|         |                                  +-----------+-------------------+   |
|         | row read/write                               |                       |
|         v                                             v                       |
| oacc_update row port                         export read port                 |
| row_rd_en/row_wr_en                           exp_rd_en/exp_rd_addr           |
| row_rd_data/row_wr_data                       exp_rd_data packed Q8.8         |
|                                                                                |
| row_rd_en and exp_rd_en share one memory read port and must not overlap.       |
+--------------------------------------------------------------------------------+
```

格式转换：

| 方向 | 转换 |
|---|---|
| load | external packed Q8.8 -> internal Q4.12 |
| update | `FA_OACC_UPDATE_REAL` writes internal Q4.12 rows |
| export | internal Q4.12 pairs -> packed Q8.8 words |

FSM：

```text
ST_IDLE --clear_req_valid--> ST_CLEAR rows 0..15 -> clear_done_pulse
ST_IDLE --load_valid-------> ST_LOAD  rows 0..15 -> load_done_pulse
ST_IDLE also accepts normal row read/write operations from OACC update/store.
```
