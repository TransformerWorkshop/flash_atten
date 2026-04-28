# PT_DMA_TOP V2 Archive

- Frozen baseline commit: `2f002d2`
- Purpose: preserve the complete `PT/PT_DMA_TOP` v2 wrapper/core/mem/math snapshot while `v3` is developed in parallel.

Archive contents:

- canonical v2 wrapper tops:
  - `pt.v`
  - `pt_dma_top.v`
  - `pt_top_v2.v`
- v2 control / memory / compute pipeline:
  - `pt_dispatch_v2.v`
  - `pt_malloc.v`
  - `pt_md_v2.v`
  - `pt_ce_v2.v`
  - `pt_mem.v`
  - `gemu.v`
  - `gemm.v`
  - `quant.v`
  - `gema.v`
- supporting RTL required to re-elaborate the archived v2 design:
  - `param.vh`
  - `csr_array.v`
  - `csr_bank.v`
  - `pt_dma_axil_csr.v`
  - `shift_reg.v`
  - `sram.v`
  - `sync_fifo.v`
  - `tsmc_sram_macros.v`

Rules for this archive:

- Do not evolve archived files for new feature work.
- Use this snapshot only for reference, bisecting, or reproducing the frozen v2 baseline.
- All new packed-int8 work must land in parallel `v3` files and targets, not by mutating this archive.
