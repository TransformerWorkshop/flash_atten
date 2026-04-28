# PT_DMA_TOP V2 Archive And V3 Scaffold

- Timestamp: `2026-04-22 12:08:45 +0800`
- Branch: `codex-app`
- Archive baseline: `2f002d2`

## Scope

- Freeze the current `PT/PT_DMA_TOP` implementation as archived `v2`
- introduce parallel `v3` targets and top-level names without changing canonical `pt` / `pt_dma_top`
- keep current v2 behavior green while creating a stable integration point for later packed-int8 work

## Changes

- archived the current v2 wrapper/core/mem/math snapshot under:
  - `rtl/archive/pt_dma_top_v2/`
- added archive metadata:
  - `rtl/archive/pt_dma_top_v2/README.md`
- added parallel v3 top-level RTL entry points:
  - `rtl/pt_v3.v`
  - `rtl/pt_top_v3.v`
  - `rtl/pt_dma_top_v3.v`
- extended app target plumbing:
  - `pt_v3`
  - `pt_dma_top_v3`
- extended runner/build parameter plumbing:
  - target-specific RTL parameter selection now uses:
    - `PT_PARAMS` for v2
    - `PT_V3_PARAMS` for v3
- extended cocotb env root-prefix routing so wrapper/core envs can inspect:
  - `u_pt_v2` / `u_pt.u_pt_v2`
  - `u_pt_v3` / `u_pt.u_pt_v3`

## Current Status

- `v2` remains the default target
- `v3` targets currently scaffold the parallel top-level structure and compile/run cleanly
- packed-int8 datapath behavior has not been landed yet in this milestone; `v3` is currently a behavioral mirror of `v2`

## Validation

- `python3 app/pt_tiled_gemm/run.py verify --m 16 --k 32 --n 16 --target pt_v3 --sim icarus`
  - `PASS`
- `python3 app/pt_tiled_gemm/run.py verify --m 16 --k 32 --n 16 --target pt_dma_top_v3 --sim icarus`
  - `PASS`

## Next Step

- replace the mirrored `v3` datapath with actual packed-int8 `WORD_WIDTH=32 / ELEM_WIDTH=8 / PACK_LANES=4` behavior
- start from `PT_CE_V3` / `PT_MD_V3` / `GEMU_V3` / `GEMM_V3` / `QUANT_V3` / `GEMA_V3`
