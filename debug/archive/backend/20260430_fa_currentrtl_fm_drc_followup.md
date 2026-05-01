# 2026-04-30 RTL vs Netlist Formality and DRC Follow-up

## Scope

- Design: `FA_TOP_BASELINE`
- RTL source: `/home/host/Desktop/flash_atten/synopsys/rtl`
- DC netlist: `/home/host/Desktop/flash_atten/synopsys/dc/results/FA_TOP_BASELINE/FA_TOP_BASELINE_compile.v`
- DC DDC: `/home/host/Desktop/flash_atten/synopsys/dc/results/FA_TOP_BASELINE/FA_TOP_BASELINE_compile.ddc`
- Local repo snapshot: `/Users/yucheng/Documents/GitHub/flash_atten`

## Equivalence Check

Formality run:

- Script: `/home/host/Desktop/flash_atten/synopsys/formality/flow/20260430_1710_currentrtl_rtl_vs_netlist.tcl`
- Log: `/home/host/Desktop/flash_atten/synopsys/formality/logs/20260430_1710_currentrtl_rtl_vs_netlist.log`
- Reports: `/home/host/Desktop/flash_atten/synopsys/formality/reports/FA_TOP_BASELINE/20260430_1710_currentrtl_rtl_vs_netlist_*.rpt`
- Local snapshots:
  - `/Users/yucheng/Documents/GitHub/flash_atten/debug/20260430_1710_currentrtl_rtl_vs_netlist_match.rpt`
  - `/Users/yucheng/Documents/GitHub/flash_atten/debug/20260430_1710_currentrtl_rtl_vs_netlist_verify.rpt`
  - `/Users/yucheng/Documents/GitHub/flash_atten/debug/20260430_1710_currentrtl_rtl_vs_netlist_setup_status.rpt`

Current status as of 2026-04-30 18:59 CST:

- Formality is still running on the remote VM:
  - wrapper PID: `14907`
  - `fm_shell_exec` PID: `14960`
- Match stage completed.
  - `114859` compare points matched by name.
  - `0(0)` unmatched reference/implementation compare points.
  - `196` matched primary inputs / black-box outputs.
  - `8497(0)` unmatched reference/implementation unread points.
- Verify stage is not final yet, so this is not a sign-off equivalence pass.
  - Latest progress: `0F/0A/113740P/1119U (99% Verification completed)`.
  - Latest observed memory: about `44901 MB`.
  - Runtime at latest progress line: `6390 sec`.
  - Formality reported about `35.0 hrs until timeout` for the remaining hard points.
  - `verify.rpt` updated at 18:58, confirming the process is still making progress.
- The 48 GB VM is enough to keep the job alive, but it is very tight:
  - observed RSS reached about `45.4 GB`;
  - swap stayed low, about `29 MB`;
  - Formality emitted `LWP: fork failed ... Cannot allocate memory. Running in parent.`

Important Formality setup note:

- The SVF accepted most guidance (`284066` accepted, `720` rejected).
- Formality warned that no `guide_hier_map` commands were found in the SVF, and recommended enabling `hdlin_enable_hier_map` and `set_verification_top` in Design Compiler. This likely explains the long runtime and the rejected guidance.

RTL interpretation warnings to review even if equivalence proves:

- `rtl/gemm_v3.v:163`: `pe_m_data` index may take values outside array bound.
- `rtl/fa_row_state_real.v:300`: `masked_score_block_valid_r` index may take values outside array bound.

These are not necessarily functional failures, but Formality warns they may disagree with a simulator if the out-of-bound index can be reached.

Recommended next steps for a clean equivalence sign-off:

1. Let the current Formality run continue if the VM can stay allocated; it has already reached 99% verification.
2. If it does not finish in a useful time, rerun with at least 64 GB memory or a hierarchical Formality flow.
3. Regenerate SVF from DC with hierarchy-map guidance enabled, using the DC/Formality-recommended `hdlin_enable_hier_map` and `set_verification_top` methodology.
4. Review/fix the two RTL out-of-bound interpretation warnings before treating a future Formality pass as final sign-off.

## DRC Summary

Source report:

- Remote parsed TSV: `/home/host/Desktop/flash_atten/synopsys/dc/reports/FA_TOP_BASELINE/20260430_1710_currentrtl_max_transition_nets_parsed.tsv`
- Local copy: `/Users/yucheng/Documents/GitHub/flash_atten/debug/20260430_1710_currentrtl_max_transition_nets_parsed.tsv`

Result:

| Constraint | Violations | Worst observed transition | Notes |
| --- | ---: | ---: | --- |
| max_transition | 49 | 0.26 ns | limit is effectively 0.25 ns; worst slack is -0.01 ns |
| max_capacitance | 0 | n/a | no violated max cap constraints |

Grouped by design region:

| Region | Violating nets | RTL correspondence | Likely cause |
| --- | ---: | --- | --- |
| `GEMU_V3` instances under `GEMM_V3` | 35 | `/Users/yucheng/Documents/GitHub/flash_atten/rtl/gemu_v3.v:36`, `/Users/yucheng/Documents/GitHub/flash_atten/rtl/gemu_v3.v:72`, `/Users/yucheng/Documents/GitHub/flash_atten/rtl/gemu_v3.v:123` | `tile_done` / `acc_done` / `m_valid_r` control terms feed wide 128-bit accumulator/output mux and reset/update cones; many generated GEMU instances reproduce the same high-fanout structure. |
| `FA_SCORE_POST_REAL` | 10 | `/Users/yucheng/Documents/GitHub/flash_atten/rtl/fa_score_post_real.v:50`, `/Users/yucheng/Documents/GitHub/flash_atten/rtl/fa_score_post_real.v:182` | One-cycle 16-column unrolled q16 multiply/mask/writeback shares scale/control predicates into large multiplier and write mux cones. |
| `FA_K_BUF_REAL/FA_REG_TILE_BUF_REAL` | 2 | `/Users/yucheng/Documents/GitHub/flash_atten/rtl/fa_buffers_real.v:119`, `/Users/yucheng/Documents/GitHub/flash_atten/rtl/fa_buffers_real.v:186` | Register-file tile buffer read uses one `rd_addr` decode to select 16 rows x 32-bit words from a 512-word register array. |
| `FA_Q_BUF_REAL/FA_REG_TILE_BUF_REAL` | 1 | `/Users/yucheng/Documents/GitHub/flash_atten/rtl/fa_buffers_real.v:119`, `/Users/yucheng/Documents/GitHub/flash_atten/rtl/fa_buffers_real.v:186` | Same read-mux structure as K buffer. |
| `FA_ROW_STATE_REAL` | 1 | `/Users/yucheng/Documents/GitHub/flash_atten/rtl/fa_row_state_real.v:294`, `/Users/yucheng/Documents/GitHub/flash_atten/rtl/fa_row_state_real.v:330` | `row_has_valid_r` / valid-mask control gates wide row update and reduction logic. |

## Representative Net Mapping

`GEMU_V3` example:

- Gate net: `u_core/u_qk_pv_core/u_gemm/gen_gemu_row[0].gen_gemu_col[2].gemu_unit/n580`
- Violation: transition 0.26 ns, slack -0.01 ns
- Driver pattern in synthesized netlist: a NAND of `tile_done`-related state/control terms followed by high fanout into many mux cells around `m_data_r[...]`.
- RTL root: `tile_done = in_accm && acc_done && !m_valid_r` and the `STATE_ACCM` block that captures `m_data_r <= accm`, clears `accm`, and updates `m_valid_r`.

`FA_SCORE_POST_REAL` example:

- Gate nets: `u_core/u_score_post/n23963`, `n23340`, `n23949`, `n29217`, `n29196`, `n25216`, `n30623`, `n30901`, `n24050`, `n17535`
- Violation: transition about 0.25 ns, zero/near-zero slack
- RTL root: the `ST_RUN` loop computes 16 masked/scaled outputs per row in one cycle and calls `q16_mul_rn_sat` for each active column.

`FA_REG_TILE_BUF_REAL` example:

- Gate nets: `u_core/u_k_buf/u_reg_buf/n1714`, `u_core/u_k_buf/u_reg_buf/n1888`, `u_core/u_q_buf/u_reg_buf/n1724`
- Violation: transition about 0.25 ns, zero/near-zero slack
- RTL root: `rd_data[(row_i * 32) +: 32] <= word_mem_r[(row_i * 32) + rd_addr];`

## Modification Plan

Recommended order:

1. Fix `GEMU_V3` high-fanout control first, because it accounts for most violations.
   - Split 128-bit accumulator/output control into 4 x 32-bit or per-packed-lane chunks.
   - Create local replicated control wires/register enables per chunk, with synthesis keep/dont-merge guidance if needed.
   - Preserve protocol latency initially; this should mainly change local control replication and generated always-block structure.

2. Rework `FA_SCORE_POST_REAL` if DRC remains after GEMU cleanup.
   - Low-risk no-latency option: duplicate scale/mask/control predicates per 4-column group and structure the loop as four independent groups.
   - Stronger QoR option: process 4 or 8 columns per cycle, or pipeline q16 multiply and writeback. This reduces fanout and area pressure but changes latency/control timing.

3. Replace or bank `FA_REG_TILE_BUF_REAL` for Q/K buffers.
   - Best area/timing direction: infer or instantiate SRAM/register-file macros rather than a 512 x 32 flop array with wide mux reads.
   - Minimal RTL option: bank the read path by row groups and register/replicate read decode locally.

4. Partition `FA_ROW_STATE_REAL` row controls.
   - Duplicate row-valid and commit controls per 4-column group.
   - If latency can change, pipeline row max/beta-sum/update reductions.

DC-only validation knob after RTL changes:

- Add targeted `set_max_fanout` or `set_max_transition` pressure on the known high-fanout control cones and rerun incremental compile to confirm buffering/replication removes the 49 max-transition violations.
- Treat this as validation/triage; structural RTL changes are more robust than relying only on backend buffering.
