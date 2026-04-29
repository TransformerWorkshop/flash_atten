# FA_AXI_RD_MASTER

RTL: [`rtl/fa_axi_rd_master.v`](../../../rtl/fa_axi_rd_master.v)

`FA_AXI_RD_MASTER` 把 core 的 read descriptor 转换为 128-bit AXI4 read burst，并输出 core 可消费的 `rd_beat_*` stream。

```text
+--------------------------------------------------------------------------------+
| FA_AXI_RD_MASTER                                                                |
|                                                                                |
| core read descriptor                                                            |
| rd_desc_valid, rd_desc_addr, rd_desc_words                                      |
|        |                                                                       |
|        v                                                                       |
| +----------------+  AXI AR channel  +--------------------------------------+   |
| | burst planner  |----------------->| m_axi_araddr/arlen/arsize/arburst    |   |
| | max 16 beats   |                  +--------------------------------------+   |
| +-------+--------+                                                            |
|         | AXI R channel                                                        |
|         v                                                                      |
| +----------------+ rd_beat_* stream +--------------------------------------+   |
| | response check |----------------->| core FA_RD_DMA                         |   |
| | rresp/rlast    |                  | data, word_count, last                 |   |
| +-------+--------+                  +--------------------------------------+   |
|         |                                                                      |
|         v                                                                      |
| error_pulse on non-OKAY response or unexpected/missing rlast.                  |
+--------------------------------------------------------------------------------+
```

FSM：

```text
ST_IDLE --descriptor--> ST_AR
ST_AR   --AR handshake--> ST_R
ST_R    --R beats--> next ST_AR if words remain, else ST_IDLE
ST_R    --rresp/rlast protocol error--> ST_ABORT
ST_ABORT drains pending local beat then returns to ST_IDLE
```

AXI constants:

| Signal | Value |
|---|---|
| `axi_arsize` | `3'b100`, 16 bytes per beat |
| `axi_arburst` | `2'b01`, INCR burst |
| max burst | 16 beats |
