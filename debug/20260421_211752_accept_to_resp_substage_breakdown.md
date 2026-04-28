# PT_DMA_TOP Accept-To-Resp Substage Breakdown

- Timestamp: `2026-04-21 21:17:52 +0800`
- Branch: `codex-app`
- Commit baseline: `f00b060`

## Scope

- Subdivide the `accept -> resp` interval using internal simulation-visible stage events.
- Use the result to decide where optimization effort should go next.

## Measurement Method

This iteration adds sim-only internal stage monitors in `PT_DMA_TOP` cocotb env for:

- `malloc_cmd` issue
- `fill_req` issue
- `fill_done`
- `ce_cmd` issue
- `ce_resp`
- top-level visible `ctrl_resp`

Files:

- `sim/cocotb/tests/pt_dma_top_env.py`
- `sim/cocotb/tests/test_pt_dma_top_perf_oneoff.py`

Measurement artifact:

- `app/pt_tiled_gemm/out/pt_dma_top_accept_to_resp_substages.json`

Representative subcommands:

- `m1_n1_k2`
  - corresponds to a `16x16x32` direct matmul command
- `m2_n2_k1`
  - corresponds to a `32x32x16` direct matmul command

## Results

### `m1_n1_k2`

| Stage | Cycles |
| --- | ---: |
| accept -> malloc_issue | `1` |
| malloc_issue -> fill_req_a | `1` |
| fill_req_a -> fill_done_a | `34` |
| fill_done_a -> fill_req_b | `1` |
| fill_req_b -> fill_done_b | `34` |
| fill_done_b -> ce_cmd | `1` |
| ce_cmd -> ce_resp | `54` |
| ce_resp -> ctrl_resp | `2` |
| total accept -> ctrl_resp | `128` |

### `m2_n2_k1`

| Stage | Cycles |
| --- | ---: |
| accept -> malloc_issue | `1` |
| malloc_issue -> fill_req_a | `1` |
| fill_req_a -> fill_done_a | `34` |
| fill_done_a -> fill_req_b | `1` |
| fill_req_b -> fill_done_b | `34` |
| fill_done_b -> ce_cmd | `1` |
| ce_cmd -> ce_resp | `152` |
| ce_resp -> ctrl_resp | `2` |
| total accept -> ctrl_resp | `226` |

## Key Findings

### 1. Wrapper control overhead is already tiny

The pure wrapper-control sections are almost negligible:

- `accept -> malloc_issue = 1`
- `malloc_issue -> fill_req_a = 1`
- `fill_done_b -> ce_cmd = 1`
- `ce_resp -> ctrl_resp = 2`

Total non-fill, non-CE wrapper tax inside this breakdown is only about:

- `5 cycles`

So optimizing descriptor/control handoff further is low ROI.

### 2. Cold-miss fill path is a fixed `68 cycles`

For both representative commands:

- `fill_req_a -> fill_done_a = 34`
- `fill_req_b -> fill_done_b = 34`

These are serialized today, so every cold-miss matmul pays:

- about `68 cycles`

This is the clear second-priority bottleneck.

### 3. CE execution path is the dominant bottleneck for larger subcommands

`ce_cmd -> ce_resp`:

- `m1_n1_k2`: `54 cycles`
- `m2_n2_k1`: `152 cycles`

For `m2_n2_k1`, the CE path is about:

- `152 / 226 = 67.3%`

of the entire `accept -> resp` window.

This is the main reason larger adapted commands still remain expensive even after wrapper-side cleanup.

## Updated Optimization Priority

### P1

Highest priority:

- optimize `ce_cmd -> ce_resp`

Reason:

- it dominates `accept -> resp` for the important larger subcommand shape `m2_n2_k1`

Likely directions:

- improve CE macro-tile progression overlap
- reduce drain/quant/store serialization in the CE completion path
- reduce per-subtile response latency inside `PT_CE_V2`

### P2

Second priority:

- optimize the cold-miss fill path

Reason:

- `A` then `B` loads are fully serialized today
- fixed `68-cycle` operand-fill tax per cold-miss command is still large

Likely directions:

- allow `A` and `B` fill requests to overlap
- parallelize DMA desc issue and fill handling for `A/B`
- prefetch next command’s operands while CE works, if safety permits

### P3

Low priority:

- further optimize wrapper accept/response glue

Reason:

- the measured glue overhead is only around `5 cycles`
- this is no longer the dominant limiter

## Conclusion

The `accept -> resp` path is now clearly split into:

1. tiny wrapper-control handoff
2. fixed serialized operand-fill cost
3. dominant CE execution-to-response cost

So the next meaningful speedup will not come from shaving another cycle off descriptor bookkeeping.
It will come from:

1. reducing `PT_CE_V2` completion latency
2. then reducing serialized `A/B` fill time
