# FA Stage1-2 Implementation Report

- Timestamp: `2026-04-24`
- Scope:
  - records the current implementation status for stage1/stage2 of the attention baseline shell
  - complements [20260424_attention_operator_space_sop.md](./20260424_attention_operator_space_sop.md)
- Intent:
  - separate implementation truth from planning intent
  - make the current milestone auditable and handoff-ready

## 1. Summary

Stage1/stage2 simulation-first infrastructure has been landed for a new parallel baseline attention top:

- new top:
  - [`rtl/fa_top_baseline_sim.v`](../rtl/fa_top_baseline_sim.v)
- key properties:
  - independent of `PT_DMA_TOP_V3`
  - uses a PDF-like AXI4-Lite CSR space
  - uses simulation DMA-shell interfaces rather than full AXI master
  - uses Q8.8-based local buffer conventions
  - uses behavioral RTL proxy modules for the missing algorithm blocks

At this milestone:

- framework shell is implemented
- stage2 behavioral proxy path is implemented
- critical single-test flows are passing in cocotb
- the all-in-one suite entry exists in `run.py`
- the full suite is currently slower/heavier than the individual single-test runs and should be treated as a follow-up optimization target rather than the primary validation path for this milestone

## 2. Implemented Modules

### 2.1 New RTL Modules

- [`rtl/fa_csr.v`](../rtl/fa_csr.v)
  - wraps `csr_array.v`
  - exposes `start_pulse`, `soft_reset_pulse`, `causal_en`, `Q/K/V/O_BASE`, `STRIDE_BYTES`, `NEG_LARGE`, `SCALE`
- [`rtl/fa_run_ctrl.v`](../rtl/fa_run_ctrl.v)
  - manages `busy/done/error/cycles`
  - keeps `DONE` sticky until next `START` or `SOFT_RESET`
- [`rtl/fa_buffers.v`](../rtl/fa_buffers.v)
  - stage1/2 local tile buffer wrappers
  - `Q_BUF`, `K_BUF`, `V_BUF`, `P_BUF`, `OACC_BUF`
  - reuses `PT_MEM_BANK` / `PT_M_MEM` structure while maintaining stage1/2 shadow copies for direct behavioral access
- [`rtl/fa_tile_sched.v`](../rtl/fa_tile_sched.v)
  - fixed traversal:
    - `q_blk = 0..15`
    - `kv_blk = 0..15`
  - exact stage sequence per `q_blk`:
    - `Q load`
    - `row init`
    - `OACC clear`
    - repeated `K load -> V load -> QK -> score -> row update -> PV -> OACC update`
    - final `O store`
- [`rtl/fa_dma_shell.v`](../rtl/fa_dma_shell.v)
  - `FA_RD_DMA`
  - `FA_WR_DMA`
  - simulation shell interface:
    - `rd_desc_valid/ready`
    - `rd_desc_addr`
    - `rd_desc_words`
    - `rd_desc_tag`
    - `rd_data_valid/ready`
    - `rd_data`
    - `rd_data_last`
    - `wr_desc_valid/ready`
    - `wr_desc_addr`
    - `wr_desc_words`
    - `wr_data_valid/ready`
    - `wr_data`
    - `wr_data_last`
- [`rtl/fa_proxies.v`](../rtl/fa_proxies.v)
  - `FA_TILE_GEMM_PROXY`
  - `FA_SCORE_POST_PROXY`
  - `FA_ROW_STATE_PROXY`
  - `FA_OACC_UPDATE_PROXY`

### 2.2 New Simulation Files

- [`sim/cocotb/tests/fa_baseline_env.py`](../sim/cocotb/tests/fa_baseline_env.py)
  - AXI-Lite helper
  - memory image / DMA shell model
  - Q8.8 packing/unpacking helpers
  - golden attention implementation
  - backpressure patterns
- [`sim/cocotb/tests/test_fa_baseline.py`](../sim/cocotb/tests/test_fa_baseline.py)
  - framework smoke test
  - single-block functional checks
  - full baseline causal/non-causal checks
  - backpressure and soft-reset coverage

### 2.3 Runner Integration

- updated [`sim/cocotb/run.py`](../sim/cocotb/run.py)
  - added suite:
    - `fa_baseline`
  - added top:
    - `FA_TOP_BASELINE_SIM`

## 3. Locked Stage1-2 Conventions

### 3.1 Datatype / Packing

Stage1/2 are locked to a Q8.8-oriented buffer skeleton:

- each logical element is signed 16-bit Q8.8
- each 32-bit local word stores two Q8.8 elements

Tile layouts:

- `Q/K/V/OACC`
  - shape: `16 x 64`
  - row-major
  - `32` words per row
  - `512` words per tile
- `score/P`
  - shape: `16 x 16`
  - row-major
  - `8` words per row
  - `128` words per tile

### 3.2 Control Flow

Stage1/2 scheduler semantics are fixed to:

- outer loop:
  - `q_blk = 0..15`
- inner loop:
  - `kv_blk = 0..15`
- no `o_col_blk` loop in stage1/2
- `PV` proxy produces the full `16 x 64` partial output in one request

### 3.3 Proxy Latencies

Fixed behavioral proxy latencies:

- `FA_TILE_GEMM_PROXY`
  - `QK`: `8 cycles`
  - `PV`: `8 cycles`
- `FA_SCORE_POST_PROXY`
  - `4 cycles`
- `FA_ROW_STATE_PROXY`
  - `2 cycles`
- `FA_OACC_UPDATE_PROXY`
  - `4 cycles`

## 4. Stage1/2 Behavioral Scope

### 4.1 What Is Real In This Milestone

The following are implemented as real RTL framework blocks:

- top-level wiring
- CSR plumbing
- run lifecycle
- tile scheduler
- DMA descriptor / stream shell behavior
- local tile-buffer plumbing
- writeback path

### 4.2 What Is Still Proxy Behavior

The following are still behavioral RTL proxies:

- `QK` tile compute
- score scaling / mask postprocess
- online row-state update
- `PV` tile compute
- output-accumulator update

These are intentionally implemented in RTL, not in cocotb direct-drive form, so that:

- stage1/2 already use the future module boundaries
- later replacement can stay module-for-module

### 4.3 What Is Explicitly Not Done Yet

- no full AXI master implementation
- no signoff-oriented synthesized top
- no replacement of proxies with final arithmetic RTL
- no optimization of stage2 runtime
- no integration with existing PT wrapper suites beyond parallel coexistence

## 5. Current Validation Status

### 5.1 Static / Syntax Checks

The following checks passed during this milestone:

```bash
python3 -m py_compile sim/cocotb/tests/fa_baseline_env.py sim/cocotb/tests/test_fa_baseline.py
PATH=/opt/homebrew/bin:/usr/local/bin:$PATH \
iverilog -g2012 -I rtl -s FA_TOP_BASELINE_SIM -o /tmp/fa_top_baseline_sim_check.out rtl/*.v
```

### 5.2 Individual Cocotb Tests Confirmed Passing

The following tests were re-run as single-test jobs and passed:

- `test_fa_baseline_csr_and_framework_smoke`
- `test_fa_baseline_single_q_single_kv_noncausal`
- `test_fa_baseline_single_q_full_kv_causal_with_backpressure`
- `test_fa_baseline_full_causal_end_to_end`
- `test_fa_baseline_full_noncausal_and_soft_reset`

These cover:

- CSR map and framework lifecycle
- stage1 shell wiring
- single-block functional correctness
- causal + backpressure interaction
- full baseline `S=256`, `d=64` causal end-to-end
- full baseline non-causal run and soft reset behavior

### 5.3 Full-Suite Status

The `fa_baseline` suite entry exists and builds correctly through:

```bash
python3 sim/cocotb/run.py fa_baseline --sim icarus
```

However, during this milestone the full multi-test single-process suite was observed to be much slower/heavier than single-test runs.

Current practical interpretation:

- use the per-test runner path as the authoritative validation path for stage1/2
- treat suite-level runtime stabilization as the next verification task, not as a blocker for recording the implementation milestone

## 6. Known Limitations

### 6.1 Proxy Runtime Cost

The stage2 proxies are accurate enough for milestone closure, but still expensive in Icarus for long multi-test suite runs.

Most likely contributors:

- behavioral arithmetic intensity inside proxy modules
- long full-baseline loops across `16 x 16` block space
- cocotb suite serialization overhead

### 6.2 Arithmetic Is Behavioral, Not Final

The proxy path is not intended to represent the final arithmetic microarchitecture.

In particular:

- score generation
- softmax / row-state update
- `P * V`
- output accumulation

are all still expressed as stage2 placeholders.

### 6.3 Buffer Wrappers Use Shadow Copies

The stage1/2 tile-buffer wrappers intentionally keep shadow copies for direct access by the proxy modules.

This is acceptable for the simulation-first milestone, but should not be treated as the final storage microarchitecture.

### 6.4 Current Runner Truth

The most reliable current validation method is:

- single-test build + run

rather than:

- one large `fa_baseline` suite process for all tests

## 7. Relationship To The SOP

Relative to the SOP in [20260424_attention_operator_space_sop.md](./20260424_attention_operator_space_sop.md):

- `stage1`
  - implemented
- `stage2`
  - implemented in behavioral RTL form
- `stage3+`
  - not started in this milestone

The implementation follows the intended route:

- new parallel top
- Q8.8 skeleton
- real framework RTL
- behavioral RTL proxies

It also preserves the long-term module replacement contract:

- `FA_TILE_GEMM_PROXY` -> real tile compute
- `FA_SCORE_POST_PROXY` -> real score/mask block
- `FA_ROW_STATE_PROXY` -> real online-softmax row-state block
- `FA_OACC_UPDATE_PROXY` -> real O-accumulator update block

## 8. Recommended Immediate Next Steps

### 8.1 Verification Stabilization

- make `python3 sim/cocotb/run.py fa_baseline --sim icarus` practical as a full suite run
- likely approaches:
  - split heavy and light tests into separate suite entries
  - reduce per-test runtime in proxy arithmetic
  - make runner support focused `testcase` invocation more naturally

### 8.2 Remove Stage2 Shadow-Copy Dependence

- progressively reduce direct dependence on shadow copies inside buffer wrappers
- move toward explicit read interfaces that real RTL modules can share

### 8.3 Replace The Most Important Proxy First

Recommended replacement order:

1. `FA_ROW_STATE_PROXY`
2. `FA_SCORE_POST_PROXY`
3. `FA_OACC_UPDATE_PROXY`
4. `FA_TILE_GEMM_PROXY`

This keeps the framework stable while replacing the most attention-specific logic first.

### 8.4 Add Performance / Traffic Counters

The stage1/2 top now has the right shell shape to add:

- `RD_BYTES`
- `WR_BYTES`
- tile request counters
- per-phase cycle counters

That should be done before deeper arithmetic replacement, so later stages already have measurement hooks.

## 9. Bottom Line

This milestone successfully establishes:

- a new attention-native simulation top
- an isolated stage1/2 framework path
- Q8.8 baseline buffer and interface conventions
- deterministic stage2 proxy boundaries
- passing critical individual cocotb validations

The main remaining gap at this point is not architectural uncertainty; it is:

- replacing behavioral stage2 math with real RTL modules
- and tightening suite-level verification ergonomics
