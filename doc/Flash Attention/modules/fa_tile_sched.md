# FA_TILE_SCHED

RTL: [`rtl/fa_tile_sched.v`](../../../rtl/fa_tile_sched.v)

`FA_TILE_SCHED` 是 tile 级主调度器，遍历 head、Q block、KV block，并向各执行单元发起阶段请求。

```text
+--------------------------------------------------------------------------------+
| FA_TILE_SCHED                                                                   |
|                                                                                |
| Inputs                                                                          |
| run_active, run_start_pulse, causal_en, num_heads, seq_blocks                   |
| done pulses from load/row/oacc/qk/score/pv/store                                |
|        |                                                                       |
|        v                                                                       |
| +----------------------+     indices       +--------------------------------+  |
| | scheduler FSM        |------------------>| q_blk_idx, kv_blk_idx, head_idx|  |
| | state_r              |                   | load_q_blk_idx/load_kv_blk_idx |  |
| | q_blk_r, kv_blk_r    |                   +--------------------------------+  |
| | head_idx_r           |                                                        |
| | prefetch flags       |---- stage reqs ------------------------------------+  |
| +----------+-----------+                                                     |  |
|            |                                                                 |  |
|            v                                                                 v  |
| load_req_valid/kind       row_init_valid       oacc_clear_valid                 |
| qk_req_valid              score_req_valid      row_update_valid                 |
| pv_req_valid              oacc_update_valid    store_req_valid                  |
|                                                                                |
| run_complete_pulse fires when final store of final Q block/head completes.      |
+--------------------------------------------------------------------------------+
```

主阶段顺序：

```text
IDLE
  -> Q_LOAD
  -> ROW_INIT
  -> OACC_CLEAR
  -> for each effective KV block:
       K_LOAD -> V_LOAD -> QK -> SCORE -> ROW_UPDATE -> PV -> OACC_UPDATE
  -> STORE
  -> next Q block / next head / COMPLETE
```

优化点：

| 机制 | 说明 |
|---|---|
| causal skip | `causal_en` 下只扫描当前 Q block 可见的 KV block |
| K prefetch | QK 后若还有下一 KV block，可在 score/row/PV/OACC 阶段触发 K 预取 |
| Q prefetch | store 当前 Q block 时可预取下一 Q block |
| valid/ready | 每个阶段都由 valid/ready 接受请求，并用 done pulse 回到调度器 |
