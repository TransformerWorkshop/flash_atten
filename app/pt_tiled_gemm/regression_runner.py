from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Optional

from . import DEFAULT_OUT_DIR, ProblemSpec, app_target_label, normalize_app_target
from .multitile_runner import MultitileSweepResult, run_multitile_sweep
from .submission import SUBMISSION_MODE_COMPACT, SUBMISSION_MODE_LEGACY
from .verify_runner import VerifyResult, normalize_sim_name, run_verification


@dataclass(frozen=True)
class VerifyRegressionSpec:
	target: str
	problem: ProblemSpec

	@property
	def label(self) -> str:
		return f"verify:{self.problem.tag}"


@dataclass(frozen=True)
class MultitileRegressionSpec:
	target: str
	m_tiles: tuple[int, ...]
	n_tiles: tuple[int, ...]
	k_tiles: tuple[int, ...]

	@property
	def label(self) -> str:
		m_text = ",".join(str(item) for item in self.m_tiles)
		n_text = ",".join(str(item) for item in self.n_tiles)
		k_text = ",".join(str(item) for item in self.k_tiles)
		return f"multitile:m={m_text};n={n_text};k={k_text}"


@dataclass
class RegressionEntry:
	kind: str
	target: str
	target_label: str
	case: str
	success: bool
	available: bool
	results_path: str
	metrics_path: Optional[str]
	tests: Optional[int]
	failures: Optional[int]
	errors: Optional[int]
	passed_cases: Optional[int]
	total_cases: Optional[int]
	message: Optional[str]

	def to_dict(self) -> dict[str, Any]:
		return asdict(self)


@dataclass
class RegressionMatrixResult:
	available: bool
	success: bool
	simulator: str
	verify_submission_mode: str
	multitile_submission_mode: str
	results_path: str
	entries: list[RegressionEntry]
	message: Optional[str]

	def to_dict(self) -> dict[str, Any]:
		return {
			"available": self.available,
			"success": self.success,
			"simulator": self.simulator,
			"verify_submission_mode": self.verify_submission_mode,
			"multitile_submission_mode": self.multitile_submission_mode,
			"results_path": self.results_path,
			"entries": [entry.to_dict() for entry in self.entries],
			"message": self.message,
		}


DEFAULT_VERIFY_SPECS = (
	VerifyRegressionSpec("pt_dma_top_v3_ch1", ProblemSpec(16, 32, 16)),
	VerifyRegressionSpec("pt_dma_top_v3_ch2", ProblemSpec(16, 32, 16)),
	VerifyRegressionSpec("pt_dma_top_v3_ch4", ProblemSpec(16, 32, 16)),
	VerifyRegressionSpec("pt_dma_top_v3_ch1", ProblemSpec(32, 32, 32)),
	VerifyRegressionSpec("pt_dma_top_v3_ch2", ProblemSpec(32, 32, 32)),
	VerifyRegressionSpec("pt_dma_top_v3_ch4", ProblemSpec(32, 32, 32)),
)

DEFAULT_MULTITILE_SPECS = (
	MultitileRegressionSpec("pt_dma_top_v3_ch1", (1, 2), (1, 2), (1, 2)),
	MultitileRegressionSpec("pt_dma_top_v3_ch2", (1, 2), (1, 2), (1, 2)),
	MultitileRegressionSpec("pt_dma_top_v3_ch4", (1, 2), (1, 2), (1, 2)),
	MultitileRegressionSpec("pt_dma_top_v3_ch1", (4,), (4,), (4,)),
	MultitileRegressionSpec("pt_dma_top_v3_ch2", (4,), (4,), (4,)),
	MultitileRegressionSpec("pt_dma_top_v3_ch4", (4,), (4,), (4,)),
)


def default_regression_path(sim_name: str) -> Path:
	return DEFAULT_OUT_DIR / f"channel_regression_{normalize_sim_name(sim_name)}.json"


def _entry_from_verify(result: VerifyResult, spec: VerifyRegressionSpec) -> RegressionEntry:
	return RegressionEntry(
		kind="verify",
		target=result.target,
		target_label=app_target_label(result.target),
		case=spec.label,
		success=result.success,
		available=result.available,
		results_path=result.results_xml,
		metrics_path=result.metrics_path,
		tests=result.tests,
		failures=result.failures,
		errors=result.errors,
		passed_cases=None,
		total_cases=None,
		message=result.message,
	)


def _entry_from_multitile(result: MultitileSweepResult, spec: MultitileRegressionSpec) -> RegressionEntry:
	passed_cases = sum(1 for case in result.cases if case.status == "passed")
	return RegressionEntry(
		kind="multitile",
		target=result.target,
		target_label=result.target_label,
		case=spec.label,
		success=result.success,
		available=result.available,
		results_path=result.results_path,
		metrics_path=result.results_path,
		tests=None,
		failures=None,
		errors=None,
		passed_cases=passed_cases,
		total_cases=len(result.cases),
		message=result.message,
	)


def render_regression_text(result: RegressionMatrixResult) -> str:
	lines = [
		"Regression Matrix Summary",
		f"  Simulator : {result.simulator}",
		f"  Verify    : {result.verify_submission_mode}",
		f"  Multitile : {result.multitile_submission_mode}",
		f"  Success   : {result.success}",
		f"  Output    : {result.results_path}",
		"",
		"  kind       target             case                         status   detail",
	]
	for entry in result.entries:
		if entry.kind == "verify":
			detail = f"tests={entry.tests} fail={entry.failures} err={entry.errors}"
		else:
			detail = f"cases={entry.passed_cases}/{entry.total_cases}"
		status = "PASS" if entry.success else "FAIL"
		lines.append(
			f"  {entry.kind:<10} {entry.target:<18} {entry.case:<28} {status:<6} {detail}"
		)
		if entry.message:
			lines.append(f"    note: {entry.message}")
	if result.message:
		lines.extend(["", f"  Message   : {result.message}"])
	return "\n".join(lines)


def run_regression_matrix(
	*,
	sim_name: str = "icarus",
	waves: bool = False,
	out_path: Optional[Path] = None,
) -> RegressionMatrixResult:
	normalized_sim = normalize_sim_name(sim_name)
	verify_mode = SUBMISSION_MODE_LEGACY
	multitile_mode = SUBMISSION_MODE_COMPACT
	output_path = out_path if out_path is not None else default_regression_path(normalized_sim)
	output_path.parent.mkdir(parents=True, exist_ok=True)

	entries: list[RegressionEntry] = []
	all_available = True
	all_success = True

	for spec in DEFAULT_VERIFY_SPECS:
		result = run_verification(
			problem=spec.problem,
			target=normalize_app_target(spec.target),
			sim_name=normalized_sim,
			submission_mode=verify_mode,
			waves=waves,
		)
		entry = _entry_from_verify(result, spec)
		entries.append(entry)
		all_available = all_available and entry.available
		all_success = all_success and entry.success

	for spec in DEFAULT_MULTITILE_SPECS:
		result = run_multitile_sweep(
			target=normalize_app_target(spec.target),
			sim_name=normalized_sim,
			m_tiles=spec.m_tiles,
			n_tiles=spec.n_tiles,
			k_tiles=spec.k_tiles,
			submission_mode=multitile_mode,
			waves=waves,
		)
		entry = _entry_from_multitile(result, spec)
		entries.append(entry)
		all_available = all_available and entry.available
		all_success = all_success and entry.success

	message = None if all_success else "固定 app regression matrix 存在失败项，请查看 per-entry results_path。"
	payload = RegressionMatrixResult(
		available=all_available,
		success=all_success,
		simulator=normalized_sim,
		verify_submission_mode=verify_mode,
		multitile_submission_mode=multitile_mode,
		results_path=str(output_path),
		entries=entries,
		message=message,
	)
	output_path.write_text(json.dumps(payload.to_dict(), ensure_ascii=False, indent=2), encoding="utf-8")
	return payload
