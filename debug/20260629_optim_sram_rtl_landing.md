# Optim SRAM RTL Landing Notes

Date: 2026-06-29

Branch: `optim`

## Scope

This branch starts the RTL landing for the storage-native FA architecture.

Current target contract:

- Logical SRAM shape: `256 x 64b` and `256 x 32b`.
- Port model: single `1RW` port.
- Read model: synchronous 1-cycle read in the behavioral wrapper.
- Write mask model: active-low bit mask at the macro wrapper boundary.
- Logical tile layout for the first scaffold: `addr = {row_idx[3:0], chunk_idx[3:0]}`.

## Process Mapping Policy

The architectural SRAM contract is kept process-neutral and sky130-compatible:

- `FA_SKY130_SRAM_256X64_1RW`
- `FA_SKY130_SRAM_256X32_1RW`

For the current RTL landing, these wrappers map to TSMC28 same-spec placeholder macros:

- `TEM5N28HPCPLVTA256X64M4SWSO`
- `TEM5N28HPCPLVTA256X32M4SWSO`

This keeps the upper RTL shape identical to the intended sky130 macro shape while allowing TSMC28 synthesis experiments. When the real sky130 macro Verilog/Lib/LEF/GDS is available in the flow, only the wrapper internals should need to change.

## Added RTL

| File | Purpose |
|---|---|
| `rtl/fa_sram_hard.v` | Added process-neutral `256x64` / `256x32` 1RW wrappers and sky130-named aliases. |
| `rtl/tsmc_sram_macros.v` | Added same-spec TSMC28 macro black-box stubs. |
| `rtl/fa_sram_tile_buffers.v` | Added `FA_LOCAL_TILE_SRAM_16X64X16`, a storage-native 16-row by 16-chunk tile scaffold backed by one `256x64` macro. |

## MC2 / sky130 Status

The locally recorded MC2 environment is for TSMC28 memory compiler flows, not a verified sky130 memory compiler. The user-provided sky130 macro list appears to contain already generated sky130 views under `/home/share/sram_macros_6_24`.

Remote `ic-canopsys` SSH was attempted from the Windows host and timed out, so direct MC2 generation and direct `/home/share/sram_macros_6_24` inspection were not completed in this step.

## Next RTL Landing Steps

1. Add a focused HDL simulator smoke for `FA_SRAM256X64_1RW` and `FA_LOCAL_TILE_SRAM_16X64X16` on the EDA VM.
2. Inspect the real macro port lists for the selected TSMC28 or sky130 `256x64` and `256x32` macros.
3. Replace placeholder stubs with exact macro black boxes or vendor Verilog.
4. Add cluster-local buffer modules for Q/K/V/OACC task staging.
5. Keep row-state/score/OACC update shared unless counters show the shared pipe is the bottleneck.

## Verification

Local Windows host does not have `iverilog`, `vvp`, or `verilator` in PATH. Local verification performed here is limited to Python static contract tests.
