# FA_TOP_BASELINE Remote SpyGlass Summary

- Date: `2026-04-26`
- Remote host: `host@100.108.220.80` (`ic-canopsys`)
- Remote repo: `~/Desktop/flash_atten`
- Goal: `lint/lint_rtl`
- Top: `FA_TOP_BASELINE`

## Final Valid Run

This summary uses the second run, which fixed the temporary flow issues from the first attempt:

- added missing RTL dependencies to the FA SpyGlass filelist:
  - `sync_fifo.v`
  - `gemu_v3.v`
  - `gemm_v3.v`
- raised SpyGlass `mthresh` from `4096` to `20000`

Final result:

- `0 error / 88 warnings / 2 infos`
- `Design Read = 0 error`
- `Blackbox Resolution = 0 error`

## Report Paths

- log:
  - `synopsys/spyglass/logs/fa_top_baseline_lint_20260426_150405.log`
- consolidated report dir:
  - `synopsys/spyglass/flow/fa_top_baseline_lint/consolidated_reports/FA_TOP_BASELINE_lint_lint_rtl/`
- key report:
  - `synopsys/spyglass/flow/fa_top_baseline_lint/consolidated_reports/FA_TOP_BASELINE_lint_lint_rtl/moresimple.rpt`

## Warning Classification

### Grade A

No remaining error or fatal blocker in the valid run.

### Grade B

Rule `STARC05-1.3.1.3 AsyncResetOtherUse`:

- count: `1`
- file:
  - `synopsys/rtl/fa_buffers_real.v:75`
- note:
  - async reset domain from core logic is seen on the `csr_array` enable path
  - this is the highest-priority real warning because it is a reset-usage rule, not a style-only duplicate-assignment warning

Rule `STARC05-2.2.3.3 InitValUsingNBA`:

- count: `15`
- files:
  - `synopsys/rtl/fa_axi_rd_master.v`: `10`
  - `synopsys/rtl/fa_cores_real.v`: `2`
  - `synopsys/rtl/fa_recip_q16_16.v`: `1`
  - `synopsys/rtl/fa_row_state_real.v`: `1`
  - `synopsys/rtl/fa_score_post_real.v`: `1`
- note:
  - this cluster indicates repeated sequential self-assignment patterns inside clocked blocks
  - these are structurally more important than the pure `W415a` style cluster because they map to STARC sequential-coding guidance

### Grade C

Rule `W415a`:

- count: `72`
- files:
  - `synopsys/rtl/fa_tile_sched.v`: `17`
  - `synopsys/rtl/fa_cores_real.v`: `15`
  - `synopsys/rtl/fa_row_state_real.v`: `15`
  - `synopsys/rtl/fa_axi_rd_master.v`: `12`
  - `synopsys/rtl/fa_buffers_real.v`: `9`
  - `synopsys/rtl/fa_score_post_real.v`: `3`
  - `synopsys/rtl/fa_recip_q16_16.v`: `1`
- note:
  - dominant pattern is multiple assignment to next-state or temporary variables inside the same `always` block
  - most of this cluster looks cleanup-oriented rather than immediately functional-blocking

## Recommended Cleanup Order

1. fix `AsyncResetOtherUse`
2. reduce `InitValUsingNBA` in `fa_axi_rd_master.v` first
3. then clean the large `W415a` clusters in:
   - `fa_tile_sched.v`
   - `fa_cores_real.v`
   - `fa_row_state_real.v`
