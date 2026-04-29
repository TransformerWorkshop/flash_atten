# FA_ROW_STATE_REAL

RTL: [`rtl/fa_row_state_real.v`](../../../rtl/fa_row_state_real.v)

`FA_ROW_STATE_REAL` 实现 online softmax row state。每行维护 `m_state`、`l_state` 和 `seen`。当前 baseline 使用 `USE_MASKED_BLOCK_INPUT=1` 和 `USE_VALID_MASK_INPUT=1`：每次消费 4-row masked score block 以及独立 valid mask，更新对应 4 行状态；`p_tile_flat` 与 `rescale_vec_flat` 仍保持完整 16 行 tile 视图，供 PV/OACC 使用和测试观察。

```text
+--------------------------------------------------------------------------------+
| FA_ROW_STATE_REAL                                                               |
|                                                                                |
| init_valid                                                                      |
|        |                                                                       |
|        v                                                                       |
| +------------------+                                                            |
| | row-state init   | m_state=neg_large, l_state=0, seen=0                      |
| +------------------+                                                            |
|                                                                                |
| update_valid, update_row_base, masked_score_block_valid, masked_score_block     |
|        |                                                                       |
|        v                                                                       |
| +------------------+   row score       +-----------------------------------+   |
| | row walker       |------------------>| max/valid scan                    |   |
| | 4 local rows     |                   | valid mask, tile row max          |   |
| +--------+---------+                   +----------------+------------------+   |
|          |                                                |                     |
|          v                                                v                     |
| +------------------+       exp LUT        +-------------------------------+    |
| | online update    |--------------------->| l_new and reciprocal           |    |
| | m_new, alpha     |                      | FA_RECIP_Q16_16                |    |
| | beta per column  |<---------------------| recip_l_new                    |    |
| +--------+---------+                      +-------------------------------+    |
|          |                                                                     |
|          v                                                                     |
| +------------------+                                                            |
| | row commit       | p_tile_flat Q8.8, rescale_vec Q16.16, update m/l/seen     |
| +------------------+                                                            |
|                                                                                |
| resp_valid, done_pulse                                                          |
+--------------------------------------------------------------------------------+
```

核心公式：

```text
m_new      = max(old_m, max(score_row))
alpha      = exp(old_m - m_new)
beta_j     = exp(score_j - m_new)
l_new      = alpha * old_l + sum(beta_j)
rescale    = alpha * old_l / l_new
p_j        = beta_j / l_new
```

FSM：

```text
ST_IDLE
  -> ST_INIT -> ST_IDLE
  -> ST_ROW_PREP -> ST_ROW_EXP -> ST_ROW_DIV_WAIT -> ST_ROW_COMMIT
  -> next row or ST_DONE
```

Block addressing:

```text
actual_row_idx = update_row_base + local_row_idx
state arrays use actual_row_idx
p_tile_flat/rescale_vec_flat write back to actual_row_idx
```

有效列判定：

```text
block-streaming baseline:
  valid(col) = masked_score_block_valid[local_row_idx, col]

legacy/fallback mode:
  valid(col) = score_word != neg_large_word
```

active baseline 使用显式 valid mask，因此 mask 语义不依赖 score 数据值本身。

输出格式：

| 输出 | 格式 | 用途 |
|---|---|---|
| `p_tile_flat` | packed Q8.8 | `FA_P_BYPASS_REAL` -> PV GEMM |
| `rescale_vec_flat` | Q16.16 per row | `FA_OACC_UPDATE_REAL` |
| debug state | Q16.16 `m/l` and seen bits | test/debug visibility |
