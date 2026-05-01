# FA Area Step 1: OACC Q4.12 Storage

- Date: `2026-04-27`
- Scheme: OACC internal storage compressed from Q16.16 32-bit words to Q4.12 16-bit words
- Top area reference: about `3,065,011` standard-cell area units from the interrupted baseline top DC progress table
- Remote stage: `/home/host/Desktop/flash_atten_fa_area_20260427_step1_after`

## RTL Change

- `FA_OACC_BUF_REAL`
  - row SRAM width: `2048` bits -> `1024` bits
  - OACC shadow storage: `1024 x 32b` -> `1024 x 16b`
  - external `tile_flat` / export data remains packed Q8.8
- `FA_OACC_UPDATE_REAL`
  - reads Q4.12 row elements, expands to Q16.16 for rescale/add, then rounds/saturates back to Q4.12
- `FA_CORE_BASELINE`
  - OACC row read/write buses updated from `2048` to `1024` bits
- Python RTL-like reference updated to model the Q4.12 storage quantization.

## Local Gates

- `python3 -m py_compile sim/cocotb/tests/test_fa_baseline.py scripts/fa_precision_analysis.py scripts/fa_baseline_profile.py`: pass
- `iverilog -g2012 -I rtl -s FA_TOP_BASELINE_SIM -o /tmp/fa_top_baseline_sim_check.out rtl/*.v`: pass
- `python3 scripts/fa_precision_analysis.py --case single_q_full_kv_causal --q-row-start 0 --q-row-start 112 --q-row-start 240`: pass
  - q0 mean/max: `0.006241 / 0.014877`
  - q112 mean/max: `0.013960 / 0.025750`
  - q240 mean/max: `0.022474 / 0.042657`
- `python3 sim/cocotb/run.py fa_full --testcase test_fa_baseline_full_causal_end_to_end,test_fa_baseline_full_noncausal_and_soft_reset --rebuild`: `2/2 pass`
- `python3 sim/cocotb/run.py fa_baseline --testcase test_fa_numeric_single_q_single_kv_noncausal,test_fa_numeric_single_q_full_kv_causal,test_fa_baseline_single_q_full_kv_causal_with_backpressure --rebuild`: `3/3 pass`
- `python3 sim/cocotb/run.py fa_full_axi --testcase test_fa_baseline_axi_full_causal_end_to_end --rebuild`: `1/1 pass`
- `python3 scripts/fa_baseline_profile.py --sim verilator`: pass, `estimated_cycles=162544`

## Remote SpyGlass

- Flow: `fa_top_baseline_lint`
- Result: `0 error / 99 warnings / 3 infos`
- Log: `/home/host/Desktop/flash_atten_fa_area_20260427_step1_after/synopsys/spyglass/logs/fa_top_baseline_lint_20260427_124944.log`
- Report dir: `/home/host/Desktop/flash_atten_fa_area_20260427_step1_after/synopsys/spyglass/flow/fa_top_baseline_lint/consolidated_reports/FA_TOP_BASELINE_lint_lint_rtl/`

Notes:

- SpyGlass elaborated the OACC row buffer as `WORK_FA_MASKED_ROWBUF_REAL_1024_16_4_16`, confirming the after-stage RTL used the compressed row width.
- Warning count stayed flat versus the baseline checkpoint.
- DC was intentionally skipped after the updated instruction to avoid long compile time; the in-flight module DC was stopped.

## Area Expectation

This step removes about half of the OACC buffer storage width:

- one OACC row SRAM instance drops from 32 x 64-bit chunks to 16 x 64-bit chunks;
- the OACC simulation/export shadow register bank drops by `16384` flip-flop bits;
- the OACC update row bus and writeback data path halve from `2048` to `1024` bits.

The expected gain is localized and low-risk because external DMA/export format remains Q8.8 and measured cycles are unchanged.
