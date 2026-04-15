# Processing Tile Programmer And Integration Guide

This document describes how software or an upstream controller should drive the native PT interface and what assumptions are valid for the current RTL.

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
- `M/N/K == PT_SCALE_FULL`
- `a_off == 0`
- `b_off == 0`
- low reserved bits are zero

Current architectural meaning:

- PT performs a full-tile GEMM using the A and B banks only
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
- reserved bits must be zero

Semantics:

- `LOAD` prefetches A and/or B/C external payload into the PT side caches associated with `ctrl_id`
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
