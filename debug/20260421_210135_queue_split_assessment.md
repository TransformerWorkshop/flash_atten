# PT_DMA_TOP Queue Split Assessment

- Timestamp: `2026-04-21 21:01:35 +0800`
- Branch: `codex-app`
- Commit baseline: `f00b060`

## Scope

- Reassess the next optimization direction after the preserve-config soft-clear fix.
- Specifically evaluate whether fully separating compute instructions and load/data instructions into independent queues would materially improve current `PT_DMA_TOP` performance.

## Current 200MHz GOPS Snapshot

Using the latest compact sweep:

- `16x16x64`
  - `18.725 GOPS @ 200MHz`
- `32x32x32`
  - `17.760 GOPS @ 200MHz`
- `64x64x64`
  - `17.097 GOPS @ 200MHz`

For reference, `64x64x64` improved from the previous `16.199 GOPS` after preserving config across `soft_clear`.

## Observed Bottleneck

Latest per-command compact breakdown remains:

| Bucket | done/cmd | push->accept | accept->resp | resp->done | other |
| --- | ---: | ---: | ---: | ---: | ---: |
| `1 cmd` | `207.400` | `1.0` | `139.4` | `67.0` | `0.0` |
| `2 cmds` | `257.250` | `1.0` | `165.25` | `79.0` | `12.0` |
| `4 cmds` | `278.000` | `1.0` | `176.0` | `83.0` | `18.0` |
| `8 cmds` | `300.400` | `1.0` | `185.8` | `92.6` | `21.0` |
| `16 cmds` | `383.312` | `1.0` | `225.0` | `131.0` | `26.312` |

So the dominant bottleneck is still:

1. `accept -> resp`
2. `resp -> done`

## What The Current Queue Structure Actually Looks Like

From `PT_DISPATCH_V2`:

- there is one ingress command queue:
  - `u_cmd_queue`
- commands are classified into:
  - `md` path
  - `malloc` path

However, this is not a true independent dual-queue architecture because issue is still cross-gated:

- `allow_md_issue = malloc_cmd_ready && !malloc_exec_busy`
- `allow_malloc_issue` depends on:
  - `active_dst_r == ACTIVE_NONE`
  - `malloc_cmd_ready`
  - `malloc_exec_busy / malloc_serial_busy`

So even though commands are classified by destination, they are not independently decoupled at issue time.

## Would Fully Separating Compute And Load/Data Queues Help?

### Short Answer

- yes, it could help some workloads
- but it is **not** the highest-leverage fix for the current measured bottleneck

### Why It Is Not First Priority

The current multitile benchmark that defines our main GOPS numbers is dominated by repeated `MATMUL` commands.

That means:

- top-level command traffic is mostly compute commands
- the expensive load activity is mostly generated internally as fill/export micro-operations
- the measured dominant term is still wrapper/control work after accept, not ingress queue acceptance

So a clean compute/load split at the top-level instruction queue would not directly remove the largest currently measured term.

### Where It Could Help

A true split would be more useful for:

1. explicit `LOAD` + compute mixed software schedules
2. `soft_clear` / recovery scenarios with follow-on setup traffic
3. avoiding head-of-line blocking between:
   - MD-side config/QCFG/reject traffic
   - malloc-side compute/load traffic

### Evidence In Current RTL

`PT_DISPATCH_V2` still serializes destination issue even after classification:

- MD issue is blocked by malloc state
- malloc issue is blocked while an MD response is in flight

This means there is some real architectural coupling.

But the data says that coupling is not what dominates the current compact sweep:

- `push->accept` is only `1 cycle/cmd`
- the main cost is downstream of accept

## Better Next Target Than Queue Split

Higher-ROI next work is still:

1. reduce `accept -> resp`
   - descriptor bookkeeping
   - command orchestration before response generation
   - internal control serialization after command acceptance
2. reduce `resp -> done`
   - export/writeback overlap

Only after that should a full queue split be considered as a larger architectural change.

## Recommended Position

### Recommendation

Do **not** make “full compute/load queue split” the next iteration’s primary implementation target.

### Reason

It is a larger structural change, but current evidence says it does not hit the biggest measured term first.

### Better Use Of The Next Iteration

Target the command path that begins after acceptance:

- why a compute command takes `139 -> 225 cycles/cmd` before response
- why export tail still takes `67 -> 131 cycles/cmd`

## When Queue Split Should Move Up In Priority

It should move up if one of these becomes true:

1. we start using explicit software prefetch/load schedules aggressively
2. we find head-of-line blocking between MD and malloc commands in real traces
3. we reduce `accept -> resp` significantly and queue coupling becomes the next dominant limiter
