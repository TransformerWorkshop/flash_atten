# PT_DMA_TOP DC Refresh Blocked - 2026-04-18

## Attempted VM Access

- Intended VM entry: `RedHat_ICDesigner`
- Resolved host from local `~/.ssh/config`: `100.67.210.14`
- Attempted command:
  - `ssh RedHat_ICDesigner 'pwd && hostname && ls -la ~/Desktop/flash_atten'`

Observed result:

- SSH connection timed out on TCP/22
- No workspace inspection, repo sync, or DC rerun completed

## Impact

- No new `PT_DMA_TOP` DC compile was executed on `2026-04-18`
- No refreshed `compile_qor.rpt`, `compile_area.rpt`, `compile_timing.rpt`, or `compile_check_design.rpt` was collected
- The latest accessible DC synthesis baseline in the repo remains:
  - [`20260417_dc_compile_tsmc_ccs_ff.md`](./20260417_dc_compile_tsmc_ccs_ff.md)

## Next Step Once Connectivity Is Restored

1. SSH into `RedHat_ICDesigner`
2. Sync the current repo to `~/Desktop/flash_atten`
3. Re-run the `PT_DMA_TOP` DC compile with the existing `5.000 ns` / `0.500 ns` constraint baseline and TSMC `7t` `ffg0p99v0c` CCS library
4. Copy back:
   - compile log
   - `compile_qor.rpt`
   - `compile_area.rpt`
   - `compile_timing.rpt`
   - `compile_check_design.rpt`
5. Update the synthesis summary note and top-level docs with the refreshed numbers
