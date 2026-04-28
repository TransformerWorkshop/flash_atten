# PT_DMA_TOP Front-End Iteration Report - 2026-04-21 15:50:38 CST

## Scope

- Branch: `codex-app`
- Local HEAD at iteration start: `d46b5cc`
- Focus:
  - software-safe submission modes for `PT_DMA_TOP`
  - compact wrapper submit path
  - per-command front-end cost instrumentation

## Local Implementation Status

Implemented in the current local working tree:

- software submission modes:
  - `legacy`
  - `shadow_delta`
  - `compact`
- shared safe submitter with bounded `ctrl_id` pool
- `verify` / `report` / `multitile` CLI support for `--submission-mode`
- compact staging path in `PT_DMA_AXIL_CSR`
- wrapper perf counters exposed through CSR
- cocotb env support for compact submission and perf counter reads
- multitile benchmark artifacts split by submission mode

## Local Verification Status

### Synthesis sanity

- local `./scripts/synth_sanity.sh`: `PASS`

### `verify` spot checks (`PT_DMA_TOP`, `compact`)

- `m16_k32_n16`: `PASS`
- `m16_k64_n16`: `PASS`
- `m32_k32_n32`: `FAIL`
- `m48_k32_n32`: `FAIL`

Notes:

- current compact path is validated on the smaller functional/perf-sensitive cases
- larger legacy app verify failures remain outside the compact-front-end scope and are not newly introduced by this iteration

### Full `multitile` sweep (`PT_DMA_TOP`, 27 cases)

All three modes are locally passing for the full `M/N/K ∈ {16,32,64}` sweep:

- `legacy`: `PASS`
- `shadow_delta`: `PASS`
- `compact`: `PASS`

Artifacts:

- [`multitile_sweep_pt_dma_top_icarus_legacy.json`](../app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_icarus_legacy.json)
- [`multitile_sweep_pt_dma_top_icarus_shadow_delta.json`](../app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_icarus_shadow_delta.json)
- [`multitile_sweep_pt_dma_top_icarus_compact.json`](../app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_icarus_compact.json)
- [`pt_dma_top_submission_mode_compare.md`](../app/pt_tiled_gemm/out/pt_dma_top_submission_mode_compare.md)

## Quantitative Delta

| Mode | Avg GOPS @200MHz | Avg AXI writes / cmd | `64x64x64` GOPS |
| --- | ---: | ---: | ---: |
| `legacy` | `16.728` | `11.000` | `15.606` |
| `shadow_delta` | `17.474` | `6.435` | `16.325` |
| `compact` | `17.475` | `6.000` | `16.336` |

Key takeaways:

- `shadow_delta` captures almost the entire measured gain from front-end write reduction
- `compact` further reduces write count, but only gives marginal extra GOPS on top of `shadow_delta`
- the dominant residual bottleneck remains broader per-command wrapper cost, not just raw CSR write count

## Remote Gate Status

### Connectivity

- remote host from `Documents/Network/vm.txt`: `ic-canopsys`
- login confirmed:
  - host: `host@100.108.220.80`
  - remote hostname: `eda`

### Remote workspace status

- `~/Desktop/flash_atten` exists remotely
- remote checkout is currently on branch `synopsys`
- remote workspace is dirty and not suitable for directly staging this iteration without isolation

### SpyGlass / DC execution

- not executed yet in this iteration

Reason:

- current local `codex-app` branch does not carry the remote gate scripts/configs directly
- remote `~/Desktop/flash_atten` is on a dirty `synopsys` branch and should not be mutated in-place for this iteration
- next step should stage an isolated remote workspace snapshot before running:
  - SpyGlass RTL check
  - DC compile for the compact-path RTL changes

## Next Step

1. create an isolated remote staging workspace on `ic-canopsys`
2. sync current local `codex-app` RTL/app files into that staging area
3. run SpyGlass on the staged wrapper RTL
4. run remote DC compile on the staged wrapper RTL
5. write a second timestamped report with remote gate results and QoR delta
