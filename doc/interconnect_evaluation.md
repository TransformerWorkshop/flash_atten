# Interconnect Evaluation

This note defines the first-pass evaluation model for organizing `PT_DMA_TOP` nodes behind a NoC-style interconnect.

## 1. Scope

- Evaluation target:
  - `each node = local tile scratchpad buffer + PT_DMA_TOP`
  - the NoC only transports tile data
  - control submission stays local to each node
- This is a planning and cost-model document.
- It does **not** change any existing RTL interface in:
  - `PT_DMA_TOP`
  - `PT_DMA_TOP_V3`
  - `NoD`
  - `network_interface`

The canonical executable model for this document is:

- [`scripts/interconnect_cost_model.py`](../scripts/interconnect_cost_model.py)

## 2. Node Definition

`buffer` in this document means a node-local tile scratchpad that sits outside `PT_DMA_TOP`.

It is explicitly **not**:

- the internal A/B/M banks inside PT
- a DMA descriptor FIFO
- an AXI-Lite mailbox

The intended role is:

- absorb one or more whole tiles at node granularity
- decouple coarse NoC packet transport from PT's existing wide beat interfaces
- make A/B reuse or M forwarding explicit at tile granularity

## 3. NoC Coverage

The model intentionally excludes control-plane distribution.

Included:

- A tile movement
- B tile movement
- optional M tile forwarding

Excluded:

- AXI-Lite command staging
- descriptor lookup policy
- response routing
- software queue management

This matches the current performance evidence that wrapper submission is no longer the dominant limiter for the adapted `PT_DMA_TOP` path; the dominant costs are now CE-side latency and export tail. See:

- [`debug/20260422_093741_pt_dma_top_bottleneck_reassessment.md`](../debug/20260422_093741_pt_dma_top_bottleneck_reassessment.md)
- [`debug/20260422_104947_pt_ce_md_block_breakdown.md`](../debug/20260422_104947_pt_ce_md_block_breakdown.md)

## 4. CLI Contract

The evaluation script is standalone and does not reuse [`pt_perf_model.py`](../scripts/pt_perf_model.py).

Required problem inputs:

- `--m`
- `--k`
- `--n`

PT-local geometry inputs:

- `--x-dim`
- `--y-dim`
- `--data-width`
- `--a-load-lanes`
- `--b-load-lanes`
- `--m-export-lanes`

NoC inputs:

- `--noc-payload-bits`
- `--head-tail-flits`
- `--topology`
- `--reuse-a`
- `--reuse-b`
- `--forward-m`

Default example:

```bash
python3 scripts/interconnect_cost_model.py --m 64 --k 64 --n 64
python3 scripts/interconnect_cost_model.py --m 64 --k 64 --n 64 --reuse-a 4 --reuse-b 4 --json
python3 scripts/interconnect_cost_model.py --m 32 --k 64 --n 64 --reuse-a 4 --reuse-b 2 --forward-m
```

## 5. Model Formulas

### 5.1 Tile Geometry

The current model assumes PT tile geometry:

- A tile = `x_dim * x_dim`
- B tile = `x_dim * y_dim`
- M tile = `x_dim * y_dim`

For the current intended use, the defaults are the repo's wide `16x16` style setup:

- `x_dim = 16`
- `y_dim = 16`
- `data_width = 32`
- `a_load_lanes = 16`
- `b_load_lanes = 16`
- `m_export_lanes = 16`

### 5.2 Baseline External Traffic

The baseline is not “full matrix bytes once.” It is the current tiled PT-style traffic without cross-output-tile scratchpad reuse.

For problem tile counts:

- `m_tiles = M / x_dim`
- `k_tiles = K / x_dim`
- `n_tiles = N / y_dim`
- `output_tiles = m_tiles * n_tiles`
- `partial_products = output_tiles * k_tiles`

Baseline external bytes:

- `A = partial_products * a_tile_bytes`
- `B = partial_products * b_tile_bytes`
- `M = output_tiles * m_tile_bytes`

This is the right comparison point for a scratchpad/interconnect exploration, because the point of the interconnect is to avoid re-fetching or re-writing those repeated tiles.

### 5.3 Baseline Cycle Anchor

The baseline cycle model is intentionally empirical rather than derived from a fresh micro-architectural simulator.

- `baseline_cycles = ceil((2 * M * K * N) / baseline_effective_ops_per_cycle)`
- default `baseline_effective_ops_per_cycle = 120.0`

That `120.0 ops/cycle` default is chosen to match the current compact `PT_DMA_TOP` long-case behavior in the repo.

### 5.4 Naive NoC

The naive architecture maps current PT wide beats directly onto the existing NoC.

Per PT beat packet:

- body flits = `ceil(pt_beat_bits / noc_payload_bits)`
- total flits = `body_flits + head_tail_flits`

This is the intentionally pessimistic “direct bridge” case.

### 5.5 Recommended NoC

The recommended architecture packetizes only full tile transfers between node scratchpads.

External A fetch count:

- `m_tiles * k_tiles * ceil(n_tiles / reuse_a)`

External B fetch count:

- `k_tiles * n_tiles * ceil(m_tiles / reuse_b)`

Forwarded A packets:

- `baseline_a_tile_uses - external_a_fetches`

Forwarded B packets:

- `baseline_b_tile_uses - external_b_fetches`

`forward_m` semantics:

- `off`: final M tiles are written off-cluster exactly as in the baseline
- `on`: M is treated as a node-to-node forwarded product and is not counted as an off-cluster write

`forward_m` is therefore a best-case pipeline assumption, not a promise about standalone GEMM writeback elimination.

### 5.6 Idealized Overlap Cycles

The current script deliberately isolates the interconnect/data-movement delta rather than giving credit for ideal compute scaling from simply instantiating more PTs.

It decomposes:

- `baseline_cycles = baseline_non_transfer_cycles + baseline_transfer_cycles`

Then it substitutes the transfer term for each architecture.

Naive NoC:

- `idealized_overlap_cycles = baseline_non_transfer_cycles + naive_noc_flits`

Recommended NoC:

- `idealized_overlap_cycles = baseline_non_transfer_cycles + remaining_external_pt_beats + recommended_noc_flits`

This keeps the model focused on the interconnect decision itself:

- how much wide external streaming is replaced
- how much packet overhead is introduced
- whether reuse/forwarding offsets the added packetization cost

### 5.7 Extra Serialization

The script reports:

- `extra_serialization_cycles = noc_total_flits - equivalent_local_pt_beats_for_forwarded_payload`

This is a packetization-only penalty term for the bytes that actually traverse the NoC.

## 6. Acceptance Criteria

The first-pass go/no-go criteria are fixed:

- throughput improvement `>= 20%`, or
- DRAM traffic reduction `>= 30%`
- and single-node latency degradation `<= 10%`

Anything else is reported as:

- useful for study
- but **not** enough to justify immediate RTL integration

## 7. Representative Cases

The first-pass fixed cases are:

- `16x16x32`
- `32x32x16`
- `32x64x64`
- `64x64x64`

These are intentionally fixed for the first round so the conclusion does not drift with ad hoc benchmark growth.

## 8. Known Limits

This model is intentionally narrow.

- `--topology` currently caps maximum reachable fanout; it is **not** a congestion or hop-count estimator.
- There is no router arbitration, VC, or hotspot model.
- There is no area, timing, or power estimate.
- There is no software scheduler or descriptor retirement model.
- It does not reopen wrapper front-end optimization, because current repo evidence says that is no longer the dominant bottleneck.

So this script is appropriate for:

- cost/benefit triage
- framing whether interconnect work is even worth prototyping

It is not sufficient for:

- signoff-style NoC sizing
- RTL QoR prediction
- system software queue design

## 9. Current Interpretation

Under the current `128-bit` payload and `HEAD + TAIL` packet tax:

- naive beat-level NoC bridging is expected to be negative
- tile-level packetization becomes interesting only when A/B reuse or M forwarding is real
- even then, the likely first-order benefit is DRAM traffic reduction before it is throughput uplift

That is the intended default interpretation for the first pass, and the accompanying debug note should be treated as the concrete instance of that interpretation:

- [`debug/20260422_interconnect_eval.md`](../debug/20260422_interconnect_eval.md)
