# PT_CE_V2 / PT_MD_V2 Block Breakdown

- Timestamp: `2026-04-22 10:49:47 +0800`
- Branch: `codex-app`
- Measurement source:
  - [`verify_metrics_pt_dma_top_m16_k32_n16.json`](/Users/yucheng/Documents/GitHub/flash_atten/app/pt_tiled_gemm/out/verify_metrics_pt_dma_top_m16_k32_n16.json)
  - extracted artifact: [`pt_ce_md_block_breakdown.json`](/Users/yucheng/Documents/GitHub/flash_atten/app/pt_tiled_gemm/out/pt_ce_md_block_breakdown.json)

## Scope

- Quantify current `PT_CE_V2` and `PT_MD_V2` bottlenecks using internal simulation-visible stage events.
- Keep the design unchanged; this iteration only adds cocotb-side instrumentation and a diagnostic testcase.
- Representative command shapes:
  - `m1_n1_k2` = direct `16x16x32`
  - `m2_n2_k1` = direct `32x32x16`
- `m2_n2_k1` is especially important because it matches the dominant logical command shape used by the current safe-adapted large sweeps.

## Key Numbers

### `m1_n1_k2`

- top-level:
  - `accept -> ctrl_resp = 128 cycles`
- `PT_MD_V2` fill:
  - `A fill = 34 cycles`
  - `B fill = 34 cycles`
  - total fill = `68 cycles`
- `PT_CE_V2`:
  - `ce_cmd -> ce_resp = 54 cycles`
- `PT_MD_V2` export:
  - `ce_resp -> wr_done = 36 cycles`

### `m2_n2_k1`

- top-level:
  - `accept -> ctrl_resp = 172 cycles`
- `PT_MD_V2` fill:
  - `A fill = 34 cycles`
  - `B fill = 34 cycles`
  - total fill = `68 cycles`
- `PT_CE_V2`:
  - `ce_cmd -> ce_resp = 98 cycles`
- `PT_MD_V2` export:
  - `ce_resp -> wr_done = 132 cycles`

## PT_MD_V2 Breakdown

### Fill path

For both representative commands, each operand fill is structurally identical:

- `fill_req -> rd_desc = 1 cycle`
- `rd_desc -> first beat = 2 cycles`
- `first beat -> last beat = 31 cycles`
- `last beat -> fill_done = 0 cycles`

So the current fill bottleneck is not descriptor/control glue. It is the streamed data phase itself:

- `31 / 34 = 91.2%` of each operand fill

This means:

- shaving a cycle from `fill_req` or `rd_desc` logic will not move the needle much
- real fill improvement requires either:
  - more effective overlap
  - or true A/B concurrent fill capability
  - or wider/faster fill streaming

### Export path

`PT_MD_V2` export is also dominated by streamed payload, not setup:

- `m1_n1_k2`
  - `ce_resp -> wr_desc = 2`
  - `wr_desc -> first beat = 3`
  - `first beat -> last beat = 30`
  - `last beat -> done = 1`
- `m2_n2_k1`
  - `ce_resp -> wr_desc = 2`
  - `wr_desc -> first beat = 3`
  - `first beat -> last beat = 126`
  - `last beat -> done = 1`

So export control overhead is only about `6 cycles`; the bulk is the AXIS/writeback stream:

- `30 / 36 = 83.3%` for `m1_n1_k2`
- `126 / 132 = 95.5%` for `m2_n2_k1`

## PT_CE_V2 Breakdown

### Launch latency is already tiny

For both representative commands:

- `ce_cmd -> first_exec_req = 1 cycle`
- `first_exec_req -> first_exec_rsp = 1 cycle`

So CE front-end launch is not the problem anymore.

### Scalable compute span

- `m1_n1_k2`
  - `first_exec_rsp -> last_exec_complete = 31 cycles`
- `m2_n2_k1`
  - `first_exec_rsp -> last_exec_complete = 75 cycles`

This is the shape-dependent part of CE cost.

### Fixed post-compute tail

For both representative commands:

- `last_exec_complete -> last_drain_complete = 20 cycles`
- `last_drain_complete -> ce_resp = 1 cycle`

That means CE currently carries a nearly fixed tail after the last compute response:

- about `21 cycles`

This is a strong candidate for optimization because it persists even when the main compute span is already done.

### Event multiplicity

- `m1_n1_k2`
  - `exec_req_count = 32`
  - `exec_rsp_count = 32`
  - `drain_accept_count = 16`
  - `drain_complete_count = 1`
- `m2_n2_k1`
  - `exec_req_count = 64`
  - `exec_rsp_count = 64`
  - `drain_accept_count = 64`
  - `drain_complete_count = 4`

This confirms that `m2_n2_k1` is not just “a slightly larger tile”; it is a 4-output-tile macro traversal, so CE and export both scale materially there.

## Bottleneck Ranking

### For accepted-command latency (`accept -> ctrl_resp`)

`m1_n1_k2`:

1. `PT_MD_V2` fill = `68 cycles`
2. `PT_CE_V2` = `54 cycles`
3. wrapper glue = about `6 cycles`

`m2_n2_k1`:

1. `PT_CE_V2` = `98 cycles`
2. `PT_MD_V2` fill = `68 cycles`
3. wrapper glue = about `6 cycles`

So:

- small command: fill dominates
- representative adapted command: CE dominates

### For end-to-end completion (`accept -> wr_done`)

`m2_n2_k1` is the more relevant current app case, and there the order becomes:

1. `PT_MD_V2` export = `132 cycles`
2. `PT_CE_V2` = `98 cycles`
3. `PT_MD_V2` fill = `68 cycles`

So for current large adapted workloads, export has become the largest single end-to-end block.

## Optimization Priority

### P1

Attack `PT_MD_V2` export stream efficiency.

Why:

- it is already the largest single block on the representative `m2_n2_k1` end-to-end path
- control overhead is tiny, so structural overlap or queueing is the only high-ROI move

Best next ideas:

- pre-arm the next export descriptor before current `m_dma_done`
- add a small export descriptor queue
- reduce `EXP_IDLE/REQ/WAIT_DONE` bubbles

### P2

Reduce the fixed `PT_CE_V2` post-compute tail.

Why:

- `last_exec_complete -> ce_resp` is effectively `21 cycles` regardless of representative shape
- this looks like drain/commit bookkeeping, not core multiply work

Best next ideas:

- deepen drain metadata queueing
- let final response depend on safe queued completion instead of waiting on the full current tail

### P3

Only after P1/P2, revisit true A/B fill parallelism.

Why:

- fill is still expensive in isolation
- but the current software prefetch path can already hide much of it on adapted workloads
- export and CE tail now have higher direct ROI on app-level GOPS

## Bottom Line

- `PT_MD_V2` fill is a fixed, stream-dominated cost
- `PT_CE_V2` launch is already cheap
- `PT_CE_V2` still has a persistent `~21 cycle` post-compute tail
- `PT_MD_V2` export is now the largest end-to-end block on the representative adapted command

So if the goal is to improve current `PT_DMA_TOP` app performance, the best next move is:

1. export-path overlap / queueing in `PT_MD_V2`
2. CE post-compute tail reduction in `PT_CE_V2`
3. only then deeper A/B fill parallelism
