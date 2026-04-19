# Processing Tile Programmer And Integration Guide

This document describes how software or an upstream controller should drive the native PT interface and what assumptions are valid for the current RTL.

If your integration point is [`PT_DMA_TOP`](../../rtl/pt_dma_top.v) instead of native [`PT`](../../rtl/pt.v), the command payload and response encoding stay the same, but software injects them through AXI-Lite staging registers and consumes DMA descriptors from `rd_dma_desc_*` / `wr_dma_desc_*` rather than driving `ctrl_*` directly.

## 1. Native Command Model

PT is not programmed through AXI-Lite directly. Its native command plane is the `ctrl_*` stream:

| Signal | Dir | Meaning |
| --- | --- | --- |
| `ctrl_valid` | in | Command word is valid |
| `ctrl_ready` | out | PT can accept a command |
| `ctrl_inst[31:0]` | in | Instruction word |
| `ctrl_id[31:0]` | in | Transaction identifier |
| `ctrl_resp[31:0]` | out | Success or error response |
| `ctrl_resp_valid` | out | One-cycle response pulse |
| `irq` | out | Pulses on successful compute completion and on error paths |

A command is accepted on `ctrl_valid && ctrl_ready`.

## 2. Response Encoding

`ctrl_resp` is packed as:

| Bit | Field | Meaning |
| --- | --- | --- |
| `31` | `err` | `1` on error |
| `30` | `m_buf` | M buffer associated with a successful compute or an export error |
| `[29:0]` | `id` | `ctrl_id[29:0]` |

Important implications:

- `ctrl_id[31:30]` is not returned in `ctrl_resp`
- if exact round-trip ID recovery matters, constrain IDs to 30 bits
- export errors are asynchronous relative to the successful compute response that created the exported buffer

## 3. Supported Opcodes

Opcode definitions come from [`rtl/param.vh`](../../rtl/param.vh).

| Opcode | Constant | Meaning |
| --- | --- | --- |
| `0x1` | `PT_OP_MATMUL` | Launch one full-tile GEMM |
| `0x2` | `PT_OP_QCFG` | Start or continue a quantization-configuration session |
| `0x3` | `PT_OP_MATADD` | Add one retained M tile to one external/B-style tile |
| `0x4` | `PT_OP_LOAD` | Explicitly preload one or both external operand tiles |
| `0xf` | `PT_OP_CFG` | Update PT-internal base-address CSRs |

Unknown opcodes are rejected and return `err=1`.

## 4. Current Instruction Semantics

### 4.1 `MATMUL`

Current accepted encoding:

- `opcode == PT_OP_MATMUL`
- `M/N/K ∈ {PT_TILES_1, PT_TILES_2, PT_TILES_4}`
- `a_off == 0`
- `b_off == 0`
- low reserved bits are zero

Current architectural meaning:

- PT performs one aggregated GEMM using the A and B banks only
- logical shapes are:
  - A = `(m_tiles * GEMM_X_DIM) x (k_tiles * GEMM_X_DIM)`
  - B = `(k_tiles * GEMM_Y_DIM) x (n_tiles * GEMM_Y_DIM)`
  - C = `(m_tiles * GEMM_X_DIM) x (n_tiles * GEMM_Y_DIM)`
- PT internally iterates over all output subtile positions and returns exactly one final `ctrl_resp` plus one aggregated export
- A and B residency may come from explicit `LOAD`, compute-side fill, or same-`ctrl_id` cache reuse
- `M`-as-`A` or `M`-as-`B` `MATMUL` reuse is **not** implemented in the current RTL

Software should therefore treat `a_off` and `b_off` in `MATMUL` as reserved and keep them zero.

### 4.2 `MATADD`

Current accepted encoding:

- `opcode == PT_OP_MATADD`
- `m_off` must encode an explicit retained-M buffer
- `c_off` must encode an external/B-style tile
- reserved fields must be zero

Current architectural meaning:

- left operand = retained M row stream
- right operand = external/B-bank row stream
- result = saturating add of quantized M and external C/B-style tile

`MATADD` is the only current operation that consumes retained M as an input operand.

### 4.3 `LOAD`

Current accepted encoding:

- `opcode == PT_OP_LOAD`
- at least one of `need_a` or `need_b` must be set
- size fields must be non-zero for requested sides
- `reserved_lo[5:0]` encodes `m_tiles/n_tiles/k_tiles` as `00->1`, `01->2`, `10->4`, `11->illegal`

Semantics:

- `LOAD` prefetches A and/or B/C external payload into the PT side caches associated with `ctrl_id`
- A-side residency matches `(m_tiles, k_tiles)` and B-side residency matches `(k_tiles, n_tiles)`; cache hit requires both shape and length to match
- success returns `pack_resp(err=0, m_buf=0, id=ctrl_id)`
- success does not itself raise `irq`

### 4.4 `CFG`

Supported selectors:

| Selector | Meaning |
| --- | --- |
| `PT_CFG_A_BASE_LO` | Write `pcsr_a_base[15:0]` |
| `PT_CFG_A_BASE_HI` | Write `pcsr_a_base[31:16]` |
| `PT_CFG_B_BASE_LO` | Write `pcsr_b_base[15:0]` |
| `PT_CFG_B_BASE_HI` | Write `pcsr_b_base[31:16]` |

Unknown selectors currently acknowledge as success while leaving effective behavior unchanged.

### 4.5 `QCFG`

Current supported session format:

- header: `opcode == PT_OP_QCFG`, `cmd == PT_QCFG_CMD_HDR`, `qtype == PT_QTYPE_SYMMETRIC`
- payload: one 32-bit inverse-scale word per required slot

Supported granularity:

| Granularity | Payload count |
| --- | ---: |
| `PT_QGRAN_PER_TENSOR` | `1` |
| `PT_QGRAN_X_WISE` | `GEMM_X_DIM` |
| `PT_QGRAN_Y_WISE` | `GEMM_Y_DIM` |
| `PT_QGRAN_X_WISE_DIV2` | `GEMM_X_DIM / 2` |
| `PT_QGRAN_Y_WISE_DIV2` | `GEMM_Y_DIM / 2` |

The configuration commits atomically on the final payload beat.

## 5. Offset Semantics

For the current RTL, software-facing offsets should be interpreted as follows:

- `MATMUL`
  - keep `a_off = 0`
  - keep `b_off = 0`
- `MATADD`
  - `m_off` must be an explicit retained-M offset of the form `bit9=1, bit8=buffer, bits[7:0]=row-aligned element offset`
  - `c_off` must be an external/B-style offset aligned to `GEMM_Y_DIM`
- `LOAD`
  - selected sides must use external/B-style offsets, not retained-M offsets

The dispatch/allocation path rewrites accepted external offsets into internal local addresses. That rewritten local form is an implementation detail and should not be generated intentionally by software.

## 6. Public Stream And DMA Semantics

### 6.1 A/B Load Request Side

The public PT wrapper currently exposes only:

| Signal | Meaning |
| --- | --- |
| `dma_req_valid/ready` | A/B request handshake |
| `dma_req_kind` | A/B/C side tag |
| `dma_req_id` | Original `ctrl_id` |

The current wrapper does **not** expose detailed external address, local address, or beat-count fields for A/B loads.

Integration implication:

- an external environment must supply the correct A/B/C payload corresponding to the accepted `dma_req_kind` and `dma_req_id`
- the detailed fill shape is implied by the accepted PT command plus the current PT configuration

### 6.2 A/B Load Return Stream

The input stream width is parameterized:

- `s_axis_tdata` width = `max(A_LOAD_LANES, B_LOAD_LANES) * DATA_WIDTH`

Semantics:

- A-load beats carry up to `A_LOAD_LANES` elements from a logical A-column slice
- B/C-load beats carry up to `B_LOAD_LANES` elements from a logical B-row slice
- load completion is tracked by received beat count
- `dma_error` aborts the fill immediately
- `dma_done` is retained on the wrapper for compatibility, but it is not used by the current fill completion logic

Current functional significance of `s_axis_*`:

- used: `tvalid`, `tready`, `tdata`, `tuser`
- not functionally decoded in current RTL: `tstrb`, `tlast`, `tkeep`, `tid`, `tdest`

These sidebands are retained for wrapper and integration compatibility, but software should not depend on them being interpreted by the active PT datapath.

### 6.3 M Export Request And Stream

Public export request signals:

| Signal | Meaning |
| --- | --- |
| `m_dma_req_valid/ready` | Export request handshake |
| `m_dma_req_id` | Zero-extended response-visible ID |
| `m_dma_req_buf` | Exported M buffer |
| `m_dma_req_beats` | Export beat count in the current stream width |

Public export stream width:

- `m_axis_tdata` width = `M_EXPORT_LANES * DATA_WIDTH`

Semantics:

- export order is row-major
- one beat carries up to `M_EXPORT_LANES` elements from one row chunk
- `m_axis_tuser = {1'b0, m_buf}`
- `m_axis_tstrb` reflects valid lanes in the widened beat
- `m_axis_tlast` is asserted only on the final export beat

On the A/B request side, `dma_done` remains on the interface for compatibility, but current fill completion is driven by accepted return-beat count rather than `dma_done`.

## 7. Parameterization That Matters To Software / Integration

The most behaviorally important parameters are:

| Parameter | Meaning |
| --- | --- |
| `A_LOAD_LANES` | A elements accepted per input beat |
| `B_LOAD_LANES` | B/C elements accepted per input beat |
| `M_WRITE_LANES` | M elements committed per CE writeback step |
| `M_EXPORT_LANES` | M elements emitted per export beat |
| `M_PHYSICAL_COPIES` | `2` or `3`; affects physical storage duplication, not the public protocol |

Two important profiles are used in practice:

- RTL performance-oriented defaults:
  - widened A/B load
  - widened M writeback/export
  - `M_PHYSICAL_COPIES = 2`
- cocotb legacy compatibility profile:
  - single-element A/B load beats
  - single-element M writeback/export beats
  - `M_PHYSICAL_COPIES = 3`

Current supported-lane rule:

- `A_LOAD_LANES` must divide `GEMM_X_DIM`
- `B_LOAD_LANES` must divide `GEMM_Y_DIM`
- `M_WRITE_LANES` must divide `GEMM_Y_DIM`
- `M_EXPORT_LANES` must divide `GEMM_Y_DIM`

This restriction was tightened after the `2026-04-18` coverage/RTL refresh so that non-divisor lane counts are no longer treated as supported operating points.

### 7.1 `PT_DMA_TOP` Practical Integration Notes

If software talks to [`PT_DMA_TOP`](../../rtl/pt_dma_top.v) rather than native [`PT`](../../rtl/pt.v), the current wrapper behavior has a few practical implications:

- a full descriptor submission currently uses `11` AXI-Lite writes:
  - `CMD_INST`, `CMD_ID`
  - `A/B/C/M` low + high address words
  - `CTRL_DESC_PUSH`
- in the current `EXT_ADDR_W=32` build profile, the four `*_ADDR_HI` writes are functionally redundant because the wrapper exposes only 32-bit external addresses
- same-`ctrl_id` pushes update the existing descriptor entry in place, so software can avoid full rewrites when only a subset of the staged fields changed
- descriptor entries are not retired automatically in the current RTL; measured wrapper tests show the table holds only `8` live IDs before `STATUS_DESC_OVERFLOW` asserts on the ninth unique ID
- under sustained DMA-side backpressure, wrapper-side command headroom is finite; current tests observe `STATUS_CMD_OVERFLOW` on the tenth repeated push in the standard configuration

Current measured top-level timing facts for the app-style wide `16x16` profile are:

- cold-miss `MATMUL`
  - `first AXI-Lite write -> resp visible = 123 cycles`
  - `CTRL_DESC_PUSH -> resp visible = 83 cycles`
- cache-hit `MATMUL`
  - full rewrite = `85 cycles`
  - same-id delta replay = `45 cycles`
- retained-M `MATADD`
  - `first AXI-Lite write -> resp visible = 147 cycles`
  - `CTRL_DESC_PUSH -> resp visible = 107 cycles`
- export
  - `wr_dma_desc -> m_axis_tlast = 33 cycles`

Software guidance from these measurements:

- reuse `ctrl_id` aggressively
- avoid rewriting unchanged descriptor fields
- when the build is known to use `EXT_ADDR_W=32`, skip redundant `*_ADDR_HI` writes
- treat AXI-Lite submission cost as a first-order performance term on cache-hit flows, not just a small control-side detail

## 8. Integration Rules

### 8.1 Always Safe Rules

- keep `MATMUL` `a_off` and `b_off` at zero
- use `LOAD` for explicit prefetch and `ctrl_id`-keyed cache residency
- use `MATADD` when chaining from retained M
- treat a successful compute response and a later export error response as separate events
- constrain `ctrl_id` to 30 bits if exact response-ID roundtrip matters

### 8.2 Unsupported Or Future-Looking Flows

The following are not supported by the current RTL:

- `M` as the left operand of `MATMUL`
- `M` as the right operand of `MATMUL`
- `MATADD` with `M + M`
- non-`FULL/FULL/FULL` `MATMUL`
- non-symmetric `QCFG` qtypes

## 9. Recommended Bring-Up Sequence

For deterministic software/integration bring-up:

1. Program A and B base registers with `CFG`
2. Program a known quantization state with `QCFG`
3. Optionally issue `LOAD` to populate A/B residency
4. Issue `MATMUL`
5. Wait for the success `ctrl_resp`
6. Independently observe `m_dma_req_*` and consume `m_axis_*`
7. If chaining through retained M, issue `MATADD`

## 10. Related Files

- Architecture overview: [README.md](./README.md)
- Verification methodology: [verification_methodology.md](./verification_methodology.md)
- Top-level RTL: [`rtl/pt.v`](../../rtl/pt.v)
- Assembled implementation: [`rtl/pt_top_v2.v`](../../rtl/pt_top_v2.v)
- Instruction definitions: [`rtl/param.vh`](../../rtl/param.vh)
