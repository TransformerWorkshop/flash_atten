# FA Baseline Operator Assessment

- Date: `2026-04-26`
- Workspace: current dirty working tree
- Scope: `FA_TOP_BASELINE_SIM` performance profile plus selected full/numeric regressions

## Executive Summary

The current FA baseline is strong on throughput and weak on final correctness closure.

- Throughput is already below the contest target:
  - conservative serial stage sum: `158,448 cycles`
  - scheduler-overlap full-flow estimate: `96,008 cycles`
  - Verilator full causal elapsed sim time: `976,010 ns`, about `97,601 cycles` at a 10 ns clock
- Precision/function is not submission-ready:
  - directed single-Q/single-KV noncausal: `PASS`
  - single-Q/full-KV causal: `FAIL`, `mean_err=0.0311855 > 0.03`
  - full causal: `FAIL`, `mean_err=0.0426581 > 0.03`
  - full noncausal + soft reset: lifecycle/status error fixed; remaining failure is precision-only, `mean_err=0.0416949 > 0.03`
- Area/resource is plausible but not signed off:
  - latest FA top SpyGlass: `0 errors / 88 warnings / 2 infos`
  - hard SRAM mapping uses `144` instances of `64x64` macros
  - physical macro bit capacity is `589,824 bits` (`72 KiB`)
  - logical live buffer payload is about `102,400 bits` (`12.5 KiB`)
  - macro bit utilization is only about `17.4%`, mainly because shallow 8/16/32-deep buffers are packed into 64-deep macros

## Precision

Current precision status is borderline-to-failing rather than fundamentally broken.

| Test | Result | Note |
| --- | --- | --- |
| `test_fa_numeric_single_q_single_kv_noncausal` | PASS | local/simple numeric path is good |
| `test_fa_numeric_single_q_full_kv_causal` | FAIL | `mean_err=0.0311855`, slightly over `0.03` |
| `test_fa_baseline_full_causal_end_to_end` | FAIL | `mean_err=0.0426581`, materially over `0.03` |
| `test_fa_baseline_full_noncausal_and_soft_reset` | FAIL | lifecycle/status error fixed; now reaches output comparison and fails only on `mean_err=0.0416949` |

Risk interpretation:

- The causal precision miss grows from a marginal single-Q/full-KV miss to a full-run miss, so the dominant error source is likely accumulated softmax/OACC approximation rather than a one-off output packing issue.
- `row_state` is now much faster than before (`valid row_update = 90 cycles`), but this speedup may have reduced reciprocal/normalization accuracy enough to exceed the mean-error threshold.
- The noncausal soft-reset lifecycle failure was caused by stale DMA-agent beats surviving the abort in the cocotb shell model; it is now covered by `test_fa_state_noncausal_restart_after_soft_reset_no_error`.

Recommended precision debug order:

1. Dump row-wise mean/max error for full causal and locate whether error is concentrated in high-index rows, diagonal rows, or all rows.
2. Compare RTL row state against the Python golden at tile boundaries: `m`, `l`, `p_tile`, and `oacc` after each `kv_blk`.
3. Sweep reciprocal/LUT precision and rounding:
   - reciprocal iterations or table width
   - exp LUT address granularity
   - `Q16.16 -> Q8.8` rounding/saturation in `p_tile` and output
4. Re-run full causal after each change; target margin should be `mean_err <= 0.025`, not just `<=0.03`.
5. Keep the soft-reset/noncausal lifecycle regression in the gate while precision is debugged separately.

## Area And Resources

No fresh Genus area/Fmax report for `FA_TOP_BASELINE` was found locally, so this is a resource assessment, not final area signoff.

Hard SRAM mapping:

| Buffer | Logical organization | Macro instances |
| --- | --- | ---: |
| Q tile buffer | `4 banks x 512-bit rows x depth 8` | 32 |
| K tile buffer | `4 banks x 512-bit rows x depth 8` | 32 |
| V tile shadow buffer | `4 banks x 512-bit rows x depth 8` | 32 |
| V PV-layout buffer | `512-bit rows x depth 32` | 8 |
| P buffer | `512-bit rows x depth 8` | 8 |
| OACC row-read copy | `1024-bit rows x depth 16` | 16 |
| OACC export-read copy | `1024-bit rows x depth 16` | 16 |
| Total | - | 144 |

Resource conclusions:

- The hardmacro move is directionally good for timing and avoids synthesizing wide SRAM-like arrays into flops.
- Macro count is high for the small logical payload because `64x64` macros are depth-inefficient for 8/16/32-deep tile buffers.
- OACC duplication is useful for read/export coherence, but it is also a resource hotspot.
- SpyGlass is usable as a structural gate, but the remaining reset and sequential-coding warnings should be cleaned before Genus signoff:
  - `AsyncResetOtherUse`: 1
  - `InitValUsingNBA`: 15
  - `W415a`: 72

Resource optimization candidates:

1. Repack shallow buffers to improve macro utilization: combine multiple logical rows/banks in the 64-deep dimension.
2. Share/re-time V shadow and PV-layout storage if the layout transform can be generated on read.
3. Revisit OACC dual-copy design after correctness is stable; merge copies only if timing and export backpressure allow.
4. Run Genus with SRAM black boxes and report:
   - NAND2-equivalent gates
   - macro area
   - WNS/TNS at target clocks
   - power

## Throughput

Current throughput is strong.

| Metric | Cycles |
| --- | ---: |
| conservative serial stage sum | 158,448 |
| scheduler-overlap estimate | 96,008 |
| full causal Verilator sim time at 10 ns clock | about 97,601 |
| contest target | <300,000 |

Top serial bottlenecks:

| Stage | Per invocation | Count | Total | Share |
| --- | ---: | ---: | ---: | ---: |
| `k_load` | 130 | 256 | 33,280 | 21.00% |
| `v_load` | 130 | 256 | 33,280 | 21.00% |
| `pv` | 110 | 256 | 28,160 | 17.77% |
| `row_update` | mixed | 256 | 17,280 | 10.91% |
| `oacc_update` | 66 | 256 | 16,896 | 10.66% |
| `qk` | 53 | 256 | 13,568 | 8.56% |
| `store` | 562 | 16 | 8,992 | 5.68% |

Bandwidth:

- Read descriptors per full run: `16 * (1 Q + 16 K + 16 V) = 528`
- Write descriptors per full run: `16`
- Bytes per tile: `512 words * 4 = 2048 bytes`
- Expected RD bytes: `528 * 2048 = 1,081,344 bytes`
- Expected WR bytes: `16 * 2048 = 32,768 bytes`

Throughput conclusions:

- The previous load bottleneck has been substantially improved: tile load is now `130 cycles`, not the earlier `514 cycles`.
- K/V traffic still dominates because each `q_blk` reloads all 16 K/V tiles.
- The next useful performance work is K/V reuse across `q_blk`, not another small local tweak to `score_post` or CSR.

## Recommended Priorities

### P0: Correctness Before More Speed

Fix full causal and full noncausal precision first; keep the noncausal soft-reset lifecycle regression green.

- Why: performance already passes the cycle target, but precision correctness does not.
- Target: full causal and full noncausal both pass with `mean_err <= 0.03`, `max_err <= 0.10`; prefer `mean_err <= 0.025` for margin.
- Likely files:
  - `rtl/fa_row_state_real.v`
  - `rtl/fa_recip_q16_16.v`
  - `rtl/fa_score_post_real.v`
  - `rtl/fa_oacc_update_real.v`
  - `rtl/fa_run_ctrl.v`
  - `rtl/fa_tile_sched.v`
  - `sim/cocotb/tests/fa_baseline_env.py`

### P1: Genus Area/Fmax Signoff

Run a clean synthesis report for `FA_TOP_BASELINE`.

- Why: current resource judgment is based on macro count and lint, not final NAND2-equivalent area.
- Required outputs:
  - Fmax or WNS/TNS at target clocks
  - equivalent gate count
  - macro count/area
  - power

### P2: SRAM Packing / Macro Utilization

Improve the `64x64` macro packing efficiency.

- Why: current logical payload is about `12.5 KiB`, physical macro capacity is `72 KiB`.
- Expected benefit: area reduction without changing math.
- Risk: medium; buffer addressing and layout tests must be expanded.

### P3: K/V Reuse Across Q Blocks

Cache or reorder traversal so each K/V tile is reused across multiple `q_blk`.

- Why: K/V load is still `42%` of serial stage cost and dominates RD bytes.
- Benefit: biggest remaining throughput/bandwidth opportunity.
- Risk: high; requires holding multiple row-state/OACC contexts or changing traversal.

### P4: PV / OACC / QK Micro-optimizations

Only after correctness and signoff.

- PV is the largest compute stage after K/V load.
- OACC and QK are meaningful but lower priority.
- Avoid optimizing `score_post`, CSR, or row_init first; they are not bottlenecks.

## Bottom Line

The operator is now performance-competitive for the contest baseline, but not ready for final submission because correctness is not closed and final area/Fmax is not signed off.

Best next move:

1. fix full causal and full noncausal mean error;
2. run Genus area/Fmax with hard SRAM macros;
3. improve SRAM packing;
4. then consider K/V reuse for a stronger bandwidth/performance story.
