# PT_DMA_TOP Top-Level Performance Evaluation - 2026-04-17

## Summary

- `PT_DMA_TOP` functional baseline remains green:
  - `python3 sim/cocotb/run.py axil --sim icarus`
  - `4x4` / `8x8` AXI-Lite wrapper regressions stay `9/9 PASS`
- A dedicated top-level perf suite was added and passed:
  - `python3 sim/cocotb/run.py axil_perf --sim icarus`
  - `legacy_4x4`, `legacy_8x8`, `wide_8x8`, `current_16x16` are all `4/4 PASS`
- Measured top-level behavior shows two distinct wrapper costs:
  - cold-miss `MATMUL`: `CTRL_DESC_PUSH -> resp_visible = native_PT + 2 cycles`
  - cache-hit `MATMUL`: `CTRL_DESC_PUSH -> resp_visible = native_PT + 4 cycles`
  - retained-M `MATADD`: `CTRL_DESC_PUSH -> resp_visible = native_path + 2 cycles`
- The current full descriptor submission path uses **11 AXI-Lite writes per command**, not 10:
  - `CMD_INST`, `CMD_ID`
  - `A/B/C/M` low + high words = `8` writes
  - `CTRL_DESC_PUSH`
- In the current `EXT_ADDR_W=32` configuration, the four high-word writes are redundant zeros.
- On the target `16x16` wide profile, cache-hit software-visible latency is now:
  - full rewrite: `85 cycles`
  - same-id delta replay: `45 cycles`
  - measured savings: `40 cycles` from eliminating `10` unnecessary AXI-Lite writes

## Measured Results

### 1. Current Target Profile (`16x16`, wide lanes, `M_PHYSICAL_COPIES=2`)

| Scenario | AXI writes | `first_write -> resp_visible` | `CTRL_DESC_PUSH -> resp_visible` | Read DMA `desc -> last beat` | Write DMA `desc -> tlast` | Write DMA `desc -> done` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| cold-miss `MATMUL` | 11 | `123` | `83` | `A: 17`, `B: 17` | `33` | `34` |
| cache-hit `MATMUL` full rewrite | 11 | `85` | `45` | none | `33` | `34` |
| cache-hit `MATMUL` delta replay | 1 | `45` | `45` | none | `33` | `34` |
| retained-M `MATADD` full rewrite | 11 | `147` | `107` | `C: 17` | `33` | `34` |

Measured implications:

- Full AXI-Lite staging before the control push costs `40 cycles`:
  - `11 writes`
  - `4 cycles/write`
  - `10 write-to-write gaps = 40 cycles`
- Export timing matches the native PT lower bound:
  - native `16x16` export `m_dma_req -> tlast = 33 cycles`
  - wrapper-level `wr_dma_desc -> tlast = 33 cycles`
  - wrapper only adds `+1 cycle` from `tlast` to `wr_dma_done`
- Cold-miss response is still primarily dominated by PT-side load/execute timing, not by the wrapper.
- Cache-hit response is heavily affected by AXI-Lite submission overhead:
  - full rewrite control overhead (`40 cycles`) is almost as large as the native PT cache-hit compute path (`41 cycles`)

### 2. Legacy vs Wide (`8x8`)

| Scenario | Legacy `8x8` | Wide `8x8` | Improvement |
| --- | ---: | ---: | ---: |
| cold-miss `MATMUL` `first_write -> resp_visible` | `267` | `91` | `-176 cycles` |
| cold-miss `MATMUL` `CTRL_DESC_PUSH -> resp_visible` | `227` | `51` | `-176 cycles` |
| cache-hit `MATMUL` full rewrite | `133` | `69` | `-64 cycles` |
| cache-hit `MATMUL` delta replay | `93` | `29` | `-64 cycles` |
| retained-M `MATADD` full rewrite | `211` | `99` | `-112 cycles` |
| read DMA `desc -> last beat` | `65` | `9` | `-56 cycles` |
| export `desc -> tlast` | `73` | `17` | `-56 cycles` |

Interpretation:

- Lane widening is still the dominant improvement lever for legacy single-lane builds.
- Once lanes are wide, wrapper-side control overhead becomes much more visible.

### 3. Full Rewrite vs Same-ID Delta Replay

Measured on cache-hit `MATMUL`:

| Profile | Full writes | Full cycles | Delta writes | Delta cycles | Savings |
| --- | ---: | ---: | ---: | ---: | ---: |
| legacy `4x4` | 11 | `77` | 1 | `37` | `40` |
| legacy `8x8` | 11 | `133` | 1 | `93` | `40` |
| wide `8x8` | 11 | `69` | 1 | `29` | `40` |
| current `16x16` | 11 | `85` | 1 | `45` | `40` |

This `40-cycle` gap is completely explained by AXI-Lite submission:

- every removed write saves `4 cycles`
- `11 -> 1` writes removes `10` writes
- `10 * 4 = 40 cycles`

## PT_DMA_TOP vs Native PT

Known native PT lower bounds already established in the repo for wide `16x16`:

| Metric | Native PT | PT_DMA_TOP | Delta |
| --- | ---: | ---: | ---: |
| cold-miss `ctrl_accept -> ctrl_resp` | `81` | `83` (`push -> resp`) | `+2` |
| cache-hit `ctrl_accept -> ctrl_resp` | `41` | `45` (`push -> resp`) | `+4` |
| export `m_dma_req -> tlast` | `33` | `33` (`wr_desc -> tlast`) | `0` |

Conclusions:

- `PT_DMA_TOP` does **not** materially slow down the export datapath once the write descriptor is issued.
- The wrapper adds a small fixed cost around response visibility:
  - `+2 cycles` on cold-miss `MATMUL`
  - `+4 cycles` on cache-hit `MATMUL`
- The dominant top-level software-visible tax is the AXI-Lite staging path, not the descriptor-to-stream datapath.

## Capacity / Queue Limits

### 1. Command FIFO Headroom Under DMA Backpressure

Scenario:

- same `ctrl_id`
- repeated `MATMUL`
- `rd_dma_desc_ready = 0`

Measured result:

- `STATUS_CMD_OVERFLOW` asserts on the **10th** push

Interpretation:

- the wrapper can absorb more than the nominal FIFO depth because work begins draining past the front-end before the DMA-side stall fully propagates
- but the headroom is still finite and easy to hit under sustained backpressure

### 2. Descriptor LUT Limit

Scenario:

- unique `ctrl_id` values
- repeated `CFG`

Measured result:

- `STATUS_DESC_OVERFLOW` asserts on the **9th** unique ID
- therefore only **8 live descriptor IDs** fit at once

Interpretation:

- descriptor entries are effectively permanent until `soft_clear`
- this is a real scalability limit for software that allocates fresh IDs aggressively

## Bottleneck Breakdown

### Current `16x16` cold-miss `MATMUL`

From the measured `123-cycle` software-visible response:

- `40 cycles` = AXI-Lite full staging before the push
- `2 cycles` = wrapper cost from push to PT-visible response path
- `81 cycles` = inherited native PT cold-miss path

Inside the inherited PT path, the dominant costs remain:

- A DMA return stream: `17 cycles`
- B DMA return stream: `17 cycles`
- PT internal load / execute / response sequencing

So the cold-miss top-level bottleneck is still the inherited PT load/execute path, with AXI-Lite staging as the second-largest term.

### Current `16x16` cache-hit `MATMUL`

From the measured `85-cycle` full-rewrite response:

- `40 cycles` = AXI-Lite staging
- `4 cycles` = wrapper push-to-response overhead
- `41 cycles` = native PT cache-hit lower bound

So on cache-hit commands, **AXI-Lite control submission is effectively tied with the core compute path** and is the main top-level optimization target.

### Current `16x16` retained-M `MATADD`

From the measured `147-cycle` software-visible response:

- `40 cycles` = AXI-Lite staging
- `2 cycles` = wrapper overhead
- `105 cycles` = retained-M `MATADD` native path
- `17 cycles` = external C return stream data phase

This path is slower than cache-hit `MATMUL` because it still pays for a C-side DMA fill plus the row-by-row add/store sequence.

## Ranked Solutions

### `P0` Software / Integration

1. Reuse `ctrl_id` and avoid full descriptor rewrites when the descriptor contents did not change.
   - Measured gain: `11 -> 1` writes on cache-hit `MATMUL`
   - Measured savings: `40 cycles`
2. Stop writing `*_ADDR_HI` when `EXT_ADDR_W=32`.
   - Immediate full-command reduction: `11 -> 7` writes
   - Immediate control-path savings: `16 cycles`
3. For partial updates, only rewrite the fields that actually changed.
   - Inference from current staging cost: every skipped write saves `4 cycles`
   - Typical “new inst + one low address + push” path would be `3` writes, not `11`

Why ranked first:

- zero RTL risk
- directly attacks the dominant top-level bottleneck on cache-hit paths
- can be adopted incrementally in software without destabilizing the datapath

### `P1` Low-Risk RTL

1. Retire descriptor entries automatically after completion instead of requiring `soft_clear`.
   - This removes the hard `8`-live-ID ceiling
2. Increase or decouple `CMD_FIFO_DEPTH` / `RESP_FIFO_DEPTH`.
   - Current measured headroom under DMA backpressure is only `10` pushes
3. Add dedicated perf counters for:
   - AXI-Lite command pushes
   - PT accepts
   - response FIFO inserts
   - descriptor misses / overflows

Why ranked second:

- fixes real scaling limits already measured in simulation
- relatively contained RTL changes
- improves observability for future tuning

### `P1` Structural RTL

1. Replace the linear descriptor search with an indexed or pipelined scoreboard.

Why it matters:

- current lookup scans `LUT_DEPTH` entries combinationally
- scaling descriptor depth without redesign will lengthen this path
- it is the right long-term shape if descriptor depth is increased beyond `8`

### `P2` Interface RTL

1. Replace the current register-by-register AXI-Lite staging path with a packed mailbox or ring entry.

Why it matters:

- full command submission currently takes `11` writes and `40` staging cycles before the control push even begins to act
- this is the single biggest avoidable software-visible tax on cache-hit paths

Expected impact:

- cache-hit `16x16` full-rewrite latency could move from `85 cycles` much closer to the current `45-cycle` delta path

### `P2` Datapath / Lane Tuning

1. Keep widening A/B load, M writeback, and export lanes only if legacy single-lane profiles remain product targets.

Why ranked last:

- wide configurations already remove the dominant datapath-side beat-count bottlenecks
- on the current `16x16` target, wrapper/control overhead is now the more urgent issue

## Final Conclusions

- `PT_DMA_TOP` is functionally healthy and now has a dedicated, deterministic top-level perf regression.
- The current top-level performance story is:
  - cold miss: dominated by inherited PT load/execute timing, with noticeable AXI-Lite staging tax
  - cache hit: dominated by AXI-Lite submission overhead plus a small wrapper fixed cost
  - export: essentially as fast as native PT after descriptor issue
- The highest-value immediate fix is **software-side submission optimization**:
  - reuse IDs
  - skip redundant writes
  - stop writing high address words in `EXT_ADDR_W=32`
- The highest-value RTL fix after that is **descriptor lifetime management**, because the measured `8`-live-ID ceiling is a hard functional scaling limit.
