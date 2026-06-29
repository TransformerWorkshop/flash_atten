# FA 4x4 SA SRAM Pipeline Model

This is a target architecture model, not current RTL evidence.

| Scenario | Cycles | SA util | Avg active SA | Max active SA | Feeder util | Row-state util | QK | Row update | PV | OACC |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| qk_only_1_feeder | 2193 | 0.248 | 0.99 | 1 | 0.992 | 0.000 | 136 | 0 | 0 | 0 |
| qk_pv_oacc_48_local_cycles | 2242 | 0.971 | 3.88 | 4 | 0.971 | 0.061 | 136 | 136 | 136 | 136 |
| qk_pv_oacc_64_local_cycles | 2787 | 0.976 | 3.90 | 4 | 0.781 | 0.049 | 136 | 136 | 136 | 136 |
| pv_uses_same_feeder | 4418 | 0.493 | 1.97 | 3 | 0.985 | 0.031 | 136 | 136 | 136 | 136 |
| two_feeders_local_post_gemm | 2211 | 0.984 | 3.94 | 4 | 0.492 | 0.062 | 136 | 136 | 136 | 136 |
| shared_row_state_4cy | 2245 | 0.969 | 3.88 | 4 | 0.969 | 0.242 | 136 | 136 | 136 | 136 |
| shared_row_state_32cy | 4433 | 0.491 | 1.96 | 3 | 0.491 | 0.982 | 136 | 136 | 136 | 136 |

## Buffer Sizing Contract

Assumed target shape: 4 clusters, each cluster is one 4x4 SA. Q operands are shared across clusters; K/V/P/PV/OACC state is cluster-local.

| Buffer | Scope | Bytes | Reason |
|---|---|---:|---|
| `q_operand_buffer` | shared | 512 | 4 Q rows x 64 dim x 16b |
| `k_operand_buffer` | per cluster | 512 | 4 K rows/cols x 64 dim x 16b |
| `v_operand_buffer` | per cluster | 512 | 4 V rows x 64 dim x 16b, avoids PV refetch through the same feeder |
| `p_tile_buffer` | per cluster | 32 | 4x4 P tile x 16b |
| `row_scale_buffer` | per cluster | 48 | 4 rows x old/new/scale x 32b |
| `pv_partial_buffer` | per cluster | 512 | 4 output rows x 64 dim x 16b |
| `oacc_old_buffer` | per cluster | 512 | 4 output rows x 64 dim x 16b |
| `oacc_new_buffer` | per cluster | 512 | 4 output rows x 64 dim x 16b |

- Per-cluster local buffer: 2640 B.
- All cluster-local buffers: 10560 B.
- Shared Q buffer: 512 B.
- Task queues: 512 B.
- Total modeled local buffer: 11584 B.

Interpretation:

- `qk_only_1_feeder` is the negative-control case: one SRAM feeder can only keep one 4x4 cluster busy.
- Local PV/OACC work increases the work per feed and can keep more clusters active if operands are buffered locally.
- `pv_uses_same_feeder` shows the risk when PV has to consume the same SRAM feeder again.
- A short shared row-state pipe can be reused by phase staggering; a long row-state pipe becomes the bottleneck.

JSON: `debug/20260629_fa_4x4_sa_sram_pipeline_model.json`
