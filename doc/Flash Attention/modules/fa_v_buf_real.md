# FA_V_BUF_REAL

RTL: [`rtl/fa_buffers_real.v`](../../../rtl/fa_buffers_real.v)

`FA_V_BUF_REAL` 保留 V tile 的 debug/test 可见镜像。实际 PV 数据通路使用 `FA_V_BUF_PV_REAL`，综合路径下本模块避免保留一份冗余 V SRAM。

```text
+--------------------------------------------------------------+
| FA_V_BUF_REAL                                                |
|                                                              |
| beat_write_* from FA_RD_DMA                                  |
| beat_write_valid, row_idx, local_addr, word_mask, data[127:0]|
|        |                                                     |
|        v                                                     |
| +-------------------------+                                  |
| | simulation shadow words |                                  |
| | 512 x 32-bit words      |                                  |
| +-----------+-------------+                                  |
|             |                                                |
|             v                                                |
| tile_flat for directed tests and debug visibility            |
|                                                              |
| Synthesized datapath consumes V through FA_V_BUF_PV_REAL.    |
+--------------------------------------------------------------+
```

定位：

| 项目 | 说明 |
|---|---|
| 功能 | 保留 V tile 写映射的仿真可观测性 |
| 主数据通路 | 不直接供 PV GEMM 使用 |
| 面积取向 | 避免 V 在综合路径中重复存储 |
