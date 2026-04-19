# 2026-04-18 PT_DMA_TOP DC Wrapper Cleanup Follow-up

## Scope

- Source RTL branch during edit: `codex-app` at base `7ad6cb4`
- Synopsys staging branch after import: `synopsys` commit `edbbf03`
- VM: `yian@100.77.71.69:~/Desktop/flash_atten`
- New compile log: `logs/dc/compile_20260418_011202.log`

## RTL change set

The cleanup kept public interfaces unchanged and only adjusted internal wrapper structure:

- `rtl/pt.v`
  - stop forwarding unused AXI stream compatibility sidebands and `dma_done` into `PT_V2`
  - drive those child pins with explicit constants
- `rtl/pt_dma_top.v`
  - stop forwarding unused AXI stream compatibility sidebands into `PT`
  - drive those child pins with explicit constants
- `rtl/pt_top_v2.v`
  - instantiate `PT_DISPATCH_V2`, `PT_MD_V2`, and `PT_CE_V2` directly
  - keep `PT_MALLOC` but tie its unused `ce_resp[31:0]` input to `32'd0`
- removed the earlier `dont_touch` unused-sink experiment from wrapper files because it did not improve DC results and would have added unnecessary synth-visible logic

## Local regression

Passed locally after the RTL update:

- `./scripts/synth_sanity.sh`
- `python3 sim/cocotb/run.py smoke --sim icarus --seed 10`
- `python3 sim/cocotb/run.py axil --sim icarus --seed 10`
- `python3 sim/cocotb/run.py axil_perf --sim icarus --seed 10`
- `python3 sim/cocotb/run.py perf --sim icarus --seed 10 --target pt`

## DC result summary

Compared against the previous wrapper-cleanup baseline from `compile_20260418_003853.log`:

- Setup still met at `5.000 ns`
- Critical path length improved slightly: `4.89 ns -> 4.88 ns`
- Cell area changed slightly: `112788.494103 -> 112798.392106`
- Hold remained effectively unchanged:
  - worst hold `-0.10`
  - total hold `-9407.30`
  - hold violations `154539`
- Max-cap violation remained `1`

## check_design delta

This pass did materially reduce wrapper-related structural noise:

- Unconnected ports: `1281 -> 1081`
- `LINT-60` hier pins without driver/load: `821 -> 718`
- `LINT-33` same-net multi-pin warnings: unchanged at `81`

Selected warning bucket counts from `compile_check_design.rpt`:

- `u_dispatch`: `4 -> 2`
- `u_md`: `34 -> 17`
- `u_ce`: `168 -> 84`
- `u_pt_v2`: unchanged at `21`
- `u_malloc`: unchanged at `32`

## Interpretation

What improved:

- direct wrapper pass-through noise inside `PT_V2` did go down
- the change was synthesis-safe and regression-clean

What did not improve:

- `PT -> PT_V2` compatibility-only pins still show as `u_pt_v2` `LINT-60`
- `PT_MALLOC` still reports all `ce_resp[31:0]` bits as unloaded at the hierarchy boundary
- the single max-cap violation is still present

The compile log's post-opt high-fanout list is now dominated by core nets, for example:

- `u_pt/u_pt_v2/u_a_bank/.../*Logic0*`
- `u_pt/u_pt_v2/u_b_bank/.../*Logic0*`
- `u_pt/u_pt_v2/u_m_mem/.../*Logic0*`
- `u_pt/u_pt_v2/gemm_inst/.../fifo_a/clk`

That makes the remaining max-cap issue look more like PT core / generated memory / GEMM fanout behavior than wrapper compatibility sideband fanout.

## Conclusion

This wrapper cleanup is worth keeping because it reduced `check_design` noise without breaking regressions, but it did **not** eliminate the remaining max-cap violation. The next DC-driven RTL pass should target core high-fanout nets or explicitly document the residual max-cap as a core-side issue rather than continuing to churn wrapper compatibility plumbing.
