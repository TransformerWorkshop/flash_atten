# FA Area Optimization History - 2026-04-27

## Baseline / Checkpoint

- Local repository: `/Users/yucheng/Documents/GitHub/flash_atten`
- Branch: `flash_atten`
- Baseline commits created before the next optimization round:
  - `67cc2f3 pt: switch app verification defaults to verilator`
  - `d764524 fa: record baseline hardmacro assessment`

## Remote Top-Level SpyGlass

- Remote host: `ic-canopsys`
- Remote project: `~/Desktop/flash_atten`
- Top: `FA_TOP_BASELINE`
- Project file: `synopsys/spyglass/flow/fa_top_baseline_lint.prj`
- Goal: `lint/lint_rtl`
- Log: `/home/host/Desktop/flash_atten/synopsys/spyglass/logs/fa_top_baseline_lint_20260427_152542.log`
- Result: PASS
  - Errors: `0`
  - Warnings: `91`
  - Infos: `3`

## Remote Top-Level DC Compile

- Top-level DC was started with `compile_ultra` for `FA_TOP_BASELINE`.
- Log: `/home/host/Desktop/flash_atten/synopsys/dc/logs/fa_top_baseline_compile_ultra_20260427_155145.log`
- The run was stopped before final reports per user request, so there is no final `compile_area.rpt` / `compile_timing.rpt` from this run.

Observed intermediate top-level standard-cell area checkpoints:

| Phase | Approx Area | WNS / Setup Status |
|---|---:|---|
| Early compile | `2,300,517.9` | positive slack observed |
| Global optimization | `1,942,817.6` | positive slack observed |
| WLM backend | `1,919,321.4` | setup cost reached `0.0` at one checkpoint |
| Late design-rule / leakage optimization | `1,852,614.3` | setup cost reached `0.0` at one checkpoint |

Interpretation:

- The design improved substantially from the earlier `~3,065,011` area estimate.
- It is still roughly `6x` larger than a `300k` standard-cell-area target.
- Small synthesis-only tuning is not enough; the next changes must remove duplicated storage and reduce GEMM micro-architecture cost.

## Main Area Suspects

1. Full-tile debug/export mirrors next to SRAM hardmacros:
   - `FA_BANKED_TILE_BUF_REAL.shadow_words_r`
   - `FA_V_BUF_PV_REAL.shadow_words_r`
   - `FA_OACC_BUF_REAL.shadow_q412_words_r`
   - staging registers such as `load_data_r`
2. Full-tile pipeline storage:
   - `FA_SCORE_POST_REAL.score_tile_r`
   - `FA_SCORE_POST_REAL.masked_score_tile_flat`
   - `FA_ROW_STATE_REAL.masked_score_tile_r`
   - `FA_ROW_STATE_REAL.p_tile_flat`
3. GEMM/GEMU internal storage:
   - 256 `GEMU_V3` instances
   - per-GEMU `sync_fifo` for A, B, and M paths
4. Shared-core result tile registers:
   - `qk_result_words_r[0:255]`
   - `pv_result_words_r[0:511]`

## Selected Implementation Order

| Step | Optimization | Expected Benefit | Risk |
|---:|---|---:|---|
| 1 | Remove synthesized full-tile shadow mirrors where the datapath already uses SRAM/read ports | High | Low to medium |
| 2 | Reduce Score/RowState full-tile temporaries by forwarding rows / avoiding duplicate tile copies | High | Medium to high |
| 3 | Simplify GEMM/GEMU FIFO structure | Very high | High |
| 5 | Stream QK/PV result buffers into downstream stages where possible | Medium to high | Medium to high |

Each step should be validated with FA local regression before committing.
