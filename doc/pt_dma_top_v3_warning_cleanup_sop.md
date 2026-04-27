# PT_DMA_TOP_V3 Warning Cleanup And Signoff SOP

## Scope

This SOP fixes and signs off `PT_DMA_TOP_V3` only.

- lint top: `PT_DMA_TOP_V3`
- local repo: `/Users/yucheng/Documents/GitHub/flash_atten`
- local Synopsys worktree: `/Users/yucheng/Documents/GitHub/flash_atten_synopsys_wt`
- remote machine: `host@100.108.220.80`
- remote direct run path: `~/Desktop/flash_atten`

As of `2026-04-23`, the remote dedicated SpyGlass flow reached:

- `0 error / 137 warnings / 4 infos`
- `P1` clean: `AsyncResetOtherUse = 0`
- `P2` clean: `SepStateNextLogic = 0`, `InitValUsingNBA = 0`
- remaining work is `P3` low-risk cleanup

## Prerequisites

- local repo is the source of RTL edits
- remote access credentials are available in `/Users/yucheng/Documents/Network/vm.txt`
- password helper exists:

```bash
/tmp/expect_pw.exp <password> ssh ...
/tmp/expect_pw.exp <password> scp ...
```

- dedicated SpyGlass files already exist:
  - `synopsys/spyglass/flow/pt_dma_top_v3_only.f`
  - `synopsys/spyglass/flow/pt_dma_top_v3_lint.prj`

## Fixed Conventions

- do not run `PT_DMA_TOP` or shell-sim tops for cleanup signoff
- do not edit the legacy generic lint project in place for ad-hoc runs
- remote lint runs directly in `~/Desktop/flash_atten`
- local RTL is authoritative; remote repo is a synced execution target
- every risk grade gate is:
  1. local functional gate
  2. `200MHz` GOPS sweep
  3. remote SpyGlass lint
- after all grades are done, run one final remote DC compile

## Dedicated Filelist

`synopsys/spyglass/flow/pt_dma_top_v3_only.f` must include:

```text
+incdir+synopsys/rtl
+incdir+synopsys/rtl/nod
```

Rules:

- include root RTL from `synopsys/rtl`
- exclude `synopsys/rtl/nod/*`
- exclude `pt_dma_top_v3_shell_sim.v`
- exclude `pt_shell_axil_csr_sim.v`

## Local Edit Loop

1. edit RTL in local repo
2. run quick syntax sanity:

```bash
PATH=/opt/homebrew/bin:/usr/local/bin:$PATH \
verilator --lint-only -Wall -Wno-fatal -Irtl -DSYNTHESIS --top-module PT_DMA_TOP_V3 rtl/*.v
```

3. sync touched RTL into remote Synopsys RTL tree:

```bash
/tmp/expect_pw.exp linuxserver scp \
  rtl/<changed_file>.v \
  host@100.108.220.80:Desktop/flash_atten/synopsys/rtl/
```

## Local Functional Gate

Run these from `/Users/yucheng/Documents/GitHub/flash_atten`.

```bash
PATH=/opt/homebrew/bin:/usr/local/bin:$PATH \
/opt/anaconda3/bin/python3 sim/cocotb/run.py axil --target pt_dma_top_v3_ch2 --sim verilator

PATH=/opt/homebrew/bin:/usr/local/bin:$PATH \
/opt/anaconda3/bin/python3 sim/cocotb/run.py axil --target pt_dma_top_v3_ch4 --sim verilator

PATH=/opt/homebrew/bin:/usr/local/bin:$PATH \
/opt/anaconda3/bin/python3 sim/cocotb/run.py axil_perf --target pt_dma_top_v3_ch4 --sim verilator

PATH=/opt/homebrew/bin:/usr/local/bin:$PATH \
/opt/anaconda3/bin/python3 app/pt_tiled_gemm/run.py regress --sim verilator
```

Important:

- do not run multiple `sim/cocotb/run.py axil ...` jobs in parallel against the same build directory
- the shared build path `sim/cocotb/build/axil_pt_dma_top_4x4` can race and fail with `FileNotFoundError`
- if needed, clean first:

```bash
rm -rf sim/cocotb/build/axil_pt_dma_top_4x4 \
       sim/cocotb/build/axil_perf_pt_dma_top_4x4
```

## 200MHz GOPS Sweep

Run compact sweeps for `ch1/ch2/ch4`:

```bash
PATH=/opt/homebrew/bin:/usr/local/bin:$PATH \
/opt/anaconda3/bin/python3 app/pt_tiled_gemm/run.py multitile \
  --target pt_dma_top_v3_ch1 --sim verilator --submission-mode compact --json \
  --out app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_v3_ch1_verilator_compact.json

PATH=/opt/homebrew/bin:/usr/local/bin:$PATH \
/opt/anaconda3/bin/python3 app/pt_tiled_gemm/run.py multitile \
  --target pt_dma_top_v3_ch2 --sim verilator --submission-mode compact --json \
  --out app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_v3_ch2_verilator_compact.json

PATH=/opt/homebrew/bin:/usr/local/bin:$PATH \
/opt/anaconda3/bin/python3 app/pt_tiled_gemm/run.py multitile \
  --target pt_dma_top_v3_ch4 --sim verilator --submission-mode compact --json \
  --out app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_v3_ch4_verilator_compact.json
```

Update summary report:

- `app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_v3_channels_200mhz_gops.md`

Performance gates:

- average GOPS regression must be `<= 1%`
- key shapes `32x64x64` and `64x64x64` regression must be `<= 2%`

Current reference after `P2` cleanup:

- `ch1` avg: `49.468 GOPS @ 200MHz`
- `ch2/ch4` avg: `49.087 GOPS @ 200MHz`
- `32x64x64`: `87.236 / 86.947 GOPS`
- `64x64x64`: `69.213 / 69.122 GOPS`

## Remote SpyGlass Run

Run directly in remote `~/Desktop/flash_atten`:

```bash
/tmp/expect_pw.exp linuxserver ssh -tt -o StrictHostKeyChecking=no host@100.108.220.80 \
  'bash -lc '\''cd ~/Desktop/flash_atten && \
  source synopsys/common/run/common.sh && \
  synopsys_install_root="$(expand_home "$(pdk_var SYNOPSYS_ROOT)")" && \
  spyglass_bin="$(locate_tool "$synopsys_install_root" spyglass)" && \
  log_file=synopsys/spyglass/logs/pt_dma_top_v3_lint_$(date +%Y%m%d_%H%M%S).log && \
  "$spyglass_bin" -project synopsys/spyglass/flow/pt_dma_top_v3_lint.prj \
    -goals lint/lint_rtl -batch -licqueue 2>&1 | tee "$log_file"; \
  test ${PIPESTATUS[0]} -eq 0'\'''
```

Key outputs:

- log: `synopsys/spyglass/logs/pt_dma_top_v3_lint_<timestamp>.log`
- report dir:
  `synopsys/spyglass/flow/pt_dma_top_v3_lint/consolidated_reports/PT_DMA_TOP_V3_lint_lint_rtl/`
- critical report:
  `.../moresimple.rpt`

To pull the consolidated report locally:

```bash
/tmp/expect_pw.exp linuxserver scp \
  host@100.108.220.80:Desktop/flash_atten/synopsys/spyglass/flow/pt_dma_top_v3_lint/consolidated_reports/PT_DMA_TOP_V3_lint_lint_rtl/moresimple.rpt \
  /tmp/pt_dma_top_v3_moresimple.rpt
```

## Warning Cleanup Order

### P1

- target: `sync_fifo.v`
- rule: `STARC05-1.3.1.3 AsyncResetOtherUse`
- policy: code fix only, no waiver

### P2

- target modules:
  - `pt_ce_v3.v`
  - `pt_md_v3.v`
  - `pt_malloc_v3.v`
  - `pt_dma_top_v3.v`
- rules:
  - `STARC05-2.11.3.1 SepStateNextLogic`
  - `STARC05-2.2.3.3 InitValUsingNBA`
- policy:
  - FSMs follow three-stage form
  - no waiver allowed

### P3

- rules:
  - `W415a`
  - `W240`
  - `W216`
  - `W215`
  - `W528`
  - `WarnAnalyzeBBox`
- policy:
  - prefer code cleanup for real issues
  - waivers allowed only for blackbox SRAM and compatibility-preserved unused ports

## Remote DC Final Gate

Run only after cleanup is complete.

Important pitfall:

- shell-sim files in `synopsys/rtl` can break DC elaboration or redirect top resolution
- for `PT_DMA_TOP_V3` compile, exclude or temporarily move out:
  - `pt_dma_top_v3_shell_sim.v`
  - `pt_shell_axil_csr_sim.v`

DC run must save:

- compile log
- `compile_qor.rpt`
- `compile_area.rpt`
- `compile_timing.rpt`
- `check_design.rpt`

## Expected Deliverables Per Iteration

- local gate status
- `200MHz` GOPS delta summary
- remote SpyGlass summary by rule
- key report/log paths
- next cleanup slice

## Quick Status Check Commands

Latest remote lint log:

```bash
/tmp/expect_pw.exp linuxserver ssh -tt -o StrictHostKeyChecking=no host@100.108.220.80 \
  'bash -lc '\''cd ~/Desktop/flash_atten && ls -lt synopsys/spyglass/logs/pt_dma_top_v3_lint_*.log | head -2'\'''
```

Latest remote summary tail:

```bash
/tmp/expect_pw.exp linuxserver ssh -tt -o StrictHostKeyChecking=no host@100.108.220.80 \
  'bash -lc '\''cd ~/Desktop/flash_atten && latest=$(ls -t synopsys/spyglass/logs/pt_dma_top_v3_lint_*.log | head -1) && tail -n 120 "$latest"'\'''
```

## Current Baseline Snapshot

Remote SpyGlass baseline after `P2`:

- total: `137 warnings / 4 infos`
- remaining buckets:
  - `W415a`: `73`
  - `W240`: `31`
  - `W216`: `18`
  - `W528`: `13`
  - `W215`: `1`
  - `WarnAnalyzeBBox`: `1`

Primary remaining files:

- `pt_md_v3.v`: `29`
- `pt_malloc_v3.v`: `28`
- `pt_ce_v3.v`: `20`
- `pt_dma_top_v3.v`: `19`
