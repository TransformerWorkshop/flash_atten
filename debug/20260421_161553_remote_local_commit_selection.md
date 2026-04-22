# Remote vs Local Commit Selection - 2026-04-21 16:15:53 CST

## Compared Workspaces

### Local

- repo: `/Users/yucheng/Documents/GitHub/flash_atten`
- branch: `codex-app`
- selected design commit: `d46b5cc`

### Remote

- host from `Documents/Network/vm.txt`: `ic-canopsys`
- login: `host@100.108.220.80`
- hostname: `eda`
- dirty working repo:
  - path: `~/Desktop/flash_atten`
  - branch: `synopsys`
  - HEAD: `6813de7`

## Structural Difference

The two repos are not symmetric clones of the same working layout.

- Local `codex-app` is the full design/app repo:
  - `app/`
  - `rtl/`
  - `sim/`
  - docs/debug artifacts
- Remote `synopsys` repo is primarily a signoff/physical-flow workspace:
  - `synopsys/common`
  - `synopsys/dc`
  - `synopsys/icc2`
  - staged RTL under `synopsys/rtl`

Remote `~/Desktop/flash_atten` also contains local ICC2-side dirty changes and generated artifacts, so it is not safe to use in-place for this iteration.

## RTL Delta Relevant To This Iteration

Compared local `d46b5cc` against remote staged RTL, the following key wrapper/front-end files differ:

- `rtl/pt_dma_axil_csr.v`
- `rtl/pt_dma_top.v`
- `rtl/pt_malloc.v`

Local SHA256:

- `pt_dma_axil_csr.v`: `1293e7dd5645b71fc3d457fb03f21e10f94101369a814fa5f8a8cb812c8b1697`
- `pt_dma_top.v`: `abce6c9c9cb8ea167ef4b24ee55fb4e46b8372831418877a56fe27340aaf4df4`
- `pt_malloc.v`: `5a96fe711b1add29853f344aa96ef07c4d3933407be6a843dda7f4727ca2d948`

After staging local RTL into the isolated remote workspace, the remote SHA256 values matched exactly.

## Commit Choice

Chosen design source commit for this iteration:

- `d46b5cc`
- message: `feat(app): add PT_DMA_TOP submission modes and compact wrapper path`

Reason:

- it is the current local milestone commit on `codex-app`
- it contains the wrapper/front-end RTL that needs gating
- it matches the software/baseline benchmark artifacts generated locally

Chosen remote flow base:

- clean tree of remote `6813de7`
- exported into isolated staging workspace:
  - `~/Desktop/flash_atten_stage_20260421_155212`

Reason:

- it carries the usable remote `synopsys/dc` flow
- it avoids mutating the dirty live `~/Desktop/flash_atten` workspace

## Continuation Status

Completed:

- remote staging workspace created from clean remote HEAD
- local `rtl/` copied into remote staging `synopsys/rtl`
- remote SpyGlass batch launched on staged RTL
- SpyGlass completed with:
  - `0 error`
  - `212 warnings`
  - reports under:
    `~/Desktop/flash_atten_stage_20260421_155212/synopsys/spyglass/pt_dma_top_lint/consolidated_reports/PT_DMA_TOP_lint_lint_rtl/`

In progress / partial:

- remote DC compile launched in staged workspace
- first attempt was blocked by missing staged libraries
- staging was repaired by copying:
  - `synopsys/common/ref/pdk_patch`
  - `synopsys/common/libs_work/memory/current`
- second DC run progressed into real `compile_ultra`
- report extraction still pending final completion

## Decision

The appropriate way to continue is:

1. treat local `d46b5cc` as the design source of truth
2. treat remote clean `6813de7` tree as the signoff-flow substrate
3. continue all remote SpyGlass/DC work only inside
   `~/Desktop/flash_atten_stage_20260421_155212`
4. do not mutate the dirty remote `~/Desktop/flash_atten` worktree directly
