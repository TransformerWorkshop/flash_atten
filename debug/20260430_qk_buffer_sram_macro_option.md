# 2026-04-30 Q/K Buffer SRAM Macro Option

## Scope

This is an implementation option only. The current RTL was not changed for Q/K
buffers in this pass.

Current Q/K tile buffer behavior:

- Logical storage per tile: `16 rows x 32 words x 32 bits`.
- Write path: one row receives up to four adjacent 32-bit words per beat,
  selected by `beat_write_local_addr` and `beat_write_word_mask[3:0]`.
- Read path: one `rd_addr[4:0]` returns the same word column from all 16 rows,
  so the output is `16 x 32 = 512` bits with one-cycle `rd_valid` alignment.

The current flat register implementation builds a 512-word flop array and a
wide 16-row read mux. That is why the Q/K DRC points map to `rd_addr` decode
and `rd_data` mux logic.

## Protocol-Preserving SRAM Mapping

Use four column banks selected by `rd_addr[1:0]`. Each column bank stores one of
the four words in a 128-bit input beat. Within each bank, use eight row-pair
macros, where one 64-bit SRAM word holds two 32-bit rows.

Per Q or K tile:

- Column banks: `4`.
- Row-pair macros per bank: `8`.
- Macro shape: `64 x 64`, using only addresses `0..7`.
- Total: `32` `64x64` macros per Q tile and `32` per K tile.

Addressing:

- SRAM address: `beat_write_local_addr` for writes, `rd_addr[4:2]` for reads.
- Column bank: `beat_write_word_mask[bank]` / `rd_addr[1:0]`.
- Row-pair index: `beat_write_row_idx[3:1]`.
- Row lane inside a 64-bit word: `beat_write_row_idx[0]`.

Write behavior:

- A 128-bit write beat may update up to four column banks in the same cycle.
- In each selected bank, only one row-pair macro is enabled.
- `BWEB[31:0]` or `BWEB[63:32]` selects the low/high 32-bit row lane.

Read behavior:

- Select one column bank from `rd_addr[1:0]`.
- Read all eight row-pair macros at address `rd_addr[4:2]`.
- Concatenate each macro's low/high 32-bit lanes into the existing 512-bit
  `rd_data` order.
- Keep `rd_valid <= rd_en`, matching the current one-cycle read contract.

## Macro Choices

Preferred if the foundry memory compiler/library supports it:

- Instantiate `TEM5N28HPCPLVTA64X64M4SWSO` directly.
- This gives one 64-bit port per row-pair macro and keeps the RTL wrapper simple.

Fallback using the currently wrapped primitive:

- Use `FA_SRAM64X64`, which currently builds one logical `64x64` from two
  `64x32` macros.
- Functionally equivalent, but macro count doubles at the physical primitive
  level.

## Expected DRC Impact

The SRAM organization removes the flat 512-word read mux. `rd_addr` only drives:

- a 4-way bank select for the output mux,
- eight local SRAM addresses in the selected bank,
- local write enables for at most four banked macros.

This should remove the Q/K max-transition violations that currently originate
from `FA_REG_TILE_BUF_REAL` read decode.

## Checks Needed Before Enabling

1. Confirm Q/K load and QK compute never require same-cycle read/write to the
   same single-port macro group. If they can overlap, add arbitration or move to
   a two-port macro.
2. Confirm the TSMC28 `.db` and LEF names for `TEM5N28HPCPLVTA64X64M4SWSO`, and
   make sure DC links the hard macro rather than inferring flops.
3. Add a wrapper-level simulation test for:
   - partial `beat_write_word_mask`,
   - all 32 `rd_addr` values,
   - row lane low/high selection,
   - clear/reset behavior.
4. Rerun DC DRC and Formality with a fresh SVF after swapping Q/K instances.
