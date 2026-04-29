# Flash Attention Module Diagrams

本目录保存重要 RTL 子模块的纯 Markdown 框图。所有框图均使用 `text` 代码块，不依赖 Mermaid 或其他插件。

| 模块 | 文档 | RTL |
|---|---|---|
| `FA_CORE_BASELINE` | [fa_core_baseline.md](fa_core_baseline.md) | [`rtl/fa_core_baseline.v`](../../../rtl/fa_core_baseline.v) |
| `FA_CSR` | [fa_csr.md](fa_csr.md) | [`rtl/fa_csr.v`](../../../rtl/fa_csr.v) |
| `FA_RUN_CTRL` | [fa_run_ctrl.md](fa_run_ctrl.md) | [`rtl/fa_run_ctrl.v`](../../../rtl/fa_run_ctrl.v) |
| `FA_TILE_SCHED` | [fa_tile_sched.md](fa_tile_sched.md) | [`rtl/fa_tile_sched.v`](../../../rtl/fa_tile_sched.v) |
| `FA_RD_DMA` | [fa_rd_dma.md](fa_rd_dma.md) | [`rtl/fa_dma_shell.v`](../../../rtl/fa_dma_shell.v) |
| `FA_WR_DMA` | [fa_wr_dma.md](fa_wr_dma.md) | [`rtl/fa_dma_shell.v`](../../../rtl/fa_dma_shell.v) |
| `FA_AXI_RD_MASTER` | [fa_axi_rd_master.md](fa_axi_rd_master.md) | [`rtl/fa_axi_rd_master.v`](../../../rtl/fa_axi_rd_master.v) |
| `FA_AXI_WR_MASTER` | [fa_axi_wr_master.md](fa_axi_wr_master.md) | [`rtl/fa_axi_rd_master.v`](../../../rtl/fa_axi_rd_master.v) |
| `FA_Q_BUF_REAL` | [fa_q_buf_real.md](fa_q_buf_real.md) | [`rtl/fa_buffers_real.v`](../../../rtl/fa_buffers_real.v) |
| `FA_K_BUF_REAL` | [fa_k_buf_real.md](fa_k_buf_real.md) | [`rtl/fa_buffers_real.v`](../../../rtl/fa_buffers_real.v) |
| `FA_V_BUF_REAL` | [fa_v_buf_real.md](fa_v_buf_real.md) | [`rtl/fa_buffers_real.v`](../../../rtl/fa_buffers_real.v) |
| `FA_V_BUF_PV_REAL` | [fa_v_buf_pv_real.md](fa_v_buf_pv_real.md) | [`rtl/fa_buffers_real.v`](../../../rtl/fa_buffers_real.v) |
| `GEMM_V3` | [gemm_v3.md](gemm_v3.md) | [`rtl/gemm_v3.v`](../../../rtl/gemm_v3.v) |
| `FA_QK_PV_SHARED_CORE_REAL` | [fa_qk_pv_shared_core_real.md](fa_qk_pv_shared_core_real.md) | [`rtl/fa_cores_real.v`](../../../rtl/fa_cores_real.v) |
| `FA_QK_PV_REQ_ARB` | [fa_qk_pv_req_arb.md](fa_qk_pv_req_arb.md) | [`rtl/fa_cores_real.v`](../../../rtl/fa_cores_real.v) |
| `FA_QK_PV_STREAM_CTRL` | [fa_qk_pv_stream_ctrl.md](fa_qk_pv_stream_ctrl.md) | [`rtl/fa_cores_real.v`](../../../rtl/fa_cores_real.v) |
| `FA_QK_PV_RESULT_PACKER` | [fa_qk_pv_result_packer.md](fa_qk_pv_result_packer.md) | [`rtl/fa_cores_real.v`](../../../rtl/fa_cores_real.v) |
| `FA_SCORE_POST_REAL` | [fa_score_post_real.md](fa_score_post_real.md) | [`rtl/fa_score_post_real.v`](../../../rtl/fa_score_post_real.v) |
| `FA_ROW_STATE_REAL` | [fa_row_state_real.md](fa_row_state_real.md) | [`rtl/fa_row_state_real.v`](../../../rtl/fa_row_state_real.v) |
| `FA_RECIP_Q16_16` | [fa_recip_q16_16.md](fa_recip_q16_16.md) | [`rtl/fa_recip_q16_16.v`](../../../rtl/fa_recip_q16_16.v) |
| `FA_P_BYPASS_REAL` | [fa_p_bypass_real.md](fa_p_bypass_real.md) | [`rtl/fa_p_bypass_real.v`](../../../rtl/fa_p_bypass_real.v) |
| `FA_OACC_BUF_REAL` | [fa_oacc_buf_real.md](fa_oacc_buf_real.md) | [`rtl/fa_buffers_real.v`](../../../rtl/fa_buffers_real.v) |
| `FA_OACC_UPDATE_REAL` | [fa_oacc_update_real.md](fa_oacc_update_real.md) | [`rtl/fa_oacc_update_real.v`](../../../rtl/fa_oacc_update_real.v) |
