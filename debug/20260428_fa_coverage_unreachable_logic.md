# FA Coverage Unreachable / Dead Logic Table

Generated: 2026-04-28

Source coverage reports:
- `sim/cocotb/coverage/code/lcov/fa_shared_gemm.info`
- `sim/cocotb/coverage/code/lcov/fa_rowstate_profile.info`
- `sim/cocotb/coverage/code/lcov/fa_oacc_update.info`

Context:
- Reachable missing-test coverage points were addressed with focused cocotb tests.
- DL-001 was removed from RTL because it was true dead logic.
- Remaining items below are residual uncovered lines judged to be unreachable, parameter-disabled, or defensive-only under the current FA simulation targets.
- Post-removal OACC line coverage: `228/237 = 96.20%` after deleting `ST_ROW_GAP`.

| ID | RTL location | Uncovered item | Classification | Why it is unreachable / dead in current target | Action / status |
| --- | --- | --- | --- | --- | --- |
| DL-001 | `rtl/fa_oacc_update_real.v` | `ST_ROW_GAP` localparam and case branches | Dead state | No transition assigned `state_n = ST_ROW_GAP`; normal state flow goes `ST_ROW_WRITE -> ST_ROW_REQ/ST_DONE`. | Removed from RTL on 2026-04-28. |
| DL-002 | `rtl/fa_oacc_update_real.v:11`, `rtl/fa_oacc_update_real.v:13`, `rtl/fa_oacc_update_real.v:44`, `rtl/fa_oacc_update_real.v:286` | `partial_row_rd_*` path and `partial_row_rd_data` selection | Parameter-disabled path | `FA_OACC_UPDATE_SIM` instantiates `FA_OACC_UPDATE_REAL` with default `USE_PARTIAL_ROW_INPUT = 0`, ties `partial_row_rd_valid` to `1'b0`, and does not expose this alternate partial-row input mode. | Keep as waiver unless `USE_PARTIAL_ROW_INPUT=1` becomes an intended target. |
| DL-003 | `rtl/fa_qk_pv_shared_core_sim.v:51`, `rtl/fa_qk_pv_shared_core_sim.v:53` | Unused QK/PV result row readback wires | Wrapper-unreachable path | The shared-GEMM sim wrapper drives `qk_result_row_rd_en` and `pv_result_row_rd_en` as `1'b0` and exposes flat tile outputs instead, so row-read valid outputs cannot toggle through this target. | Keep as wrapper waiver. |
| DL-004 | `rtl/fa_qk_pv_shared_core_sim.v:55`, `rtl/fa_oacc_update_sim.v:39`, `rtl/fa_row_state_profile_sim.v:38`, `rtl/fa_p_bypass_real.v:28` | `unused_params_w = (PARAM == 0) ...` guards | Parameter guard unreachable | Current runner builds legal nonzero parameters. These wires exist only to consume otherwise-unused parameters and keep lint clean. | Keep as lint-helper waiver. |
| DL-005 | `rtl/fa_row_state_real.v:154` | `q16_clamp_nonpos_neg8(value > Q16_ZERO)` branch | Mathematically unreachable | Callers pass deltas of the form `old_m - m_new` or `score - m_new`; `m_new` is the max, so the delta should be non-positive. | Keep as defensive math waiver. |
| DL-006 | `rtl/fa_row_state_real.v:176` | `q16_delta_to_exp_idx` `shifted > 256` branch | Mathematically unreachable | `q16_clamp_nonpos_neg8` clamps delta to `[-8, 0]`, which bounds the converted LUT index to `0..256`. | Keep as defensive saturation waiver. |
| DL-007 | `rtl/fa_row_state_real.v:188` | `fa_exp_lut_q16_16` default case | Mathematically unreachable | The index generator is bounded to `0..256`; the included LUT covers those legal indices. | Keep as defensive default waiver. |
| DL-008 | `rtl/fa_row_state_real.v:96`, `rtl/fa_row_state_real.v:120`, `rtl/fa_row_state_real.v:141` | Positive/negative saturation branches in row-state helper functions | Algorithm-constrained unreachable path | In the row-state probability path, beta, alpha, reciprocal, and normalized probability values are bounded by construction; normal FA inputs cannot drive these helpers to 32-bit or Q8.8 saturation limits. | Keep as defensive arithmetic waiver. |
| DL-009 | `rtl/fa_cores_real.v:544`, `rtl/gemu_v3.v:92`, `rtl/gemu_v3.v:136`, `rtl/fa_oacc_update_real.v`, `rtl/fa_row_state_real.v:252`, `rtl/fa_row_state_real.v:490` | FSM `default` branches | Illegal-state defensive path | Normal reset and transition logic cannot enter these encodings. Hitting them would require fault injection or forcing internal state. | Keep as illegal-state defensive waiver. |
| DL-010 | `rtl/gemm_v3.v:164` | `OUTPUT_BY_ROW == 0` column-output branch | Parameter-disabled branch in current shared-GEMM instance | Current `FA_QK_PV_SHARED_CORE_REAL` instantiates `GEMM_V3` with `.OUTPUT_BY_ROW(1)`. The column-output path is generic GEMM code, not active for this FA target. | Keep as parameter waiver for FA shared-GEMM coverage. |
| DL-011 | `rtl/fa_sram_hard.v:154`, `rtl/fa_sram_hard.v:168` | Bit-granular write path / readback path in shared-GEMM coverage target | Parameter/wrapper coverage artifact | Shared-GEMM uses masked row buffers with configurations that do not exercise every generic SRAM mode and row-read path through the selected wrapper. Other FA top-level coverage may exercise different SRAM modes. | Keep as per-suite waiver; cover with SRAM unit tests only if generic SRAM coverage is required. |
