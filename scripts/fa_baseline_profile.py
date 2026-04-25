from __future__ import annotations

import argparse
import json
import sys
from datetime import date
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
COCOTB_DIR = REPO_ROOT / "sim" / "cocotb"
if str(COCOTB_DIR) not in sys.path:
    sys.path.insert(0, str(COCOTB_DIR))

import run as cocotb_run  # noqa: E402


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run FA baseline RTL profiling and emit a markdown summary.")
    parser.add_argument("--sim", default="icarus")
    parser.add_argument("--waves", action="store_true", default=False)
    parser.add_argument("--verbose", action="store_true", default=False)
    return parser.parse_args()


def stage_rows(report: dict[str, Any]) -> list[tuple[str, dict[str, Any]]]:
    return sorted(
        report["extrapolated_top_level"].items(),
        key=lambda item: (-int(item[1]["total_cycles"]), item[0]),
    )


def relation_rows(report: dict[str, Any]) -> list[tuple[str, dict[str, Any]]]:
    return sorted(
        report["extrapolated_row_update_breakdown"].items(),
        key=lambda item: (-int(item[1]["total_cycles"]), item[0]),
    )


def substage_rows(report: dict[str, Any], key: str) -> list[tuple[str, dict[str, Any]]]:
    return sorted(
        report[key].items(),
        key=lambda item: (-int(item[1]["total_cycles"]), item[0]),
    )


def render_report(report: dict[str, Any]) -> str:
    lines: list[str] = []
    lines.append("# FA Baseline RTL Profiling")
    lines.append("")
    lines.append(f"- Date: `{date.today().isoformat()}`")
    lines.append("- Top: `FA_TOP_BASELINE_SIM`")
    lines.append("- Method: sample per-stage RTL latency on early tiles, then extrapolate with deterministic scheduler invocation counts")
    lines.append("- Row-update correction: override scheduler sampling with direct `FA_ROW_STATE_REAL` microbench for `masked` vs `valid` tiles")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append(f"- Estimated full-run cycles: `{report['extrapolated_total_cycles']}`")
    lines.append(f"- Row-state sub-total inside row-update: `{report['extrapolated_row_state_total_cycles']}`")
    lines.append(f"- P-load sub-total inside row-update: `{report['extrapolated_p_load_total_cycles']}`")
    lines.append("")
    lines.append("## Top-Level Stages")
    lines.append("")
    lines.append("| Stage | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |")
    lines.append("| --- | ---: | ---: | ---: | ---: | --- |")
    for name, stage in stage_rows(report):
        per_invocation = stage["per_invocation_cycles"]
        per_text = "-" if per_invocation is None else str(per_invocation)
        uniques = ",".join(str(value) for value in stage["observed_unique_cycles"]) if stage["observed_unique_cycles"] else "-"
        lines.append(
            f"| `{name}` | {per_text} | {stage['count']} | {stage['total_cycles']} | {stage['share_pct']:.2f}% | `{uniques}` |"
        )
    lines.append("")

    lines.append("## Row-Update Breakdown")
    lines.append("")
    lines.append("| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |")
    lines.append("| --- | ---: | ---: | ---: | ---: | --- |")
    for relation, stage in relation_rows(report):
        uniques = ",".join(str(value) for value in stage["observed_unique_cycles"])
        lines.append(
            f"| `{relation}` | {stage['per_invocation_cycles']} | {stage['count']} | {stage['total_cycles']} | {stage['share_pct']:.2f}% | `{uniques}` |"
        )
    lines.append("")

    lines.append("## Row-State Substage")
    lines.append("")
    lines.append("| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |")
    lines.append("| --- | ---: | ---: | ---: | ---: | --- |")
    for relation, stage in substage_rows(report, "extrapolated_row_state_breakdown"):
        uniques = ",".join(str(value) for value in stage["observed_unique_cycles"])
        lines.append(
            f"| `{relation}` | {stage['per_invocation_cycles']} | {stage['count']} | {stage['total_cycles']} | {stage['share_pct']:.2f}% | `{uniques}` |"
        )
    lines.append("")

    lines.append("## P-Load Substage")
    lines.append("")
    lines.append("| Class | Per invocation cycles | Count | Total cycles | Share | Sampled uniques |")
    lines.append("| --- | ---: | ---: | ---: | ---: | --- |")
    for relation, stage in substage_rows(report, "extrapolated_p_load_breakdown"):
        uniques = ",".join(str(value) for value in stage["observed_unique_cycles"])
        lines.append(
            f"| `{relation}` | {stage['per_invocation_cycles']} | {stage['count']} | {stage['total_cycles']} | {stage['share_pct']:.2f}% | `{uniques}` |"
        )
    lines.append("")

    lines.append("## Sampled Stage Latency")
    lines.append("")
    lines.append("| Stage | Selected cycles | Sample count | Observed uniques |")
    lines.append("| --- | ---: | ---: | --- |")
    for name, stage in sorted(report["sampled_stages"].items()):
        uniques = ",".join(str(value) for value in stage["observed_unique_cycles"])
        lines.append(
            f"| `{name}` | {stage['selected_cycles']} | {stage['observed_count']} | `{uniques}` |"
        )
    lines.append("")

    return "\n".join(lines) + "\n"


def run_profile(sim_name: str, waves: bool, verbose: bool, output_dir: Path) -> dict[str, Any]:
    json_path = output_dir / f"{date.today().strftime('%Y%m%d')}_fa_baseline_profile_causal.json"
    config = cocotb_run.RunConfig(
        name="fa_baseline_profile_causal",
        build_name="fa_baseline_profile_causal",
        x_dim=16,
        y_dim=16,
        test_modules=["tests.test_fa_baseline_perf_profile"],
        hdl_toplevel="FA_TOP_BASELINE_SIM",
        seeds=[cocotb_run.DEFAULT_SEED],
        extra_env={
            "FA_PROFILE_JSON": str(json_path),
        },
        rtl_params={},
    )
    cocotb_run.ensure_dirs()
    cocotb_run.run_case(sim_name, "fa_baseline_profile", waves, verbose, config, cocotb_run.APP_TARGET_PT_DMA_TOP)
    return json.loads(json_path.read_text(encoding="utf-8"))


def run_rowstate_profile(sim_name: str, waves: bool, verbose: bool, output_dir: Path) -> dict[str, Any]:
    json_path = output_dir / f"{date.today().strftime('%Y%m%d')}_fa_baseline_rowstate_profile.json"
    config = cocotb_run.RunConfig(
        name="fa_baseline_rowstate_profile",
        build_name="fa_baseline_rowstate_profile",
        x_dim=16,
        y_dim=16,
        test_modules=["tests.test_fa_baseline_perf_rowstate"],
        hdl_toplevel="FA_TOP_BASELINE_SIM",
        seeds=[cocotb_run.DEFAULT_SEED],
        extra_env={
            "FA_ROWSTATE_PROFILE_JSON": str(json_path),
        },
        rtl_params={},
    )
    cocotb_run.ensure_dirs()
    cocotb_run.run_case(sim_name, "fa_baseline_profile", waves, verbose, config, cocotb_run.APP_TARGET_PT_DMA_TOP)
    return json.loads(json_path.read_text(encoding="utf-8"))


def apply_rowstate_override(report: dict[str, Any], rowstate: dict[str, Any]) -> dict[str, Any]:
    masked_row_state = int(rowstate["masked_row_state_cycles"])
    masked_row_update = int(rowstate["masked_row_update_cycles"])
    valid_row_state = int(rowstate["valid_row_state_cycles"])
    valid_row_update = int(rowstate["valid_row_update_cycles"])

    report["rowstate_microbench"] = rowstate

    for relation in ("diagonal", "history"):
        report["sampled_row_state"][relation]["selected_cycles"] = valid_row_state
        report["sampled_row_state"][relation]["observed_unique_cycles"] = [valid_row_state]
        report["sampled_row_update"][relation]["selected_cycles"] = valid_row_update
        report["sampled_row_update"][relation]["observed_unique_cycles"] = [valid_row_update]

    report["sampled_row_state"]["future_masked"]["selected_cycles"] = masked_row_state
    report["sampled_row_state"]["future_masked"]["observed_unique_cycles"] = [masked_row_state]
    report["sampled_row_update"]["future_masked"]["selected_cycles"] = masked_row_update
    report["sampled_row_update"]["future_masked"]["observed_unique_cycles"] = [masked_row_update]

    row_relation_counts = report["row_relation_counts"]
    row_update_total = 0
    row_state_total = 0
    p_load_total = 0
    for relation, count in row_relation_counts.items():
        row_update_cycles = int(report["sampled_row_update"][relation]["selected_cycles"])
        row_state_cycles = int(report["sampled_row_state"][relation]["selected_cycles"])
        p_load_cycles = int(report["sampled_p_load"][relation]["selected_cycles"])

        report["extrapolated_row_update_breakdown"][relation]["per_invocation_cycles"] = row_update_cycles
        report["extrapolated_row_update_breakdown"][relation]["observed_unique_cycles"] = [row_update_cycles]
        report["extrapolated_row_update_breakdown"][relation]["total_cycles"] = row_update_cycles * count

        report["extrapolated_row_state_breakdown"][relation]["per_invocation_cycles"] = row_state_cycles
        report["extrapolated_row_state_breakdown"][relation]["observed_unique_cycles"] = [row_state_cycles]
        report["extrapolated_row_state_breakdown"][relation]["total_cycles"] = row_state_cycles * count

        report["extrapolated_p_load_breakdown"][relation]["total_cycles"] = p_load_cycles * count

        row_update_total += row_update_cycles * count
        row_state_total += row_state_cycles * count
        p_load_total += p_load_cycles * count

    report["extrapolated_top_level"]["row_update"]["total_cycles"] = row_update_total
    report["extrapolated_row_state_total_cycles"] = row_state_total
    report["extrapolated_p_load_total_cycles"] = p_load_total

    total_cycles = sum(entry["total_cycles"] for entry in report["extrapolated_top_level"].values())
    report["extrapolated_total_cycles"] = total_cycles
    for entry in report["extrapolated_top_level"].values():
        entry["share_pct"] = (entry["total_cycles"] * 100.0 / total_cycles) if total_cycles else 0.0
    for key in (
        "extrapolated_row_update_breakdown",
        "extrapolated_row_state_breakdown",
        "extrapolated_p_load_breakdown",
    ):
        for entry in report[key].values():
            entry["share_pct"] = (entry["total_cycles"] * 100.0 / total_cycles) if total_cycles else 0.0
    return report


def main() -> None:
    args = parse_args()
    output_dir = REPO_ROOT / "debug"
    output_dir.mkdir(parents=True, exist_ok=True)

    report = run_profile(args.sim, args.waves, args.verbose, output_dir)
    rowstate = run_rowstate_profile(args.sim, args.waves, args.verbose, output_dir)
    report = apply_rowstate_override(report, rowstate)
    json_path = output_dir / f"{date.today().strftime('%Y%m%d')}_fa_baseline_profile_causal.json"
    json_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    md_path = output_dir / f"{date.today().strftime('%Y%m%d')}_fa_baseline_profile_summary.md"
    md_path.write_text(render_report(report), encoding="utf-8")

    print(f"wrote {md_path}")
    print(f"estimated_cycles={report['extrapolated_total_cycles']}")


if __name__ == "__main__":
    main()
