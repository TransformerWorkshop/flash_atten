# Processing Tile Documentation

`Processing Tile (PT)` is the tile-level matrix engine used by this repository's Flash-Attention datapath. This document is the canonical architecture overview for the current RTL rooted at [`rtl/pt.v`](../../rtl/pt.v).

## 1. Documentation Map

- Architecture overview: [README.md](./README.md)
- Programmer and integration guide: [programming_guide.md](./programming_guide.md)
- Verification methodology: [verification_methodology.md](./verification_methodology.md)
- Top-level block diagram: [block_diagram.svg](./block_diagram.svg)

This directory is the authoritative home for PT documentation. Architecture, programming, and verification are kept as separate but aligned documents.

The SVG block diagram is a conceptual aid. For exact signal widths, parameter semantics, and currently supported behaviors, treat the written documentation and RTL as authoritative.

## 2. Role In The System

PT accepts tile-level control commands, fetches operand tiles A and B on demand, executes a full-tile GEMM, applies programmable quantization, optionally performs a post-quantization `MATADD` against an external B-style tile, retains the result in a dual-buffered M window, and automatically exports completed M tiles over a dedicated DMA-backed stream.

## 3. Main Submodules

| Module | Role | Current behavior |
| --- | --- | --- |
| [`PT`](../../rtl/pt.v) | Public top-level wrapper | Exposes the native PT control interface plus A/B load and M export DMA/stream ports |
| [`PT_V2`](../../rtl/pt_top_v2.v) | Canonical assembled implementation | Connects dispatch, allocation, memory/control execution, compute, storage, and response merge |
| [`PT_DISPATCH`](../../rtl/pt_dispatch.v) | Front-end dispatch | Owns `ctrl_*` ingress, command classification, ordering, and QCFG barrier handling |
| [`PT_MALLOC`](../../rtl/pt_malloc.v) | Residency and allocation control | Tracks A/B cache entries by `ctrl_id`, allocates local buffer space, and issues fill/compute work |
| [`PT_MD`](../../rtl/pt_md.v) | Memory/control executor | Handles `CFG`, `QCFG`, `LOAD`, DMA-backed A/B fills, and M export scheduling |
| [`PT_CE`](../../rtl/pt_ce.v) | Compute engine | Runs `MATMUL` from A/B banks and `MATADD` from retained M plus external/B-bank rows, then writes quantized results into M |
| [`CSR_BANK`](../../rtl/csr_bank.v) | Internal PT CSR state | Holds A/B base registers and quantization configuration |
| [`PT_MEM_BANK`](../../rtl/pt_mem.v) | Bank primitive | Standard SRAM-backed ping/pong lane storage with lane-selective writes and full-row reads |
| [`PT_M_MEM`](../../rtl/pt_mem.v) | M result storage | Standard SRAM-backed row-major M storage with one always-present reuse view and an optional dedicated export copy |
| [`GEMM`](../../rtl/gemm.v) | Tile GEMM array | Operates with `OUTPUT_BY_ROW=1` and emits row-wide result groups |
| [`QUANT`](../../rtl/quant.v) | Post-GEMM quantizer | Applies inverse-scale Q16.16 rounding and saturation |
| [`GEMA`](../../rtl/gema.v) | Post-quant add | Applies signed lane-wise saturating add for `MATADD` |

`PT_DISPATCH` and `PT_MALLOC` decide what work is legal and resident, `PT_MD` owns memory-side execution and export, and `PT_CE` owns compute and result writeback.

## 4. Public Interfaces

### 4.1 Interface Groups

| Group | Ports | Meaning |
| --- | --- | --- |
| Clock and reset | `clk`, `rstn`, `clear` | `rstn` is the active-low reset; `clear` is a runtime flush |
| Control stream | `ctrl_valid`, `ctrl_ready`, `ctrl_inst`, `ctrl_id`, `ctrl_resp`, `ctrl_resp_valid` | Native PT control interface, not AXI-Lite |
| A/B load stream | `s_axis_*` | Return payload path for A/B load DMA requests |
| M export stream | `m_axis_*` | Automatic M-tile export stream |
| A/B DMA request | `dma_req_*`, `dma_done`, `dma_error` | External A/B load request interface; `dma_done` is kept for compatibility but is not part of load completion in current RTL |
| M export DMA request | `m_dma_req_*`, `m_dma_done`, `m_dma_error` | Export request interface for the active ready M buffer |
| Completion/error indication | `irq` | Pulses on successful compute completion and error paths |

PT is programmed through its native command interface. It is not driven through [`csr_array.v`](../../rtl/csr_array.v).

### 4.2 Width And Streaming Semantics

The top-level stream widths are parameterized:

- `s_axis_tdata` width = `max(A_LOAD_LANES, B_LOAD_LANES) * DATA_WIDTH`
- `m_axis_tdata` width = `M_EXPORT_LANES * DATA_WIDTH`

Semantically:

- A-load beats carry up to `A_LOAD_LANES` elements from one logical A-column slice.
- B/C-load beats carry up to `B_LOAD_LANES` elements from one logical B-row slice.
- M-export beats carry up to `M_EXPORT_LANES` elements from one row-major M row chunk.

The external byte count does not change when widening these paths; widening reduces beat count and protocol overhead.

## 5. Parameters

| Parameter | Meaning |
| --- | --- |
| `DATA_WIDTH` | Scalar element width for A, B, C, and quantized M |
| `GEMM_X_DIM` | Tile row count and accumulation depth |
| `GEMM_Y_DIM` | Tile column count |
| `EXT_ADDR_W` | External address width |
| `DMA_BEATS_W` | DMA beat counter width |
| `LUT_DEPTH` | A/B cache metadata depth in `PT_MALLOC` |
| `A_BANK_DEPTH` | Per-bank SRAM depth for A storage |
| `B_BANK_DEPTH` | Per-bank SRAM depth for B/C storage |
| `M_BANK_DEPTH` | Per-buffer row depth for M storage |
| `A_LOAD_LANES` | Number of A elements accepted per load beat |
| `B_LOAD_LANES` | Number of B/C elements accepted per load beat |
| `M_WRITE_LANES` | Number of M elements committed per CE writeback step |
| `M_EXPORT_LANES` | Number of M elements emitted per export beat |
| `M_PHYSICAL_COPIES` | Number of physical M row-major copies; legal values are `2` or `3` |

Important distinctions:

- RTL top-level defaults are performance-oriented:
  - `A_LOAD_LANES = GEMM_X_DIM`
  - `B_LOAD_LANES = GEMM_Y_DIM`
  - `M_WRITE_LANES = GEMM_Y_DIM`
  - `M_EXPORT_LANES = GEMM_Y_DIM`
  - `M_PHYSICAL_COPIES = 2`
- The cocotb legacy regression profile intentionally overrides these to conservative compatibility settings:
  - `A_LOAD_LANES = 1`
  - `B_LOAD_LANES = 1`
  - `M_WRITE_LANES = 1`
  - `M_EXPORT_LANES = 1`
  - `M_PHYSICAL_COPIES = 3`
- In practical tiled-GEMM software flows, `LUT_DEPTH` is also a real scaling limit:
  - if software allocates a fresh `ctrl_id` for every partial tile, the default
    `LUT_DEPTH = 8` can be exhausted before the compute datapath itself becomes
    the bottleneck

Depth semantics remain intentionally different across A/B and M:

- `A_BANK_DEPTH` and `B_BANK_DEPTH` are per-bank SRAM row depths, not byte counts.
- `M_BANK_DEPTH` is the row address depth for each logical M buffer.
- PT still owns only two logical M buffers. Increasing `M_BANK_DEPTH` increases retained row capacity, not the number of retained tiles.

Legal builds must satisfy:

- `GEMM_X_DIM` and `GEMM_Y_DIM` are powers of two
- `M_BANK_DEPTH * GEMM_X_DIM >= max(GEMM_X_DIM, GEMM_Y_DIM)`
- `0 < A_LOAD_LANES <= GEMM_X_DIM`
- `0 < B_LOAD_LANES <= GEMM_Y_DIM`
- `0 < M_WRITE_LANES <= GEMM_Y_DIM`
- `0 < M_EXPORT_LANES <= GEMM_Y_DIM`
- `M_PHYSICAL_COPIES in {2, 3}`

## 6. Current Execution Model

### 6.1 Main Flow

1. `ctrl_*` commands enter `PT_DISPATCH`, which classifies them into memory/control or compute traffic and preserves ordering.
2. `PT_MALLOC` checks legality, allocates or reuses A/B residency, and emits either fill requests or compute work.
3. `PT_MD` performs `CFG`, `QCFG`, and `LOAD`, and services compute-side A/B misses through `dma_req_*` plus `s_axis_*`.
4. Once operands are resident and compute is legal to issue, `PT_MALLOC` forwards the work into `PT_CE`.
5. `PT_CE` executes:
   - `MATMUL`: reads only from the A and B banks, drives [`GEMM`](../../rtl/gemm.v), then [`QUANT`](../../rtl/quant.v)
   - `MATADD`: reads one retained M row plus one B/C-bank row and drives [`GEMA`](../../rtl/gema.v)
6. `PT_CE` writes each result row back into M in chunks of `M_WRITE_LANES` and returns a success `ctrl_resp` when the final row chunk has committed.
7. `PT_MD` marks the returned M buffer `READY` and automatically launches `m_dma_req_*` plus `m_axis_*` export.

There is no separate export command. Export is a post-compute side effect once a result buffer becomes ready.

### 6.2 Residency Model

- A/B reuse is cache-by-`ctrl_id` inside `PT_MALLOC`.
- For the same `ctrl_id`, B and C share the B-side residency slot. A later `MATADD` may therefore overwrite B metadata with C metadata, which can force a later B reload.
- M retention is not cache-by-`ctrl_id`. It is a dual-buffer lifetime model owned by `PT_MD`.
- `PT_MD` tracks `m_buf_state{0,1}` as `FREE`, `READY`, or `EXPORTING`.
- Practical implication:
  - software that keeps assigning new `ctrl_id`s instead of reusing old ones may
    hit the default `LUT_DEPTH = 8` residency limit on larger tiled problems,
    even when the underlying `MATMUL` datapath is otherwise functioning normally

## 7. Storage Organization

### 7.1 A/B Banks

`PT_MEM_BANK` builds standard-SRAM-backed ping/pong lane storage:

- A writes are lane-masked row updates indexed by logical column progress.
- B/C writes are lane-masked row updates indexed by logical row progress.
- Reads return full logical rows to the compute engine.

The widened load path is implemented by `PT_MD_V2`: one external beat is expanded into lane-masked writes at a single bank row address.

### 7.2 M Storage

The current M storage is intentionally simpler than earlier experimental versions:

- PT does **not** implement `M`-as-`A` reuse for `MATMUL`
- `PT_M_MEM` therefore no longer carries a dummy A-side read path
- The active physical views are:
  - one row-major view for `MATADD`/retained-M reads
  - one row-major view for export when `M_PHYSICAL_COPIES = 3`
  - or a shared row-major view for both purposes when `M_PHYSICAL_COPIES = 2`

Implementation detail:

- `PT_M_MEM` is now backed by standard [`PT_MEM_BANK`](../../rtl/pt_mem.v) instances, and therefore by the standard [`sram`](../../rtl/sram.v) primitive
- Export in `PT_MD_V2` uses a synchronous row-fetch pipeline to account for SRAM read latency

## 8. Current Architectural Constraints

- `MATMUL` currently accepts only full-tile `M/N/K = PT_SCALE_FULL`
- `MATMUL` currently requires `a_off == 0` and `b_off == 0`
- `M` as a `MATMUL` operand is **not** implemented in the current RTL
- `MATADD` accepts only `M-window + external/B-style tile`
- External A/B offsets must remain tile-row aligned
- `QCFG` supports only `PT_QTYPE_SYMMETRIC` with the `PT_QCFG_CMD_HDR` header format
- `ctrl_resp` returns only `ctrl_id[29:0]`; exact round-trip recovery therefore assumes IDs are constrained to 30 bits
- `dma_done` is not part of A/B load completion; fill completion is determined by received beat count

These are architectural facts of the current RTL, not just testbench assumptions.

## 9. Reset And `clear`

- `rstn` resets runtime state across dispatch, allocation, memory/control, compute, and CSR storage
- `clear` is a soft flush that resets:
  - command queues and runtime registers
  - A/B cache metadata and sequencing state
  - A/B base CSRs
  - quantization mode and inverse-scale defaults
  - M-buffer ownership state
- Underlying SRAM contents are not physically scrubbed; only logical visibility and ownership reset

After `clear`, stale data may still exist in SRAM physically, but PT must treat it as unreachable.

## 10. Related Sources

- Top level: [`rtl/pt.v`](../../rtl/pt.v)
- Assembled implementation: [`rtl/pt_top_v2.v`](../../rtl/pt_top_v2.v)
- Front-end dispatch: [`rtl/pt_dispatch.v`](../../rtl/pt_dispatch.v)
- Residency/allocation: [`rtl/pt_malloc.v`](../../rtl/pt_malloc.v)
- Memory/control executor: [`rtl/pt_md.v`](../../rtl/pt_md.v)
- Compute engine: [`rtl/pt_ce.v`](../../rtl/pt_ce.v)
- PT storage: [`rtl/pt_mem.v`](../../rtl/pt_mem.v)
- Internal CSR bank: [`rtl/csr_bank.v`](../../rtl/csr_bank.v)
- Instruction definitions: [`rtl/param.vh`](../../rtl/param.vh)
- Quantizer: [`rtl/quant.v`](../../rtl/quant.v)
- Verification entry: [`sim/cocotb/run.py`](../../sim/cocotb/run.py)
