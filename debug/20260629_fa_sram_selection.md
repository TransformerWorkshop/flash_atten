# FA SRAM Selection Notes

- Date: `2026-06-29`
- Scope: SRAM macro selection for the current `FA_TOP_BASELINE` storage path.
- Macro source: user-provided screenshot `C:/Users/yucheng/Documents/Tencent Files/2926457320/nt_qq/nt_data/Pic/2026-06/Ori/eea7a6e571736eeec520a017e2e7d818.png`, showing `/home/share/sram_macros_6_24`.
- Evidence status: macro names and view availability are from the screenshot. Port lists, write-mask behavior, timing arcs, and physical dimensions still need direct file inspection.

## Available SRAM Macros

The available macro list contains two `sky130` single-port read/write SRAM macros.

| Macro | Capacity | Organization | Interface class | Views shown in list | Timing corner shown |
| --- | ---: | --- | --- | --- | --- |
| `sky130_sram_1kbytes_1rw_256x32_256` | `8192b = 1KiB` | `256 x 32b` | `1RW` | GDS, LEF, Liberty, SPICE, Verilog | `TT_1p8V_25C` |
| `sky130_sram_2kbytes_1rw_256x64_256` | `16384b = 2KiB` | `256 x 64b` | `1RW` | GDS, LEF, Liberty, SPICE, Verilog | `TT_1p8V_25C` |

File paths shown in the macro list:

```text
pdk/sky130_sram_macros/gds/sky130_sram_1kbytes_1rw_256x32_256.gds
pdk/sky130_sram_macros/gds/sky130_sram_2kbytes_1rw_256x64_256.gds
pdk/sky130_sram_macros/lef/sky130_sram_1kbytes_1rw_256x32_256.lef
pdk/sky130_sram_macros/lef/sky130_sram_2kbytes_1rw_256x64_256.lef
pdk/sky130_sram_macros/lib/sky130_sram_1kbytes_1rw_256x32_256_TT_1p8V_25C.lib
pdk/sky130_sram_macros/lib/sky130_sram_2kbytes_1rw_256x64_256_TT_1p8V_25C.lib
pdk/sky130_sram_macros/spice/sky130_sram_1kbytes_1rw_256x32_256.spice
pdk/sky130_sram_macros/spice/sky130_sram_2kbytes_1rw_256x64_256.spice
pdk/sky130_sram_macros/verilog/sky130_sram_1kbytes_1rw_256x32_256.v
pdk/sky130_sram_macros/verilog/sky130_sram_2kbytes_1rw_256x64_256.v
```

## Executive Conclusion

For the current area-closed `FA_TOP_BASELINE`, keep Q/K, V/PV, OACC, row-state, P bypass, and QK/PV result paths register-backed or streaming. The available `sky130` macros are real and complete enough to consider for a macroized variant, but both macros are `256` words deep and only `32b` or `64b` wide. The current datapath consumes `512b` and `1024b` wide rows in one cycle. Matching that bandwidth with these macros requires many parallel macro instances and wastes most of each macro's depth.

Best practical use of these macros:

1. Use `sky130_sram_2kbytes_1rw_256x64_256` for any future storage that can be naturally serialized as `256 x 64b`.
2. Use `sky130_sram_1kbytes_1rw_256x32_256` only when the natural datapath word is exactly `32b`, or when 64-bit packing is not worth the wrapper complexity.
3. Do not replace the current one-cycle `512b`/`1024b` row-buffer interfaces directly unless the scheduler is updated to accept multi-cycle SRAM row reads and writes.

## Current Buffer Fit

Table I maps the current FA storage bodies onto the two available macros. The `parallel macro` column means preserving the current one-cycle wide-read contract. The `serialized macro` column means changing the local interface so one logical row is fetched over multiple cycles.

| Current storage | Logical payload | Current read/write contract | Parallel macro fit | Serialized macro fit | Recommendation |
| --- | ---: | --- | --- | --- | --- |
| Q tile buffer | `512 x 32b = 16Kb` | Read `512b` per cycle, made from 16 scattered `32b` words | Needs `16 x 256x32` or `8 x 256x64`; poor depth utilization | `1 x 256x64` stores the tile exactly, but each `512b` read needs 8 macro reads | Keep register buffer for current baseline |
| K tile buffer | `512 x 32b = 16Kb` | Same as Q | Same as Q | Same as Q | Keep register buffer for current baseline |
| V/PV layout buffer | `32 x 512b = 16Kb` | Read `512b` per cycle | Needs `8 x 256x64`; uses only 32 of 256 addresses in each macro | `1 x 256x64` stores the buffer exactly, but each row needs 8 reads | Candidate only if PV schedule accepts serialized reads |
| OACC buffer | `16 x 1024b = 16Kb` | Read/write `1024b` rows | Needs `16 x 256x64`; uses only 16 of 256 addresses in each macro | `1 x 256x64` stores the buffer exactly, but each row needs 16 reads/writes | Candidate only with a row-serializer protocol |
| P tile | `4096b` | Current design bypasses P SRAM | Standalone SRAM removed | `1 x 256x32` can hold it with 50% bit utilization, but would reintroduce a removed memory | Keep bypass |
| QK result storage | Old full result was `8192b` | Current design streams 4-row blocks | Removed from main path | `1 x 256x32` can hold old full QK result exactly if serialized | Keep block streaming |
| PV result storage | Old full result was `16384b` | Current design streams 4-row blocks | Removed from main path | `1 x 256x64` can hold old full PV result exactly if serialized | Keep block streaming |
| Row-state `p_tile_flat` | `4096b` | Consumed through `FA_P_BYPASS_REAL` as `512b` slices | Parallel macro would be wasteful | `1 x 256x32`, 50% bit utilization, but adds PV latency | Keep registers |

## Selection By Design Goal

### Goal A: Keep Current Cycle Budget And RTL Shape

Use registers, not SRAM macros.

This is the current baseline. It preserves the existing one-cycle wide-row interfaces:

```text
Q/K read      : 512b/cycle
V/PV read     : 512b/cycle
OACC row read : 1024b/cycle
OACC row write: 1024b/cycle
```

With only `256x32` and `256x64` macros, preserving those widths requires `8` to `16` parallel macros per storage body and wastes depth for shallow buffers. That is usually worse than the current register-backed implementation.

### Goal B: Build A Macroized Area Experiment

Prefer the `256x64` macro and serialize wide rows.

Recommended mapping:

| Storage | Macro | Packing | Interface change |
| --- | --- | --- | --- |
| One Q tile | `1 x sky130_sram_2kbytes_1rw_256x64_256` | pack two adjacent `32b` words per `64b` macro word | QK feed must gather 8 macro words for each old `512b` operand vector |
| One K tile | `1 x sky130_sram_2kbytes_1rw_256x64_256` | same as Q | same as Q |
| V/PV layout | `1 x sky130_sram_2kbytes_1rw_256x64_256` | 32 logical rows x 8 chunks | PV feed must gather 8 macro words per old `512b` row |
| OACC | `1 x sky130_sram_2kbytes_1rw_256x64_256` | 16 logical rows x 16 chunks | OACC update/export must gather or write 16 chunks per old `1024b` row |
| Old QK result buffer, if restored | `1 x sky130_sram_1kbytes_1rw_256x32_256` | exact bit capacity | Not recommended because block streaming already removed it |
| Old PV result buffer, if restored | `1 x sky130_sram_2kbytes_1rw_256x64_256` | exact bit capacity | Not recommended because block streaming already removed it |

This option is a target architecture, not current RTL. It requires scheduler, stream-control, and buffer wrapper changes. The largest risk is Q/K: serializing QK operands can add many cycles because QK consumes many `512b` operand vectors per KV tile.

### Goal C: Preserve Wide Bandwidth Using Macros

Do not do this unless a physical constraint forces it.

Example one-cycle mappings:

| Storage | One-cycle macro mapping | Effective bit utilization |
| --- | --- | ---: |
| Q tile | `8 x 256x64` | about `12.5%` if only 32 row-column addresses are active per bank |
| K tile | `8 x 256x64` | about `12.5%` |
| V/PV layout | `8 x 256x64` | about `12.5%` |
| OACC | `16 x 256x64` | about `6.25%` |

This gives bandwidth but spends macros like a wide register file. It is not a good fit for the two available SRAM shapes.

## Recommended Wrapper Direction

Create two primitive wrappers after direct Verilog inspection:

```text
FA_SKY130_SRAM_256X32_1RW
FA_SKY130_SRAM_256X64_1RW
```

Wrapper contract to freeze before RTL use:

| Contract item | Required decision |
| --- | --- |
| Read latency | Confirm from macro Verilog and Liberty. Assume synchronous 1-cycle only after inspection. |
| Write mask | Confirm whether byte/word mask exists. Do not assume bit mask. |
| Read-during-write | Confirm same-address behavior. Current `FA_MASKED_ROWBUF_*` forbids simultaneous read/write on the single-port path. |
| Reset behavior | SRAM contents are not reset; wrappers must preserve architectural clear by sequenced writes or valid tracking. |
| Enable polarity | Match exact macro port names and active levels from Verilog. |
| Clock domain | Current FA core is single-clock; do not treat `1RW` as dual-port or dual-clock. |

## Integration Impact

The current RTL row buffers support mask granularity that SRAM macros may not:

- Q/K writes update one `32b` word lane from a `128b` DMA beat.
- V/PV writes update `16b` half-lanes in the PV layout.
- OACC writes full `1024b` rows in Q4.12 internal format.

If the macro has byte-write or word-write mask only, the serialized wrapper must implement read-modify-write for subword updates. That adds cycles and a hazard state. If the macro has no useful write mask, the wrapper must either stage full rows before writeback or keep registers for subword-updated structures.

## Verification Checklist

Before changing RTL to use these macros:

1. Inspect the two Verilog macro port lists and record exact ports, enables, write-mask, and read latency.
2. Add black-box stubs or wrappers under `rtl/` with simulation behavior matching the macro contract.
3. Confirm Liberty import for `TT_1p8V_25C`; generate `.db` if the synthesis flow needs Synopsys DB.
4. Add LEF/GDS to the physical flow if ICC/OpenROAD-style placement is in scope.
5. Run focused tests for every touched buffer:
   - Q/K write mapping and QK core tile tests.
   - V/PV layout and PV core tile tests.
   - OACC update/export tests if OACC is changed.
6. Rerun full FA numeric tests and profile cycles. Mark any new cycle number as measured only after regression output exists.
7. Rerun synthesis/PPA. Report cell area, macro area, timing, and the new cycle count together; do not judge SRAM selection by bit capacity alone.

## Current Recommendation

For the current deliverable:

```text
Q/K tile buffers     : keep register-backed
V/PV layout buffer   : keep register-backed
OACC buffer          : keep register-backed
P storage            : keep bypass, no SRAM
QK/PV result storage : keep block streaming, no SRAM
Primary SRAM macro   : sky130_sram_2kbytes_1rw_256x64_256, for serialized experiments
Secondary SRAM macro : sky130_sram_1kbytes_1rw_256x32_256, for 32-bit-word or exact 1KiB experiments
```

In short: the available `sky130` macros are useful for a macroized experiment, especially `256x64`, but they are not a drop-in win for the current FA baseline because the active datapath is shallow and very wide.
