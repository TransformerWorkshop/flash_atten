from __future__ import annotations

import json
import os
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass
from itertools import product
from pathlib import Path
from typing import Any, Optional

from . import (
	COCOTB_ROOT,
	DEFAULT_APP_TARGET,
	DEFAULT_OUT_DIR,
	REPO_ROOT,
	RTL_DIR,
	app_target_label,
	hdl_toplevel_for_target,
	normalize_app_target,
	rtl_params_for_target,
)
from .multitile_utils import build_command_schedule, choose_partition_plan
from .param_utils import load_pt_param_snapshot
from .submission import SUBMISSION_MODE_SHADOW_DELTA, normalize_submission_mode
from .verify_runner import normalize_sim_name

try:
	from cocotb_tools.runner import get_runner
except ModuleNotFoundError as exc:
	get_runner = None
	IMPORT_ERROR = exc
else:
	IMPORT_ERROR = None


MULTITILE_TEST_MODULE = "app.pt_tiled_gemm.tests.test_pt_multitile_bench"


@dataclass(frozen=True)
class MultitileCaseSpec:
	m_tiles: int
	n_tiles: int
	k_tiles: int

	@property
	def tag(self) -> str:
		return f"m{self.m_tiles}_n{self.n_tiles}_k{self.k_tiles}"


@dataclass
class MultitileCaseResult:
	m_tiles: int
	n_tiles: int
	k_tiles: int
	m_dim: int
	n_dim: int
	k_dim: int
	status: str
	reason: Optional[str]
	submission_mode: str
	command_count: Optional[int]
	issued_command_count: Optional[int]
	clear_count: Optional[int]
	accept_to_resp_cycles: Optional[int]
	accept_to_done_cycles: Optional[int]
	axil_writes_total: Optional[int]
	axil_writes_per_command: Optional[float]
	descriptor_push_count: Optional[int]
	dma_req_count: Optional[int]
	export_req_count: Optional[int]
	export_beats: Optional[int]
	perf_axil_write_count: Optional[int]
	perf_command_push_count: Optional[int]
	perf_pt_accept_count: Optional[int]
	perf_resp_enqueue_count: Optional[int]
	perf_wr_dma_done_count: Optional[int]
	perf_compact_commit_count: Optional[int]
	perf_push_to_accept_cycles: Optional[int]
	perf_accept_to_resp_cycles: Optional[int]
	perf_resp_to_done_cycles: Optional[int]
	perf_other_cycles: Optional[int]
	macs: int
	ops: int
	macs_per_cycle: Optional[float]
	ops_per_cycle: Optional[float]
	tops_at_1ghz: Optional[float]
	results_xml: str
	metrics_path: str

	def to_dict(self) -> dict[str, Any]:
		return asdict(self)


@dataclass
class MultitileSweepResult:
	available: bool
	success: bool
	target: str
	target_label: str
	simulator: str
	submission_mode: str
	pt_size_w: int
	max_encoded_elems: int
	results_path: str
	cases: list[MultitileCaseResult]
	message: Optional[str]

	def to_dict(self) -> dict[str, Any]:
		return {
			"available": self.available,
			"success": self.success,
			"target": self.target,
			"target_label": self.target_label,
			"simulator": self.simulator,
			"submission_mode": self.submission_mode,
			"pt_size_w": self.pt_size_w,
			"max_encoded_elems": self.max_encoded_elems,
			"results_path": self.results_path,
			"cases": [case.to_dict() for case in self.cases],
			"message": self.message,
		}


def _rtl_sources() -> list[Path]:
	return sorted(RTL_DIR.glob("*.v"))


def _parse_results_xml(results_xml: Path) -> dict[str, int]:
	if not results_xml.exists():
		return {"tests": 0, "failures": 0, "errors": 0}
	root = ET.parse(results_xml).getroot()
	suites = [root] if root.tag == "testsuite" else list(root.iter("testsuite"))
	if not suites:
		return {"tests": 0, "failures": 0, "errors": 0}
	attr_tests = sum(int(item.get("tests", "0")) for item in suites)
	attr_failures = sum(int(item.get("failures", "0")) for item in suites)
	attr_errors = sum(int(item.get("errors", "0")) for item in suites)
	case_tests = len(list(root.iter("testcase")))
	case_failures = len(list(root.iter("failure")))
	case_errors = len(list(root.iter("error")))
	return {
		"tests": attr_tests if attr_tests else case_tests,
		"failures": attr_failures if attr_failures else case_failures,
		"errors": attr_errors if attr_errors else case_errors,
	}


def _case_dims(case: MultitileCaseSpec) -> tuple[int, int, int]:
	rtl_params = rtl_params_for_target(DEFAULT_APP_TARGET)
	return (
		rtl_params["GEMM_X_DIM"] * case.m_tiles,
		rtl_params["GEMM_Y_DIM"] * case.n_tiles,
		rtl_params["GEMM_X_DIM"] * case.k_tiles,
	)


def _default_sweep_path(target: str, sim_name: str, submission_mode: str) -> Path:
	return DEFAULT_OUT_DIR / f"multitile_sweep_{normalize_app_target(target)}_{normalize_sim_name(sim_name)}_{submission_mode}.json"


def _case_output_root(target: str, sim_name: str, submission_mode: str, case: MultitileCaseSpec) -> Path:
	return DEFAULT_OUT_DIR / "cocotb_multitile" / normalize_app_target(target) / normalize_sim_name(sim_name) / submission_mode / case.tag


def _load_case_metrics(metrics_path: Path) -> dict[str, Any]:
	if not metrics_path.exists():
		return {}
	try:
		return json.loads(metrics_path.read_text(encoding="utf-8"))
	except json.JSONDecodeError:
		return {}


def _format_float(value: Optional[float]) -> str:
	return "-" if value is None else f"{value:.3f}"


def render_multitile_text(result: MultitileSweepResult) -> str:
	lines = [
		"Multitile Sweep Summary",
		f"  Target    : {result.target_label}",
		f"  Simulator : {result.simulator}",
		f"  Mode      : {result.submission_mode}",
		f"  PT_SIZE_W : {result.pt_size_w}",
		f"  Max Elems : {result.max_encoded_elems}",
		f"  Success   : {result.success}",
		f"  Output    : {result.results_path}",
		"",
		"  m  n  k  status       done_cycles  ops/cycle  tops@1GHz  note",
	]
	for case in result.cases:
		note = case.reason or ""
		lines.append(
			f"  {case.m_tiles:<2} {case.n_tiles:<2} {case.k_tiles:<2} "
			f"{case.status:<12} "
			f"{str(case.accept_to_done_cycles or '-'):>11}  "
			f"{_format_float(case.ops_per_cycle):>9}  "
			f"{_format_float(case.tops_at_1ghz):>10}  "
			f"{note}"
		)
	if result.message:
		lines.extend(["", f"  Message   : {result.message}"])
	return "\n".join(lines)


def run_multitile_sweep(
	*,
	target: str = DEFAULT_APP_TARGET,
	sim_name: str = "icarus",
	m_tiles: tuple[int, ...],
	n_tiles: tuple[int, ...],
	k_tiles: tuple[int, ...],
	submission_mode: str = SUBMISSION_MODE_SHADOW_DELTA,
	waves: bool = False,
	out_path: Optional[Path] = None,
) -> MultitileSweepResult:
	normalized_target = normalize_app_target(target)
	normalized_sim = normalize_sim_name(sim_name)
	normalized_submission_mode = normalize_submission_mode(submission_mode)
	rtl_params = rtl_params_for_target(normalized_target)
	params = load_pt_param_snapshot()
	output_path = out_path if out_path is not None else _default_sweep_path(normalized_target, normalized_sim, normalized_submission_mode)
	output_path.parent.mkdir(parents=True, exist_ok=True)

	if get_runner is None:
		return MultitileSweepResult(
			available=False,
			success=False,
			target=normalized_target,
			target_label=app_target_label(normalized_target),
			simulator=normalized_sim,
			submission_mode=normalized_submission_mode,
			pt_size_w=params.pt_size_w,
			max_encoded_elems=params.max_encoded_elems,
			results_path=str(output_path),
			cases=[],
			message=f"缺少 cocotb_tools 依赖，无法运行 multitile sweep。 Import error: {IMPORT_ERROR}",
		)

	runner = get_runner(normalized_sim)
	build_root = DEFAULT_OUT_DIR / "cocotb_multitile" / normalized_target / normalized_sim / normalized_submission_mode / "build"
	build_root.mkdir(parents=True, exist_ok=True)
	build_log = DEFAULT_OUT_DIR / "cocotb_multitile" / normalized_target / normalized_sim / f"build_{normalized_submission_mode}.log"
	existing_pythonpath = os.getenv("PYTHONPATH", "")
	pythonpath_entries = [str(REPO_ROOT), str(COCOTB_ROOT)]
	if existing_pythonpath:
		pythonpath_entries.append(existing_pythonpath)

	runner.build(
		sources=_rtl_sources(),
		includes=[RTL_DIR],
		hdl_toplevel=hdl_toplevel_for_target(normalized_target),
		parameters=rtl_params,
		build_args=["-Wall"],
		build_dir=build_root,
		always=True,
		timescale=("1ns", "1ps"),
		waves=waves,
		verbose=False,
		log_file=build_log,
	)

	cases: list[MultitileCaseResult] = []
	for case in [MultitileCaseSpec(mv, nv, kv) for mv, nv, kv in product(m_tiles, n_tiles, k_tiles)]:
		m_dim, n_dim, k_dim = _case_dims(case)
		macs = m_dim * n_dim * k_dim
		ops = 2 * macs
		case_root = _case_output_root(normalized_target, normalized_sim, normalized_submission_mode, case)
		test_dir = case_root / "test"
		log_dir = case_root / "logs"
		results_xml = case_root / "results.xml"
		metrics_path = case_root / "metrics.json"
		for path in (test_dir, log_dir):
			path.mkdir(parents=True, exist_ok=True)
		if metrics_path.exists():
			metrics_path.unlink()
		m_parts, n_parts, k_parts = choose_partition_plan(
			m_tiles=case.m_tiles,
			n_tiles=case.n_tiles,
			k_tiles=case.k_tiles,
			valid_tile_counts=params.valid_tile_counts,
			max_encoded_elems=params.max_encoded_elems,
			x_dim=rtl_params["GEMM_X_DIM"],
			y_dim=rtl_params["GEMM_Y_DIM"],
			pack_lanes=rtl_params.get("PACK_LANES", 1),
		)
		schedule = build_command_schedule(m_parts=m_parts, n_parts=n_parts, k_parts=k_parts)
		reason = None
		if (m_parts, n_parts, k_parts) != ((case.m_tiles,), (case.n_tiles,), (case.k_tiles,)):
			reason = (
				f"software adapted via m={list(m_parts)} n={list(n_parts)} k={list(k_parts)} "
				f"({len(schedule)} commands)"
			)

		extra_env = {
			"PYTHONPATH": os.pathsep.join(pythonpath_entries),
			"PT_APP_TARGET": normalized_target,
			"PT_X_DIM": str(rtl_params["GEMM_X_DIM"]),
			"PT_Y_DIM": str(rtl_params["GEMM_Y_DIM"]),
			"PT_DATA_WIDTH": str(rtl_params["DATA_WIDTH"]),
			"PT_A_BASE": str(0x0000_1000),
			"PT_B_BASE": str(0x0000_2000),
			"PT_LUT_DEPTH": str(rtl_params["LUT_DEPTH"]),
			"PT_A_BANK_DEPTH": str(rtl_params["A_BANK_DEPTH"]),
			"PT_B_BANK_DEPTH": str(rtl_params["B_BANK_DEPTH"]),
			"PT_M_BANK_DEPTH": str(rtl_params["M_BANK_DEPTH"]),
			"PT_A_LOAD_LANES": str(rtl_params["A_LOAD_LANES"]),
			"PT_B_LOAD_LANES": str(rtl_params["B_LOAD_LANES"]),
			"PT_M_WRITE_LANES": str(rtl_params["M_WRITE_LANES"]),
			"PT_M_EXPORT_LANES": str(rtl_params["M_EXPORT_LANES"]),
			"PT_M_PHYSICAL_COPIES": str(rtl_params["M_PHYSICAL_COPIES"]),
			"PT_TEST_SEED": "10",
			"PT_SUITE_NAME": "multitile_sweep",
			"PT_RUN_NAME": case.tag,
			"PT_APP_SUBMISSION_MODE": normalized_submission_mode,
			"PT_MT_METRICS_PATH": str(metrics_path),
			"PT_MT_M_TILES": str(case.m_tiles),
			"PT_MT_N_TILES": str(case.n_tiles),
			"PT_MT_K_TILES": str(case.k_tiles),
			"PT_MT_TARGET_M_TILES": str(case.m_tiles),
			"PT_MT_TARGET_N_TILES": str(case.n_tiles),
			"PT_MT_TARGET_K_TILES": str(case.k_tiles),
			"PT_MT_MAX_ENCODED_ELEMS": str(params.max_encoded_elems),
			"PT_MT_VALID_TILE_COUNTS": ",".join(str(item) for item in params.valid_tile_counts),
			"PT_MT_CTRL_ID_BASE": str(0xB00),
			"PT_EXT_ADDR_W": str(rtl_params["EXT_ADDR_W"]),
		}
		if "WORD_WIDTH" in rtl_params:
			extra_env["PT_WORD_WIDTH"] = str(rtl_params["WORD_WIDTH"])
			extra_env["PT_ELEM_WIDTH"] = str(rtl_params["ELEM_WIDTH"])
			extra_env["PT_PACK_LANES"] = str(rtl_params["PACK_LANES"])
			extra_env["PT_ACC_WIDTH"] = str(rtl_params["ACC_WIDTH"])
		failure_message: Optional[str] = None
		try:
			runner.test(
				test_module=MULTITILE_TEST_MODULE,
				hdl_toplevel=hdl_toplevel_for_target(normalized_target),
				build_dir=build_root,
				test_dir=test_dir,
				results_xml=str(results_xml),
				extra_env=extra_env,
				waves=waves,
				verbose=False,
				timescale=("1ns", "1ps"),
				log_file=log_dir / "test.log",
			)
		except SystemExit as exc:
			failure_message = f"bench 退出码异常: {exc.code}"
		except Exception as exc:  # pragma: no cover
			failure_message = str(exc)

		result_counts = _parse_results_xml(results_xml)
		payload = _load_case_metrics(metrics_path)
		measurement = payload.get("measurement", {})
		case_status = "passed"
		case_reason: Optional[str] = None
		if failure_message is not None or result_counts["tests"] == 0 or result_counts["failures"] != 0 or result_counts["errors"] != 0:
			case_status = "failed"
			case_reason = failure_message or "cocotb case failed"

		cases.append(
			MultitileCaseResult(
				m_tiles=case.m_tiles,
				n_tiles=case.n_tiles,
				k_tiles=case.k_tiles,
				m_dim=m_dim,
				n_dim=n_dim,
				k_dim=k_dim,
				status=case_status,
				reason=case_reason or reason,
				submission_mode=normalized_submission_mode,
				command_count=payload.get("case", {}).get("logical_command_count", payload.get("case", {}).get("command_count")),
				issued_command_count=payload.get("case", {}).get("issued_command_count"),
				clear_count=payload.get("case", {}).get("clear_count"),
				accept_to_resp_cycles=measurement.get("accept_to_resp_cycles"),
				accept_to_done_cycles=measurement.get("accept_to_done_cycles"),
				axil_writes_total=measurement.get("axil_writes_total"),
				axil_writes_per_command=measurement.get("axil_writes_per_command"),
				descriptor_push_count=measurement.get("descriptor_push_count"),
				dma_req_count=measurement.get("dma_req_count"),
				export_req_count=measurement.get("export_req_count"),
				export_beats=measurement.get("export_beats"),
				perf_axil_write_count=measurement.get("perf_axil_write_count"),
				perf_command_push_count=measurement.get("perf_command_push_count"),
				perf_pt_accept_count=measurement.get("perf_pt_accept_count"),
				perf_resp_enqueue_count=measurement.get("perf_resp_enqueue_count"),
				perf_wr_dma_done_count=measurement.get("perf_wr_dma_done_count"),
				perf_compact_commit_count=measurement.get("perf_compact_commit_count"),
				perf_push_to_accept_cycles=measurement.get("perf_push_to_accept_cycles"),
				perf_accept_to_resp_cycles=measurement.get("perf_accept_to_resp_cycles"),
				perf_resp_to_done_cycles=measurement.get("perf_resp_to_done_cycles"),
				perf_other_cycles=measurement.get("perf_other_cycles"),
				macs=macs,
				ops=ops,
				macs_per_cycle=measurement.get("macs_per_cycle"),
				ops_per_cycle=measurement.get("ops_per_cycle"),
				tops_at_1ghz=measurement.get("tops_at_1ghz"),
				results_xml=str(results_xml),
				metrics_path=str(metrics_path),
			)
		)

	success = all(case.status == "passed" for case in cases)
	result = MultitileSweepResult(
		available=True,
		success=success,
		target=normalized_target,
		target_label=app_target_label(normalized_target),
		simulator=normalized_sim,
		submission_mode=normalized_submission_mode,
		pt_size_w=params.pt_size_w,
		max_encoded_elems=params.max_encoded_elems,
		results_path=str(output_path),
		cases=cases,
		message=None if success else "部分 multitile 组合失败，请查看 per-case results.xml / test.log。",
	)
	output_path.write_text(json.dumps(result.to_dict(), ensure_ascii=False, indent=2), encoding="utf-8")
	return result
