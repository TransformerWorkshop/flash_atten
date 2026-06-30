# Optim Windowed RTL Contract Anchor

Current note: the latest landed implementation is the q4 macro-backed
20-SRAM-macro contract recorded in
[#q4-macro-backed-current-anchor](#q4-macro-backed-current-anchor). Earlier
cycle anchors in this file are historical debug evidence for the previous
flop-backed/16-bank landing.

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
54 tests OK
```

The correctness regression includes one negative-control check:
`test_streaming_state_must_survive_across_kv_windows`. The golden windowed
model matches dense attention with `max_abs < 1.0e-12`, while a forbidden model
that drops all previous KV-window row-state/OACC and keeps only the final
window differs from dense attention by more than `1.0e-4`. This proves the
model-level requirement that row-state and OACC must survive across KV windows.

The RTL-contract model in `model/fa_windowed_rtl_contract_model.py` now also
checks the non-numerical RTL correctness surface that the dense math model does
not see: Q/K/V request order, fixed S=256,d=64 counters, core restore starts,
and K/V window-local SRAM layout roundtrips. It also models the current
`FA_TOP_OPTIM_WINDOWED` AXI layout: Q tiles occupy 512 B each, K/V tiles occupy
2048 B each, O is written as four 8192 B Q groups, the external AXI beat is
128 b, and each read AXI beat is split into two 64 b tile beats for the
existing Q/K/V interfaces. The model checks that the AXI memory layout
roundtrips to the original dense-QK tile stream, that the top-level read
traffic is `1536` AR bursts, `24576` R beats, and `393216` read bytes, and that
the top-level write traffic is `128` AW bursts, `2048` W beats, and `32768`
write bytes. It also checks that the O write word order matches the group dump
stream: group, q4 tile in group, local row, then column pair. It includes a
negative-control for the V SRAM packing bug found by VCS: forcing the V write
bank high bit to zero must produce layout roundtrip errors for resident slots
2 and 3.

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

The current RTL now exposes a structural state restore/spill path for
cross-window correctness:

- The active q4 product path uses `FA_ROW_STATE_Q4_BLOCK_REAL`, which can load
  four rows of `m_state`, `l_state`, and `row_seen` from restore inputs during
  its init handshake.
- `FA_OPTIM_4X4_Q_TILE_STAGGERED_CORE` exports row-state snapshots and accepts
  row-state/OACC restore inputs. On `start`, it either clears OACC for the first
  KV window or restores the previous OACC snapshot for later windows.
- `FA_OPTIM_4X4_WINDOWED_LOOP` stores only q4 row-state in flops inside the
  active Q group: `128b m + 128b l + 4b seen` per q4 tile. OACC state is not a
  q_tile-wide flop snapshot table; it is backed by `FA_OACC_GROUP_SRAM_64X64X16`
  and restored/spilled as 16 x 256b chunks per q4 tile.

This is still not a complete numerical product RTL claim. The model proves the
math contract, and the RTL structural contract is now present. The windowed
real-core top now has fixed-point directed numerical proof for both the earlier
`Q=0` uniform-softmax case and a nonzero-Q/K dense-reference case. The product
top now also writes the full O buffer and checks it against the dense-QK
fixed-point reference. It still needs randomized and causal coverage before
claiming general end-to-end product RTL signoff.

Remote VCS now proves the fixed-shape windowed real-core schedule smoke:

```text
RUN=/home/host/codex_runs/fa_optim_windowed_loop_20260630_131637
VCS compile: CODEX_VCS_COMPILE_STATUS=0
VCS run: CODEX_VCS_RUN_STATUS=0
PASS: fa_optim_4x4_windowed_loop_tb shape=S256_D64_B1_H1 perf_max_cycles=600000 cycles=169093 q_groups=4 kv_windows=16 micro_tiles=1024 q_visits=256 kv_tiles=1024 q_reqs=256 q_beats=16384 k_reqs=64 k_beats=16384 v_reqs=64 v_beats=16384 qk_tasks=131072 pv_tasks=131072 restore_starts=192
```

This VCS run found and closed a real window-local V SRAM packing bug: the write
bank high bit must come from `kv_load_slot_idx_r[1]`, otherwise resident slots
2 and 3 are written into banks 0-7 but read back from banks 8-15.

The Python RTL-contract model reproduces that failure mode with the historical
16-bank layout negative control. In the current 8-bank packed layout, the active
negative control is
`count_v_layout_roundtrip_errors(..., v_write_addr_uses_slot=False) > 0`, and
the corrected mapping must have zero K/V layout roundtrip errors.

The Python model now also has an RTL-bench-aligned fixed-point dense-QK golden
path. `fixed_dense_qk_score_q16`, `expected_dense_qk_fixed_o_word`, and
`fixed_dense_qk_window_output` reproduce the directed Verilog bench reference
for the deterministic dense-QK Q/K/V stream, including Q8.8 input generation,
Q16 score accumulation, exp LUT index quantization, reciprocal, Q8.8 PV
partial conversion, and Q4.12 OACC update. The model intentionally preserves
the Verilog expression width behavior in the dense Q/K pattern:
`row_idx[1:0] + tile_idx[1:0]` wraps as a 2-bit sum before being zero-extended.
This was caught by a cross-checksum mismatch during model calibration, so the
checksum is now a real guard against Python/Verilog reference drift.

Reference points:

```text
fixed_dense_qk_score_q16(63, 0, 0, 0) = 960
fixed_dense_qk_score_q16(63, 3, 15, 15) = 1376
expected_dense_qk_fixed_o_word(0, 0) = 0x082c
expected_dense_qk_fixed_o_word(2, 31) = 0x0a1f
expected_dense_qk_fixed_o_word(3, 63) = 0x0c07
4x64 weighted O checksum = 0x03735a74
```

Remote VCS now also proves a fixed-point directed numerical case for the same
shape. The test drives zero Q, a deterministic low-range V pattern, and full
K/V traffic through the 64-bit beat interfaces. With zero Q, every score in a
KV tile is equal, so the softmax contract collapses to a uniform mean over the
V rows. The testbench computes the expected result using a cycle-independent
fixed-point reference model for row-state `p/rescale`, PV accumulation, and
OACC q4.12 update, then checks all 4 x 64 output words for every final q4 tile.
It also checks V SRAM read responses against the window-local layout.

```text
RUN=/home/host/codex_runs/fa_optim_windowed_numeric_20260630_140520
VCS compile: CODEX_VCS_COMPILE_STATUS=0
VCS run: CODEX_VCS_RUN_STATUS=0
PASS: fa_optim_4x4_windowed_loop_tb shape=S256_D64_B1_H1 numeric=uniform_q_mean_v perf_max_cycles=600000 cycles=154245 q_groups=4 kv_windows=16 micro_tiles=1024 q_visits=256 kv_tiles=1024 q_reqs=256 q_beats=16384 k_reqs=64 k_beats=16384 v_reqs=64 v_beats=16384 qk_tasks=131072 pv_tasks=131072 restore_starts=192
```

This pass closes the earlier "nonzero O only" weakness for the windowed RTL
landing. During debug, the same bench exposed an OACC mode bug in
`FA_OPTIM_4X4_Q_TILE_STAGGERED_CORE`: row-input mode made
`FA_OACC_UPDATE_REAL` update 16 rows while the local O tile only has 4 rows,
aliasing rows 4-15 onto rows 0-3. The core now uses block-input OACC mode with
a packed 4-row `slot_partial_o_block_flat_w`, so OACC only updates the local
4-row q tile.

The same VCS bench now defaults to a nonzero-Q/K dense-reference directed mode.
It drives small nonzero q8.8 Q and K patterns, computes QK scores in the
testbench, runs the same fixed-point max/exp/L/reciprocal, PV, and OACC q4.12
reference sequence as the RTL, and compares every final 4 x 64 output word.
This proves the non-uniform score path, not only the uniform-softmax shortcut.

```text
RUN=/home/host/codex_runs/fa_optim_windowed_dense_20260630_142028
VCS compile: CODEX_VCS_COMPILE_STATUS=0
VCS run: CODEX_VCS_RUN_STATUS=0
PASS: fa_optim_4x4_windowed_loop_tb shape=S256_D64_B1_H1 numeric=dense_qk_reference perf_max_cycles=600000 cycles=154245 q_groups=4 kv_windows=16 micro_tiles=1024 q_visits=256 kv_tiles=1024 q_reqs=256 q_beats=16384 k_reqs=64 k_beats=16384 v_reqs=64 v_beats=16384 qk_tasks=131072 pv_tasks=131072 restore_starts=192
```

The dense-QK Verilog bench now also checks the same `4x64` weighted reference
checksum as the Python fixed-point model:

```text
RUN=/home/host/codex_runs/fa_optim_windowed_modelcheck_20260630_144444
VCS compile: CODEX_VCS_COMPILE_STATUS=0
VCS run: CODEX_VCS_RUN_STATUS=0
PASS: fa_optim_4x4_windowed_loop_tb shape=S256_D64_B1_H1 numeric=dense_qk_reference perf_max_cycles=600000 cycles=154245 q_groups=4 kv_windows=16 micro_tiles=1024 q_visits=256 kv_tiles=1024 q_reqs=256 q_beats=16384 k_reqs=64 k_beats=16384 v_reqs=64 v_beats=16384 qk_tasks=131072 pv_tasks=131072 restore_starts=192
```

`FA_TOP_OPTIM_WINDOWED` now wraps the windowed loop with the existing
`FA_CSR` AXI-Lite control/status plane and uses `FA_AXI_RD_MASTER` to fetch
Q/K/V tiles from the external 128-bit AXI read channel. The top converts each
128-bit AXI beat into two 64-bit tile-interface beats, preserving the dense-QK
Q/K/V stream already checked by the lower-level numerical bench.

The loop now exposes a group O dump stream after each Q group's final KV window
and before the group snapshot table is cleared for the next group. One dump is
`64 rows x 64 columns x 16b = 8192 B`, or `2048` 32-bit words. The top-level
write controller issues one AXI write descriptor per group at
`csr_o_base + group_idx * 8192`, feeds the dump stream into `FA_AXI_WR_MASTER`,
counts write bytes on accepted 32-bit words, and delays CSR `done` until the
final write response has drained. This relies on the current `FA_AXI_WR_MASTER`
contract that `wr_desc_ready` is only high in its idle state; after the final
dump word the top enters `WR_DRAIN` and waits for `wr_desc_ready` before
allowing CSR `done` to become sticky.

The current top smoke drives both AXI read and write channels, stores all
write data into a testbench O memory, and compares every `256 x 64` output word
against the same dense-QK fixed-point reference used by the lower-level loop
bench.

```text
RUN=/home/host/codex_runs/fa_top_optim_windowed_writeback_20260630_154650
VCS compile: CODEX_VCS_COMPILE_STATUS=0
VCS run: CODEX_VCS_RUN_STATUS=0
PASS: fa_top_optim_windowed_tb numeric=dense_qk_reference cycles=165509 rd_bytes=393216 wr_bytes=32768 ar_count=1536 r_beat_count=24576 aw_count=128 w_beat_count=2048
```

The previous read-only top anchor measured `155013` cycles. The current
writeback-complete top measures `165509` cycles, so full O dump plus AXI write
response drain adds `10496` cycles in this serialized functional scaffold. The
delta versus the `FA_OPTIM_4X4_WINDOWED_LOOP` direct-feed dense anchor
(`154245` cycles) is `11264` cycles. This is a measured current-RTL cost, not a
model rejection.

## Causal Product-Top Correctness Anchor

`csr_causal_en` is now functionally wired through the active product path:

```text
FA_TOP_OPTIM_WINDOWED.csr_causal_en
  -> FA_OPTIM_4X4_WINDOWED_LOOP.causal_en
  -> FA_OPTIM_4X4_Q_TILE_STAGGERED_CORE.causal_en
  -> FA_SCORE_POST_REAL.causal_en
```

The q4 tile index is also carried into the score-post path. The global query row
used by causal masking is reconstructed as:

```text
q_blk_idx             = q_tile_idx[5:2]
score_block_row_base = {q_tile_idx[1:0], 2'b00}
global_q             = q_blk_idx * 16 + score_block_row_base + local_row
                     = q_tile_idx * 4 + local_row
```

Important local-row invariant: `score_block_row_base` is used only inside
`FA_SCORE_POST_REAL` for the causal compare. `FA_ROW_STATE_REAL` still receives
`update_row_base=4'd0`, because the staggered core stores and consumes only the
local q4 rows `0..3` in `slot_p_block_flat_r`, `slot_rescale_block_flat_r`, and
OACC. Letting the global row base flow into row-state/OACC would make q tiles
with `q_tile_idx[1:0] != 0` write P/rescale into rows `4/8/12` and then read the
wrong low 4 rows.

The product-top smoke now has a parameterized `CAUSAL_MODE`. It writes CSR
`ADDR_CFG=7'h08` bit0 before `START`, expands the expected-O cache from 4
periodic q tiles to all 64 q tiles, and masks expected scores using
`global_k <= global_q`.

```text
RUN=/home/host/codex_runs/fa_top_optim_windowed_causal_20260630_161107

Non-causal:
VCS compile: CODEX_VCS_COMPILE_STATUS=0
VCS run: CODEX_VCS_RUN_STATUS=0
PASS: fa_top_optim_windowed_tb numeric=dense_qk_reference causal=0 cycles=165509 rd_bytes=393216 wr_bytes=32768 ar_count=1536 r_beat_count=24576 aw_count=128 w_beat_count=2048

Causal:
VCS compile: CODEX_VCS_COMPILE_STATUS=0
VCS run: CODEX_VCS_RUN_STATUS=0
PASS: fa_top_optim_windowed_tb numeric=dense_qk_reference causal=1 cycles=165509 rd_bytes=393216 wr_bytes=32768 ar_count=1536 r_beat_count=24576 aw_count=128 w_beat_count=2048
```

The causal run is a functional correctness anchor, not a causal performance
optimization. The current RTL still schedules all KV tiles and masks future
keys in score-post, so cycles and AXI traffic match the non-causal run. The
model-level opportunity remains to skip fully future KV tiles/windows; that is
the next performance lever after this correctness landing.

### Causal Compute Skip Anchor

The first causal performance landing is now implemented inside
`FA_OPTIM_4X4_Q_TILE_STAGGERED_CORE`. The core computes an
`effective_kv_end_idx_w`:

```text
causal_kv_end_idx_w    = q_tile_idx[5:2] + 1
effective_kv_end_idx_w = min(kv_window_end, causal_kv_end_idx_w) when causal
                       = kv_window_end when non-causal
```

All QK, score-post, row-state, PV, and OACC issue checks use this effective end
index. If an entire resident KV window is future-only for the current q4 tile,
the core restores/init state and then finishes without issuing any compute work.

This lands the model target for causal compute work:

| Metric | Non-causal | Causal after skip |
| --- | ---: | ---: |
| `kv_tiles` / `micro_tile_count` | `1024` | `544` |
| `qk_tasks` | `131072` | `69632` |
| `pv_tasks` | `131072` | `69632` |
| Product-top cycles | `165509` | `118597` |
| `rd_bytes` | `393216` | `393216` |

```text
RUN=/home/host/codex_runs/fa_top_optim_windowed_causal_skip_20260630_162321

Non-causal:
VCS compile: CODEX_VCS_COMPILE_STATUS=0
VCS run: CODEX_VCS_RUN_STATUS=0
PASS: fa_top_optim_windowed_tb numeric=dense_qk_reference causal=0 cycles=165509 rd_bytes=393216 wr_bytes=32768 ar_count=1536 r_beat_count=24576 aw_count=128 w_beat_count=2048 kv_tiles=1024 qk_tasks=131072 pv_tasks=131072

Causal compute-skip:
VCS compile: CODEX_VCS_COMPILE_STATUS=0
VCS run: CODEX_VCS_RUN_STATUS=0
PASS: fa_top_optim_windowed_tb numeric=dense_qk_reference causal=1 cycles=118597 rd_bytes=393216 wr_bytes=32768 ar_count=1536 r_beat_count=24576 aw_count=128 w_beat_count=2048 kv_tiles=544 qk_tasks=69632 pv_tasks=69632
```

### Causal Load-Window Skip Anchor

The next scheduler landing suppresses fully future resident KV windows in
`FA_OPTIM_4X4_WINDOWED_LOOP`. For the fixed `S=256,d=64` shape, a 64-row Q
group only needs KV windows whose `kv_window_idx <= q_group_idx` in causal
mode. The loop now uses:

```text
causal_kv_window_needed_w = (!causal_en) || (kv_window_idx_r <= q_group_idx_r)
core_last_kv_window_w     = physical_last_window ||
                            (causal_en && kv_window_idx_r == q_group_idx_r)
```

When the next KV window is future-only, the loop dumps the retained per-q4
snapshot/OACC state for the Q group instead of loading K/V, reloading Q, or
starting the core. The total causal skipped future work remains `480` KV
micro-tiles: `384` from six whole skipped windows plus `96` from the diagonal
windows' per-q4 effective-end truncation inside the core.

```text
RUN=/home/host/codex_runs/fa_top_optim_windowed_causal_load_skip_20260630_164010

Non-causal:
VCS compile/run: pass
PASS: fa_top_optim_windowed_tb numeric=dense_qk_reference causal=0 cycles=165509 rd_bytes=393216 wr_bytes=32768 ar_count=1536 r_beat_count=24576 aw_count=128 w_beat_count=2048 kv_windows=16 q_reqs=256 k_reqs=64 v_reqs=64 core_starts=256 restore_starts=192 kv_tiles=1024 qk_tasks=131072 pv_tasks=131072

Causal load-window skip:
VCS compile/run: pass
PASS: fa_top_optim_windowed_tb numeric=dense_qk_reference causal=1 cycles=99061 rd_bytes=245760 wr_bytes=32768 ar_count=960 r_beat_count=15360 aw_count=128 w_beat_count=2048 kv_windows=10 q_reqs=160 k_reqs=40 v_reqs=40 core_starts=160 restore_starts=96 kv_tiles=544 qk_tasks=69632 pv_tasks=69632
```

This closes the previous `rtl_missing_feature` for causal K/V load-window
suppression on the active product path. It is a measured current RTL fact, not
only a model target.

### Q4 Macro-Backed Current Anchor

The active windowed loop has since moved from the earlier flop-backed q4 OACC
snapshot table to q4 OACC macro backing and the 20-macro storage contract:

- `STATE_GROUP_ROWS = 4`; state fill/spill/restore accounting is per q4 tile,
  not q8/q16.
- K window uses 8 `256x64` macros. Adjacent K rows are packed into the low/high
  32b halves of each 64b macro word, so the QK read side still returns
  `16 rows x 32b = 512b` per request. The current functional write path stores
  each external 64b K beat as two internal macro writes.
- V window uses 8 `256x64` macros. Slot identity is held in the macro address
  field rather than doubling banks by `slot_high`.
- OACC group uses 4 `256x64` macros via
  `FA_OACC_GROUP_SRAM_64X64X16`. One q4 OACC state is 4096b and is restored or
  spilled as 16 beats of 256b.
- The old `reg [4095:0] q_tile_o_state_r [0:Q_TILES_PER_GROUP-1]` snapshot
  array is no longer part of the design.

Current measured VCS anchors:

```text
RUN=/home/host/codex_runs/fa_q4_oacc_macro_20260630_215127

Windowed loop:
PASS: fa_optim_4x4_windowed_loop_tb shape=S256_D64_B1_H1 numeric=dense_qk_reference perf_max_cycles=600000 cycles=191109 q_groups=4 kv_windows=16 micro_tiles=1024 q_visits=256 kv_tiles=1024 q_reqs=256 q_beats=16384 k_reqs=64 k_beats=16384 v_reqs=64 v_beats=16384 qk_tasks=131072 pv_tasks=131072 restore_starts=192

Product top, non-causal:
PASS: fa_top_optim_windowed_tb numeric=dense_qk_reference causal=0 cycles=193037 rd_bytes=393216 wr_bytes=32768 ar_count=1536 r_beat_count=24576 aw_count=128 w_beat_count=2048 kv_windows=16 q_reqs=256 k_reqs=64 v_reqs=64 core_starts=256 restore_starts=192 kv_tiles=1024 qk_tasks=131072 pv_tasks=131072

Product top, causal:
PASS: fa_top_optim_windowed_tb numeric=dense_qk_reference causal=1 cycles=115837 rd_bytes=245760 wr_bytes=32768 ar_count=960 r_beat_count=15360 aw_count=128 w_beat_count=2048 kv_windows=10 q_reqs=160 k_reqs=40 v_reqs=40 core_starts=160 restore_starts=96 kv_tiles=544 qk_tasks=69632 pv_tasks=69632
```

The cycle delta versus the earlier flop-backed/16-bank anchors is expected for
this functional landing: OACC restore/spill now costs real macro cycles, and K
8-bank packing serializes each K load beat into two internal writes. These are
current-RTL costs and should be optimized only after preserving the 20-macro q4
contract.

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
| `kv_window_count` | `16` | `10` | Resident KV windows actually loaded |
| `q_tile_visit_count` | `256` | `160` | Q reload visits across loaded windows |
| `q_tile_req_count` | `256` | `160` | Q request handshakes |
| `q_tile_beat_count` | `16384` | `10240` | Q 64-bit beat handshakes |
| `k_tile_req_count` | `64` | `40` | K tile load requests |
| `k_tile_beat_count` | `16384` | `10240` | K 64-bit beat handshakes |
| `v_tile_req_count` | `64` | `40` | V tile load requests |
| `v_tile_beat_count` | `16384` | `10240` | V 64-bit beat handshakes |
| `core_start_count` | `256` | `160` | Q tile core starts |
| `restore_start_count` | `192` | `96` | Starts after the first effective window |
| `kv_tile_compute_count` | `1024` | `544` | Non-skipped q4 x kv16 work items |
| `skipped_future_kv_tiles` | `0` | `480` | Fully future-masked causal tiles |
| `score_slice_count` | `4096` | `2176` | Score slice beats |
| `oacc_slice_count` | `4096` | `2176` | OACC slice beats |
| `state_fill_count` | `256` | `160` | Row-state/OACC restore/init events |
| `state_spill_count` | `256` | `160` | Row-state/OACC save events |
| `rd_bytes` | `393216` | `245760` | AXI read byte count |
| `ar_count` | `1536` | `960` | AXI read address bursts |
| `r_beat_count` | `24576` | `15360` | AXI read data beats |

## Current Gap To Final RTL

The current full-loop landing module, `FA_OPTIM_4X4_FULL_LOOP`, still implements
the historical full K/V resident schedule. The new contract module is separate
so the target loop can be checked without destabilizing the numerical full-loop
anchor.

Remaining RTL landing items after the q4 macro-backed area cleanup:

1. Add randomized numerical coverage around `FA_OPTIM_4X4_WINDOWED_LOOP`. The
   current directed benches prove one nonzero-Q/K dense-reference fixed-point
   stream in both non-causal and causal product-top modes, but not arbitrary
   score distributions.
2. Re-run product-top VCS after the post-latest-run q4-specialized
   score/row-state/OACC/GEMM-control cleanup. The expected counters remain the
   q4 OACC macro-backed values above.
3. Run the next DC only after that VCS gate is green; the latest measured DC
   area remains the compile-ultra `1.964860M NAND2` run recorded in `AREA.md`.
4. Broaden product-top output checking beyond the current directed dense-QK
   fixed-point stream.
