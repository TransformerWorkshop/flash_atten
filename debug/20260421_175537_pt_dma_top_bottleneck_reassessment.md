# PT_DMA_TOP Bottleneck Reassessment

- Timestamp: `2026-04-21 17:55:37 +0800`
- Branch: `codex-app`
- Commit baseline: `9285433`

## Scope

- Reassess the performance bottleneck using the latest interval-counter-enabled compact sweep.
- Separate true command-path latency from the additional `soft_clear + setup` residual that appears when command count exceeds `LUT_DEPTH`.

## Data

- `app/pt_tiled_gemm/out/multitile_sweep_pt_dma_top_icarus_compact.json`
- `app/pt_tiled_gemm/out/multitile_sweep_pt_icarus_shadow_delta.json`

## Updated Breakdown

Compact-mode average per-command breakdown:

| Bucket | done/cmd | push->accept | accept->resp | resp->done | other |
| --- | ---: | ---: | ---: | ---: | ---: |
| `1 cmd` | `207.400` | `1.0` | `139.4` | `67.0` | `0.0` |
| `2 cmds` | `257.250` | `1.0` | `165.25` | `79.0` | `12.0` |
| `4 cmds` | `278.000` | `1.0` | `176.0` | `83.0` | `18.0` |
| `8 cmds` | `300.400` | `1.0` | `185.8` | `92.6` | `21.0` |
| `16 cmds` | `404.562` | `1.0` | `225.0` | `131.0` | `47.562` |

Interpretation:

- `push -> accept` is still negligible.
- `accept -> resp` remains the dominant command-path bottleneck.
- `resp -> done` remains the secondary bottleneck.
- there is now a clearly visible `other` residual term that grows with command count.

## New Finding: Two Bottleneck Regimes

### Regime A: up to 8 commands

For `1/2/4/8 cmd` buckets:

- the main limiter is `accept -> resp`
- the next limiter is `resp -> done`
- `other` is relatively modest:
  - `0`
  - `24`
  - `72`
  - `168`
  total cycles per case

This residual likely represents ordinary inter-command gaps and bookkeeping overhead, but it is not the dominant term.

### Regime B: crossing `LUT_DEPTH`

For `16 cmd`:

- total `other` cycles jump to `761`
- average `other` rises to `47.562 cycles/cmd`
- compared with the `8 cmd` average total residual `168`, the extra residual is:
  - `761 - 168 = 593 cycles`

This is the strongest new signal in the reassessment.

## Likely Root Cause Of The `593` Extra Cycles

The `16 cmd` case is the first compact-sweep workload that necessarily crosses the current safe recycle boundary:

- `LUT_DEPTH = 8`
- the benchmark uses safe `soft_clear` and re-setup when command count exceeds the safe live-id envelope

The wrapper-side setup function after each clear is:

- A base low
- A base high
- B base low
- B base high
- passthrough QCFG

So the new hypothesis is:

- the extra `~593 cycles` in the `16 cmd` case is primarily `soft_clear + bring-up reconfiguration`
- not PT compute itself
- and not the already-measured workload command intervals

In other words, for very long adapted schedules the performance bottleneck is no longer just per-command latency; it is also the **safe segmentation boundary** forced by current lifetime semantics.

## Representative Cases

| Shape | Cmds | Total cycles | Push->Accept | Accept->Resp | Resp->Done | Other |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `16x16x64` | `2` | `350` | `2` | `254` | `70` | `24` |
| `32x32x32` | `2` | `738` | `2` | `450` | `262` | `24` |
| `64x64x64` | `16` | `6473` | `16` | `3600` | `2096` | `761` |

## Reassessed Priority

### P1a

Still highest priority:

- reduce `accept -> resp`

because it is the largest term for all buckets.

### P1b

Second priority:

- reduce `resp -> done`

because it is consistently the second-largest term.

### P1c

New explicit third priority:

- reduce or avoid the `soft_clear + re-setup` tax once command count exceeds `LUT_DEPTH`

This only matters once schedules become long enough, but when it appears, it is expensive.

## Implication For Next Work

There are now two distinct optimization tracks:

1. command-path optimization
   - target `accept -> resp`
   - then `resp -> done`
2. segmentation-boundary optimization
   - reduce the safe-clear/setup cost
   - or reduce how often workloads cross that boundary

Without addressing the second track, very long schedules like `64x64x64` will keep paying a large fixed penalty even if the per-command path improves.
