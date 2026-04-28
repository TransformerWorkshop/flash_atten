# Flash Attention Documentation

This document is the architecture and bring-up guide for the current Flash Attention baseline in this repository. The implementation baseline is rooted at [`rtl/fa_top_baseline.v`](../../rtl/fa_top_baseline.v) and was marked by the tag `fa-baseline-20260428` before being merged into `main`.

## 1. Scope

The current Flash Attention design is an RTL accelerator for one fixed full-attention problem shape:

- sequence length: `256`, scheduled as `16` Q blocks by `16` KV blocks
- Q block size: `16` rows
- KV block size: `16` rows
- head dimension: `64` 16-bit lanes, packed as two lanes per 32-bit word
- external memory path: one 128-bit AXI read/write master
- software interface: AXI-Lite CSR block

The top is named `FA_TOP_BASELINE` because it is the currently signed-off comparison point for later area and timing work. It is not a toy model: it contains the real load, compute, online-softmax, accumulation, and store path used by the FA regression suite.

## 2. Documentation Map

- Flash Attention architecture: this file
- PT architecture used elsewhere in the repo: [Processing Tile README](<../Processing Tile/README.md>)
- FA area/timing checkpoint after 4x16 GEMM: [`debug/20260428_fa_top_dc_gemm4x16_8core.md`](../../debug/20260428_fa_top_dc_gemm4x16_8core.md)
- FA row-buffer DRC cleanup checkpoint: [`debug/20260428_fa_rowbuf_write_granularity_drc.md`](../../debug/20260428_fa_rowbuf_write_granularity_drc.md)

For exact behavior, the RTL and cocotb tests are authoritative. Debug reports capture measured checkpoints and should be treated as dated evidence, not live specifications.

## 3. Top-Level Integration

### 3.1 Top Module

[`FA_TOP_BASELINE`](../../rtl/fa_top_baseline.v) wraps three major pieces:

| Block | RTL | Role |
| --- | --- | --- |
| CSR front end | [`FA_CSR`](../../rtl/fa_csr.v) | AXI-Lite configuration, status, counters, start, soft reset, and IRQ enable |
| Core datapath | [`FA_CORE_BASELINE`](../../rtl/fa_core_baseline.v) | Q/K/V load scheduling, QK, score processing, online row state, PV, OACC update, and O store |
| DMA shell | [`fa_dma_shell.v`](../../rtl/fa_dma_shell.v) | Converts core read/write descriptors into 128-bit AXI memory transactions |

The public top-level ports are grouped as:

| Group | Ports | Meaning |
| --- | --- | --- |
| Clock/reset | `clk`, `rstn`, `clear` | Active-low reset plus runtime clear |
| AXI-Lite slave | `s_axil_*` | CSR access from software or a testbench |
| AXI read master | `m_axi_ar*`, `m_axi_r*` | Q/K/V tile fetches from external memory |
| AXI write master | `m_axi_aw*`, `m_axi_w*`, `m_axi_b*` | O tile stores to external memory |
| Interrupt | `irq` | Pulses/levels according to CSR IRQ enable and core done/error status |

### 3.2 CSR Map

The CSR address width is 7 bits and the active register map is:

| Offset | Register | Access | Bits |
| ---: | --- | --- | --- |
| `0x00` | `CTRL` | RW | bit 0 `start`, bit 1 `soft_reset`, bit 2 `irq_en` |
| `0x04` | `STATUS` | RO | bit 0 `busy`, bit 1 `done`, bit 2 `error` |
| `0x08` | `CFG` | RW | bit 0 `causal_en` |
| `0x14` | `Q_BASE_L` | RW | Q base address low 32 bits |
| `0x18` | `Q_BASE_H` | RW | Q base address high 32 bits |
| `0x1c` | `K_BASE_L` | RW | K base address low 32 bits |
| `0x20` | `K_BASE_H` | RW | K base address high 32 bits |
| `0x24` | `V_BASE_L` | RW | V base address low 32 bits |
| `0x28` | `V_BASE_H` | RW | V base address high 32 bits |
| `0x2c` | `O_BASE_L` | RW | O base address low 32 bits |
| `0x30` | `O_BASE_H` | RW | O base address high 32 bits |
| `0x34` | `STRIDE_BYTES` | RW | Row/block stride in bytes |
| `0x38` | `NEG_LARGE` | RW | Mask fill value used for causal masking |
| `0x3c` | `SCALE` | RW | QK scale word |
| `0x40` | `CYCLES` | RO | Core run cycle counter |
| `0x44` | `RD_BYTES` | RO | Accepted AXI read payload bytes |
| `0x48` | `WR_BYTES` | RO | Accepted AXI write payload bytes |

`start_pulse` is generated on the rising edge of `CTRL.start`. `soft_reset_pulse` is generated on the rising edge of `CTRL.soft_reset`.

The CSR block reports `config_error` if any Q/K/V/O base or `stride_bytes` is not 16-byte aligned. A config error is ORed into `STATUS.error`, and a start pulse is suppressed while the configuration is invalid.

### 3.3 Programming Sequence

1. Write Q/K/V/O base addresses.
2. Write `STRIDE_BYTES`, `NEG_LARGE`, and `SCALE`.
3. Write `CFG.causal_en` for causal or noncausal mode.
4. Optionally set `CTRL.irq_en`.
5. Toggle `CTRL.start` from `0` to `1`.
6. Poll `STATUS` or wait for `irq`.
7. Read `CYCLES`, `RD_BYTES`, and `WR_BYTES` for profiling.
8. Use `CTRL.soft_reset` or top-level `clear` before reprogramming after an error path.

## 4. Datapath

### 4.1 Main Flow

The scheduled datapath for one Q block is:

1. Load Q tile.
2. Initialize online row state.
3. Clear O accumulator.
4. For each KV block:
   - load K tile
   - load V tile, with overlap where the scheduler can use it
   - run QK GEMM
   - apply scale and causal/noncausal mask
   - update online softmax row state
   - bypass the probability tile directly into PV
   - run PV GEMM
   - rescale and add into OACC
5. Store the finished O block.
6. Advance to the next Q block.

The scheduler is implemented by [`FA_TILE_SCHED`](../../rtl/fa_tile_sched.v). It has explicit states for Q load, row init, OACC clear, K/V load, QK, score post, row update, PV, OACC update, and O store. K prefetch is opportunistic during several downstream states.

### 4.2 Core Blocks

| Block | RTL | Role |
| --- | --- | --- |
| Run control | [`FA_RUN_CTRL`](../../rtl/fa_run_ctrl.v) | Busy/done/error state and cycle counting |
| Tile scheduler | [`FA_TILE_SCHED`](../../rtl/fa_tile_sched.v) | Top-level phase sequencing for 16 Q blocks and 16 KV blocks |
| Read DMA | [`FA_RD_DMA`](../../rtl/fa_dma_shell.v) | Issues Q/K/V read descriptors and writes returned words into tile buffers |
| Write DMA | [`FA_WR_DMA`](../../rtl/fa_dma_shell.v) | Reads exported O rows and emits write descriptors/data |
| Q/K buffers | [`fa_buffers_real.v`](../../rtl/fa_buffers_real.v) | Register-backed tile buffers feeding QK |
| V/PV buffer | [`FA_V_BUF_PV_REAL`](../../rtl/fa_buffers_real.v) | Layout-optimized V storage for PV reads |
| Shared QK/PV core | [`FA_QK_PV_SHARED_CORE_REAL`](../../rtl/fa_cores_real.v) | One shared 4x16 `GEMM_V3` array, time-multiplexed for QK and PV |
| Score post | [`FA_SCORE_POST_REAL`](../../rtl/fa_score_post_real.v) | Scale and causal/noncausal masking |
| Row state | [`FA_ROW_STATE_REAL`](../../rtl/fa_row_state_real.v) | Online softmax state, probability tile, rescale vector |
| P bypass | [`FA_P_BYPASS_REAL`](../../rtl/fa_p_bypass_real.v) | Presents row-state probability rows directly to PV without a separate P SRAM |
| OACC buffer | [`FA_OACC_BUF_REAL`](../../rtl/fa_buffers_real.v) | 16-bit Q4.12 internal accumulator storage with export repacking |
| OACC update | [`FA_OACC_UPDATE_REAL`](../../rtl/fa_oacc_update_real.v) | Rescale old accumulator and add new PV partials |

### 4.3 Current Area-Oriented Choices

The current baseline already includes these area optimizations:

- OACC internal storage is compressed to 16-bit Q4.12.
- P buffer SRAM has been removed; PV reads probability rows through `FA_P_BYPASS_REAL`.
- QK and PV share one `GEMM_V3` instance.
- The shared GEMM is reduced to a 4x16 array and serializes row blocks.
- Q, K, V/PV, OACC, QK-result, and PV-result row buffers use register-backed shallow storage where this is smaller than the available SRAM macro option.
- Wide synthesized debug mirrors are excluded from the synthesis path.
- Several wide reset/clear and write-mask fanout paths have been trimmed.

These choices trade extra cycles for much lower standard-cell area while staying below the 300k-cycle target for the measured full-run profile.

## 5. Numeric Formats

The external Q/K/V/O payload convention is packed 32-bit words, each containing two 16-bit lanes. The current fixed-point datapath is not IEEE floating point.

Important internal conventions:

- QK and PV use `GEMM_V3` with 32-bit packed operands and 16-bit element lanes.
- QK accumulates across the 64-lane head dimension using `num_acc = 32`.
- PV uses probability rows against V data and accumulates with `num_acc = 8` per serialized sub-block.
- OACC stores accumulated O rows as 16-bit Q4.12 internally.
- Export repacks OACC pairs into the externally visible 32-bit packed output words.

Precision tracking lives in [`scripts/fa_precision_analysis.py`](../../scripts/fa_precision_analysis.py). The current sampled causal full-KV precision checkpoint is:

- worst sampled mean error: `0.022474`
- worst sampled max error: `0.042657`

Both are below the working thresholds of mean error `<= 0.03` and max error `<= 0.10`.

## 6. Verification

### 6.1 Local Gates

Common smoke and focused checks:

```bash
python3 -m py_compile \
  sim/cocotb/tests/test_fa_baseline.py \
  scripts/fa_precision_analysis.py \
  scripts/fa_baseline_profile.py

iverilog -g2012 -I rtl -s FA_TOP_BASELINE_SIM \
  -o /tmp/fa_top_baseline_sim_check.out rtl/*.v

iverilog -g2012 -DSYNTHESIS -I rtl -s FA_TOP_BASELINE \
  -o /tmp/fa_top_baseline_synth_check.out rtl/*.v
```

Focused FA regression:

```bash
python3 sim/cocotb/run.py fa_baseline \
  --testcase test_fa_numeric_single_q_single_kv_noncausal,test_fa_numeric_single_q_full_kv_causal,test_fa_baseline_single_q_full_kv_causal_with_backpressure \
  --rebuild

python3 sim/cocotb/run.py fa_full \
  --testcase test_fa_baseline_full_causal_end_to_end,test_fa_baseline_full_noncausal_and_soft_reset \
  --rebuild
```

Full FA make target:

```bash
make -C sim/cocotb fa_ci SIM=verilator
```

Precision and cycle profiling:

```bash
python3 scripts/fa_precision_analysis.py \
  --case single_q_full_kv_causal \
  --q-row-start 0 --q-row-start 112 --q-row-start 240

python3 scripts/fa_baseline_profile.py --sim verilator
```

The current profile checkpoint is `223984` estimated cycles.

### 6.2 Remote Signoff

Remote Synopsys runs use:

- host: `ic-canopsys`
- workspace: `~/Desktop/flash_atten`
- top: `FA_TOP_BASELINE`
- SpyGlass project: `synopsys/spyglass/flow/fa_top_baseline_lint.prj`

The current top-level SpyGlass checkpoint is:

- `0 error / 93 warnings / 3 infos`
- log: `synopsys/spyglass/logs/fa_top_baseline_lint_20260428_141042_rowbuf_gran.log`
- report dir: `synopsys/spyglass/flow/fa_top_baseline_lint/consolidated_reports/FA_TOP_BASELINE_lint_lint_rtl/`

The latest valid top-level DC checkpoint before the row-buffer write-granularity cleanup reported:

- cell area: `545,044.935124`
- NAND2 equivalent: `1,853,894`
- setup WNS/TNS: `0.00 / 0.00`
- max-transition violations: `60`
- main visible DRC issue: high-fanout GEMM clock net

After the row-buffer write-granularity cleanup, area is estimated at about `1.83M-1.85M` NAND2 equivalent. A fresh DC run is needed to convert that estimate into a signoff number.

## 7. Known Limitations And Risks

- The current FA baseline is fixed around the 256-token, 64-lane-head schedule. Runtime sequence length and head dimension are not CSR-programmable.
- The design is optimized for area and uses serialized QK/PV work through one shared 4x16 GEMM array.
- The remaining DRC risk is dominated by clock/reset and wide datapath fanout, especially around GEMM and shallow register row buffers.
- Hold reports had near-zero residual paths in the last valid top DC run; final tapeout-style closure still needs physical signoff.
- CSR alignment is strict: base addresses and stride must be 16-byte aligned.
- The remote Synopsys flow reads `~/Desktop/flash_atten/synopsys/rtl`, so local RTL must be synced into that tree before SpyGlass or DC measurements.

## 8. Change Checklist

For every FA RTL change:

1. Keep the public CSR and AXI behavior stable unless the change explicitly updates this document.
2. Run focused local FA regressions and precision profiling.
3. Check `estimated_cycles < 300000`.
4. Run top-level SpyGlass on `FA_TOP_BASELINE`.
5. For area-sensitive changes, run or estimate against the latest top-level DC baseline.
6. Archive results under `debug/YYYYMMDD_fa_*.md`.
7. Keep unrelated PT/app/debug experiments out of FA commits unless they are required by the change.
