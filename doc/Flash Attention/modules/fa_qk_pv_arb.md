# FA_QK_PV_ARB

RTL: [`rtl/fa_cores_real.v`](../../../rtl/fa_cores_real.v)

`FA_QK_PV_ARB` 是 shared QK/PV core 的仲裁器。它包含两类仲裁：

- 请求仲裁：只在 stream controller 空闲、没有未握手的 QK/PV response、没有未消费的 QK/PV block 时接受新请求。QK 和 PV 同时请求时，QK 优先。
- GEMM 输入仲裁：根据当前 `mode` 在 QK 输入与 PV 输入之间选择 GEMM A/B 数据，并根据 `row_blk` 从 512-bit A 侧读数据中切出 128-bit `GEMM_V3.a`。同时选择 `num_acc`，QK 为 32，PV 为 8。

```text
+----------------------------------------------------------------------------+
| FA_QK_PV_ARB                                                               |
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
|                                                                            |
| mode,row_blk + Q/K/P/V rd_data                                             |
|        |                                                                   |
|        v                                                                   |
| +----------------------+                                                   |
| | GEMM input mux       |  QK: A=Q slice, B=K, num_acc=32                  |
| |                      |  PV: A=P slice, B=V, num_acc=8                   |
| +----------+-----------+                                                   |
|            |                                                               |
|            v                                                               |
| gemm_a_data[127:0], gemm_b_data[511:0], gemm_num_acc                       |
+----------------------------------------------------------------------------+
```

请求仲裁核心逻辑：

```text
idle_ready = stream_idle
          && !qk_resp_valid && !pv_resp_valid
          && !qk_block_valid && !pv_block_valid

qk_req_ready = idle_ready
pv_req_ready = idle_ready && !qk_req_valid

qk_req_fire = qk_req_valid && qk_req_ready
pv_req_fire = pv_req_valid && pv_req_ready
```

GEMM 输入选择：

```text
gemm_a_full = (mode == QK) ? q_rd_data : p_rd_data
gemm_b_data = (mode == QK) ? k_rd_data : v_rd_data
gemm_num_acc = (mode == QK) ? 32 : 8

row_blk 0 -> gemm_a_data = gemm_a_full[127:0]
row_blk 1 -> gemm_a_data = gemm_a_full[255:128]
row_blk 2 -> gemm_a_data = gemm_a_full[383:256]
row_blk 3 -> gemm_a_data = gemm_a_full[511:384]
```
