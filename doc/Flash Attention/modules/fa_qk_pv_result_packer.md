# FA_QK_PV_RESULT_PACKER

RTL: [`rtl/fa_cores_real.v`](../../../rtl/fa_cores_real.v)

`FA_QK_PV_RESULT_PACKER` converts `GEMM_V3` output groups into the block-streaming interface used by score post and OACC update. It also owns QK/PV response handshakes and the simulation-only full-tile debug mirrors.

```text
+--------------------------------------------------------------------------------+
| FA_QK_PV_RESULT_PACKER                                                         |
|                                                                                |
| mode, row_blk, col_blk                                                         |
| gemm_stream_fire, gemm_group_idx, gemm_last, gemm_group_data[2047:0]           |
|        |                                                                       |
|        v                                                                       |
| +----------------------+       +-------------------------------------------+   |
| | QK pack path         |------>| qk_block_data[2047:0]                     |   |
| | clamp 128b -> 32b    |       | qk_block_row_base, qk_block_valid         |   |
| +----------------------+       +-------------------------------------------+   |
|                                                                                |
| +----------------------+       +-------------------------------------------+   |
| | PV pack path         |------>| pv_block_data[4095:0]                     |   |
| | round/sat 128b ->16b |       | pv_block_row_base, pv_block_valid         |   |
| +----------------------+       +-------------------------------------------+   |
|                                                                                |
| +----------------------+                                                       |
| | response control     | qk_resp_valid/pv_resp_valid and done pulses          |
| +----------------------+                                                       |
|                                                                                |
| qk_result_tile_flat / pv_result_tile_flat debug mirrors under !SYNTHESIS       |
+--------------------------------------------------------------------------------+
```

QK packing:

```text
each GEMM group -> one score row inside the active 4-row block
lane col 0..15: signed 128-bit accumulator -> saturated signed 32-bit score
block valid when gemm_last for the current row block
qk_resp_valid when final row_blk 3 completes
```

PV packing:

```text
each GEMM group -> one output row and one 16-column slice
lane col 0..15: signed 128-bit accumulator -> rounded/saturated Q8.8 16-bit lane
col_blk 0..3 are packed into one 4x64 block
block valid when gemm_last && col_blk == 3
pv_resp_valid when final row_blk 3 and col_blk 3 complete
```

Synthesis note:

```text
qk_result_tile_flat and pv_result_tile_flat are debug mirrors only.
Under SYNTHESIS they are tied to zero; the synthesized datapath uses qk_block/pv_block.
```
