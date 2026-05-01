# Cadence FlashAttention Contest Fit Analysis

Date: 2026-05-01

Basis:

- Contest brief: `doc/Flash Attention/cadence.md`
- Current design/spec: `doc/Flash Attention/spec.md`
- Latest backend notes: `debug/archive/backend/20260501_latest_dc_cleanup_plan.md`
- Current P2 light check: `debug/archive/backend/20260501_p2_light_dc_check_report.md`
- Current performance/precision/coverage report: `debug/archive/backend/20260501_perf_precision_coverage_eval.md`

## Workspace Cleanup

The local workspace was cleaned before this analysis.

Removed generated or cache-only content:

- `sim/cocotb/build`, `sim/cocotb/results`, `sim/cocotb/logs`, `sim/cocotb/waves`, `sim/cocotb/coverage`
- `.pytest_cache`, Python `__pycache__` directories
- `.DS_Store` files
- ignored generated directories: `results`, `work`, `libs`, `ref`
- ignored `app/` content after confirming it contained only generated `out/` files and no non-output source files

After cleanup, no ignored/generated artifacts remain in `git status --short --ignored`; this report is the only new tracked-work candidate from the current pass.

## Executive Assessment

The design is a strong match for the functional and architectural intent of the Cadence FlashAttention contest baseline. It implements a synthesizable `FA_TOP_BASELINE` for `S=256`, `d=64`, Q8.8 data, online softmax, K/V tiling, AXI4-Lite CSR control, and AXI4 master DMA. Current RTL performance and normal precision results are comfortably inside the contest thresholds.

The main gap is not the algorithm or RTL front end. The main gap is Cadence deliverability: the strongest backend evidence today is from Synopsys DC/Formality, while the contest explicitly asks for Cadence EDA scripts and Cadence-generated physical synthesis reports. The current P2 RTL has only been light-checked in DC after the latest datapath cleanup, so it still needs a full Genus/DC-equivalent synthesis and LEC pass.

Recommended readiness score:

| Area | Fit |
|---|---:|
| Algorithm/functionality fit | High |
| RTL synthesizability fit | High, pending full post-P2 compile |
| Performance/precision fit | High for baseline distributions |
| Verification maturity | Medium-high |
| Cadence submission readiness | Medium |
| Overall contest readiness | About 70-75% |

## Requirement Mapping

| Cadence requirement | Current status | Evidence / risk |
|---|---|---|
| FlashAttention-style, no explicit `SxS` score/P matrix | Meets | Uses tiling, online row state, P bypass, and OACC update. No standalone full attention matrix storage. |
| Online softmax | Meets | `FA_ROW_STATE_REAL` maintains row `m/l` and emits probability/rescale. |
| K/V tiling | Meets | 16-row Q/KV tile schedule with causal future-tile skip. |
| Baseline shape `S=256`, `d=64`, batch/head = 1 | Meets | Fixed baseline top is designed around this shape. |
| Q/K/V/O Q8.8 fixed point | Meets | External lanes are packed 16-bit Q8.8; internal row-state/OACC use higher or specialized formats. |
| Dot-product accumulator at least 32-bit | Meets | Current shared GEMM uses 64-bit accumulator width after P2 cleanup. |
| AXI4-Lite CSR | Meets | `FA_CSR` / `csr_array` implement required offsets from `CTRL` through `CYCLES`, plus `RD_BYTES` and `WR_BYTES`. |
| AXI4 master DMA | Meets | Top exposes 128-bit AXI read/write master paths. |
| Causal mode | Meets | CSR `CFG[0]` controls causal/non-causal behavior; causal skip is also a performance feature. |
| Correctness threshold `mean <= 0.03`, `max <= 0.10` | Meets for normal sampled baseline | Worst sampled normal case: mean `0.022474`, max `0.042657`. Extreme/adversarial diagnostics can fail and should be documented as outside nominal input envelope unless numeric formats are widened. |
| Cycle target `<300k` causal | Meets | Current scheduled causal estimate is `85,531` cycles. Previous end-to-end summaries are also well below `300k`. |
| Area target `<2M` NAND2 | Likely meets, needs post-P2 full confirmation | Latest full Synopsys DC run before the newest P2-only light check reports about `1.596M` NAND2. Current P2 RTL only has light DC PASS so far. |
| Fmax/physical synthesis | Partially meets | Synopsys DC achieved 5.0 ns setup clean. Cadence Genus physical synthesis report is still missing. |
| Bandwidth reporting | Partially meets | RTL exposes `RD_BYTES/WR_BYTES`; report needs final captured values. Expected static baseline is about causal `589,824` read bytes and `32,768` write bytes, non-causal about `1,081,344` read bytes and `32,768` write bytes. |
| Verification by UVM/cocotb | Meets, but coverage model needs cleanup | cocotb regression exists and passes; functional coverage is `32/46` or `69.57%` because stale descriptor/stream bins remain after moving to synthesizable AXI top. |
| Cadence scripts/constraints/reports | Gap | Current maintained scripts are under `scripts/synopsys`. Need Cadence `Genus`/possibly `Innovus`/`Tempus`/`Joules` scripts and SDC deliverables. |

## Strengths For The Contest

- The architecture directly targets the problem statement: online softmax, K/V tiling, no full attention matrix, DMA-driven IP interface.
- Current performance has large headroom versus the `300k` cycle target, leaving room for Cadence constraint realism and P&R overhead.
- Current area evidence is inside the `2M` NAND2 target on the latest full Synopsys compile.
- The design has useful differentiators beyond a minimal baseline: shared 4x16 QK/PV GEMM, P buffer bypass, QK/PV block streaming, OACC compression, causal future-tile skip, and Q tile prefetch.
- The verification environment already exercises CSR, AXI, backpressure, reset, numeric compare, precision diagnostics, performance profiling, and code coverage.

## Main Gaps And Risks

1. Cadence toolchain mismatch

   Contest deliverables ask for Cadence EDA scripts, SDC, and Cadence-generated area/timing/power reports. Synopsys DC/Formality results are excellent engineering evidence, but they are not sufficient as final contest artifacts.

2. Post-P2 backend proof is incomplete

   The current P2 RTL passed a light DC analyze/elaborate/link/check run, but full compile and LEC were intentionally not rerun. The next backend run must prove area, timing, DRC, and equivalence on the current baseline.

3. Constraint and IO load completeness

   Current SDC still has placeholder-style IO timing/load modeling. For Cadence Genus, split clock/reset/control from data ports, add output loads, add driving models, and emit an IO coverage audit.

4. Coverage model staleness

   The `69.57%` functional coverage number is artificially depressed by old descriptor/stream bins. Rebase coverage around AXI top-level behavior and internal monitors, then add missing CSR/AXI fault/byte-counter cases.

5. Netlist readability and report noise

   Prior DC reports show unconnected-port and generated-net noise. P2 narrowed GEMM result buses, but a full run is needed to verify reduction. Remaining cleanup should target unused debug ports, explicit unused ties, and sign-cast warnings.

6. Precision envelope

   Normal/random baseline cases pass the contest threshold. Extreme stress cases expose QK saturation and OACC Q4.12 range limitations. The submission should document the accepted input distribution and include the precision diagnostic as a known-boundary study.

7. Power and physical evidence

   The spec document still has power placeholders. Contest submission asks for physical synthesis reports including power; at minimum, generate Genus power from realistic switching estimates, and preferably add Innovus/Tempus/Joules evidence if time permits.

## Recommended Plan

### P0: Make It Cadence-Submission Ready

- Add `scripts/cadence/genus/` flow for read/elaborate/synthesize/report/write.
- Port the current SDC into a Cadence-clean constraint tree.
- Generate Genus reports for timing, area, power, reference hierarchy, constraints, and DRC.
- Add a Cadence run manifest that records RTL file list, top, clock, library, constraints, and tool version.
- Run LEC on current P2 RTL vs synthesized netlist using Cadence Conformal if available; otherwise keep Formality as side evidence and clearly label it.

### P1: Repair Verification And Reporting

- Rebaseline functional coverage to remove obsolete descriptor/stream bins.
- Add direct top-level AXI/CSR tests for alignment error, start-while-busy, exact byte counters, and read/write fault paths.
- Turn `RD_BYTES/WR_BYTES` into a formal bandwidth table in the report.
- Refresh the design spec numbers so they use the latest agreed baseline: P2 current RTL, `85,531` scheduled cycles, and latest post-P2 synthesis when available.

### P1: Backend Hygiene

- Complete IO load/driver modeling and fail the synthesis flow if any non-clock/non-reset data port is unconstrained.
- Add high-precision DRC reports.
- Reduce `SYNOPSYS_UNCONNECTED_`/Cadence equivalent generated-net noise by removing or explicitly tying unused wide debug/result ports.
- Keep clock fanout as a CTS/physical implementation topic, not RTL clock-buffering.

### P2: Contest Differentiation

Best bonus alignment from the current baseline:

1. Padding mask: lowest-cost functional extension and close to current causal mask machinery.
2. Multi-head support: high scoring value; start with serial heads, then consider parallel/interleaved heads.
3. `S=512`: demonstrates the value of FlashAttention tiling, but costs more verification and counter/address work.
4. DMA/task queue: system-level polish without destabilizing numeric datapath.

Floating-point/BF16/FP16 and INT8/FP8 are high-value but should only start after the baseline Cadence flow is closed.

## Go / No-Go View

Go for baseline submission after these are true:

- Current P2 RTL has full Genus synthesis passing timing at target clock.
- Area remains below `2M` NAND2 equivalent by the contest's Genus reporting method.
- Power report is populated, even if first-pass.
- LEC/Formality/Conformal equivalence is clean or all non-equivalent points are documented and justified.
- Functional coverage is rebased and meaningful, preferably above `80%`.
- Final report includes cycles, Fmax, area, power, RD/WR bytes, precision, and known limitations.

Without the Cadence flow, the project is technically strong but submission-risky. With Genus reports and cleaned coverage, it should be a credible and well-aligned baseline entry.
