# Processing Tile Programmer And Integration Guide

This document describes how software or an upstream controller should drive the native PT interface, and how the repository's separate `csr_array` block can be used as a system-level wrapper pattern.

## 1. Native Command Model

PT is not programmed through AXI-Lite directly. Its native control plane is a backpressure-aware command stream:

| Signal | Dir | Meaning |
| --- | --- | --- |
| `ctrl_valid` | in | Command word is valid in the current cycle |
| `ctrl_ready` | out | PT can accept a new command; driven by `PT_DISPATCH`'s ingress queues |
| `ctrl_inst[31:0]` | in | Instruction word |
| `ctrl_id[31:0]` | in | Transaction identifier used for cache lookup, DMA request tagging, and responses |
| `ctrl_resp[31:0]` | out | Result or error response word |
| `ctrl_resp_valid` | out | One-cycle response pulse |
| `irq` | out | Pulses on successful `MATMUL`/`MATADD` completion and on error events |

Treat `ctrl_*` as the authoritative PT programming interface. A command is accepted on `ctrl_valid && ctrl_ready`.

### 1.1 Response Sources

| Source | When returned | `err` | `m_buf` |
| --- | --- | --- | --- |
| `CFG` success | Immediately after acceptance | `0` | `0` |
| `QCFG` success | After the final payload commits | `0` | `0` |
| `LOAD` success | After the selected A/B sides finish | `0` | `0` |
| Illegal `MATMUL` | Immediately when rejected by `PT_MD` | `1` | `0` |
| Illegal `MATADD` | Immediately when rejected by `PT_MD` | `1` | `0` |
| Illegal `LOAD` | Immediately when the dispatched `REJECT` command completes | `1` | `0` |
| A/B load DMA or stream error | When the load path fails | `1` | `0` |
| `MATMUL` success | When the result has been written into an M buffer | `0` | Target M buffer |
| `MATADD` success | When the result has been written into an M buffer | `0` | Target M buffer |
| Export DMA error | After a prior success, if export later fails | `1` | Failing M buffer |

A successful `MATMUL` response does not mean export is finished. Export runs afterward and can still generate an error response.

## 2. `ctrl_inst` Encoding

Instruction fields are defined in [`rtl/param.vh`](../../rtl/param.vh).

### 2.1 Opcode

| Name | Value | Meaning |
| --- | --- | --- |
| `PT_OP_MATMUL` | `4'h1` | Launch one tile GEMM |
| `PT_OP_QCFG` | `4'h2` | Start a quantization configuration session |
| `PT_OP_MATADD` | `4'h3` | Add one retained M tile and one external/B-style tile |
| `PT_OP_LOAD` | `4'h4` | Explicitly prefetch one or both external operand tiles into the `ctrl_id` cache |
| `PT_OP_CFG` | `4'hf` | Update a 16-bit fragment of the internal PT base CSR state |

Unknown opcodes are converted into a dispatched `REJECT` command and return `err=1`.

### 2.2 `MATMUL` Format

| Bit | Field | Meaning |
| --- | --- | --- |
| `[31:28]` | `opcode` | Must be `PT_OP_MATMUL` |
| `[27:26]` | `M scale` | Must currently be `PT_SCALE_FULL` |
| `[25:24]` | `N scale` | Must currently be `PT_SCALE_FULL` |
| `[23:22]` | `K scale` | Must currently be `PT_SCALE_FULL` |
| `[21:12]` | `A offset` | 10-bit A operand offset |
| `[11:2]` | `B offset` | 10-bit B operand offset |
| `[1:0]` | reserved | Reserved |

Defined scale constants:

| Constant | Value |
| --- | --- |
| `PT_SCALE_SCALAR` | `2'b00` |
| `PT_SCALE_FULL_DIV4` | `2'b01` |
| `PT_SCALE_FULL_DIV2` | `2'b10` |
| `PT_SCALE_FULL` | `2'b11` |

Although all constants are defined, the current RTL accepts only the `FULL/FULL/FULL` combination.

### 2.3 `MATADD` Format

| Bit | Field | Meaning |
| --- | --- | --- |
| `[31:28]` | `opcode` | Must be `PT_OP_MATADD` |
| `[27:22]` | reserved | Must be zero |
| `[21:12]` | `m_off` | Must be an explicit M-window offset |
| `[11:2]` | `c_off` | Must be an external/B-style offset aligned to `GEMM_Y_DIM` |
| `[1:0]` | reserved | Must be zero |

`MATADD` v1 accepts only `quantized M-window + external/B-style tile`. It does not accept `M+M`, external left operands, or any new scale/QCFG fields.

### 2.4 `LOAD` Format

| Bit | Field | Meaning |
| --- | --- | --- |
| `[31:28]` | `opcode` | Must be `PT_OP_LOAD` |
| `[27]` | `need_a` | Prefetch side A when `1` |
| `[26]` | `need_b` | Prefetch side B when `1` |
| `[25:22]` | reserved | Must be zero |
| `[21:12]` | `a_off` | External A offset used when `need_a=1` |
| `[11:2]` | `b_off` | External B offset used when `need_b=1` |
| `[1:0]` | reserved | Must be zero |

`LOAD` legality rules:

- `need_a` and `need_b` cannot both be zero.
- Each selected side must use an external offset, not an M-window offset.
- Each selected side must satisfy the same row-alignment rule as `MATMUL`.
- Success returns exactly one `pack_resp(err=0, m_buf=0, id=ctrl_id)`.
- Success does not raise `irq`.
- If both sides are requested, DMA order is always `A -> B`.

### 2.5 Offset Semantics

`A offset` and `B offset` support two legal forms:

1. External tile offset
   - Interpreted as an element offset relative to `pcsr_a_base` or `pcsr_b_base`
   - Must be tile-row aligned
   - A: `offset % GEMM_X_DIM == 0`
   - B: `offset % GEMM_Y_DIM == 0`

2. M-window offset
   - bit 9 = `1`
   - bit 8 = `buffer`
   - bits `[7:0]` = retained M tile element offset, still subject to tile-row alignment

On a cache hit, `PT_DISPATCH` may rewrite an external offset into an internal local offset using the form `{1'b0, buf_sel, row_base_elem_off}`. That rewritten value is an internal implementation detail and should not be generated intentionally by software.

Software should generate either external offsets or explicit M-window offsets. Internal local offsets are patched by `PT_DISPATCH`.

For `MATADD`, software must use:

- `m_off` as an explicit M-window offset.
- `c_off` as an external/B-style offset.
- Zero for every reserved bit.

### 2.6 `CFG` Format

| Bit | Field | Meaning |
| --- | --- | --- |
| `[31:28]` | `opcode` | `PT_OP_CFG` |
| `[27:24]` | `selector` | 16-bit fragment selector |
| `[15:0]` | `value` | Written payload |

Supported selectors:

| Selector | Constant | Meaning |
| --- | --- | --- |
| `4'h0` | `PT_CFG_A_BASE_LO` | Write `pcsr_a_base[15:0]` |
| `4'h1` | `PT_CFG_A_BASE_HI` | Write `pcsr_a_base[31:16]` |
| `4'h2` | `PT_CFG_B_BASE_LO` | Write `pcsr_b_base[15:0]` |
| `4'h3` | `PT_CFG_B_BASE_HI` | Write `pcsr_b_base[31:16]` |

Unknown selectors do not raise an error. PT returns a success response while leaving the effective configuration unchanged.

### 2.7 `QCFG` Format

Header word:

| Bit | Field | Meaning |
| --- | --- | --- |
| `[31:28]` | `opcode` | `PT_OP_QCFG` |
| `[27:24]` | `cmd` | Currently only `PT_QCFG_CMD_HDR` is supported |
| `[23:22]` | `qtype` | Currently only `PT_QTYPE_SYMMETRIC` is supported |
| `[21:19]` | `granularity` | Quantization granularity |

Supported granularity:

| Constant | Meaning | Payload count |
| --- | --- | --- |
| `PT_QGRAN_PER_TENSOR` | One scale for the entire tile | `1` |
| `PT_QGRAN_X_WISE` | One scale per output row | `GEMM_X_DIM` |
| `PT_QGRAN_Y_WISE` | One scale per output column | `GEMM_Y_DIM` |
| `PT_QGRAN_X_WISE_DIV2` | One scale per two rows | `GEMM_X_DIM / 2`, valid only for even dimensions |
| `PT_QGRAN_Y_WISE_DIV2` | One scale per two columns | `GEMM_Y_DIM / 2`, valid only for even dimensions |

Payload words:

- Each payload following the header is one full 32-bit signed Q16.16 inverse-scale word.
- Every payload must use the same `ctrl_id` as the header.
- PT does not return a success response until the final payload arrives.
- Commit updates `quant_mode` and `quant_inv_scale` atomically.
- Any `quant_inv_scale` slot not overwritten by the current payload sequence retains its previous value.

`QCFG` is a session, not a single command. A header starts the session and the final payload commits it atomically.

## 3. Response Encoding

`ctrl_resp` is packed the same way in [`PT_MD`](../../rtl/pt_md.v) and [`PT_CE`](../../rtl/pt_ce.v):

| Bit | Field | Meaning |
| --- | --- | --- |
| `31` | `err` | `1` indicates an error |
| `30` | `m_buf` | M buffer associated with a successful `MATMUL` or an export error |
| `[29:0]` | `id` | `ctrl_id[29:0]` |

Important implications:

- The upper 2 bits of `ctrl_id` are not returned through `ctrl_resp`.
- `dma_req_id` preserves the full 32-bit original `ctrl_id`.
- `m_dma_req_id` zero-extends the response-visible 30-bit ID as `{2'b00, id[29:0]}`.

If host software requires exact response-ID roundtrip, keep `ctrl_id < 2^30`.

## 4. DMA Contract

### 4.1 A/B Load DMA

`PT_MD` issues the following request for each explicit `LOAD` side and each compute miss side:

| Signal | Meaning |
| --- | --- |
| `dma_req_valid/ready` | Request handshake |
| `dma_req_tuser` | `2'b01` for A and `2'b10` for B |
| `dma_req_id` | Original 32-bit `ctrl_id` |
| `dma_req_ext_addr` | `base + (offset << log2(DATA_WIDTH/8))` |
| `dma_req_local_addr` | `{1'b0, buf_sel, row_base_elem_off}` |
| `dma_req_beats` | `GEMM_X_DIM * GEMM_X_DIM` for A and `GEMM_Y_DIM * GEMM_Y_DIM` for B |

After the request is accepted, external logic must return payload through `s_axis_*`:

- `s_axis_tvalid`, `s_axis_tready`, `s_axis_tdata`, and `s_axis_tuser` are functionally significant.
- `s_axis_tuser` must match the active `dma_req_tuser`.
- `s_axis_tstrb`, `s_axis_tlast`, `s_axis_tkeep`, `s_axis_tid`, and `s_axis_tdest` are not used for functional decode in the current RTL.
- A/B load completion is determined by received beat count reaching `dma_req_beats`.
- `dma_error=1` immediately generates an error response.
- `dma_done` is currently not part of the load completion logic and remains a retained wire.

The A/B DMA return path is stream-driven. PT counts beats internally and only checks `dma_error` and `s_axis_tuser` consistency.

### 4.2 M Export DMA

Once an M buffer becomes `READY`, `PT_MD` automatically issues:

| Signal | Meaning |
| --- | --- |
| `m_dma_req_valid/ready` | Export request handshake |
| `m_dma_req_id` | `{2'b00, ctrl_id[29:0]}` |
| `m_dma_req_buf` | Buffer being exported |
| `m_dma_req_beats` | `GEMM_X_DIM * GEMM_Y_DIM` |

PT then automatically drives the full tile on `m_axis_*`:

- Export order is row-major.
- `m_axis_tlast` is asserted only on the final element.
- `m_axis_tstrb` is always all ones.
- `m_axis_tkeep` is always `1`.
- `m_axis_tid` is always `0`.
- `m_axis_tdest` is always `0`.
- `m_axis_tuser = {1'b0, m_buf}`.

After streaming completes:

- `m_dma_done=1` releases the buffer successfully.
- `m_dma_error=1` also releases the buffer but generates an additional error response.

Export is fire-and-forget from PT's point of view, but software must still monitor for a later export error response.

## 5. AXIS Behavioral Conventions

### 5.1 Input Side `s_axis_*`

- `s_axis_tready` is asserted only while `PT_MD` is in `ST_DMA_RECV`.
- The current design functionally consumes only:
  - `s_axis_tvalid`
  - `s_axis_tdata`
  - `s_axis_tuser`
- The current design does not use `s_axis_tlast` for packet delimiting.

### 5.2 Output Side `m_axis_*`

- `m_axis_tvalid` is asserted only during export `EXP_STREAM`.
- `m_axis_tready` may backpressure export.
- When `m_axis_tready=0`, the current beat remains stable until the handshake completes.

PT uses AXIS as a transport shell around a stricter tile contract.

## 6. Recommended Programming Sequences

### 6.1 Cold Start

1. Use `CFG` to write `A_BASE_LO/HI` and `B_BASE_LO/HI`.
2. Send a default `QCFG` header plus payload to initialize inverse scale values.
3. Wait for the immediate success responses from each `CFG`, then for the final `QCFG` success response.
4. If the system uses `clear`, repeat the same initialization sequence after `clear`.

`clear` resets the internal PT base and quantization state, so configuration is not persistent across a soft flush.

### 6.2 `QCFG` Followed By `MATMUL`

1. Send the `QCFG` header with `ctrl_id = cfg_id`.
2. Send the required number of payloads, all using the same `ctrl_id = cfg_id`.
3. Wait for `ctrl_resp = pack(err=0, m_buf=0, id=cfg_id)`.
4. Send a legal `MATMUL`.
5. Wait for `ctrl_resp = pack(err=0, m_buf=<buf>, id=matmul_id)`.
6. Continue monitoring automatic export and any later export error.

### 6.3 `LOAD` Followed By `MATMUL`

1. Send `LOAD` with the target `ctrl_id`, offsets, and `need_a/need_b`.
2. Wait for `ctrl_resp = pack(err=0, m_buf=0, id=load_id)`.
3. Reuse the same `ctrl_id` in a later `MATMUL` so `PT_DISPATCH` can hit the preloaded tile(s).
4. Any side not covered by the earlier `LOAD` may still miss and DMA normally.

### 6.4 `MATMUL` Followed By `MATADD`

1. Send a legal `MATMUL` and wait for `ctrl_resp = pack(err=0, m_buf=<buf>, id=matmul_id)`.
2. Encode `m_off` as `build_mwin_off(<buf>, row_base_elem_off)` and encode `c_off` as the external/B-style tile offset for `C`.
3. Send `MATADD`.
4. Wait for `ctrl_resp = pack(err=0, m_buf=<new_buf>, id=matadd_id)`.
5. Continue monitoring automatic export and any later export error exactly as with `MATMUL`.

This is the native PT sequence for `quant(A*B) + C`.

### 6.5 M-Window Reuse

1. Complete one legal `MATMUL` and capture the returned `m_buf`.
2. In a later `MATMUL`, encode `a_off` or `b_off` as an M-window source with bit 9 set and bit 8 equal to `m_buf`.
3. Keep the other operand as an external offset or another M-window source.
4. Handle success and error responses exactly as with a regular `MATMUL`.

M-window reuse is useful for tile-to-tile chaining, but the surrounding system must track buffer lifetime across `clear` and export.

### 6.6 Completion And Export Handling

1. Treat a successful `MATMUL` response as “the result has been written into an M buffer.”
2. Treat `m_dma_req_*` and `m_axis_*` as “the result is now being exported.”
3. PT marks the exported buffer back to `FREE` only after `m_dma_done`.
4. If an export error response arrives, treat export for that buffer as failed and apply the system retry or recompute policy.

### 6.7 Error Handling And Recovery

When any of the following occurs, the recommended recovery action is `clear` followed by reconfiguration:

- Illegal `MATMUL` encoding
- Illegal `QCFG` header or payload ID mismatch
- `dma_error` during A/B load
- Wrong `s_axis_tuser` during A/B load
- `m_dma_error` during export

After `clear`, re-run:

1. A/B base `CFG`
2. `QCFG`
3. Any external tile loads needed for future reuse

`clear` is the clean recovery primitive because it resets cache state, M buffers, base CSR state, and quantization state in one step.

## 7. System-Level Appendix: `csr_array`

### 7.1 Positioning

[`rtl/csr_array.v`](../../rtl/csr_array.v) is a separate AXI4-Lite CSR block in the repository for higher-level Flash-Attention accelerator control. It is not part of the `PT` top level and does not directly mirror the PT-native `CFG/QCFG/MATMUL` command stream.

`csr_array` is a system wrapper example. Integrating PT behind it requires an adapter or sequencer that translates register writes into PT-native commands.

### 7.2 Current Register Map

| Offset | Name | Access | Meaning |
| --- | --- | --- | --- |
| `0x00` | `CTRL` | R/W | bit 0 `START`, bit 1 `SOFT_RESET`, bit 2 `IRQ_EN` |
| `0x04` | `STATUS` | R | bit 0 `BUSY`, bit 1 `DONE`, bit 2 `ERROR` |
| `0x08` | `CFG` | R/W | bit 0 `CAUSAL_EN` |
| `0x14/0x18` | `Q_BASE_L/H` | R/W | 64-bit Q base |
| `0x1C/0x20` | `K_BASE_L/H` | R/W | 64-bit K base |
| `0x24/0x28` | `V_BASE_L/H` | R/W | 64-bit V base |
| `0x2C/0x30` | `O_BASE_L/H` | R/W | 64-bit O base |
| `0x34` | `STRIDE_BYTES` | R/W | Row stride |
| `0x38` | `NEG_LARGE` | R/W | Mask-related constant |
| `0x3C` | `SCALE` | R/W | Scale constant |
| `0x40` | `CYCLES` | R | Cycle counter |

Important differences:

- `csr_array` manages Q/K/V/O base addresses and higher-level datapath configuration.
- Internal PT `CSR_BANK` manages only A/B base addresses and quantization state.
- If the system drives PT indirectly through AXI-Lite, extra software or hardware sequencing is required to generate PT `ctrl_inst` traffic.

### 7.3 AXI-Lite Notes

- The write channel accepts only when `AWVALID` and `WVALID` arrive together.
- `WSTRB` is honored per byte.
- Writes to read-only or unmapped addresses return `OKAY` and are ignored.
- Reads of unmapped addresses return `0`.

Keep `csr_array` as a control-plane convenience layer, not as the normative PT API.

## 8. Related Sources

- Instruction definitions: [`rtl/param.vh`](../../rtl/param.vh)
- PT top: [`rtl/pt.v`](../../rtl/pt.v)
- `PT_DISPATCH`: [`rtl/pt_dispatch.v`](../../rtl/pt_dispatch.v)
- `PT_MD`: [`rtl/pt_md.v`](../../rtl/pt_md.v)
- `PT_CE`: [`rtl/pt_ce.v`](../../rtl/pt_ce.v)
- `CSR_BANK`: [`rtl/csr_bank.v`](../../rtl/csr_bank.v)
- `csr_array`: [`rtl/csr_array.v`](../../rtl/csr_array.v)
- cocotb environment: [`sim/cocotb/tests/pt_blackbox_env.py`](../../sim/cocotb/tests/pt_blackbox_env.py)
- model helpers: [`sim/cocotb/tests/pt_model.py`](../../sim/cocotb/tests/pt_model.py)
