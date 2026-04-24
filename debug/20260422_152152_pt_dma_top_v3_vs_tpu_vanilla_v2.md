# PT_DMA_TOP_V3 vs TPU_VANILLA-V2

- Timestamp: `2026-04-22 15:21:52 +0800`
- PT source:
  - `app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_v3_200mhz_gops.md`
  - `app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_v3_icarus_compact.json`
  - `app/pt_tiled_gemm/out/verify_metrics_pt_dma_top_v3_m16_k128_n128.json`
  - `app/pt_tiled_gemm/out/verify_metrics_pt_dma_top_v3_m32_k128_n128.json`
- TPU source:
  - `../tpu_vanilla/third_party/tpu_vanilla-v2-local/tb/results/verilator_local_axiip_pe16_axi128_ram128_soak_hw_soak/summary.md`
  - `../tpu_vanilla/third_party/tpu_vanilla-v2-local/tb/results/verilator_local_axiip_pe16_axi128_ram128_soak_hw_soak/conclusion.md`
  - `../tpu_vanilla/third_party/tpu_vanilla-v2-local/rtl/tpu_top.v`

## Scope

- This note compares current `PT_DMA_TOP_V3` against sibling repo `tpu_vanilla-v2-local`.
- Frequency-neutral metric is `MAC/cycle`.
- For convenience, `GOPS@200MHz = ops/cycle * 0.2`.
- TPU testbench itself is configured at `100MHz` in `tb_tpu_top_64bit.v`, so its native absolute GOPS would be half of the `GOPS@200MHz` normalization below.

## Architecture Snapshot

- `PT_DMA_TOP_V3`
  - compute array: `16 x 16`
  - peak MAC/cycle: `256`
- `tpu_vanilla-v2`
  - `PE_SIZE = 8`
  - effective array width: `8 x 8`
  - peak MAC/cycle: `64`

PT has about `4.0x` larger raw array peak.

## Stable Overlap Cases

These are the shapes where both sides already have stable end-to-end data and PT is fully green on the current v3 path.

| Shape | PT cycles | TPU cycles | PT MAC/cycle | TPU MAC/cycle | PT / TPU | PT GOPS @200MHz | TPU GOPS @200MHz |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `16x64x64` | `343` | `973` | `191.067` | `67.355` | `2.837x` | `76.427` | `26.942` |
| `32x64x64` | `529` | `1617` | `247.773` | `81.059` | `3.057x` | `99.109` | `32.424` |

## Large-Shape Reference Cases

These `128`-wide PT numbers are taken from the current app-level best passing algorithm inside verify:

- `numeric_host_reduce_pipelined`

Important caveat:

- `m16_k128_n128` and `m32_k128_n128` are **not fully green verify cases** on PT today; two tests still fail in each full verify run.
- TPU `int8_int32` cases include its `A * B + C` style end-to-end path.
- PT figures below are therefore useful as “current practical status”, not as final signoff-quality apples-to-apples numbers.

| Shape | PT best passing cycles | TPU cycles | PT MAC/cycle | TPU MAC/cycle | PT / TPU | PT GOPS @200MHz | TPU GOPS @200MHz |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `16x128x128` | `4053` | `2903` | `64.679` | `90.301` | `0.716x` | `25.872` | `36.120` |
| `32x128x128` | `8157` | `4703` | `64.275` | `111.479` | `0.577x` | `25.710` | `44.592` |

For reference, PT direct `host_reduce_per_tensor` is even slower here:

- `16x128x128 = 7301 cycles`
- `32x128x128 = 14653 cycles`

## Main Takeaways

- On the currently stable and directly overlapping `64x64`-class shapes, `PT_DMA_TOP_V3` is clearly ahead of `tpu_vanilla-v2`.
  - End-to-end advantage is about `2.84x ~ 3.06x`.
  - This is consistent with PT’s larger `16x16` array plus the recent packed-export improvement.
- On `128x128`-class shapes, PT’s current app-level path is not yet mature.
  - Even the best currently passing pipelined path trails TPU.
  - Since TPU’s `128`-class path still includes `C` ingress and PT still trails, this is a real warning sign rather than a benchmarking artifact.
- The breakpoint is therefore very clear:
  - up to `64x64x64`, current PT v3 is stronger
  - at `128x128x128` scale, current TPU v2 path is more mature end-to-end

## Bottleneck Interpretation

Current PT v3 bottleneck picture after packed export:

- `64x64x64`
  - `accept->resp = 694 cycles`
  - `resp->done = 772 cycles`

This means PT has already compressed export a lot, but its large-shape software decomposition / app-level execution path is still not good enough once total tile count grows to `8`.

Current TPU v2 bottleneck picture from its own profiling:

- dominant phase is `load`
- next is `compute`
- then `store`
- leading gating modules are:
  - `data_flow_load`
  - `data_flow_load_c`
  - `c_matrix_adder`
  - `transfer_d_to_axi_ctrl`

So the two designs are bottlenecked in different places now:

- PT v3: large-shape tiled execution and post-compute tail
- TPU v2: ingress/load and post-array fusion/store control

## Practical Conclusion

- If the target product window is mainly `16~64` sized tiles and wrapper-driven GEMM throughput, current `PT_DMA_TOP_V3` is the better performer.
- If the target must already handle `128x128x128`-class workloads robustly today, `tpu_vanilla-v2` is currently ahead in practical end-to-end maturity.
- The most important PT follow-up is not more front-end polish; it is:
  1. make `8-tile` large-shape paths fully green
  2. move from packed export only to packed `M/C`
  3. keep reducing the post-compute tail in `PT_CE_V3`
