# Formality Current Status: Verified and Unverified Points

Snapshot time: 2026-04-30 20:02 CST

## Run Scope

- Top: `FA_TOP_BASELINE`
- Reference design: `r:/WORK/FA_TOP_BASELINE`
- Implementation design: `i:/WORK/FA_TOP_BASELINE`
- Formality script: `/home/host/Desktop/flash_atten/synopsys/formality/flow/20260430_1710_currentrtl_rtl_vs_netlist.tcl`
- Remote report root: `/home/host/Desktop/flash_atten/synopsys/formality/reports/FA_TOP_BASELINE`
- Current verify report: `/home/host/Desktop/flash_atten/synopsys/formality/reports/FA_TOP_BASELINE/20260430_1710_currentrtl_rtl_vs_netlist_verify.rpt`
- Local verify snapshot: `/Users/yucheng/Documents/GitHub/flash_atten/debug/20260430_1710_currentrtl_rtl_vs_netlist_verify.rpt`

## Process Status

The Formality job is still running.

| Item | Value |
| --- | --- |
| Wrapper PID | `14907` |
| `fm_shell_exec` PID | `14960` |
| Elapsed time | about `2:50:42` |
| CPU time | about `2:50:29` |
| CPU usage | about `99.8%` |
| RSS | `45416076 KB` |
| VSZ | `45978668 KB` |
| VM memory | `46G` total, about `44G` used |
| Swap | about `28M` used |

The process is CPU-bound and memory-stable. It has not exited, and no final `Verification SUCCEEDED`, `Verification FAILED`, or `Verification INCONCLUSIVE` line has been produced yet.

## Matching Summary

The compare-point matching stage completed cleanly.

| Metric | Count |
| --- | ---: |
| Compare points matched by name | `114859` |
| Compare points matched by signature analysis | `0` |
| Compare points matched by topology | `0` |
| Matched primary inputs / black-box outputs | `196` |
| Unmatched reference / implementation compare points | `0(0)` |
| Unmatched reference / implementation primary inputs / black-box outputs | `0(0)` |
| Unmatched reference / implementation unread points | `8497(0)` |

Interpretation:

- The run is not blocked at compare-point matching.
- There are no unmatched compare points.
- The remaining issue is proof convergence on already-matched compare points.
- The `8497` unread reference points are reported separately from unmatched compare points; they are not listed as compare-point mismatches in the current report.

## Verification Progress

Latest reported verification line:

```text
0F/0A/113740P/1119U (99% Verification completed) 04/30/26 20:00 44901MB/10140sec (33.9 hrs until timeout)
```

Meaning:

| Field | Meaning | Count |
| --- | --- | ---: |
| `F` | failing compare points | `0` |
| `A` | aborted compare points | `0` |
| `P` | proven / passing compare points | `113740` |
| `U` | unverified compare points | `1119` |

Calculated convergence:

- Proven fraction: `113740 / 114859 = 99.026%`
- Unverified fraction: `1119 / 114859 = 0.974%`

Progress timeline:

| Time | Status | Proven | Unverified | Memory | Runtime | Timeout estimate |
| --- | --- | ---: | ---: | ---: | ---: | --- |
| 18:27 | 99% verification completed | `113740` | `1119` | `44901 MB` | `4532 sec` | `35.5 hrs` |
| 18:58 | 99% verification completed | `113740` | `1119` | `44901 MB` | `6390 sec` | `35.0 hrs` |
| 19:28 | 99% verification completed | `113740` | `1119` | `44901 MB` | `8210 sec` | `34.5 hrs` |
| 20:00 | 99% verification completed | `113740` | `1119` | `44901 MB` | `10140 sec` | `33.9 hrs` |

The proof count has not changed since the first 99% line, but the report continues to update, so the process is not dead. It appears to be spending time on the remaining hard proof points.

## Verified Content

Tool-confirmed verified content:

- `113740` matched compare points are currently proven passing.
- `0` compare points are currently reported failing.
- `0` compare points are currently reported aborted.
- All compare points that Formality exposed for matching have a corresponding implementation compare point by name.

Important limitation:

- The current `verify.rpt` reports counts, not the full names of the `113740` proven points.
- The script will generate `report_failing_points`, `report_aborted_points`, and final `report_status` only after `verify` returns. Those final reports are not available yet because the `verify` command is still running.

Work-log evidence of successful supporting proofs:

- Many recovered datapath blocks report `Pre-verification ... SUCCEEDED`.
- Recent successful datapath pre-verification entries are heavily associated with:
  - `FA_ROW_STATE_REAL`
  - `FA_OACC_BUF_REAL`
  - `FA_OACC_UPDATE_REAL`
- These messages indicate supporting datapath blocks were proven during guidance processing, but they are not a full per-compare-point verified list.

Representative successful log patterns:

```text
Pre-verification of r:/WORK/FA_ROW_STATE_REAL_RSOP_6946/DP_OP_6794J3_235_7884 SUCCEEDED.
Pre-verification of r:/WORK/FA_ROW_STATE_REAL/DP_OP_6978J3_153_9207 SUCCEEDED.
Pre-verification of r:/WORK/FA_OACC_BUF_REAL_RSOP_724/DP_OP_668J24_311_7889 SUCCEEDED.
Pre-verification of recovered datapath block SUCCEEDED
```

## Unverified Content

Tool-confirmed unverified content:

- `1119` matched compare points remain unverified.
- They are not currently classified as failing.
- They are not currently classified as aborted.
- Formality has not emitted their exact compare-point names in the current running report.

Current blocking phase:

```text
Status: Matching hierarchy...
...
Status: Verifying...
```

Interpretation:

- Formality completed the main matching stage.
- It then entered hierarchy matching / hard proof handling.
- It returned to `Status: Verifying...`, where it is still running.

Best current module-level localization from logs:

| Area | Evidence | Confidence |
| --- | --- | --- |
| `FA_ROW_STATE_REAL` | Many recent `FA_ROW_STATE_REAL_RSOP_*` and `FA_ROW_STATE_REAL/DP_OP_*` datapath pre-verification entries; one rejected datapath guidance at `u_core/u_row_state/DP_OP_6097_905_3838`. | High |
| `FA_OACC_BUF_REAL` | Many recent `FA_OACC_BUF_REAL_RSOP_* / DP_OP_*` pre-verification entries. | Medium-high |
| `FA_OACC_UPDATE_REAL` | Repeated rejected SVF guidance for `FA_OACC_UPDATE_REAL_RSOP_*` designs/cells. | Medium-high |
| `FA_RD_DMA` | One rejected constraint guidance: `FA_RD_DMA_DP_OP_87J20_123_6872_J20_0`. | Low-medium |

Representative rejected guidance around likely hard areas:

```text
guide_datapath ... could not find reference design 'FA_OACC_UPDATE_REAL_RSOP_2148'.
guide_change_names ... cannot find or apply name change to cell 'RSOP_2148/DP_OP_1468J6_191_9009' in design 'FA_OACC_UPDATE_REAL'.
guide_ungroup ... Cannot find cell 'RSOP_6913' in design 'FA_ROW_STATE_REAL'.
guide_change_names ... cannot find or apply name change to cell 'RSOP_6913/DP_OP_6097_905_3838' in design 'FA_ROW_STATE_REAL'.
guide_datapath ... Cannot find reference cell for instance 'u_core/u_row_state/DP_OP_6097_905_3838' in design 'FA_TOP_BASELINE'.
guide_constraints ... -body 'FA_RD_DMA_DP_OP_87J20_123_6872_J20_0' not applied.
```

This is an inference from work-log context, not a formal `report_unverified_points` list. The exact `1119` compare-point names are not available from the current reports yet.

## SVF and Setup Notes

SVF guidance summary from `match.rpt`:

| Guidance command | Accepted | Rejected | Total |
| --- | ---: | ---: | ---: |
| `change_names` | `1674` | `325` | `1999` |
| `constraints` | `115` | `1` | `116` |
| `datapath` | `376` | `66` | `442` |
| `instance_map` | `161` | `65` | `226` |
| `merge` | `508` | `131` | `639` |
| `replace` | `810` | `66` | `876` |
| `ungroup` | `162` | `65` | `227` |
| Total | `284066` | `720` | `284786` |

Formality also warned:

- No `guide_hier_map` commands were found in the SVF.
- The recommended methodology is to enable `hdlin_enable_hier_map` and use `set_verification_top` in Design Compiler.
- Because memory was tight, Formality reported fork fallback messages:
  - `LWP: fork failed ... Cannot allocate memory. Running in parent.`

These setup issues are consistent with long runtime on the last hard points.

## Current Conclusion

Current status is not a final equivalence sign-off.

What can be said now:

- Matching is clean: `0` unmatched compare points.
- Verification has proven `113740` of `114859` matched compare points.
- Remaining unverified count is `1119`.
- No failing or aborted compare points have been reported so far.
- The unverified/hard proof region is most likely around `FA_ROW_STATE_REAL`, `FA_OACC_BUF_REAL`, and `FA_OACC_UPDATE_REAL`, with one minor `FA_RD_DMA` guidance issue.

Recommended next actions:

1. Let the current run continue if the VM can stay allocated.
2. When `verify` returns, collect:
   - `20260430_1710_currentrtl_rtl_vs_netlist_status.rpt`
   - `20260430_1710_currentrtl_rtl_vs_netlist_failing_points.rpt`
   - `20260430_1710_currentrtl_rtl_vs_netlist_aborted_points.rpt`
3. If exact unverified names are needed before final timeout, rerun a dedicated Formality debug flow with an explicit unverified-points report, preferably with more memory.
4. For the next sign-off run, regenerate SVF with hierarchy-map guidance enabled and consider 64 GB memory or hierarchical Formality.
