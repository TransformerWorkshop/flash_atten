from __future__ import annotations

import json
import os
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Dict, Optional

from . import (
	COCOTB_ROOT,
	DEFAULT_APP_TARGET,
	PT_PARAMS,
	ProblemSpec,
	REPO_ROOT,
	RTL_DIR,
	app_target_label,
	cocotb_output_root,
	default_metrics_path,
	hdl_toplevel_for_target,
	normalize_app_target,
)

try:
	from cocotb_tools.runner import get_runner
except ModuleNotFoundError as exc:
	get_runner = None
	IMPORT_ERROR = exc
else:
	IMPORT_ERROR = None


APP_TEST_MODULE = "app.pt_tiled_gemm.tests.test_pt_tiled_gemm"


@dataclass
class VerifyResult:
	available: bool
	success: bool
	target: str
	simulator: str
	problem: Dict[str, list[int]]
	tests: int
	failures: int
	errors: int
	message: Optional[str]
	results_xml: str
	metrics_path: str
	algorithms: Dict[str, Any]
	unsupported_paths: Dict[str, Any]

	def to_dict(self) -> Dict[str, Any]:
		return asdict(self)


def normalize_sim_name(sim_name: str) -> str:
	name = sim_name.strip().lower()
	if name in {"icarus", "iverilog"}:
		return "icarus"
	if name in {"questa", "questasim", "modelsim"}:
		return "questa"
	if name == "verilator":
		return "verilator"
	return name


def _rtl_sources() -> list[Path]:
	return sorted(RTL_DIR.glob("*.v"))


def _parse_results_xml(results_xml: Path) -> Dict[str, int]:
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


def load_metrics(metrics_path: Path) -> Dict[str, Any]:
	if not metrics_path.exists():
		return {}
	try:
		return json.loads(metrics_path.read_text(encoding="utf-8"))
	except json.JSONDecodeError:
		return {}


def render_verify_text(result: VerifyResult) -> str:
	lines = [
		"Verify Summary",
		f"  Problem   : A={result.problem['A'][0]}x{result.problem['A'][1]}, "
		f"B={result.problem['B'][0]}x{result.problem['B'][1]}, "
		f"C={result.problem['C'][0]}x{result.problem['C'][1]}",
		f"  Target    : {app_target_label(result.target)}",
		f"  Simulator : {result.simulator}",
		f"  Success   : {result.success}",
		f"  Tests     : {result.tests}",
		f"  Failures  : {result.failures}",
		f"  Errors    : {result.errors}",
		f"  Results   : {result.results_xml}",
		f"  Metrics   : {result.metrics_path}",
	]
	if result.message:
		lines.append(f"  Message   : {result.message}")
	return "\n".join(lines)


def run_verification(
	problem: ProblemSpec,
	sim_name: str = "icarus",
	waves: bool = False,
	target: str = DEFAULT_APP_TARGET,
) -> VerifyResult:
	problem.validate()
	normalized_target = normalize_app_target(target)
	normalized_sim = normalize_sim_name(sim_name)
	base_dir = cocotb_output_root(problem, normalized_target) / normalized_sim
	build_dir = base_dir / "build"
	test_dir = base_dir / "test"
	log_dir = base_dir / "logs"
	func_cov_dir = base_dir / "functional"
	results_xml = base_dir / "results.xml"
	metrics_path = default_metrics_path(problem, normalized_target)
	hdl_toplevel = hdl_toplevel_for_target(normalized_target)

	for path in (build_dir, test_dir, log_dir, func_cov_dir, metrics_path.parent):
		path.mkdir(parents=True, exist_ok=True)
	if metrics_path.exists():
		metrics_path.unlink()

	if get_runner is None:
		return VerifyResult(
			available=False,
			success=False,
			target=normalized_target,
			simulator=normalized_sim,
			problem=problem.shape,
			tests=0,
			failures=0,
			errors=0,
			message=(
				"缺少 cocotb_tools 依赖，无法运行 verify。"
				f" Import error: {IMPORT_ERROR}"
			),
			results_xml=str(results_xml),
			metrics_path=str(metrics_path),
			algorithms={},
			unsupported_paths={},
		)

	runner = get_runner(normalized_sim)
	build_log = log_dir / "build.log"
	test_log = log_dir / "test.log"
	existing_pythonpath = os.getenv("PYTHONPATH", "")
	pythonpath_entries = [str(REPO_ROOT), str(COCOTB_ROOT)]
	if existing_pythonpath:
		pythonpath_entries.append(existing_pythonpath)

	extra_env = {
		"PYTHONPATH": os.pathsep.join(pythonpath_entries),
		"PT_APP_TARGET": normalized_target,
		"PT_X_DIM": str(PT_PARAMS["GEMM_X_DIM"]),
		"PT_Y_DIM": str(PT_PARAMS["GEMM_Y_DIM"]),
		"PT_DATA_WIDTH": str(PT_PARAMS["DATA_WIDTH"]),
		"PT_A_BASE": str(0x0000_1000),
		"PT_B_BASE": str(0x0000_2000),
		"PT_LUT_DEPTH": str(PT_PARAMS["LUT_DEPTH"]),
		"PT_A_BANK_DEPTH": str(PT_PARAMS["A_BANK_DEPTH"]),
		"PT_B_BANK_DEPTH": str(PT_PARAMS["B_BANK_DEPTH"]),
		"PT_M_BANK_DEPTH": str(PT_PARAMS["M_BANK_DEPTH"]),
		"PT_A_LOAD_LANES": str(PT_PARAMS["A_LOAD_LANES"]),
		"PT_B_LOAD_LANES": str(PT_PARAMS["B_LOAD_LANES"]),
		"PT_M_WRITE_LANES": str(PT_PARAMS["M_WRITE_LANES"]),
		"PT_M_EXPORT_LANES": str(PT_PARAMS["M_EXPORT_LANES"]),
		"PT_M_PHYSICAL_COPIES": str(PT_PARAMS["M_PHYSICAL_COPIES"]),
		"PT_TEST_SEED": "10",
		"PT_SUITE_NAME": "app_verify",
		"PT_RUN_NAME": problem.tag,
		"PT_FUNC_COV_DIR": str(func_cov_dir),
		"PT_APP_METRICS_PATH": str(metrics_path),
		"PT_APP_M_DIM": str(problem.m_dim),
		"PT_APP_K_DIM": str(problem.k_dim),
		"PT_APP_N_DIM": str(problem.n_dim),
	}

	failure_message: Optional[str] = None
	try:
		runner.build(
			sources=_rtl_sources(),
			includes=[RTL_DIR],
			hdl_toplevel=hdl_toplevel,
			parameters=PT_PARAMS,
			build_args=["-Wall"],
			build_dir=build_dir,
			always=True,
			timescale=("1ns", "1ps"),
			waves=waves,
			verbose=False,
			log_file=build_log,
		)
		runner.test(
			test_module=APP_TEST_MODULE,
			hdl_toplevel=hdl_toplevel,
			build_dir=build_dir,
			test_dir=test_dir,
			results_xml=str(results_xml),
			extra_env=extra_env,
			waves=waves,
			verbose=False,
			timescale=("1ns", "1ps"),
			log_file=test_log,
		)
	except SystemExit as exc:
		failure_message = f"verify 退出码异常: {exc.code}"
	except Exception as exc:  # pragma: no cover
		failure_message = str(exc)

	result_counts = _parse_results_xml(results_xml)
	metrics = load_metrics(metrics_path)
	if result_counts["tests"] == 0 and failure_message is None:
		failure_message = "未发现任何 app 本地 cocotb tests，请检查 test discovery / PYTHONPATH。"
	success = (
		failure_message is None
		and result_counts["tests"] > 0
		and result_counts["failures"] == 0
		and result_counts["errors"] == 0
	)
	if not success and failure_message is None:
		failure_message = "cocotb regression 未全部通过，请查看 results.xml / test.log。"

	return VerifyResult(
		available=True,
		success=success,
		target=normalized_target,
		simulator=normalized_sim,
		problem=problem.shape,
		tests=result_counts["tests"],
		failures=result_counts["failures"],
		errors=result_counts["errors"],
		message=failure_message,
		results_xml=str(results_xml),
		metrics_path=str(metrics_path),
		algorithms=metrics.get("algorithms", {}),
		unsupported_paths=metrics.get("unsupported_paths", {}),
	)
