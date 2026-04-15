from __future__ import annotations

import json
import re
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Dict, Iterable, List, Mapping


BIN_DESCRIPTIONS: Dict[str, str] = {
	"cmd:cfg": "CFG command accepted",
	"cmd:qcfg": "QCFG header/payload flow exercised",
	"cmd:load": "LOAD command exercised",
	"cmd:matmul": "MATMUL command exercised",
	"cmd:matadd": "MATADD command exercised",
	"qcfg:per_tensor": "PER_TENSOR quantization mode",
	"qcfg:x_wise": "X_WISE quantization mode",
	"qcfg:y_wise": "Y_WISE quantization mode",
	"qcfg:x_wise_div2": "X_WISE_DIV2 quantization mode",
	"qcfg:y_wise_div2": "Y_WISE_DIV2 quantization mode",
	"load:need_a_only": "LOAD need_a only",
	"load:need_b_only": "LOAD need_b only",
	"load:need_a_and_b": "LOAD need_a and need_b",
	"operand:matmul_ab": "MATMUL uses A/B bank operands",
	"operand:matadd_m_c": "MATADD uses retained M plus C/B-slot tile",
	"cache:a_hit": "A-side cache hit",
	"cache:a_miss": "A-side cache miss",
	"cache:b_hit": "B-side cache hit",
	"cache:b_miss": "B-side cache miss",
	"cache:c_hit": "C-side reuse hit",
	"cache:c_miss": "C-side reuse miss",
	"reuse:b_reload_after_c": "B reload after C overwrote B-side metadata",
	"mwindow:buf0": "MATADD consumed M buffer 0",
	"mwindow:buf1": "MATADD consumed M buffer 1",
	"export:success": "M export completed successfully",
	"export:error": "M export completed with error",
	"clear:pre_issue": "clear inserted before command issue",
	"clear:in_flight": "clear inserted while work was in flight",
	"clear:post_export": "clear inserted after export completed",
	"queue:ctrl_ready_low": "ctrl_ready deasserted before acceptance",
	"queue:ctrl_accept_slow": "control acceptance latency exceeded one cycle",
	"backpressure:long_phase": "Observed long backpressure phase",
	"slot_scan:hit_nonzero": "slot_scan hit matched a non-zero slot",
	"slot_scan:free_nonzero": "slot_scan first free slot was non-zero",
	"slot_scan:lut_full_reject": "LUT full miss rejected at command stage",
	"csr:selector:a_base_lo": "CFG selector A_BASE_LO written",
	"csr:selector:a_base_hi": "CFG selector A_BASE_HI written",
	"csr:selector:b_base_lo": "CFG selector B_BASE_LO written",
	"csr:selector:b_base_hi": "CFG selector B_BASE_HI written",
	"csr:pattern:zero": "CSR zero pattern written",
	"csr:pattern:onehot": "CSR one-hot pattern written",
	"csr:pattern:sparse": "CSR sparse multi-bit pattern written",
	"csr:pattern:alternating": "CSR alternating pattern written",
	"csr:pattern:all_ones": "CSR all-ones pattern written",
	"reject:illegal_cfg": "Rejected malformed CFG command",
	"reject:illegal_load": "Rejected malformed LOAD command",
	"reject:illegal_matmul": "Rejected malformed MATMUL command",
	"reject:illegal_matadd": "Rejected malformed MATADD command",
	"reject:lut_full_miss": "Rejected miss because LUT had no free slot",
	"reject:a_capacity": "Rejected because A capacity was exhausted",
	"reject:b_capacity": "Rejected because B/C capacity was exhausted",
	"reject:a_size_mismatch": "Rejected because cached A length mismatched",
	"reject:b_size_mismatch": "Rejected because cached B/C length mismatched",
	"reject:b_conflicts_with_c": "Rejected because B-side slot currently holds C metadata",
	"reject:mwindow_empty": "Rejected because MATADD referenced an empty M buffer",
}


SUITE_REQUIRED_BINS: Dict[str, List[str]] = {
	"ci": [
		"cmd:cfg",
		"cmd:qcfg",
		"cmd:load",
		"cmd:matmul",
		"cmd:matadd",
		"qcfg:per_tensor",
		"qcfg:x_wise",
		"qcfg:y_wise",
		"qcfg:x_wise_div2",
		"qcfg:y_wise_div2",
		"load:need_a_only",
		"load:need_b_only",
		"load:need_a_and_b",
		"operand:matmul_ab",
		"operand:matadd_m_c",
		"cache:a_hit",
		"cache:a_miss",
		"cache:b_hit",
		"cache:b_miss",
		"cache:c_miss",
		"reuse:b_reload_after_c",
		"export:success",
		"export:error",
		"clear:pre_issue",
		"clear:in_flight",
		"clear:post_export",
		"queue:ctrl_ready_low",
		"backpressure:long_phase",
		"slot_scan:hit_nonzero",
		"slot_scan:free_nonzero",
		"slot_scan:lut_full_reject",
		"csr:selector:a_base_lo",
		"csr:selector:a_base_hi",
		"csr:selector:b_base_lo",
		"csr:selector:b_base_hi",
		"csr:pattern:zero",
		"csr:pattern:onehot",
		"csr:pattern:sparse",
		"csr:pattern:alternating",
		"csr:pattern:all_ones",
	],
}
SUITE_REQUIRED_BINS["coverage"] = list(SUITE_REQUIRED_BINS["ci"])
SUITE_REQUIRED_BINS["soak"] = [
	"cmd:matmul",
	"cache:a_miss",
	"cache:b_miss",
	"export:success",
	"backpressure:long_phase",
]


def sanitize_name(value: str) -> str:
	return re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip()) or "unnamed"


def classify_csr_pattern(value: int) -> str:
	word = value & 0xFFFF
	if word == 0x0000:
		return "csr:pattern:zero"
	if word != 0 and (word & (word - 1)) == 0:
		return "csr:pattern:onehot"
	if word in {0xAAAA, 0x5555}:
		return "csr:pattern:alternating"
	if word == 0xFFFF:
		return "csr:pattern:all_ones"
	return "csr:pattern:sparse"


@dataclass
class FunctionalCoverageRecorder:
	case_name: str
	suite_name: str
	run_name: str
	seed: int
	x_dim: int
	y_dim: int
	profile: str = ""
	metadata: Dict[str, object] = field(default_factory=dict)
	hits: Counter[str] = field(default_factory=Counter)

	def hit(self, bin_name: str, count: int = 1) -> None:
		if count <= 0:
			return
		self.hits[bin_name] += count

	def hit_many(self, bin_names: Iterable[str]) -> None:
		for bin_name in bin_names:
			self.hit(bin_name)

	def dump(self, out_dir: Path) -> Path:
		out_dir.mkdir(parents=True, exist_ok=True)
		payload = {
			"generated_at": datetime.now().isoformat(timespec="seconds"),
			"case_name": self.case_name,
			"suite_name": self.suite_name,
			"run_name": self.run_name,
			"seed": self.seed,
			"x_dim": self.x_dim,
			"y_dim": self.y_dim,
			"profile": self.profile,
			"metadata": self.metadata,
			"hits": dict(sorted(self.hits.items())),
		}
		path = out_dir / f"{sanitize_name(self.case_name)}.functional.json"
		path.write_text(json.dumps(payload, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
		return path


def load_fragment(path: Path) -> Dict[str, object]:
	return json.loads(path.read_text(encoding="utf-8"))


def aggregate_fragments(fragment_paths: Iterable[Path], suite_name: str) -> Dict[str, object]:
	paths = sorted({Path(path) for path in fragment_paths})
	case_entries: List[Dict[str, object]] = []
	bin_hits: Counter[str] = Counter()
	bin_cases: Dict[str, set[str]] = defaultdict(set)

	for path in paths:
		payload = load_fragment(path)
		case_name = str(payload["case_name"])
		hits = {str(key): int(value) for key, value in dict(payload.get("hits", {})).items()}
		case_entries.append(payload)
		for bin_name, count in hits.items():
			bin_hits[bin_name] += count
			if count > 0:
				bin_cases[bin_name].add(case_name)

	required_bins = SUITE_REQUIRED_BINS.get(suite_name, [])
	all_bins = sorted(set(bin_hits) | set(required_bins))
	missing_required = [bin_name for bin_name in required_bins if bin_hits.get(bin_name, 0) <= 0]

	return {
		"generated_at": datetime.now().isoformat(timespec="seconds"),
		"suite_name": suite_name,
		"case_count": len(case_entries),
		"fragment_count": len(paths),
		"required_bins": required_bins,
		"missing_required_bins": missing_required,
		"bins": {
			bin_name: {
				"description": BIN_DESCRIPTIONS.get(bin_name, ""),
				"hits": int(bin_hits.get(bin_name, 0)),
				"cases": sorted(bin_cases.get(bin_name, set())),
			}
			for bin_name in all_bins
		},
		"cases": case_entries,
	}


def render_markdown(report: Mapping[str, object]) -> str:
	suite_name = str(report["suite_name"])
	required_bins = list(report.get("required_bins", []))
	bins = dict(report.get("bins", {}))
	lines = [
		"# PT Functional Coverage",
		"",
		"| Field | Value |",
		"| --- | --- |",
		f"| `suite` | `{suite_name}` |",
		f"| `cases` | `{report['case_count']}` |",
		f"| `fragments` | `{report['fragment_count']}` |",
		f"| `required_bins` | `{len(required_bins)}` |",
		f"| `missing_required_bins` | `{len(report['missing_required_bins'])}` |",
		"",
		"## Required Bins",
		"",
		"| Bin | Status | Hits | Cases | Description |",
		"| --- | --- | --- | --- | --- |",
	]
	for bin_name in required_bins:
		entry = dict(bins.get(bin_name, {}))
		hits = int(entry.get("hits", 0))
		cases = list(entry.get("cases", []))
		status = "HIT" if hits > 0 else "MISS"
		lines.append(
			f"| `{bin_name}` | `{status}` | `{hits}` | `{len(cases)}` | `{entry.get('description', '')}` |"
		)

	lines.extend(
		[
			"",
			"## All Bins",
			"",
			"| Bin | Hits | Cases | Description |",
			"| --- | --- | --- | --- |",
		]
	)
	for bin_name in sorted(bins):
		entry = dict(bins[bin_name])
		lines.append(
			f"| `{bin_name}` | `{int(entry.get('hits', 0))}` | `{len(list(entry.get('cases', [])))}` | `{entry.get('description', '')}` |"
		)
	return "\n".join(lines) + "\n"


def write_aggregate_reports(fragment_paths: Iterable[Path], out_dir: Path, suite_name: str) -> Dict[str, str]:
	out_dir.mkdir(parents=True, exist_ok=True)
	report = aggregate_fragments(fragment_paths, suite_name)
	json_path = out_dir / "functional_coverage.json"
	md_path = out_dir / "functional_coverage.md"
	json_path.write_text(json.dumps(report, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
	md_path.write_text(render_markdown(report), encoding="utf-8")
	return {
		"json_path": str(json_path),
		"md_path": str(md_path),
	}
