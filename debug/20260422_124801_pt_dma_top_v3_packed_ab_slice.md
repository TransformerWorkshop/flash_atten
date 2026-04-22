# PT_DMA_TOP V3 Packed-AB Vertical Slice

- Timestamp: `2026-04-22 12:48:01 +0800`
- Branch: `codex-app`
- Base scaffold commit: `dab0343`

## Scope

- Move `v3` from a pure mirror of `v2` to a real packed-int8 compute slice.
- This iteration implements:
  - `A/B` packed as `4 x int8 / 32-bit word`
  - `GEMU/GEMM` packed dot4 compute
  - v3 allocator/model/software length semantics in packed-word units for `A/B`
- This iteration does **not** yet complete the full plan-D chain:
  - `C/M/export` are still scalar-width semantic paths
  - `PT_CE_V3` post-compute tail cleanup is not yet done
  - full `v3` multitile closure is not finished

## Implemented Changes

- Added real v3 compute modules:
  - `rtl/gemu_v3.v`
  - `rtl/gemm_v3.v`
  - `rtl/pt_ce_v3.v`
  - `rtl/pt_md_v3.v`
  - `rtl/pt_malloc_v3.v`
- Updated `rtl/pt_top_v3.v` and `rtl/pt_dma_top_v3.v` to use the v3-specific modules.
- Updated cocotb models/envs so v3 now understands:
  - `PACK_LANES=4`
  - packed-word residency sizes for `A/B`
  - packed A/B DMA streaming
- Updated app-side verify/multitile helpers so `LOAD` sizes and multitile partitioning can use packed-word counts for v3 targets.

## Local Validation

Passing spot checks:

- `python3 app/pt_tiled_gemm/run.py verify --m 16 --k 32 --n 16 --target pt_v3 --sim icarus`
  - `PASS`
- `python3 app/pt_tiled_gemm/run.py verify --m 16 --k 32 --n 16 --target pt_dma_top_v3 --sim icarus`
  - `PASS`
- `python3 app/pt_tiled_gemm/run.py verify --m 16 --k 64 --n 16 --target pt_dma_top_v3 --sim icarus`
  - `PASS`

Representative multitile status:

- `pt_v3`
  - `m2_n1_k1`: `PASS`
  - `m1_n2_k1`: `PASS`
- `pt_dma_top_v3`
  - `m2_n1_k1`: `PASS`
  - `m1_n2_k1`: `PASS`

Observed v3 throughput highlights:

- `pt_dma_top_v3`
  - `16x16x16`: `103.696 ops/cycle`
  - `16x16x32`: `180.044 ops/cycle`
  - `16x16x64`: `284.939 ops/cycle`

These are clear signs that packed `A/B + dot4` is active and no longer mirroring v2.

## Remaining Blocker

`pt_dma_top_v3` full `27`-case compact multitile sweep is not closed yet.

Current pattern:

- all `n=1` cases pass
- simple `n>1` + `k=1/2` cases now pass
- failures remain on larger adapted `n>1` and `k>1` combinations such as:
  - `m1_n2_k4`
  - `m1_n4_k2`
  - `m2_n2_k4`
  - `m4_n4_k4`

This strongly suggests the next issue is not the basic packed-AB datapath anymore, but:

- multi-command / multi-`n_tile` packed scheduling interactions
- likely in the remaining scalar `M/export` path assumptions versus packed `A/B` command semantics

## Gate Status

- No remote SpyGlass/DC run yet for this v3 slice.
- Reason:
  - the implementation is still functionally incomplete at the full multitile level
  - hardware gates should wait for a stable `v3` milestone candidate

## Next Step

The next meaningful implementation target is:

- finish `PT_MD_V3` / `PT_CE_V3` semantics for larger adapted multitile flows
- then move on to true plan-D work:
  - packed `C/M/export`
  - `PT_CE_V3` tail reduction
