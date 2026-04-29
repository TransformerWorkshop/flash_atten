# FA_CSR

RTL: [`rtl/fa_csr.v`](../../../rtl/fa_csr.v)

`FA_CSR` 是 AXI4-Lite 配置与状态入口，负责寄存器读写、start/soft reset pulse 生成、配置合法性检查和状态计数器暴露。

```text
+--------------------------------------------------------------------------------+
| FA_CSR                                                                          |
|                                                                                |
| AXI4-Lite slave                                                                 |
| s_axi_aw/w/b, s_axi_ar/r                                                        |
|        |                                                                       |
|        v                                                                       |
| +----------------+      write strobes      +--------------------------------+  |
| | AXI-Lite FSM   |------------------------>| CSR register bank              |  |
| | addr/data/resp |                         | CTRL, CFG, BASE, STRIDE,      |  |
| +-------+--------+                         | NEG_LARGE, SCALE              |  |
|         | read mux                         +---------------+----------------+  |
|         v                                                  |                   |
| +----------------+        status inputs                    | config outputs    |
| | readback mux   |<----------------------------------------+                   |
| | status/counter |   busy, done, error, cycles, rd/wr bytes                    |
| +-------+--------+                                                             |
|         |                                                                      |
|         v                                                                      |
| s_axi_rdata/rresp                                                              |
|                                                                                |
| CTRL edge detect:                                                               |
| CTRL.start rising edge      -> start_pulse                                      |
| CTRL.soft_reset rising edge -> soft_reset_pulse                                 |
| CTRL.irq_en                -> irq_en                                            |
|                                                                                |
| Alignment check: Q/K/V/O base and stride must be 16-byte aligned.               |
| Misalignment -> config_error and start suppression at top/core integration.     |
+--------------------------------------------------------------------------------+
```

输出分组：

| 输出 | 用途 |
|---|---|
| `start_level/start_pulse` | 软件启动 core run |
| `soft_reset_level/soft_reset_pulse` | 清理运行期状态 |
| `causal_en` | 选择 causal 或 non-causal 调度/score mask |
| `q_base/k_base/v_base/o_base`、`stride_bytes` | 供 DMA 生成外部地址 |
| `neg_large`、`scale` | 供 score post 和 row state 使用 |
| `config_error` | 地址或 stride 非 16-byte 对齐 |
