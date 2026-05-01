# 2026-04-30 DC DRC RTL Root-Cause And Fix Plan

## Summary

- DC run: `20260430_161604_full_ultra_area_timing_48g_rerun`
- Top: `FA_TOP_BASELINE`
- Constraint: `set_max_transition 0.250`, `set_max_capacitance 0.200`
- QoR status: setup meets 200 MHz, area is about 1.68M NAND2 equivalent.
- DRC status: 49 total DRC nets, all are max-transition violations.
- Worst transition: 0.26 ns against 0.25 ns, worst slack -0.01 ns.
- Max-capacitance violations: 0.

This is a narrow transition cleanup problem, not a broad timing or capacitance failure. The violations are concentrated in a few replicated wide data/control structures.

## Violation Grouping

| Region | Count | Representative nets | RTL location | Main cause |
| --- | ---: | --- | --- | --- |
| `GEMU_V3` under `GEMM_V3` | 35 | `...gemu_unit/n580`, `n578`, `n579`, `n581`, `n582`, `n584`, `n585`, plus `n1673/n1674/n1745/n1750` | `/Users/yucheng/Documents/GitHub/flash_atten/rtl/gemu_v3.v:36`, `:72`, `:123` | `tile_done` / `acc_done` / `m_valid_r` control is reused across 128-bit `accm` and `m_data_r` mux/update cones. |
| `FA_SCORE_POST_REAL` | 10 | `u_core/u_score_post/n23963`, `n23340`, `n23949`, `n29217`, `n29196`, `n25216`, `n30623`, `n30901`, `n24050`, `n17535` | `/Users/yucheng/Documents/GitHub/flash_atten/rtl/fa_score_post_real.v:182` to `:196` | 16-column one-cycle mask/scale/writeback creates many parallel q16 multipliers and wide write muxes. |
| `FA_K_BUF_REAL/FA_REG_TILE_BUF_REAL` | 2 | `u_core/u_k_buf/u_reg_buf/n1714`, `n1888` | `/Users/yucheng/Documents/GitHub/flash_atten/rtl/fa_buffers_real.v:119`, `:186` to `:188`, wrapper at `:239` | One `rd_addr` decode selects 16 rows x 32-bit words from a 512-word flop array. |
| `FA_Q_BUF_REAL/FA_REG_TILE_BUF_REAL` | 1 | `u_core/u_q_buf/u_reg_buf/n1724` | `/Users/yucheng/Documents/GitHub/flash_atten/rtl/fa_buffers_real.v:119`, `:186` to `:188`, wrapper at `:203` | Same read mux structure as K buffer. |
| `FA_ROW_STATE_REAL` | 1 | `u_core/u_row_state/n50018` | `/Users/yucheng/Documents/GitHub/flash_atten/rtl/fa_row_state_real.v:294` to `:300`, `:475` to `:503` | `row_has_valid_r` gates a wide row commit path and fans into many muxes. |

## Evidence From Netlist

### GEMU

For `u_core/u_qk_pv_core/u_gemm/gen_gemu_row[0].gen_gemu_col[2].gemu_unit/n580`, the synthesized netlist has:

```verilog
ND2D1BWP7T40P140 U787 ( .A1(n575), .A2(tile_done), .ZN(n580) );
DEL025D1BWP7T40P140 U788 ( .I(n580), .Z(n581) );
MOAI22D1BWP7T40P140 U859 ( .A1(...), .A2(n580), .B1(...), .B2(m_data_r[...]), ... );
...
```

The DC verbose report shows 54 violating pins on each of the worst GEMU nets. That matches a single finish/control term driving many `m_data_r[...]` mux inputs.

RTL root:

- `/Users/yucheng/Documents/GitHub/flash_atten/rtl/gemu_v3.v:37`: `acc_done`
- `/Users/yucheng/Documents/GitHub/flash_atten/rtl/gemu_v3.v:72`: `tile_done`
- `/Users/yucheng/Documents/GitHub/flash_atten/rtl/gemu_v3.v:123`: `STATE_ACCM` finish branch updates `m_data_r`, `m_valid_r`, `accm`, and `acc_cnt`.

### Score Post

The score-post violations sit in the single-cycle `ST_RUN` loop:

- `/Users/yucheng/Documents/GitHub/flash_atten/rtl/fa_score_post_real.v:182`
- `/Users/yucheng/Documents/GitHub/flash_atten/rtl/fa_score_post_real.v:184`
- `/Users/yucheng/Documents/GitHub/flash_atten/rtl/fa_score_post_real.v:193`
- `/Users/yucheng/Documents/GitHub/flash_atten/rtl/fa_score_post_real.v:194`

Each cycle processes 16 columns. For active columns it calls `q16_mul_rn_sat(score_word_s, scale_word_r)` and writes both block output and debug tile output. This duplicates multiplier/control fanout.

### Q/K Buffers

The flat register tile buffer implements:

```verilog
for (row_i = 0; row_i < 16; row_i = row_i + 1) begin
    rd_data[(row_i * 32) +: 32] <= word_mem_r[(row_i * 32) + rd_addr];
end
```

This creates 16 parallel 32-bit muxes from a 512-entry flop array. The same address decode/control nets fan into many mux cells.

There is already a more DRC-friendly banked implementation in the same file:

- `/Users/yucheng/Documents/GitHub/flash_atten/rtl/fa_buffers_real.v:1`: `FA_BANKED_TILE_BUF_REAL`
- Current Q wrapper still instantiates flat `FA_REG_TILE_BUF_REAL` at `/Users/yucheng/Documents/GitHub/flash_atten/rtl/fa_buffers_real.v:220`.
- Current K wrapper still instantiates flat `FA_REG_TILE_BUF_REAL` at `/Users/yucheng/Documents/GitHub/flash_atten/rtl/fa_buffers_real.v:256`.

### Row State

The row-state violation maps to a commit gate:

```verilog
if (!row_has_valid_r) begin
    ...
end else begin
    ...
    for (col_i = 0; col_i < 16; col_i = col_i + 1) begin
        p_q16_s = q16_mul_rn_sat(beta_r[col_i], recip_l_new_r);
        ...
    end
end
```

The synthesized netlist contains:

```verilog
ND2D1BWP7T40P140 U3626 ( .A1(...), .A2(row_has_valid_r), .ZN(n50018) );
OAI22D1BWP7T40P140 ... .A2(n50018) ...
```

So `row_has_valid_r` is not just a scalar state flag after synthesis; it becomes a control for many muxes in the row commit datapath.

## Recommended RTL Fix Order

### 1. Fix `GEMU_V3` first

This covers 35/49 violations, so it is the highest-leverage fix.

Implementation status:

- Done locally after this report was created.
- `GEMU_V3` now has `ACC_WIDTH`, defaulting to the old `4 * WIDTH` behavior.
- `GEMM_V3` passes `ACC_WIDTH` into each `GEMU_V3`.
- The current `FA_QK_PV_SHARED_CORE_REAL` instance sets `ACC_WIDTH(64)`.
- External `m` / `m_group_data` width is unchanged; the 64-bit internal result is sign-extended back to the existing 128-bit lane interface.
- Local `./scripts/synth_sanity.sh` passed after the change.

Low-risk, no-latency-change approach:

- Define an internal finish condition, e.g. `finish_fire = in_accm && acc_done && !m_valid_r`.
- Split the 128-bit `accm` and `m_data_r` update logic into 4 x 32-bit chunks or 2 x 64-bit chunks.
- Give each chunk a local replicated finish/control wire, e.g. `finish_fire_chunk[0..3]`.
- Add Synopsys-friendly keep/dont-merge guidance on the replicated control nets if DC re-merges them.
- Keep the external protocol unchanged: `tile_done`, `m_valid`, `m`, `start_ready`, `a_ready`, and `b_ready` should preserve current cycle behavior.

Expected effect:

- Worst GEMU net fanout should drop from about 54 violating pins to about 13-14 pins per 32-bit chunk.
- This should remove most or all of the -0.01 ns transition violations without adding pipeline latency.

Stronger option if no-latency split is not enough:

- Add a `STATE_FINISH` or registered finish enable and perform `m_data_r <= accm` one cycle later.
- This is more robust electrically, but it changes the GEMU/output handshake latency and requires upstream/downstream validation.

### 2. Clean up `FA_SCORE_POST_REAL`

No-latency cleanup:

- Compute `scaled_word_s = q16_mul_rn_sat(score_word_s, scale_word_r)` once per column and reuse it for both outputs.
- Guard `masked_score_tile_flat` synthesis behavior consistently. It is marked debug, but the `ST_RUN` assignments are not under `ifndef SYNTHESIS`; either move them under `ifndef SYNTHESIS` or drive a synthesis-only zero/debug-disabled path if this signal is not needed in gates.
- Split the 16-column loop into four 4-column groups, with local copies of `scale_word_r`, `causal_r`, and row/column mask controls.

Higher-impact option:

- Process 4 or 8 columns per cycle instead of all 16.
- This cuts multiplier/control fanout and area pressure substantially, but changes score-post latency and row-state backpressure timing.

### 3. Switch Q/K to the banked tile buffer

Minimal structural RTL change:

- In `FA_Q_BUF_REAL`, instantiate `FA_BANKED_TILE_BUF_REAL` instead of `FA_REG_TILE_BUF_REAL`.
- In `FA_K_BUF_REAL`, instantiate `FA_BANKED_TILE_BUF_REAL` instead of `FA_REG_TILE_BUF_REAL`.

Reason:

- The banked implementation already decomposes `rd_addr` into `rd_addr[4:2]` and `rd_addr[1:0]`.
- It avoids building a single 512-word flop mux per read and should remove the 3 Q/K max-transition violations.

Signoff check needed:

- Run simulation/sanity on Q/K read-after-write behavior, especially around `rd_valid` alignment and `rd_bank_sel_r`.
- Then rerun DC DRC and Formality.

### 4. Partition `FA_ROW_STATE_REAL` commit controls

No-latency cleanup:

- Create local replicated commit controls for 4-column groups, e.g. `row_has_valid_commit_g[0..3]`.
- Split the `ST_ROW_COMMIT` loop into four small groups so one scalar `row_has_valid_r` does not directly gate all p-tile write muxes.
- Keep scalar state updates (`m_state_r`, `l_state_r`, `row_seen_r`, `rescale_vec_flat`) outside the wide per-column loop where possible.

If DRC remains:

- Add a separate empty-row commit state for `!row_has_valid_r`.
- Pipeline the beta/probability update tree. This changes latency and should be done only after the no-latency partition is checked.

## DC Validation After RTL Changes

Recommended validation sequence:

1. Run local RTL sanity tests.
2. Rerun DC with the same 200 MHz, area, max-transition, and max-cap constraints.
3. Check:
   - `report_qor`: max-transition violations should go from 49 to 0.
   - setup WNS/TNS must remain 0.
   - area should remain below 588000 cell-area target, about 2.0M NAND2 equivalent.
4. Rerun Formality with fresh SVF.

DC triage knob, not the primary fix:

- Add targeted `set_max_fanout` / tighter `set_max_transition` pressure on the known GEMU finish controls and Q/K read-decode cones.
- This can confirm that buffering/replication solves the violation, but structural RTL partitioning is a cleaner long-term fix.
