# Attention Operator Space SOP

- Timestamp: `2026-04-24`
- Repo: `flash_atten`
- Scope:
  - based on the current repo status
  - based on the requirement PDF `cadence.pdf`
  - summarizes the analysis from the current conversation into an executable SOP
- Goal:
  - determine how to extend the current `PT_DMA_TOP_V3`-centered codebase into the operator space required by the competition baseline
  - decide what to reuse, what to rebuild, and how to stage the work with minimal disruption

## 1. Executive Summary

The current repo already contains three valuable assets:

- a mature tile-GEMM-oriented compute/storage substrate centered on `PT_V3`
- a software-facing wrapper family centered on `PT_DMA_TOP` / `PT_DMA_TOP_V3`
- a shell-style simulation prototype that demonstrates "outer control shell + local reduce + delayed output" on top of `PT_V3`

However, the competition baseline is not asking for a generic GEMM wrapper. It is asking for an attention-native operator space with:

- fixed baseline shape `S = 256`, `d = 64`, `batch = 1`, `head = 1`
- causal mask support
- FlashAttention-style execution constraints:
  - no explicit full attention matrix storage
  - online softmax
  - tiled `K/V`
- fixed-point baseline datatype:
  - `Q/K/V/O = Q8.8`, i.e. signed 16-bit fixed-point
- AXI4-Lite control + DMA read `Q/K/V` / DMA write `O`

Therefore the key conclusion is:

- do not treat `PT_DMA_TOP_V3` itself as the final attention baseline top
- instead, use a new parallel attention-native top and selectively reuse the strongest existing pieces from `PT_V3`
- the highest-value reuse is in:
  - SRAM/banked local storage
  - DMA fill/export skeletons
  - compute pipeline partitioning style
- the lowest-value reuse is in:
  - current PT opcode semantics
  - current PT front-end dispatch / allocation / descriptor control model

The recommended main route is:

- `parallel new top` as the target architecture
- `hybrid kernel` only in the limited sense that `PT_V3` or a PT-derived GEMM core can act as a tile GEMM sub-kernel
- work in staged fashion:
  - first build the operator/framework shell
  - then fill the reusable hardware substrate
  - then use scripted proxy modules for the missing algorithm blocks
  - finally replace proxies with real RTL modules

## 2. Requirement Extraction From `cadence.pdf`

The PDF is image-based. Direct text extraction returned empty pages, so the requirement summary below was reconstructed by inspecting rendered page images.

### 2.1 Baseline Algorithm Definition

The baseline target is SDPA / FlashAttention-style attention:

- target formula:
  - `O = softmax(Q K^T / sqrt(d) + M) V`
- baseline constraints:
  - no explicit storage of the full attention matrix
  - online softmax is mandatory
  - `K/V` must be processed by tiling

### 2.2 Fixed Baseline Shape

The baseline uses a fixed input size for unified evaluation:

- sequence length: `S = 256`
- head dimension: `d = 64`
- `Q/K/V/O` shape: `[S, d]`
- `batch = 1`
- `head = 1`

### 2.3 Baseline Datatype

The baseline fixed-point requirements are:

- input `Q/K/V`: `Q8.8`, 16-bit signed fixed-point
- dot-product accumulation:
  - at least 32-bit
  - 40-bit or wider is recommended to reduce overflow risk
- softmax path:
  - may use wider internal precision or segmented scaling
- output `O`:
  - `Q8.8`, 16-bit signed fixed-point

### 2.4 Baseline Interface Requirements

The baseline interface model is:

- AXI4-Lite control plane:
  - host writes base addresses and parameters
  - host starts the accelerator through a start register
  - host polls status / done
- AXI4 Master + DMA data plane:
  - accelerator reads `Q/K/V` from memory
  - accelerator writes `O` back to memory

### 2.5 Required Register Map

The baseline register map reconstructed from the PDF is:

| Offset | Name | Access | Meaning |
| --- | --- | --- | --- |
| `0x00` | `CTRL` | `R/W` | bit0 `START`, bit1 `SOFT_RESET`, bit2 `IRQ_EN` |
| `0x04` | `STATUS` | `R` | bit0 `BUSY`, bit1 `DONE` (write-1-clear in the PDF description), bit2 `ERROR` |
| `0x08` | `CFG` | `R/W` | bit0 `CAUSAL_EN` |
| `0x14` | `Q_BASE_L` | `R/W` | `Q` base low 32 |
| `0x18` | `Q_BASE_H` | `R/W` | `Q` base high 32 |
| `0x1C` | `K_BASE_L` | `R/W` | `K` base low 32 |
| `0x20` | `K_BASE_H` | `R/W` | `K` base high 32 |
| `0x24` | `V_BASE_L` | `R/W` | `V` base low 32 |
| `0x28` | `V_BASE_H` | `R/W` | `V` base high 32 |
| `0x2C` | `O_BASE_L` | `R/W` | `O` base low 32 |
| `0x30` | `O_BASE_H` | `R/W` | `O` base high 32 |
| `0x34` | `STRIDE_BYTES` | `R/W` | row stride, default `d * 2` |
| `0x38` | `NEG_LARGE` | `R/W` | `-inf` approximation in fixed-point |
| `0x3C` | `SCALE` | `R/W` | `1 / sqrt(d)` |
| `0x40` | `CYCLES` | `R` | execution cycle count |

### 2.6 Storage / Resource Constraints

The baseline explicitly requires low intermediate storage:

- storing the full `score` / `p` matrix is forbidden
- on-chip intermediate storage should be limited to:
  - one or a few `K/V` tiles
  - per-row `m/l/acc` state
  - necessary pipeline registers

### 2.7 Correctness / Validation Requirements

The PDF defines correctness acceptance in terms of numerical tolerance rather than bit-exact matching:

- compare against FP32 golden under the same formula and mask
- target tolerance:
  - `mean_abs_error(O) <= 0.03`
  - `max_abs_error(O) <= 0.10`

### 2.8 Baseline Performance / Evaluation Requirements

The PDF also gives performance and reporting direction:

- maximize frequency
- area target:
  - equivalent gate count `<= 2,000,000`
  - including SRAM
  - using Genus-equivalent gate reporting
- latency target:
  - single attention with `S = 256`, `d = 64`, `causal`
  - execution cycles `< 300k`
- bandwidth reporting:
  - provide `RD_BYTES` / `WR_BYTES`
  - analyze optimization opportunities such as tile cache / reuse

### 2.9 Bonus Options

Optional bonus directions mentioned in the PDF include:

- BF16 / FP16 version
- multi-head support
- longer sequence support, e.g. `S = 512`
- padding mask
- other fixed-point formats
- dropout
- lower precision ideas such as `INT8/FP8`
- extra AXI4-Stream data interface
- DMA / task queue support

## 3. Current Repo Status

### 3.1 Current Top-Level Families

The current repo contains:

- native PT family:
  - `rtl/pt.v`
  - `rtl/pt_v3.v`
  - `rtl/pt_top_v3.v`
- wrapper family:
  - `rtl/pt_dma_top.v`
  - `rtl/pt_dma_top_v3.v`
- shell-style simulation top:
  - `rtl/pt_dma_top_v3_shell_sim.v`

### 3.2 Current PT Operator Space

The current PT opcode space comes from `rtl/param.vh` and is still low-level:

- `PT_OP_MATMUL`
- `PT_OP_QCFG`
- `PT_OP_MATADD`
- `PT_OP_LOAD`
- `PT_OP_CFG`

Evidence:

- [rtl/param.vh](/Users/yucheng/Documents/GitHub/flash_atten/rtl/param.vh:14)

This is not the same as an attention-native operator space.

### 3.3 Current `PT_DMA_TOP_V3` Control Plane

`PT_DMA_TOP_V3` currently uses `PT_DMA_AXIL_CSR`, which is a descriptor-mailbox-oriented register map. It is not the PDF baseline register map.

Evidence:

- [rtl/pt_dma_axil_csr.v](/Users/yucheng/Documents/GitHub/flash_atten/rtl/pt_dma_axil_csr.v:1)
- [rtl/pt_dma_top_v3.v](/Users/yucheng/Documents/GitHub/flash_atten/rtl/pt_dma_top_v3.v:348)

### 3.4 Existing Baseline-Like CSR Block In Repo

The repo already has a `csr_array.v` that almost matches the PDF baseline register space:

- `CTRL`
- `STATUS`
- `CFG`
- `Q/K/V/O_BASE`
- `STRIDE_BYTES`
- `NEG_LARGE`
- `SCALE`
- `CYCLES`

Evidence:

- [rtl/csr_array.v](/Users/yucheng/Documents/GitHub/flash_atten/rtl/csr_array.v:6)

However, it is currently isolated and not wired into the main `PT_DMA_TOP_V3` path.

### 3.5 Existing `PT_V3` Structural Assets

`PT_V3` and `PT_TOP_V3` already provide a mature compute-storage substrate:

- banked local A/B storage
- banked M/result storage
- DMA fill path
- export path
- compute pipeline with:
  - dispatch
  - malloc / residency
  - MD
  - CE
  - GEMM
  - QUANT
  - GEMA

Evidence:

- [rtl/pt_top_v3.v](/Users/yucheng/Documents/GitHub/flash_atten/rtl/pt_top_v3.v:67)

### 3.6 Existing Shell Prototype

`PT_DMA_TOP_V3_SHELL_SIM` is especially important:

- it does not wrap `PT_DMA_TOP_V3`
- it directly instantiates `PT_V3`
- it adds shell-side ingress, output metadata, local reduction and delayed output behavior

Evidence:

- [rtl/pt_dma_top_v3_shell_sim.v](/Users/yucheng/Documents/GitHub/flash_atten/rtl/pt_dma_top_v3_shell_sim.v:576)
- [rtl/pt_dma_top_v3_shell_sim.v](/Users/yucheng/Documents/GitHub/flash_atten/rtl/pt_dma_top_v3_shell_sim.v:1152)
- [sim/cocotb/run.py](/Users/yucheng/Documents/GitHub/flash_atten/sim/cocotb/run.py:553)
- [sim/cocotb/tests/test_pt_shell_sim.py](/Users/yucheng/Documents/GitHub/flash_atten/sim/cocotb/tests/test_pt_shell_sim.py:150)

This is already a strong signal that the repo's own exploration direction is closer to a parallel new top than to a deep mutation of `PT_DMA_TOP_V3`.

### 3.7 Current Datatype Direction

Current v3 mainline is a packed-int8-oriented datapath:

- `ELEM_WIDTH = 8`
- `PACK_LANES = 4`
- packed export / packed AB work already landed into v3 flow

Evidence:

- [rtl/pt_v3.v](/Users/yucheng/Documents/GitHub/flash_atten/rtl/pt_v3.v:6)
- [rtl/pt_dma_top_v3.v](/Users/yucheng/Documents/GitHub/flash_atten/rtl/pt_dma_top_v3.v:6)
- [debug/20260422_120845_pt_dma_top_v2_archive_v3_scaffold.md](/Users/yucheng/Documents/GitHub/flash_atten/debug/20260422_120845_pt_dma_top_v2_archive_v3_scaffold.md:47)
- [sim/cocotb/run.py](/Users/yucheng/Documents/GitHub/flash_atten/sim/cocotb/run.py:555)

This is a major mismatch with the PDF baseline requirement of `Q8.8` 16-bit.

## 4. Gap Analysis

### 4.1 Interface Gap

The PDF baseline wants:

- one attention-native AXI4-Lite CSR space
- direct DMA semantics for `Q/K/V/O`

The current `PT_DMA_TOP_V3` provides:

- a descriptor staging mailbox for PT low-level commands
- separate descriptor tables for `A/B/C/M`

This is not a cosmetic difference. It changes the software and verification model fundamentally.

### 4.2 Operator-Semantic Gap

Current PT op space is low-level and tile-centric:

- `LOAD`
- `MATMUL`
- `MATADD`
- `CFG`
- `QCFG`

The required baseline operator space is attention-centric:

- read `Q/K/V`
- schedule tile loops over `S = 256`, `d = 64`
- causal mask
- online softmax
- row-wise running state
- final output writeback

### 4.3 Algorithmic Gap

Current PT supports:

- tile GEMM
- quantization
- post-quant saturating add

Current PT does not natively support:

- online softmax
- row-wise `m/l/acc` state maintenance
- attention score masking semantics
- attention probability generation
- direct probability-weighted `V` accumulation semantics

### 4.4 Datatype Gap

Required baseline:

- `Q8.8`, 16-bit external format

Current v3 direction:

- packed-int8 style

This affects:

- local bank packing
- GEMM lane arithmetic
- export formatting
- accumulation and scaling widths

### 4.5 Signoff / Productization Gap

The shell prototype is useful, but it is explicitly excluded from signoff-oriented SOPs:

- `pt_dma_top_v3_shell_sim.v`
- `pt_shell_axil_csr_sim.v`

Evidence:

- [doc/pt_dma_top_v3_warning_cleanup_sop.md](/Users/yucheng/Documents/GitHub/flash_atten/doc/pt_dma_top_v3_warning_cleanup_sop.md:58)

So shell code should be treated as architecture guidance, not as final signoff RTL.

## 5. Scheme Comparison

### 5.1 Option A: Interface-Alignment Wrapper

Description:

- keep the PT low-level semantics
- only make the top register space look like the PDF baseline

Cost:

- low

Risk:

- low

Benefit:

- medium for external alignment only

Problem:

- this solves control-space alignment only
- it does not solve attention semantics

### 5.2 Option B: Macro-Operator Orchestration On Top Of Existing PT

Description:

- decompose attention into a sequence of PT `LOAD/MATMUL/MATADD/QCFG/CFG`
- keep the current wrapper semantics

Cost:

- medium

Risk:

- high

Benefit:

- medium

Problem:

- current PT semantics are too narrow
- softmax and row-state logic cannot be cleanly expressed in current PT op space
- control complexity rises quickly

### 5.3 Option C: Hybrid Kernel

Description:

- reuse PT or PT-derived tile GEMM as a compute sub-kernel
- add new attention-specific blocks around it

Cost:

- high

Risk:

- medium

Benefit:

- high

Important clarification:

- this is only attractive if PT is used as a tile GEMM engine
- if the new attention logic sits outside PT, then this route naturally converges toward a parallel new top

### 5.4 Option D: Parallel New Top

Description:

- build a new attention-native top
- reuse PT structural assets selectively
- do not overload `PT_DMA_TOP_V3` semantics

Cost:

- high

Risk:

- medium

Benefit:

- highest long-term fit

Why it is attractive:

- aligns cleanly with the PDF baseline
- isolates the old GEMM-wrapper flow from the new attention baseline
- matches the repo's own shell exploration direction

### 5.5 Option E: Shell-First Prototype

Description:

- first build an attention shell in simulation
- use local reduction / proxy blocks to validate the architecture

Cost:

- low to medium

Risk:

- low to medium

Benefit:

- high for architecture exploration

Problem:

- not sufficient as final signoff code

### 5.6 Recommendation

Recommended main route:

- `parallel new top`

Recommended supporting route:

- `hybrid kernel` only in the narrow sense that PT-derived compute/storage pieces are reused as sub-blocks

Recommended validation route:

- shell/proxy-assisted phased development

Not recommended as final architecture:

- deepening `PT_DMA_TOP_V3` into a full attention-native top

## 6. Detailed Evaluation Of `Hybrid Kernel` And `Parallel New Top`

### 6.1 Hybrid Kernel

What PT can realistically contribute:

- tile GEMM execution
- tile-local storage
- DMA fill/export structure

What PT cannot directly contribute:

- online softmax state machine
- causal masking semantics
- row-wise running normalization state
- probability generation
- final attention-native control plane

Consequences:

- if PT is reused only as a GEMM tile engine, the route is valid
- if one tries to make `PT_DMA_TOP_V3` itself absorb attention semantics, complexity rises sharply and maintainability drops

### 6.2 Parallel New Top

This route fits the repo evidence best:

- `csr_array.v` already matches the required register map closely
- `shell_sim` already packages `PT_V3`, not `PT_DMA_TOP_V3`
- shell evaluation notes already frame future gains as "shell + local reduction + reuse"

Important note from the shell cost model:

- shell-side `forward_m` and reuse benefits are still architecture projections
- they are not yet native stable RTL behavior

Evidence:

- [debug/20260422_ps_pl_128b_internal_512_shell_eval.md](/Users/yucheng/Documents/GitHub/flash_atten/debug/20260422_ps_pl_128b_internal_512_shell_eval.md:11)
- [debug/20260422_ps_pl_128b_internal_512_shell_eval.md](/Users/yucheng/Documents/GitHub/flash_atten/debug/20260422_ps_pl_128b_internal_512_shell_eval.md:154)

This means:

- the shell direction is architecturally promising
- but real baseline RTL still requires a proper attention-native top and real algorithm modules

## 7. Reuse Boundary Table

### 7.1 Reuse Summary

| Module | Decision | Reason |
| --- | --- | --- |
| `rtl/pt_mem.v : PT_MEM_BANK` | reuse as-is | generic banked local storage |
| `rtl/pt_mem.v : PT_M_MEM` | reuse as-is or with rename | dual-use local read + export read is valuable |
| `rtl/sram.v` | reuse as-is | low-risk memory primitive |
| `rtl/csr_array.v` | high-value reuse | already close to PDF register map |
| `rtl/pt_md_v3.v` fill path | thin-mod reuse | useful DMA fill skeleton |
| `rtl/pt_md_v3.v` export path | thin-mod reuse | useful result export skeleton |
| `rtl/pt_ce_v3.v` execution partitioning | borrow structure only | good `shadow/exec/drain` partitioning |
| `rtl/gemm_v3.v` | conditional reuse | useful only if datatype plan matches |
| `rtl/gemu_v3.v` | conditional reuse | same as `GEMM_V3` |
| `rtl/quant.v` | do not directly reuse | not attention softmax semantics |
| `rtl/gema.v` | limited reference only | saturating add is not attention core logic |
| `rtl/csr_bank.v` | likely thin-mod or drop | current fields do not match new top |
| `rtl/pt_dispatch_v2.v` | rewrite | current op classification is PT-specific |
| `rtl/pt_malloc_v3.v` | rewrite | current residency logic is PT-op specific |
| `rtl/pt_dma_top_v3.v` | do not use as final top | wrapper semantics are mismatched |
| `rtl/pt_dma_top_v3_shell_sim.v` | use as architecture prototype only | helpful shell behavior, not final signoff code |

### 7.2 Most Valuable Structural Reuse

The strongest reuse candidates are:

- storage:
  - [rtl/pt_mem.v](/Users/yucheng/Documents/GitHub/flash_atten/rtl/pt_mem.v:1)
  - [rtl/pt_mem.v](/Users/yucheng/Documents/GitHub/flash_atten/rtl/pt_mem.v:112)
- DMA fill/export flow:
  - [rtl/pt_md_v3.v](/Users/yucheng/Documents/GitHub/flash_atten/rtl/pt_md_v3.v:279)
  - [rtl/pt_md_v3.v](/Users/yucheng/Documents/GitHub/flash_atten/rtl/pt_md_v3.v:437)
- pipeline partitioning style:
  - [rtl/pt_ce_v3.v](/Users/yucheng/Documents/GitHub/flash_atten/rtl/pt_ce_v3.v:205)

### 7.3 Lowest-Value Reuse

The least attractive pieces to carry over are:

- current PT opcode semantics
- current PT dispatch / malloc / low-level wrapper mailbox control

Evidence:

- [rtl/pt_dispatch_v2.v](/Users/yucheng/Documents/GitHub/flash_atten/rtl/pt_dispatch_v2.v:41)
- [rtl/pt_malloc_v3.v](/Users/yucheng/Documents/GitHub/flash_atten/rtl/pt_malloc_v3.v:234)

## 8. Recommended New Operator Internal Architecture

### 8.1 High-Level Architectural Intent

Build an attention-native top with:

- PDF-compatible CSR space
- DMA read `Q/K/V`
- tiled local buffer flow
- tile-level compute engine reuse where possible
- online softmax state
- local accumulated output buffer
- DMA write `O`

The preferred internal shape is still tile-based. A natural first baseline is:

- tile geometry `16 x 16`
- `Q` block:
  - `16 x 64`
- `K/V` block:
  - `16 x 64`
- `QK^T` score tile:
  - `16 x 16`
- `PV` partial output tile:
  - `16 x 16`, repeated across output column blocks as needed

### 8.2 Proposed Internal Modules

- `FA_TOP`
  - final attention-native top
- `FA_CSR`
  - AXI4-Lite register block
- `FA_RUN_CTRL`
  - run lifecycle management
- `FA_TILE_SCHED`
  - loops over `q_blk`, `kv_blk`, and output column blocks
- `FA_RD_DMA`
  - reads `Q/K/V` tiles into local buffers
- `Q_BUF`
- `K_BUF`
- `V_BUF`
- `P_BUF`
- `OACC_BUF`
- `FA_TILE_GEMM`
  - tile GEMM for `QK` and possibly `PV`
- `FA_SCORE_POST`
  - scale + mask + pre-softmax processing
- `FA_ROW_STATE`
  - row-wise `m/l` state
- `FA_P_WRITE`
  - writes probability tile to local buffer if needed
- `FA_OACC_UPDATE`
  - updates output accumulator buffer
- `FA_WR_DMA`
  - writes final `O`

### 8.3 Interface Groups

Recommended interface groups:

- `cfg_if`
  - register outputs:
    - `start`
    - `soft_reset`
    - `irq_en`
    - `causal_en`
    - `q_base`
    - `k_base`
    - `v_base`
    - `o_base`
    - `stride_bytes`
    - `neg_large`
    - `scale`
- `tile_req_if`
  - generic controller-to-submodule request:
    - `valid`
    - `ready`
    - metadata containing block indices and phase
- `bank_if`
  - local memory access
  - should preserve the feel of existing PT bank interfaces
- `gemm_if`
  - if reusing GEMM-like compute subcore
- `row_state_if`
  - per-row state read/update interface
- `dma_if`
  - descriptor valid/ready + stream valid/ready

### 8.4 Internal Data Flow

Recommended baseline dataflow:

1. `FA_CSR` captures the run configuration.
2. `FA_RUN_CTRL` raises one run.
3. `FA_TILE_SCHED` selects one `Q` block.
4. `FA_RD_DMA` loads `Q` into `Q_BUF`.
5. `FA_ROW_STATE` initializes row states for that block:
   - `m = -inf`
   - `l = 0`
   - `O_acc = 0`
6. For each `kv_blk`:
   - `FA_RD_DMA` loads `K` into `K_BUF`
   - `FA_RD_DMA` loads `V` into `V_BUF`
   - `FA_TILE_GEMM` computes `QK^T`
   - `FA_SCORE_POST` applies scale and causal mask
   - `FA_ROW_STATE` updates running `m/l`
   - probability tile is either buffered or consumed immediately
   - `FA_TILE_GEMM` computes `P * V`
   - `FA_OACC_UPDATE` rescales prior accumulator and adds current partial output
7. After all `kv_blk` complete:
   - `FA_WR_DMA` exports final `O`
8. Repeat for the next `Q` block until done.

## 9. Internal Module Interfaces And Data Flow Reporting

This section is a more explicit module-by-module view focused on the new operator.

### 9.1 `FA_CSR`

Role:

- owns the PDF-facing register map

Inputs:

- AXI4-Lite bus
- status from `FA_RUN_CTRL`

Outputs:

- configuration bundle to the rest of the design

Recommended outputs:

- `cfg_start_pulse`
- `cfg_soft_reset_pulse`
- `cfg_irq_en`
- `cfg_causal_en`
- `cfg_q_base[63:0]`
- `cfg_k_base[63:0]`
- `cfg_v_base[63:0]`
- `cfg_o_base[63:0]`
- `cfg_stride_bytes[31:0]`
- `cfg_neg_large[31:0]`
- `cfg_scale[31:0]`

### 9.2 `FA_RUN_CTRL`

Role:

- controls top-level run lifecycle

Inputs:

- start pulse from `FA_CSR`
- scheduler done
- error flags from downstream modules

Outputs:

- `busy`
- `done`
- `error`
- run enable / reset to all data path blocks

### 9.3 `FA_TILE_SCHED`

Role:

- generates block traversal order

Inputs:

- `busy`
- completion pulses from load / compute / writeback stages
- baseline constants:
  - `S = 256`
  - `d = 64`
  - tile sizes

Outputs:

- current block metadata:
  - `q_blk_idx`
  - `kv_blk_idx`
  - `o_col_blk_idx`
  - `is_last_kv`
  - `is_last_o_col`

Suggested outgoing request channels:

- `q_load_req`
- `kv_load_req`
- `qk_compute_req`
- `pv_compute_req`
- `o_store_req`

### 9.4 `FA_RD_DMA`

Role:

- fetches `Q/K/V` tiles from external memory into local banks

Inputs:

- block requests from `FA_TILE_SCHED`
- base addresses and stride from `FA_CSR`
- downstream bank ready

Outputs:

- DMA read descriptors
- stream writes into:
  - `Q_BUF`
  - `K_BUF`
  - `V_BUF`

Suggested internal channels:

- `rd_desc_valid/ready`
- `rd_desc_addr`
- `rd_desc_words`
- `rd_stream_valid/ready`
- `rd_stream_data`

### 9.5 `Q_BUF` / `K_BUF` / `V_BUF`

Role:

- store current tiles

Preferred implementation:

- derive from `PT_MEM_BANK`

Inputs:

- write traffic from `FA_RD_DMA`

Outputs:

- read traffic to `FA_TILE_GEMM`

### 9.6 `FA_TILE_GEMM`

Role:

- shared tile GEMM sub-kernel

Possible modes:

- `QK`
- `PV`

Inputs:

- local tile reads from buffers
- launch metadata from scheduler / local controller

Outputs:

- for `QK`:
  - raw score tile stream
- for `PV`:
  - partial output tile stream

Important note:

- if current `GEMM_V3` is reused, datatype mismatch must be handled explicitly

### 9.7 `FA_SCORE_POST`

Role:

- converts raw `QK` score tile into masked/scaled row-wise data for online softmax update

Inputs:

- raw score tile
- `scale`
- `causal_en`
- block indices needed for causal masking

Outputs:

- score tile after scale/mask
- row-local max candidates
- exponent or exponent-like numerics depending on approximation choice

### 9.8 `FA_ROW_STATE`

Role:

- maintains per-row running state

Inputs:

- row update candidates from `FA_SCORE_POST`
- block lifecycle control from scheduler

Stored state:

- `m_i`
- `l_i`

Optional:

- rescale factor for old accumulated output

Outputs:

- updated state
- rescale coefficient for `O_acc`
- possibly normalized probability tile or normalization helpers

### 9.9 `P_BUF`

Role:

- optional probability-tile staging

Use when:

- the chosen PV kernel wants `P` written in a specific packed layout before multiply with `V`

Alternative:

- bypass `P_BUF` if the chosen implementation supports on-the-fly probability consumption

### 9.10 `FA_OACC_UPDATE`

Role:

- maintains running output accumulator

Inputs:

- partial output tile from `PV`
- previous output accumulator tile from `OACC_BUF`
- rescale factor from `FA_ROW_STATE`

Outputs:

- updated output tile back into `OACC_BUF`

### 9.11 `OACC_BUF`

Role:

- stores running / final output tiles

Preferred implementation:

- derive from `PT_M_MEM`

Reason:

- needs both local update read port and final export read port

### 9.12 `FA_WR_DMA`

Role:

- exports final `O` back to external memory

Inputs:

- store request from scheduler
- tile data from `OACC_BUF`

Outputs:

- DMA write descriptors
- output stream / beats

## 10. Evaluation Of The Workflow

The proposed workflow is:

- first build the operator framework
- then fill reusable existing hardware blocks
- use scripts for missing modules
- finally replace the missing modules with RTL

### 10.1 Overall Evaluation

This workflow is recommended.

Current rating:

- feasibility: high
- startup speed: high
- final maintainability: high if interfaces are disciplined
- risk: medium

### 10.2 Why It Fits This Repo

This repo already contains:

- reusable hardware substrate
- shell-first exploration precedent
- a natural divide between:
  - structural hardware
  - algorithmically incomplete pieces

So this workflow matches the current asset distribution very well.

### 10.3 Hard Rule For Script Replacement

Script replacement is allowed only for algorithm blocks, not for system skeleton blocks.

Good proxy candidates:

- `FA_SCORE_POST`
- `FA_ROW_STATE`
- `FA_OACC_UPDATE`
- if necessary, parts of tile-level math golden behavior

Bad proxy candidates:

- DMA
- buffer address generation
- tile scheduler
- external interface timing
- local bank protocol

### 10.4 Strict Proxy Rules

All proxy blocks must:

- keep the exact future RTL interface shape
- use `valid/ready`
- model finite latency
- model backpressure
- avoid bypassing local buffers by directly peeking global arrays in a non-architectural way

Otherwise later replacement becomes a redesign rather than a swap.

## 11. Detailed Staged Plan

### 11.1 Stage 1: Build The Framework Shell

Goal:

- freeze the operator framework and system-level interfaces

Deliverables:

- `FA_TOP`
- `FA_CSR`
- `FA_RUN_CTRL`
- `FA_TILE_SCHED`
- `FA_RD_DMA`
- `FA_WR_DMA`
- `Q_BUF/K_BUF/V_BUF/P_BUF/OACC_BUF`

Reuse:

- `csr_array.v`
- `PT_MEM_BANK`
- `PT_M_MEM`
- `sram.v`

Acceptance:

- register map works
- `start -> busy -> done` lifecycle works
- DMA request paths are structurally correct
- tile traversal logic completes one full run skeleton

### 11.2 Stage 2: Plug Proxy Algorithm Blocks

Goal:

- achieve end-to-end functional closure with proxies

Proxy candidates:

- `FA_SCORE_POST_PROXY`
- `FA_ROW_STATE_PROXY`
- `FA_OACC_UPDATE_PROXY`
- optionally a compute proxy if datatype uncertainty is still unresolved

Acceptance:

- one `q_blk` correct end-to-end
- full `S = 256` end-to-end run completes
- causal and non-causal modes both behave correctly

### 11.3 Stage 3: Replace System-Like Proxies With Real Reuse Blocks

Goal:

- maximize true structural hardware early

Replace / refine:

- DMA internals toward `PT_MD_V3`-style fill/export paths
- local bank usage toward real `PT_MEM_BANK` / `PT_M_MEM`
- if datatype plan is sufficiently fixed, introduce real tile GEMM path

Acceptance:

- memory traffic shape is realistic
- tile schedule is no longer abstract
- only algorithm-specific modules remain proxied

### 11.4 Stage 4: Implement Online Softmax State RTL

Goal:

- replace the most attention-specific and architecturally critical blocks

Replace:

- `FA_SCORE_POST`
- `FA_ROW_STATE`

Acceptance:

- numerical error fits baseline tolerance
- backpressure does not corrupt row state
- causal corner cases pass

### 11.5 Stage 5: Implement Output Accumulator Update RTL

Goal:

- replace output accumulation proxy

Replace:

- `FA_OACC_UPDATE`

Acceptance:

- multiple `kv_blk` accumulation is correct
- old-acc rescaling is correct
- final output matches golden within tolerance

### 11.6 Stage 6: Finalize Compute Kernel Strategy

Goal:

- settle whether the compute subcore is:
  - a PT-derived reused GEMM
  - or a newly written baseline-accurate `Q8.8` tile core

Acceptance:

- full RTL end-to-end
- no algorithm proxy left
- baseline flow fully reproducible

## 12. Risk Register And Controls

### 12.1 Risk: Interface Drift Between Proxy And RTL

Symptom:

- proxies are too permissive
- final RTL cannot be dropped in cleanly

Control:

- freeze `valid/ready`, latency contract, and metadata fields from day one

### 12.2 Risk: Datatype Drift

Symptom:

- early framework silently assumes packed-int8
- later baseline `Q8.8` integration becomes expensive

Control:

- freeze external baseline datatype early
- if using reused compute kernels temporarily, clearly isolate the conversion boundary

### 12.3 Risk: Scheduler Grows Around Unrealistic Proxy Behavior

Symptom:

- scheduler depends on zero-latency or bulk-complete behavior

Control:

- proxies must model real pipeline latency and backpressure

### 12.4 Risk: Over-Reuse Of PT Control Semantics

Symptom:

- new design starts inheriting `LOAD/MATMUL/MATADD` logic where attention-native control would be simpler

Control:

- only reuse PT structural blocks
- do not reuse PT low-level control semantics unless a direct benefit is proven

### 12.5 Risk: Shell Prototype Confused With Signoff Path

Symptom:

- shell-specific simulation code leaks into final target RTL plan

Control:

- treat shell code as architecture guidance only
- keep final path separate from shell-only artifacts

## 13. Practical Next-Step Recommendation

The most pragmatic execution order is:

1. freeze the attention-native top-level module partition
2. adopt `csr_array.v` as the baseline register map seed
3. decide and freeze baseline internal word packing for `Q8.8`
4. instantiate local buffer skeleton using `PT_MEM_BANK` / `PT_M_MEM`
5. define a strict proxy interface for:
   - score postprocess
   - row state
   - output accumulator update
6. keep current PT wrapper family intact
7. build the new top in parallel rather than mutating `PT_DMA_TOP_V3`

## 14. Final Architectural Recommendation

The recommended final architecture is:

- a new attention-native top
- PDF-compatible AXI4-Lite register space
- DMA-managed `Q/K/V/O`
- PT-derived storage and possibly PT-derived tile compute reuse
- newly built online-softmax / row-state / output-accumulation logic

The current `PT_DMA_TOP_V3` should be treated as:

- a mature GEMM-wrapper line
- a useful performance and substrate reference
- but not the final semantic home for the competition baseline attention operator space

The shell exploration should be treated as:

- a valuable prototype
- evidence that shell-side local reduction is architecturally promising
- but not final signoff RTL

In short:

- reuse the substrate
- rebuild the operator semantics
- keep the top-level control model attention-native
