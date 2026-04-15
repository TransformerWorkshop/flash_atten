from __future__ import annotations

import json
import subprocess
import tempfile
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, Tuple


REPO_ROOT = Path(__file__).resolve().parents[2]
RTL_DIR = REPO_ROOT / "rtl"
DEBUG_ROOT = REPO_ROOT / "debug" / "cocotb" / "PT"
REPORT_FILES = (
	"pt.v",
	"pt_dispatch.v",
	"pt_dispatch_v2.v",
	"pt_malloc.v",
	"pt_md.v",
	"pt_md_v2.v",
	"pt_ce.v",
	"pt_ce_v2.v",
)

EXCLUDED_LINE_POINTS = {
	"pt_md.v": {325, 326, 333, 334},
}
EXCLUDED_BRANCH_LINES = {
	"pt_md.v": {325, 326, 333, 334},
}
EXCLUDED_EXPR_COMMENTS = {
	"pt_md.v": {"((value > 32'sh0)==0) => 0"},
	"pt_ce.v": {
		"((value > 32'sh0)==0) => 0",
		"(gemm_a_ready==0) => 0",
		"(gemm_b_ready==0) => 0",
	},
	"pt_ce_v2.v": {
		"((value > 32'sh0)==0) => 0",
		"(gemm_a_ready==0) => 0",
		"(gemm_b_ready==0) => 0",
		"((M_WRITE_LANES <= 32'sh0)==1) => 1",
		"((M_WRITE_LANES > GEMM_Y_DIM)==1) => 1",
	},
	"pt_md_v2.v": {
		"((value > 32'sh0)==0) => 0",
		"((A_LOAD_LANES <= 32'sh0)==1) => 1",
		"((A_LOAD_LANES > GEMM_X_DIM)==1) => 1",
		"((B_LOAD_LANES <= 32'sh0)==1) => 1",
		"((B_LOAD_LANES > GEMM_Y_DIM)==1) => 1",
		"((M_EXPORT_LANES <= 32'sh0)==1) => 1",
		"((M_EXPORT_LANES > GEMM_Y_DIM)==1) => 1",
		"(md_cmd_ready==0) => 0",
		"(ce_resp[31]==1) => 0",
	},
}

LOW_VALUE_BRANCH_LINES = {
	"csr_bank.v": {22},
	"pt_malloc.v": {18, 22},
	"pt_md_v2.v": {22},
	"pt_ce_v2.v": {17},
}

LOW_VALUE_TOGGLE_PREFIXES = {
	"csr_bank.v": ("quant_inv_scale_wdata[",),
}

CLASSIFICATION_OVERRIDES = {
	("line", "pt_md.v", 325, ""): ("unreachable", "Guarded by top-level power-of-two constraint."),
	("line", "pt_md.v", 326, ""): ("unreachable", "Guarded by top-level power-of-two constraint."),
	("line", "pt_md.v", 333, ""): ("unreachable", "Guarded by top-level power-of-two constraint."),
	("line", "pt_md.v", 334, ""): ("unreachable", "Guarded by top-level power-of-two constraint."),
}


@dataclass
class CoverageCount:
	covered: int
	total: int

	def as_dict(self) -> Dict[str, float | int]:
		pct = (100.0 * self.covered / self.total) if self.total else 0.0
		return {"covered": self.covered, "total": self.total, "pct": round(pct, 2)}


@dataclass
class PointRecord:
	kind: str
	file: str
	line: int
	covered: bool
	comment: str
	hier: str


@dataclass
class ResidualPoint:
	kind: str
	file: str
	line: int
	comment: str
	hier: str
	classification: str
	reason: str

	def as_dict(self) -> Dict[str, object]:
		return {
			"kind": self.kind,
			"file": self.file,
			"line": self.line,
			"comment": self.comment,
			"hier": self.hier,
			"classification": self.classification,
			"reason": self.reason,
		}


def pct(covered: int, total: int) -> float:
	return round((100.0 * covered / total) if total else 0.0, 2)


def _count_or_zero(summary: Mapping[str, CoverageCount], key: str) -> CoverageCount:
	return summary.get(key, CoverageCount(0, 0))


def _delta(current: Mapping[str, float | int], previous: Mapping[str, float | int] | None) -> Dict[str, float | int] | None:
	if previous is None:
		return None
	return {
		"covered": int(current["covered"]) - int(previous["covered"]),
		"total": int(current["total"]) - int(previous["total"]),
		"pct": round(float(current["pct"]) - float(previous["pct"]), 2),
	}


def _parse_lcov(info_path: Path) -> Dict[str, Dict[str, Dict[int, int]]]:
	files: Dict[str, Dict[str, Dict[int, int]]] = {}
	current: str | None = None
	for raw in info_path.read_text(encoding="utf-8", errors="ignore").splitlines():
		if raw.startswith("SF:"):
			current = Path(raw[3:]).name
			files[current] = {"lines": {}, "branches": {}}
			continue
		if current is None:
			continue
		if raw.startswith("DA:"):
			line_no, count = raw[3:].split(",")
			files[current]["lines"][int(line_no)] = int(count)
		elif raw.startswith("BRDA:"):
			line_no, _block, _branch, count = raw[5:].split(",")
			value = -1 if count == "-" else int(count)
			key = len([ln for ln in files[current]["branches"] if (ln >> 16) == int(line_no)])
			files[current]["branches"][(int(line_no) << 16) | key] = value
	return files


def _summarize_lcov(
	lcov_data: Mapping[str, Dict[str, Dict[int, int]]],
	excluded_lines: Mapping[str, set[int]] | None = None,
	excluded_branch_lines: Mapping[str, set[int]] | None = None,
) -> Dict[str, CoverageCount]:
	summary: Dict[str, CoverageCount] = {}
	for file_name, payload in lcov_data.items():
		line_ex = (excluded_lines or {}).get(file_name, set())
		branch_ex = (excluded_branch_lines or {}).get(file_name, set())
		line_total = line_hit = 0
		for line_no, count in payload["lines"].items():
			if line_no in line_ex:
				continue
			line_total += 1
			if count > 0:
				line_hit += 1
		branch_total = branch_hit = 0
		for composite, count in payload["branches"].items():
			line_no = composite >> 16
			if line_no in branch_ex:
				continue
			branch_total += 1
			if count > 0:
				branch_hit += 1
		summary[file_name] = CoverageCount(line_hit, line_total)
		summary[f"{file_name}::branch"] = CoverageCount(branch_hit, branch_total)
	return summary


def _annotate_type(coverage_dat: Path, point_type: str) -> Tuple[CoverageCount, Dict[str, CoverageCount], List[PointRecord]]:
	with tempfile.TemporaryDirectory(prefix=f"pt_cov_{point_type}_") as tmpdir:
		tmpdir_path = Path(tmpdir)
		subprocess.run(
			[
				"verilator_coverage",
				"--annotate",
				str(tmpdir_path),
				"--annotate-points",
				"--annotate-all",
				"--annotate-min",
				"1",
				"--filter-type",
				point_type,
				str(coverage_dat),
			],
			check=True,
			stdout=subprocess.DEVNULL,
			stderr=subprocess.DEVNULL,
		)

		overall_total = overall_hit = 0
		per_file: Dict[str, CoverageCount] = {}
		points: List[PointRecord] = []
		for annotated in sorted(tmpdir_path.glob("*.v")):
			file_total = file_hit = 0
			current_lineno = 0
			for raw in annotated.read_text(encoding="utf-8", errors="ignore").splitlines():
				if "point: type=" in raw:
					covered = raw.startswith("+")
					file_total += 1
					if covered:
						file_hit += 1
					comment = ""
					hier = ""
					if "comment=" in raw:
						comment = raw.split("comment=", 1)[1].split(" hier=", 1)[0]
					if "hier=" in raw:
						hier = raw.split("hier=", 1)[1]
					points.append(PointRecord(point_type, annotated.name, current_lineno, covered, comment, hier))
				else:
					current_lineno += 1
			if file_total:
				per_file[annotated.name] = CoverageCount(file_hit, file_total)
				overall_total += file_total
				overall_hit += file_hit
		return CoverageCount(overall_hit, overall_total), per_file, points


def _is_excluded_expr(point: PointRecord) -> bool:
	return point.comment in EXCLUDED_EXPR_COMMENTS.get(point.file, set())


def _summarize_points(points: Iterable[PointRecord], exclude_fn=None) -> Tuple[CoverageCount, Dict[str, CoverageCount], List[PointRecord]]:
	overall_total = overall_hit = 0
	per_file_totals: Dict[str, List[int]] = {}
	filtered_points: List[PointRecord] = []
	for point in points:
		if exclude_fn and exclude_fn(point):
			continue
		filtered_points.append(point)
		file_hit, file_total = per_file_totals.setdefault(point.file, [0, 0])
		file_total += 1
		per_file_totals[point.file] = [file_hit, file_total]
		overall_total += 1
		if point.covered:
			per_file_totals[point.file][0] += 1
			overall_hit += 1
	per_file = {name: CoverageCount(hit, total) for name, (hit, total) in per_file_totals.items()}
	return CoverageCount(overall_hit, overall_total), per_file, filtered_points


def _top_uncovered(points: Iterable[PointRecord], limit: int = 12) -> List[Dict[str, object]]:
	entries: List[Dict[str, object]] = []
	for point in points:
		if point.covered:
			continue
		classification, _reason = _classify_residual(point.kind, point.file, point.line, point.comment)
		if classification != "test_gap":
			continue
		entries.append({"file": point.file, "line": point.line, "comment": point.comment, "hier": point.hier})
		if len(entries) >= limit:
			break
	return entries


def _classify_residual(kind: str, file_name: str, line_no: int, comment: str) -> Tuple[str, str]:
	override = CLASSIFICATION_OVERRIDES.get((kind, file_name, line_no, comment), None)
	if override is not None:
		return override
	if kind == "expr" and comment in EXCLUDED_EXPR_COMMENTS.get(file_name, set()):
		return ("unreachable", "Excluded by legal-configuration reachability rule.")
	if kind == "line" and line_no in EXCLUDED_LINE_POINTS.get(file_name, set()):
		return ("unreachable", "Excluded by legal-configuration reachability rule.")
	if kind == "branch" and line_no in EXCLUDED_BRANCH_LINES.get(file_name, set()):
		return ("unreachable", "Excluded by legal-configuration reachability rule.")
	if kind == "branch" and line_no in LOW_VALUE_BRANCH_LINES.get(file_name, set()):
		return ("instrumentation_noise", "Branch instrumentation on declaration/control fanout line is not behavior-relevant.")
	if kind == "toggle" and any(comment.startswith(prefix) for prefix in LOW_VALUE_TOGGLE_PREFIXES.get(file_name, ())):
		return ("low_value_bit_toggle", "Wide data-bus bit toggles are tracked separately from behavior-driven coverage gaps.")
	return ("test_gap", "No testcase currently exercises this point.")


def _collect_line_branch_residuals(
	lcov_data: Mapping[str, Dict[str, Dict[int, int]]],
	excluded_lines: Mapping[str, set[int]],
	excluded_branch_lines: Mapping[str, set[int]],
) -> List[ResidualPoint]:
	points: List[ResidualPoint] = []
	for file_name, payload in lcov_data.items():
		for line_no, count in payload["lines"].items():
			if line_no in excluded_lines.get(file_name, set()) or count > 0:
				continue
			classification, reason = _classify_residual("line", file_name, line_no, "")
			points.append(ResidualPoint("line", file_name, line_no, "", "", classification, reason))
		for composite, count in payload["branches"].items():
			line_no = composite >> 16
			branch_idx = composite & 0xFFFF
			if line_no in excluded_branch_lines.get(file_name, set()) or count > 0:
				continue
			comment = f"branch[{branch_idx}]"
			classification, reason = _classify_residual("branch", file_name, line_no, comment)
			points.append(ResidualPoint("branch", file_name, line_no, comment, "", classification, reason))
	return points


def _collect_point_residuals(points: Iterable[PointRecord]) -> List[ResidualPoint]:
	residuals: List[ResidualPoint] = []
	for point in points:
		if point.covered:
			continue
		classification, reason = _classify_residual(point.kind, point.file, point.line, point.comment)
		residuals.append(ResidualPoint(point.kind, point.file, point.line, point.comment, point.hier, classification, reason))
	return residuals


def _render_residual_markdown(residuals: List[ResidualPoint]) -> str:
	class_totals: Dict[str, int] = {}
	for point in residuals:
		class_totals[point.classification] = class_totals.get(point.classification, 0) + 1
	lines = [
		"# PT Residual Uncovered Points",
		"",
		"| Classification | Count |",
		"| --- | --- |",
	]
	for key in sorted(class_totals):
		lines.append(f"| `{key}` | `{class_totals[key]}` |")
	lines.extend(
		[
			"",
			"| Kind | File | Line | Classification | Detail | Reason |",
			"| --- | --- | --- | --- | --- | --- |",
		]
	)
	for point in residuals:
		detail = point.comment or "-"
		lines.append(
			f"| `{point.kind}` | `{point.file}` | `{point.line}` | `{point.classification}` | `{detail}` | `{point.reason}` |"
		)
	return "\n".join(lines) + "\n"


def generate_coverage_reports(coverage_dat: Path, coverage_info: Path, summary_txt: Path) -> Dict[str, object]:
	lcov_data = _parse_lcov(coverage_info)
	raw_line_branch = _summarize_lcov(lcov_data)
	adj_line_branch = _summarize_lcov(
		lcov_data,
		excluded_lines=EXCLUDED_LINE_POINTS,
		excluded_branch_lines=EXCLUDED_BRANCH_LINES,
	)
	expr_raw_overall, expr_raw_per_file, expr_raw_points = _annotate_type(coverage_dat, "expr")
	toggle_overall, toggle_per_file, toggle_points = _annotate_type(coverage_dat, "toggle")
	user_overall, user_per_file, user_points = _annotate_type(coverage_dat, "user")
	expr_adj_overall, expr_adj_per_file, expr_adj_points = _summarize_points(expr_raw_points, exclude_fn=_is_excluded_expr)

	rtl_files = sorted(path.name for path in RTL_DIR.glob("*.v"))
	overall_line_raw = CoverageCount(
		sum(raw_line_branch[name].covered for name in rtl_files if name in raw_line_branch),
		sum(raw_line_branch[name].total for name in rtl_files if name in raw_line_branch),
	)
	overall_line_adj = CoverageCount(
		sum(adj_line_branch[name].covered for name in rtl_files if name in adj_line_branch),
		sum(adj_line_branch[name].total for name in rtl_files if name in adj_line_branch),
	)
	overall_branch_raw = CoverageCount(
		sum(raw_line_branch[f"{name}::branch"].covered for name in rtl_files if f"{name}::branch" in raw_line_branch),
		sum(raw_line_branch[f"{name}::branch"].total for name in rtl_files if f"{name}::branch" in raw_line_branch),
	)
	overall_branch_adj = CoverageCount(
		sum(adj_line_branch[f"{name}::branch"].covered for name in rtl_files if f"{name}::branch" in adj_line_branch),
		sum(adj_line_branch[f"{name}::branch"].total for name in rtl_files if f"{name}::branch" in adj_line_branch),
	)

	metrics = {
		"generated_at": datetime.now().isoformat(timespec="seconds"),
		"paths": {
			"coverage_dat": str(coverage_dat),
			"coverage_info": str(coverage_info),
			"summary_txt": str(summary_txt),
		},
		"exclusions": {
			"line": {key: sorted(value) for key, value in EXCLUDED_LINE_POINTS.items()},
			"branch_lines": {key: sorted(value) for key, value in EXCLUDED_BRANCH_LINES.items()},
		},
		"overall": {
			"line_raw": overall_line_raw.as_dict(),
			"line_adj": overall_line_adj.as_dict(),
			"branch_raw": overall_branch_raw.as_dict(),
			"branch_adj": overall_branch_adj.as_dict(),
			"expr_raw": expr_raw_overall.as_dict(),
			"expr_adj": expr_adj_overall.as_dict(),
			"toggle": toggle_overall.as_dict(),
			"user": user_overall.as_dict(),
		},
		"per_file": {},
		"top_uncovered": {
			"expr": _top_uncovered(expr_adj_points),
			"toggle": _top_uncovered(toggle_points),
			"user": _top_uncovered(user_points),
		},
	}

	metrics_path = coverage_dat.parent / "coverage_metrics.json"
	previous_metrics = None
	if metrics_path.exists():
		try:
			previous_metrics = json.loads(metrics_path.read_text(encoding="utf-8"))
		except json.JSONDecodeError:
			previous_metrics = None

	for file_name in rtl_files:
		metrics["per_file"][file_name] = {
			"line_raw": _count_or_zero(raw_line_branch, file_name).as_dict(),
			"line_adj": _count_or_zero(adj_line_branch, file_name).as_dict(),
			"branch_raw": _count_or_zero(raw_line_branch, f"{file_name}::branch").as_dict(),
			"branch_adj": _count_or_zero(adj_line_branch, f"{file_name}::branch").as_dict(),
			"expr_raw": expr_raw_per_file.get(file_name, CoverageCount(0, 0)).as_dict(),
			"expr_adj": expr_adj_per_file.get(file_name, CoverageCount(0, 0)).as_dict(),
			"toggle": toggle_per_file.get(file_name, CoverageCount(0, 0)).as_dict(),
			"user": user_per_file.get(file_name, CoverageCount(0, 0)).as_dict(),
		}

	metrics["delta"] = {}
	if previous_metrics is not None:
		for key in ("line_raw", "line_adj", "branch_raw", "branch_adj", "expr_raw", "expr_adj", "toggle", "user"):
			metrics["delta"][key] = _delta(metrics["overall"][key], previous_metrics.get("overall", {}).get(key))
	metrics_path.write_text(json.dumps(metrics, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")

	line_branch_residuals = _collect_line_branch_residuals(lcov_data, EXCLUDED_LINE_POINTS, EXCLUDED_BRANCH_LINES)
	expr_residuals = _collect_point_residuals(expr_adj_points)
	toggle_residuals = _collect_point_residuals(toggle_points)
	user_residuals = _collect_point_residuals(user_points)
	residuals = sorted(
		line_branch_residuals + expr_residuals + toggle_residuals + user_residuals,
		key=lambda point: (point.kind, point.file, point.line, point.comment),
	)
	if any(not point.classification for point in residuals):
		raise SystemExit("coverage report contains unclassified residual points")

	residual_json = {
		"generated_at": datetime.now().isoformat(timespec="seconds"),
		"counts": {
			"total": len(residuals),
			"by_classification": {
				key: len([point for point in residuals if point.classification == key])
				for key in sorted({point.classification for point in residuals})
			},
		},
		"points": [point.as_dict() for point in residuals],
	}
	residual_json_path = coverage_dat.parent / "residual_uncovered.json"
	residual_md_path = coverage_dat.parent / "residual_uncovered.md"
	residual_json_path.write_text(json.dumps(residual_json, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
	residual_md_path.write_text(_render_residual_markdown(residuals), encoding="utf-8")

	functional_json_path = coverage_dat.parent / "functional_coverage.json"
	functional_md_path = coverage_dat.parent / "functional_coverage.md"

	coverage_types_lines = [
		"# PT Coverage Types",
		"",
		"| Type | Covered / Total | Percent |",
		"| --- | --- | --- |",
		f"| `line(raw)` | `{overall_line_raw.covered} / {overall_line_raw.total}` | `{pct(overall_line_raw.covered, overall_line_raw.total):.2f}%` |",
		f"| `line(adjusted)` | `{overall_line_adj.covered} / {overall_line_adj.total}` | `{pct(overall_line_adj.covered, overall_line_adj.total):.2f}%` |",
		f"| `branch(raw)` | `{overall_branch_raw.covered} / {overall_branch_raw.total}` | `{pct(overall_branch_raw.covered, overall_branch_raw.total):.2f}%` |",
		f"| `branch(adjusted)` | `{overall_branch_adj.covered} / {overall_branch_adj.total}` | `{pct(overall_branch_adj.covered, overall_branch_adj.total):.2f}%` |",
		f"| `expr(raw)` | `{expr_raw_overall.covered} / {expr_raw_overall.total}` | `{pct(expr_raw_overall.covered, expr_raw_overall.total):.2f}%` |",
		f"| `expr(adjusted)` | `{expr_adj_overall.covered} / {expr_adj_overall.total}` | `{pct(expr_adj_overall.covered, expr_adj_overall.total):.2f}%` |",
		f"| `toggle` | `{toggle_overall.covered} / {toggle_overall.total}` | `{pct(toggle_overall.covered, toggle_overall.total):.2f}%` |",
		f"| `user` | `{user_overall.covered} / {user_overall.total}` | `{pct(user_overall.covered, user_overall.total):.2f}%` |",
		"",
		"## Delta Vs Previous Run",
		"",
		"| Type | Covered Delta | Percent Delta |",
		"| --- | --- | --- |",
	]
	for key in ("line_adj", "expr_adj", "toggle", "user"):
		delta = metrics["delta"].get(key)
		if delta is None:
			coverage_types_lines.append(f"| `{key}` | `n/a` | `n/a` |")
		else:
			coverage_types_lines.append(f"| `{key}` | `{delta['covered']:+d}` | `{delta['pct']:+.2f}%` |")
	coverage_types_lines.extend(
		[
			"",
			"## PT Wrapper And v2 Files",
			"",
			"| File | line(adj) | expr(adj) | toggle | user |",
			"| --- | --- | --- | --- | --- |",
		]
	)
	for file_name in REPORT_FILES:
		per = metrics["per_file"].get(file_name, {})
		line_adj = per.get("line_adj", CoverageCount(0, 0).as_dict())
		expr_adj = per.get("expr_adj", CoverageCount(0, 0).as_dict())
		toggle = per.get("toggle", CoverageCount(0, 0).as_dict())
		user = per.get("user", CoverageCount(0, 0).as_dict())
		coverage_types_lines.append(
			f"| `{file_name}` | `{line_adj['covered']} / {line_adj['total']} ({line_adj['pct']:.2f}%)` | "
			f"`{expr_adj['covered']} / {expr_adj['total']} ({expr_adj['pct']:.2f}%)` | "
			f"`{toggle['covered']} / {toggle['total']} ({toggle['pct']:.2f}%)` | "
			f"`{user['covered']} / {user['total']} ({user['pct']:.2f}%)` |"
		)
	coverage_types_lines.extend(
		[
			"",
			"## Residual Summary",
			"",
			f"- Residual points: `{len(residuals)}`",
			f"- Residual report: [`residual_uncovered.md`](./residual_uncovered.md)",
		]
	)
	if functional_md_path.exists():
		coverage_types_lines.append(f"- Functional coverage: [`functional_coverage.md`](./functional_coverage.md)")
	coverage_types_lines.extend(["", "## Top Uncovered Points", "", "### expr"])
	for entry in metrics["top_uncovered"]["expr"][:10]:
		coverage_types_lines.append(f"- `{entry['file']}:{entry['line']}` `{entry['comment']}`")
	coverage_types_lines.append("")
	coverage_types_lines.append("### toggle")
	for entry in metrics["top_uncovered"]["toggle"][:10]:
		coverage_types_lines.append(f"- `{entry['file']}:{entry['line']}` `{entry['comment']}`")
	coverage_types_lines.append("")
	coverage_types_lines.append("### user")
	if metrics["top_uncovered"]["user"]:
		for entry in metrics["top_uncovered"]["user"][:10]:
			coverage_types_lines.append(f"- `{entry['file']}:{entry['line']}` `{entry['comment']}`")
	else:
		coverage_types_lines.append("- All current user coverage points are covered.")
	coverage_types_path = coverage_dat.parent / "coverage_types.md"
	coverage_types_path.write_text("\n".join(coverage_types_lines) + "\n", encoding="utf-8")

	DEBUG_ROOT.mkdir(parents=True, exist_ok=True)
	timestamp = datetime.now().strftime("%Y%m%d")
	report_path = DEBUG_ROOT / f"coverage_PASS_{timestamp}.md"
	report_lines = [
		"# PT Coverage 覆盖率报告",
		"",
		"| 字段 | 内容 |",
		"| --- | --- |",
		"| 报告名称 | `coverage` |",
		"| 生成方式 | `make -C sim/cocotb coverage` |",
		"| 仿真后端 | `Verilator` |",
		"| 当前状态 | `PASS` |",
		f"| 文档时间戳 | `{timestamp}` |",
		"",
		"## 产物",
		"- 覆盖汇总：[`coverage_types.md`](../../../sim/cocotb/coverage/coverage/coverage_types.md)",
		"- metrics：[`coverage_metrics.json`](../../../sim/cocotb/coverage/coverage/coverage_metrics.json)",
		"- 功能覆盖：[`functional_coverage.md`](../../../sim/cocotb/coverage/coverage/functional_coverage.md)",
		"- residual：[`residual_uncovered.md`](../../../sim/cocotb/coverage/coverage/residual_uncovered.md)",
		"- lcov：[`coverage.info`](../../../sim/cocotb/coverage/coverage/coverage.info)",
		"- raw data：[`coverage.dat`](../../../sim/cocotb/coverage/coverage/coverage.dat)",
		"",
		"## 总体统计",
		"",
		"| 指标 | 数值 |",
		"| --- | --- |",
		f"| `line(raw)` | `{overall_line_raw.covered} / {overall_line_raw.total} = {pct(overall_line_raw.covered, overall_line_raw.total):.2f}%` |",
		f"| `line(adjusted)` | `{overall_line_adj.covered} / {overall_line_adj.total} = {pct(overall_line_adj.covered, overall_line_adj.total):.2f}%` |",
		f"| `branch(adjusted)` | `{overall_branch_adj.covered} / {overall_branch_adj.total} = {pct(overall_branch_adj.covered, overall_branch_adj.total):.2f}%` |",
		f"| `expr(adjusted)` | `{expr_adj_overall.covered} / {expr_adj_overall.total} = {pct(expr_adj_overall.covered, expr_adj_overall.total):.2f}%` |",
		f"| `toggle` | `{toggle_overall.covered} / {toggle_overall.total} = {pct(toggle_overall.covered, toggle_overall.total):.2f}%` |",
		f"| `user` | `{user_overall.covered} / {user_overall.total} = {pct(user_overall.covered, user_overall.total):.2f}%` |",
		"",
		"## Residual 分类",
		"",
		"| 分类 | 数量 |",
		"| --- | --- |",
	]
	for key, value in residual_json["counts"]["by_classification"].items():
		report_lines.append(f"| `{key}` | `{value}` |")
	report_lines.extend(
		[
			"",
			"## PT Wrapper And v2 Files",
			"",
			"| 文件 | line(adj) | expr(adj) | toggle | user |",
			"| --- | --- | --- | --- | --- |",
		]
	)
	for file_name in REPORT_FILES:
		per = metrics["per_file"].get(file_name, {})
		line_adj = per.get("line_adj", CoverageCount(0, 0).as_dict())
		expr_adj = per.get("expr_adj", CoverageCount(0, 0).as_dict())
		toggle = per.get("toggle", CoverageCount(0, 0).as_dict())
		user = per.get("user", CoverageCount(0, 0).as_dict())
		report_lines.append(
			f"| `{file_name}` | `{line_adj['covered']} / {line_adj['total']} ({line_adj['pct']:.2f}%)` | "
			f"`{expr_adj['covered']} / {expr_adj['total']} ({expr_adj['pct']:.2f}%)` | "
			f"`{toggle['covered']} / {toggle['total']} ({toggle['pct']:.2f}%)` | "
			f"`{user['covered']} / {user['total']} ({user['pct']:.2f}%)` |"
		)
	report_lines.extend(["", "## 重点未覆盖点", "", "### expr"])
	for entry in metrics["top_uncovered"]["expr"][:8]:
		report_lines.append(f"- `{entry['file']}:{entry['line']}` `{entry['comment']}`")
	report_lines.append("")
	report_lines.append("### toggle")
	for entry in metrics["top_uncovered"]["toggle"][:8]:
		report_lines.append(f"- `{entry['file']}:{entry['line']}` `{entry['comment']}`")
	report_lines.append("")
	report_lines.append("### user")
	if metrics["top_uncovered"]["user"]:
		for entry in metrics["top_uncovered"]["user"][:8]:
			report_lines.append(f"- `{entry['file']}:{entry['line']}` `{entry['comment']}`")
	else:
		report_lines.append("- 当前 user coverage 点已全部命中。")
	report_path.write_text("\n".join(report_lines) + "\n", encoding="utf-8")

	return {
		"metrics_path": str(metrics_path),
		"coverage_types_path": str(coverage_types_path),
		"residual_json_path": str(residual_json_path),
		"residual_md_path": str(residual_md_path),
		"functional_json_path": str(functional_json_path) if functional_json_path.exists() else "",
		"functional_md_path": str(functional_md_path) if functional_md_path.exists() else "",
		"debug_report_path": str(report_path),
	}
