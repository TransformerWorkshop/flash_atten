from __future__ import annotations

import json
import subprocess
import sys
from dataclasses import dataclass
from typing import Dict

from . import PT_PARAMS, REPO_ROOT


@dataclass(frozen=True)
class PerfSnapshot:
	scenario: str
	single_tile_latency_cycles: float
	ctrl_resp_visible_cycles: float
	a_load_cycles: float
	b_load_cycles: float
	export_phase_cycles: float
	internal_total_cycles: float


def _run_perf_model(scenario: str) -> Dict[str, float]:
	cmd = [
		sys.executable,
		str(REPO_ROOT / "scripts" / "pt_perf_model.py"),
		"--x-dim",
		str(PT_PARAMS["GEMM_X_DIM"]),
		"--y-dim",
		str(PT_PARAMS["GEMM_Y_DIM"]),
		"--a-load-lanes",
		str(PT_PARAMS["A_LOAD_LANES"]),
		"--b-load-lanes",
		str(PT_PARAMS["B_LOAD_LANES"]),
		"--m-write-lanes",
		str(PT_PARAMS["M_WRITE_LANES"]),
		"--m-export-lanes",
		str(PT_PARAMS["M_EXPORT_LANES"]),
		"--m-physical-copies",
		str(PT_PARAMS["M_PHYSICAL_COPIES"]),
		"--scenario",
		scenario,
		"--format",
		"json",
	]
	try:
		completed = subprocess.run(
			cmd,
			check=True,
			capture_output=True,
			text=True,
		)
	except subprocess.CalledProcessError as exc:
		raise RuntimeError(
			f"性能模型调用失败: {' '.join(cmd)}\nstdout:\n{exc.stdout}\nstderr:\n{exc.stderr}"
		) from exc
	return json.loads(completed.stdout)


def get_perf_snapshot(scenario: str) -> PerfSnapshot:
	payload = _run_perf_model(scenario)
	return PerfSnapshot(
		scenario=scenario,
		single_tile_latency_cycles=float(payload["single_tile_latency_cycles"]),
		ctrl_resp_visible_cycles=float(payload["ctrl_resp_visible_cycles"]),
		a_load_cycles=float(payload["a_load_cycles"]),
		b_load_cycles=float(payload["b_load_cycles"]),
		export_phase_cycles=float(payload["export_phase_cycles"]),
		internal_total_cycles=float(payload["internal_total_cycles"]),
	)


def load_perf_baselines() -> Dict[str, PerfSnapshot]:
	return {
		"cold_miss": get_perf_snapshot("cold_miss"),
		"cache_hit": get_perf_snapshot("cache_hit"),
		"m_window": get_perf_snapshot("m_window"),
	}

