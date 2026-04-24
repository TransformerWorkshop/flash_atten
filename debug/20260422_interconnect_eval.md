# 2026-04-22 Interconnect First-Pass Evaluation

## Scope

- Branch intent: interconnect exploration only
- Deliverable type: cost model + reproducible first-pass note
- No RTL data-path integration in this round

The executable source of truth is:

- [`scripts/interconnect_cost_model.py`](../scripts/interconnect_cost_model.py)

The methodology is documented in:

- [`doc/interconnect_evaluation.md`](../doc/interconnect_evaluation.md)

## Repro Commands

Syntax check:

```bash
python3 -m py_compile scripts/interconnect_cost_model.py
```

Fixed-case baseline / naive sweep:

```bash
python3 scripts/interconnect_cost_model.py --m 16 --k 32 --n 16
python3 scripts/interconnect_cost_model.py --m 32 --k 32 --n 16
python3 scripts/interconnect_cost_model.py --m 32 --k 64 --n 64
python3 scripts/interconnect_cost_model.py --m 64 --k 64 --n 64
```

Sensitivity runs used below:

```bash
python3 scripts/interconnect_cost_model.py --m 32 --k 64 --n 64 --reuse-a 4
python3 scripts/interconnect_cost_model.py --m 32 --k 64 --n 64 --reuse-a 4 --reuse-b 2
python3 scripts/interconnect_cost_model.py --m 32 --k 64 --n 64 --reuse-a 4 --reuse-b 2 --forward-m

python3 scripts/interconnect_cost_model.py --m 64 --k 64 --n 64 --reuse-a 4
python3 scripts/interconnect_cost_model.py --m 64 --k 64 --n 64 --reuse-a 4 --reuse-b 4
python3 scripts/interconnect_cost_model.py --m 64 --k 64 --n 64 --reuse-a 4 --reuse-b 4 --forward-m
```

All runs below use the script defaults:

- PT tile `16x16`
- `A/B/M` wide lanes = `16`
- NoC payload = `128 bits`
- `HEAD + TAIL = 2 flits`
- topology = `2x2`

`2x2` was kept for the first pass because the current model uses topology only as a fanout cap, not as a congestion estimator.

## Fixed Cases

### Baseline vs Naive NoC

| Case | Baseline External Traffic | Naive NoC Flits | Naive Idealized Cycles | Naive Verdict |
| --- | ---: | ---: | ---: | --- |
| `16x32x16` | `5.00 KiB` | `480` | `537` | `FAIL` |
| `32x32x16` | `10.00 KiB` | `960` | `1,074` | `FAIL` |
| `32x64x64` | `72.00 KiB` | `6,912` | `7,945` | `FAIL` |
| `64x64x64` | `144.00 KiB` | `13,824` | `15,890` | `FAIL` |

Key observation:

- direct beat-level NoC bridging is uniformly bad in this model
- the packet tax is large enough that even the long cases degrade sharply
- this matches the intended risk hypothesis for the current `128-bit` NoC

### Recommended NoC Without Reuse

| Case | Recommended External Traffic | Recommended NoC Flits | Recommended Cycles | Verdict |
| --- | ---: | ---: | ---: | --- |
| `16x32x16` | `5.00 KiB` | `0` | `137` | `FAIL` |
| `32x32x16` | `10.00 KiB` | `0` | `274` | `FAIL` |
| `32x64x64` | `72.00 KiB` | `0` | `2,185` | `FAIL` |
| `64x64x64` | `144.00 KiB` | `0` | `4,370` | `FAIL` |

Interpretation:

- merely inserting node-local buffers and a tile-packet abstraction does not help by itself
- under this model, the interconnect only becomes interesting once it enables real data reuse or forwarding

## Sensitivity

### `32x64x64`

| Scenario | External Traffic | NoC Flits | Idealized Cycles | DRAM Savings | Throughput Gain | Verdict |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `reuse_a=1, reuse_b=1, forward_m=off` | `72.00 KiB` | `0` | `2,185` | `0.0%` | `0.0%` | `FAIL` |
| `reuse_a=4, reuse_b=1, forward_m=off` | `48.00 KiB` | `1,584` | `3,385` | `33.3%` | `-35.5%` | `PASS` |
| `reuse_a=4, reuse_b=2, forward_m=off` | `32.00 KiB` | `2,640` | `4,185` | `55.6%` | `-47.8%` | `PASS` |
| `reuse_a=4, reuse_b=2, forward_m=on` | `24.00 KiB` | `3,168` | `4,585` | `66.7%` | `-52.3%` | `PASS` |

### `64x64x64`

| Scenario | External Traffic | NoC Flits | Idealized Cycles | DRAM Savings | Throughput Gain | Verdict |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `reuse_a=1, reuse_b=1, forward_m=off` | `144.00 KiB` | `0` | `4,370` | `0.0%` | `0.0%` | `FAIL` |
| `reuse_a=4, reuse_b=1, forward_m=off` | `96.00 KiB` | `3,168` | `6,770` | `33.3%` | `-35.5%` | `PASS` |
| `reuse_a=4, reuse_b=4, forward_m=off` | `48.00 KiB` | `6,336` | `9,170` | `66.7%` | `-52.3%` | `PASS` |
| `reuse_a=4, reuse_b=4, forward_m=on` | `32.00 KiB` | `7,392` | `9,970` | `77.8%` | `-56.2%` | `PASS` |

## What The Numbers Mean

### 1. Naive NoC is clearly negative

- Mapping the current wide PT load/export beats directly onto a `128-bit` NoC is not viable.
- The flit count explodes before any reuse benefit can help.
- This is the strongest immediate conclusion from the first pass.

### 2. Tile-level packetization is necessary but not sufficient

- With `reuse_a=1`, `reuse_b=1`, `forward_m=off`, the recommended architecture is a wash.
- The model does not give free credit for “more nodes exist now.”
- So a tile scratchpad + packet abstraction only matters if it changes data reuse.

### 3. Under current assumptions, the first credible benefit is DRAM reduction, not throughput uplift

- Once A/B reuse is real, the model can beat the `30%` DRAM-savings threshold.
- But none of the current `128-bit` payload runs produce a positive throughput gain.
- In other words:
  - the interconnect can plausibly be justified as a bandwidth-relief structure
  - it is **not** yet justified as a throughput accelerator under the current packet width

### 4. More reuse can still make cycles worse

- `A+B` reuse and `M` forwarding increase NoC packets.
- In this first-pass model, that extra packetization outweighs the saved wide external beats.
- So “more on-cluster forwarding” is not automatically better.

## Bottom Line

- `Naive NoC`: `NO`
- `Tile-packet NoC with no reuse`: `NO`
- `Tile-packet NoC with real A/B reuse or M forwarding`: `possibly yes for DRAM savings`, `not yet for throughput`

That means the next technical choice should be:

1. if the product goal is DRAM pressure reduction or off-cluster bandwidth relief, interconnect work is still worth deeper study
2. if the product goal is near-term throughput uplift on the current `128-bit` NoC, this first pass does **not** justify RTL integration yet

## Suggested Next Step

If interconnect work continues, the next study should answer one of these before touching RTL:

1. can the packet payload width move materially above `128 bits`
2. can real multicast/broadcast semantics replace repeated tile packets
3. can the target workload guarantee strong A-only or A/B reuse in practice

If not, the higher-ROI path remains the local PT work already identified elsewhere in the repo:

- export overlap in `PT_MD`
- CE tail reduction in `PT_CE`
