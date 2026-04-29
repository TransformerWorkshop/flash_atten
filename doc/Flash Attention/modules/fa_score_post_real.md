# FA_SCORE_POST_REAL

RTL: [`rtl/fa_score_post_real.v`](../../../rtl/fa_score_post_real.v)

`FA_SCORE_POST_REAL` 对 QK score 执行 scale 与 causal mask。当前 baseline 使用 `USE_SCORE_BLOCK_INPUT=1`：每次消费 shared core 输出的 4-row QK block，并输出 4-row masked block 与显式 valid mask 给 online softmax；完整 `masked_score_tile_flat` 作为 debug 镜像逐块填充。

```text
+--------------------------------------------------------------------------------+
| FA_SCORE_POST_REAL                                                              |
|                                                                                |
| req_valid                                                                       |
| q_blk_idx, kv_blk_idx, causal_en                                                |
| scale_word, neg_large_word                                                      |
|        |                                                                       |
|        v                                                                       |
| +------------------+  score input      +-----------------------------------+   |
| | input selector   |<------------------| score_block_flat / score_tile_flat |   |
| | block/tile/row   |--- score_row_rd_* | legacy row read port               |   |
| +--------+---------+                   +-----------------------------------+   |
|          |                                                                     |
|          v                                                                     |
| +------------------+                                                            |
| | row walker       | rows 0..3 in block mode, cols 0..15                        |
| +--------+---------+                                                            |
|          |                                                                     |
|          v                                                                     |
| +------------------+                                                            |
| | scale/mask       | if invalid/causal future -> neg_large                     |
| | q16 multiply     | else score * scale with round/saturate                    |
| +--------+---------+                                                            |
|          |                                                                     |
|          v                                                                     |
| masked_score_block_valid, masked_score_block_flat                               |
| masked_score_tile_flat, resp_valid, done_pulse                                  |
+--------------------------------------------------------------------------------+
```

Mask 条件：

```text
global_q_idx = q_blk_idx * 16 + row_idx
global_k_idx = kv_blk_idx * 16 + col_idx

masked when:
  causal_en && global_k_idx > global_q_idx
```

FSM：

```text
ST_IDLE -> ST_RUN -> ST_DONE
or with USE_SCORE_ROW_INPUT:
ST_IDLE -> ST_ROW_REQ -> ST_ROW_WAIT per row -> ST_DONE
```

Block mode uses:

```text
actual_row_idx = score_block_row_base + local_row_idx
masked_score_block_flat[local_row_idx, col] = scaled or neg_large score
masked_score_block_valid[local_row_idx, col] = 0 only for causal future mask
masked_score_tile_flat[actual_row_idx, col] is updated for debug/test visibility
```

`masked_score_block_valid` keeps mask semantics separate from the `NEG_LARGE` data value. A real unmasked score that numerically equals `NEG_LARGE` therefore remains valid for row-state softmax.
