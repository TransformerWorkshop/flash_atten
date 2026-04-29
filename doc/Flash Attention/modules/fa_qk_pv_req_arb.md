# FA_QK_PV_REQ_ARB

RTL: [`rtl/fa_cores_real.v`](../../../rtl/fa_cores_real.v)

`FA_QK_PV_REQ_ARB` 是 shared QK/PV core 的请求仲裁器。它只在 stream controller 空闲、没有未握手的 QK/PV response、没有未消费的 QK/PV block 时接受新请求。QK 和 PV 同时请求时，QK 优先。

```text
+----------------------------------------------------------------------------+
| FA_QK_PV_REQ_ARB                                                           |
|                                                                            |
| stream_idle                                                                |
| qk_resp_valid, pv_resp_valid                                               |
| qk_block_valid, pv_block_valid                                             |
|        |                                                                   |
|        v                                                                   |
| +----------------------+                                                   |
| | idle_ready equation  |  ready only when no outstanding response/block    |
| +----------+-----------+                                                   |
|            |                                                               |
|            v                                                               |
| +----------------------+                                                   |
| | fixed priority arb   |  QK wins over PV on simultaneous requests         |
| +----------+-----------+                                                   |
|            |                                                               |
|            v                                                               |
| qk_req_ready, pv_req_ready, qk_req_fire, pv_req_fire                       |
+----------------------------------------------------------------------------+
```

核心逻辑：

```text
idle_ready = stream_idle
          && !qk_resp_valid && !pv_resp_valid
          && !qk_block_valid && !pv_block_valid

qk_req_ready = idle_ready
pv_req_ready = idle_ready && !qk_req_valid

qk_req_fire = qk_req_valid && qk_req_ready
pv_req_fire = pv_req_valid && pv_req_ready
```
