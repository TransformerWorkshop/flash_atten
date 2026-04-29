# FA_AXI_WR_MASTER

RTL: [`rtl/fa_axi_rd_master.v`](../../../rtl/fa_axi_rd_master.v)

`FA_AXI_WR_MASTER` 把 core 的 write descriptor 与 32-bit write stream 聚合为 128-bit AXI4 write burst。

```text
+--------------------------------------------------------------------------------+
| FA_AXI_WR_MASTER                                                                |
|                                                                                |
| core write descriptor                                                           |
| wr_desc_valid, wr_desc_addr, wr_desc_words                                      |
|        |                                                                       |
|        v                                                                       |
| +----------------+  AXI AW channel  +--------------------------------------+   |
| | burst planner  |----------------->| m_axi_awaddr/awlen/awsize/awburst    |   |
| | max 16 beats   |                  +--------------------------------------+   |
| +-------+--------+                                                            |
|         |                                                                      |
|         | wr_data 32-bit words                                                 |
|         v                                                                      |
| +----------------+ 128-bit beat       +------------------------------------+   |
| | gather buffer  |------------------->| AXI W channel                       |   |
| | 4 words/beat   |                    | wdata, wstrb, wlast                 |   |
| +-------+--------+                    +------------------------------------+   |
|         |                                                                      |
|         | AXI B response                                                       |
|         v                                                                      |
| +----------------+                                                            |
| | response check |---- error_pulse on non-OKAY bresp                          |
| +----------------+                                                            |
+--------------------------------------------------------------------------------+
```

FSM：

```text
ST_IDLE --descriptor--> ST_AW
ST_AW   --AW handshake--> ST_GATHER
ST_GATHER accepts 32-bit words until a 128-bit beat is full or burst ends
ST_W    sends one AXI W beat
ST_B    waits for response on final beat, then next burst or IDLE
```

AXI constants:

| Signal | Value |
|---|---|
| `axi_awsize` | `3'b100`, 16 bytes per beat |
| `axi_awburst` | `2'b01`, INCR burst |
| max burst | 16 beats |
