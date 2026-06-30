# Optim Windowed RTL Contract Anchor

This note records the first RTL landing step for the target windowed Flash
Attention architecture. It is a contract scaffold and not a complete numerical
product RTL claim.

## Current Evidence

The target mathematical schedule is modeled in
`model/fa_windowed_attention_model.py`. The model proves that the following
loop order is numerically equivalent to dense attention for both causal and
non-causal cases:

```text
for q_group in 4 groups of 64 rows:
  for kv_window in 4 windows of 4 KV tiles:
    load K/V window
    for q4 tile in q_group:
      restore row-state/OACC
      process 4 KV tiles
      spill row-state/OACC
```

Local evidence:

```text
python -m unittest discover model -v
36 tests OK
```

The correctness regression includes one negative-control check:
`test_streaming_state_must_survive_across_kv_windows`. The golden windowed
model matches dense attention with `max_abs < 1.0e-12`, while a forbidden model
that drops all previous KV-window row-state/OACC and keeps only the final
window differs from dense attention by more than `1.0e-4`. This proves the
model-level requirement that row-state and OACC must survive across KV windows.

## RTL Landing Status

`FA_OPTIM_WINDOWED_SCHED_CONTRACT` is the first RTL contract module for the new
schedule. It implements the loop nest and exposes request and accounting
counters. It does not yet instantiate the real `FA_OPTIM_4X4_Q_TILE_STAGGERED_CORE`
or perform numerical QK/softmax/PV/OACC computation.

`FA_OPTIM_4X4_WINDOWED_LOOP` is the first RTL landing module that connects the
windowed loop nest to the real `FA_OPTIM_4X4_Q_TILE_STAGGERED_CORE`. It keeps
the external Q/K/V 64-bit beat interfaces, loads four K/V tiles per resident
window, starts the real core once per `{q4 tile, KV window}`, and drives
`kv_base_idx`, `kv_count=4`, `first_kv_window`, and `last_kv_window` into the
core. Its K/V SRAM layout is window-local, not full-matrix resident: the local
SRAM row encodes the resident window slot.

The current RTL now exposes a structural state snapshot path for cross-window
correctness:

- `FA_ROW_STATE_REAL` can load `m_state`, `l_state`, and `row_seen` from restore
  inputs during its init handshake.
- `FA_OPTIM_4X4_Q_TILE_STAGGERED_CORE` exports row-state snapshots and accepts
  row-state/OACC restore inputs. On `start`, it either clears OACC for the first
  KV window or restores the previous OACC snapshot for later windows.
- `FA_OPTIM_4X4_WINDOWED_LOOP` stores one snapshot per q4 tile inside the active
  Q group and reconnects it on later KV windows. One q4 snapshot is
  `512b m + 512b l + 16b seen + 4096b OACC = 5136b`; 16 q4 tiles require
  `82176b`, or `10272B`, before any later area-oriented compression.

This is still not a complete numerical product RTL claim. The model proves the
math contract, and the RTL structural contract is now present, but the
windowed real-core top still needs a remote VCS numerical directed test before
claiming end-to-end RTL correctness or performance.

TABLE I
Module Parameters

| Parameter | Value | Meaning |
| --- | ---: | --- |
| `SEQ_LEN` | `256` | Fixed competition sequence length |
| `HEAD_DIM` | `64` | Fixed head dimension |
| `Q_GROUP_ROWS` | `64` | Rows whose row-state/OACC lifetime is retained |
| `Q_TILE_ROWS` | `4` | One 4x4 SA query tile |
| `KV_TILE_ROWS` | `16` | One KV tile |
| `KV_WINDOW_TILES` | `4` | Resident KV window size |
| `SCORE_SLICE_COLS` | `4` | Score post slice width |
| `OACC_SLICE_COLS` | `16` | OACC slice width |

## Interface Contract

The module has one synchronous clock domain, active-low `rstn`, and a
synchronous `clear`. `start` is sampled in `ST_IDLE`. `done` is a one-cycle
pulse after all groups, windows, q tiles, and KV slots have been scheduled.

The Q/K/V request interfaces are single-beat valid/ready requests:

| Interface | Valid | Ready | Index | Contract |
| --- | --- | --- | --- | --- |
| Q tile request | `q_tile_req_valid` | `q_tile_req_ready` | `q_tile_req_q_idx[5:0]` | One request per q4 visit |
| K tile request | `k_tile_req_valid` | `k_tile_req_ready` | `k_tile_req_kv_idx[4:0]` | One request per resident K tile load |
| V tile request | `v_tile_req_valid` | `v_tile_req_ready` | `v_tile_req_kv_idx[4:0]` | One request per resident V tile load |

Backpressure is supported on all three request interfaces. The module advances
only after each valid/ready handshake.

## Counter Contract

TABLE II
Expected Counter Values

| Counter | Non-causal | Causal | Meaning |
| --- | ---: | ---: | --- |
| `q_group_count` | `4` | `4` | Number of 64-row Q groups |
| `kv_window_count` | `16` | `16` | Four KV windows per Q group |
| `q_tile_visit_count` | `256` | `256` | Q reload visits across windows |
| `q_tile_req_count` | `256` | `256` | Q request handshakes |
| `k_tile_req_count` | `64` | `64` | K tile load requests |
| `v_tile_req_count` | `64` | `64` | V tile load requests |
| `kv_tile_compute_count` | `1024` | `544` | Non-skipped q4 x kv16 work items |
| `skipped_future_kv_tiles` | `0` | `480` | Fully future-masked causal tiles |
| `score_slice_count` | `4096` | `2176` | Score slice beats |
| `oacc_slice_count` | `4096` | `2176` | OACC slice beats |
| `state_fill_count` | `256` | `256` | Row-state/OACC restore events |
| `state_spill_count` | `256` | `256` | Row-state/OACC save events |

## Current Gap To Final RTL

The current full-loop landing module, `FA_OPTIM_4X4_FULL_LOOP`, still implements
the historical full K/V resident schedule. The new contract module is separate
so the target loop can be checked without destabilizing the numerical full-loop
anchor.

Remaining RTL landing items:

1. Add a numerical VCS directed bench for `FA_OPTIM_4X4_WINDOWED_LOOP` that
   checks S=256,d=64 against the model-generated dense/windowed reference.
2. Convert score post and OACC update to the sliced widths used by the contract.
3. Decide whether the q4 snapshot table remains flops for the first functional
   anchor or is moved into small SRAM/RF storage before area work.
4. Run remote VCS on `fa_optim_windowed_sched_contract_tb` and then a full
   numerical windowed top once the real compute path is connected.
