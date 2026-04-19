from __future__ import annotations

import json
import math
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence

from . import (
	APP_TARGET_PT_DMA_TOP,
	DEFAULT_APP_TARGET,
	INV_SCALE_WORD,
	PT_PARAMS,
	ProblemSpec,
	TILE_DIM,
	app_target_label,
	default_metrics_path,
	normalize_app_target,
)
from .perf_adapter import load_perf_baselines


LOAD_CTRL_OVERHEAD_CYCLES = 10
PIPELINED_FIRST_OUTPUT_TILE_CYCLES = 118
PIPELINED_SECOND_K_TILE_OVERLAP_CYCLES = 42
PIPELINED_STEADY_K_TILE_OVERLAP_CYCLES = 59


@dataclass(frozen=True)
class AxisTile:
	axis: str
	index: int
	start: int
	stop: int

	@property
	def label(self) -> str:
		return f"{self.axis.lower()}{self.index}"

	@property
	def expr(self) -> str:
		return f"{self.start}:{self.stop}"

	@property
	def size(self) -> int:
		return self.stop - self.start


@dataclass
class CandidatePlan:
	name: str
	description: str
	command_sequence: List[str]
	estimated_cycles: float
	dma_req_count: int
	export_req_count: int
	export_beats: int
	matadd_count: int
	host_side_add_ops: int
	metric_keys: List[str] = field(default_factory=list)
	notes: List[str] = field(default_factory=list)
	measured_cycles: Optional[float] = None
	measured_dma_req_count: Optional[int] = None
	measured_export_req_count: Optional[int] = None
	measured_export_beats: Optional[int] = None
	measured_matadd_count: Optional[int] = None

	def __post_init__(self) -> None:
		if not self.metric_keys:
			self.metric_keys = [self.name]

	@property
	def ranking_cycles(self) -> float:
		return self.measured_cycles if self.measured_cycles is not None else self.estimated_cycles

	@property
	def ranking_source(self) -> str:
		return "measured" if self.measured_cycles is not None else "estimated"

	def merge_measured(self, payload: Dict[str, Any]) -> None:
		if "total_cycles" in payload:
			self.measured_cycles = float(payload["total_cycles"])
		if "dma_req_count" in payload:
			self.measured_dma_req_count = int(payload["dma_req_count"])
		if "export_req_count" in payload:
			self.measured_export_req_count = int(payload["export_req_count"])
		if "export_beats" in payload:
			self.measured_export_beats = int(payload["export_beats"])
		if "matadd_count" in payload:
			self.measured_matadd_count = int(payload["matadd_count"])

	def to_dict(self) -> Dict[str, Any]:
		payload = asdict(self)
		payload["ranking_cycles"] = self.ranking_cycles
		payload["ranking_source"] = self.ranking_source
		return payload


@dataclass
class UnsupportedPath:
	name: str
	description: str
	status: str
	note: str
	metric_keys: List[str] = field(default_factory=list)
	observed_dma_increment: Optional[int] = None
	observed_same_result: Optional[bool] = None
	observed_result_changed: Optional[bool] = None

	def __post_init__(self) -> None:
		if not self.metric_keys:
			self.metric_keys = [self.name]

	def merge_measured(self, payload: Dict[str, Any]) -> None:
		if "status" in payload:
			self.status = str(payload["status"])
		if "observed_dma_increment" in payload:
			self.observed_dma_increment = int(payload["observed_dma_increment"])
		if "observed_same_result" in payload:
			self.observed_same_result = bool(payload["observed_same_result"])
		if "observed_result_changed" in payload:
			self.observed_result_changed = bool(payload["observed_result_changed"])

	def to_dict(self) -> Dict[str, Any]:
		return asdict(self)


@dataclass
class Recommendation:
	target: str
	target_label: str
	problem_definition: Dict[str, Any]
	notation: str
	pt_tile_shape: str
	per_tensor_inv_scale: str
	tile_summary: Dict[str, int]
	m_tiles: List[AxisTile]
	k_tiles: List[AxisTile]
	n_tiles: List[AxisTile]
	candidates: List[CandidatePlan]
	unsupported_paths: List[UnsupportedPath]
	winner: str
	ranking_source: str
	metrics_path: str
	notes: List[str]

	def to_dict(self) -> Dict[str, Any]:
		return {
			"target": self.target,
			"target_label": self.target_label,
			"problem_definition": self.problem_definition,
			"notation": self.notation,
			"pt_tile_shape": self.pt_tile_shape,
			"per_tensor_inv_scale": self.per_tensor_inv_scale,
			"tile_summary": dict(self.tile_summary),
			"m_tiles": [asdict(item) for item in self.m_tiles],
			"k_tiles": [asdict(item) for item in self.k_tiles],
			"n_tiles": [asdict(item) for item in self.n_tiles],
			"candidates": [item.to_dict() for item in self.candidates],
			"unsupported_paths": [item.to_dict() for item in self.unsupported_paths],
			"winner": self.winner,
			"ranking_source": self.ranking_source,
			"metrics_path": self.metrics_path,
			"notes": list(self.notes),
		}


def load_verify_metrics(metrics_path: Path) -> Dict[str, Any]:
	if not metrics_path.exists():
		return {}
	try:
		return json.loads(metrics_path.read_text(encoding="utf-8"))
	except json.JSONDecodeError:
		return {}


def _build_axis_tiles(axis: str, dim: int) -> List[AxisTile]:
	tile_count = dim // TILE_DIM
	return [
		AxisTile(axis=axis, index=index, start=index * TILE_DIM, stop=(index + 1) * TILE_DIM)
		for index in range(tile_count)
	]


def _tile_export_beats() -> int:
	return PT_PARAMS["GEMM_X_DIM"] * math.ceil(PT_PARAMS["GEMM_Y_DIM"] / PT_PARAMS["M_EXPORT_LANES"])


def _estimate_pipelined_output_tile_cycles(problem: ProblemSpec) -> int:
	"""Empirical app-level fallback for the current 16x16 direct pipeline.

	The cocotb app flow keeps up to 2 MATMULs in flight (limited by
	`M_PHYSICAL_COPIES=2`), so one output tile pays:

	- 118 cycles when `K_tiles == 1`
	- +42 cycles for the second K tile
	- +59 cycles for each additional K tile once the overlap window is full

	This matches the currently re-measured single-output-tile points:
	`16x16x16 -> 117`, `16x32x16 -> 159`, `16x64x16 -> 277`,
	`16x128x16 -> 513` total cycles.
	"""

	if problem.k_tiles <= 1:
		return PIPELINED_FIRST_OUTPUT_TILE_CYCLES
	return (
		PIPELINED_FIRST_OUTPUT_TILE_CYCLES
		+ PIPELINED_SECOND_K_TILE_OVERLAP_CYCLES
		+ max(problem.k_tiles - 2, 0) * PIPELINED_STEADY_K_TILE_OVERLAP_CYCLES
	)


def _build_candidates(problem: ProblemSpec) -> List[CandidatePlan]:
	perf = load_perf_baselines()
	matmul_cold_cycles = perf["cold_miss"].single_tile_latency_cycles
	matmul_hit_cycles = perf["cache_hit"].single_tile_latency_cycles
	load_ab_cycles = perf["cold_miss"].a_load_cycles + perf["cold_miss"].b_load_cycles + LOAD_CTRL_OVERHEAD_CYCLES
	matadd_reduce_cycles = matmul_hit_cycles + perf["cold_miss"].b_load_cycles

	output_tile_count = problem.output_tiles
	partial_matmuls = problem.partial_matmuls
	tile_export_beats = _tile_export_beats()
	host_add_ops = problem.host_add_ops
	matadd_count = output_tile_count * max(problem.k_tiles - 1, 0)
	pipelined_output_tile_cycles = _estimate_pipelined_output_tile_cycles(problem)
	pipelined_total_cycles = (output_tile_count * pipelined_output_tile_cycles) - 1

	return [
		CandidatePlan(
			name="host_reduce_direct_tiled_matmul",
			metric_keys=[
				"host_reduce_direct_tiled_matmul",
				"host_reduce_direct_4x_matmul",
				"numeric_host_reduce_per_tensor",
			],
			description="每个输出 tile 的所有 K-partial 都直接用 MATMUL 计算，partial result 导出后由 host 精确累加。",
			command_sequence=[
				"CFG A_BASE",
				"CFG B_BASE",
				"QCFG(per_tensor, payload=0x0001_0000)",
				"对每个输出 tile C[m_i, n_j]，遍历所有 K tiles：",
				"  MATMUL(A[m_i, k_t], B[k_t, n_j]) -> P_t",
				"HOST: reduce(P_0..P_t) -> C[m_i, n_j]",
			],
			estimated_cycles=partial_matmuls * matmul_cold_cycles,
			dma_req_count=2 * partial_matmuls,
			export_req_count=partial_matmuls,
			export_beats=partial_matmuls * tile_export_beats,
			matadd_count=0,
			host_side_add_ops=host_add_ops,
			notes=[
				"最贴合当前 RTL：所有 partial 只用原生 full-tile MATMUL。",
				f"host 端额外逐元素加法 = (K_tiles-1) * M * N = {host_add_ops}。",
			],
		),
		CandidatePlan(
			name="host_reduce_direct_pipelined",
			metric_keys=["host_reduce_direct_pipelined", "numeric_host_reduce_pipelined"],
			description="和 direct path 一样只做 MATMUL + host reduce，但保持最多 2 个 MATMUL in-flight，重叠下一 tile 的 DMA-fill 与当前 tile 的 compute/export。",
			command_sequence=[
				"CFG A_BASE",
				"CFG B_BASE",
				"QCFG(per_tensor, payload=0x0001_0000)",
				"对每个输出 tile C[m_i, n_j]，遍历所有 K tiles：",
				"  先发起 MATMUL(A[m_i, k_t], B[k_t, n_j])",
				"  在前一个 partial 仍在 compute/export 时继续发下一个 MATMUL",
				"HOST: drain/export 完成后 reduce(P_0..P_t) -> C[m_i, n_j]",
			],
			estimated_cycles=pipelined_total_cycles,
			dma_req_count=2 * partial_matmuls,
			export_req_count=partial_matmuls,
			export_beats=partial_matmuls * tile_export_beats,
			matadd_count=0,
			host_side_add_ops=host_add_ops,
			notes=[
				"当前 app testbench 使用 pipeline_depth=2，受 `M_PHYSICAL_COPIES=2` 限制。",
				"fallback estimate 来自当前 16x16 app-level re-measurement，而不是低层 structural perf model。",
			],
		),
		CandidatePlan(
			name="host_reduce_load_then_matmul",
			description="每个 partial 先显式 LOAD 对应 A/B tile，再执行 MATMUL，最后由 host 精确累加。",
			command_sequence=[
				"CFG A_BASE",
				"CFG B_BASE",
				"QCFG(per_tensor, payload=0x0001_0000)",
				"对每个输出 tile C[m_i, n_j]，遍历所有 K tiles：",
				"  LOAD(A[m_i, k_t], B[k_t, n_j])",
				"  MATMUL(A[m_i, k_t], B[k_t, n_j]) -> P_t",
				"HOST: reduce(P_0..P_t) -> C[m_i, n_j]",
			],
			estimated_cycles=partial_matmuls * (load_ab_cycles + matmul_hit_cycles),
			dma_req_count=2 * partial_matmuls,
			export_req_count=partial_matmuls,
			export_beats=partial_matmuls * tile_export_beats,
			matadd_count=0,
			host_side_add_ops=host_add_ops,
			notes=[
				"相对 direct path，多了显式 LOAD 控制开销。",
			],
		),
		CandidatePlan(
			name="pt_matadd_reduce",
			metric_keys=["pt_matadd_reduce", "numeric_pt_matadd_reduce_per_tensor"],
			description="每个输出 tile 先算所有 K-partial，再在 PT 内用 MATADD 串联归约。",
			command_sequence=[
				"CFG A_BASE",
				"CFG B_BASE",
				"QCFG(per_tensor, payload=0x0001_0000)",
				"对每个输出 tile C[m_i, n_j]：",
				"  MATMUL(A[m_i, k_0], B[k_0, n_j]) -> P0",
				"  MATMUL(A[m_i, k_1], B[k_1, n_j]) -> P1",
				"  MATADD(P1, ext=P0) -> S01",
				"  重复直到完成全部 K tiles",
			],
			estimated_cycles=(partial_matmuls * matmul_cold_cycles) + (matadd_count * matadd_reduce_cycles),
			dma_req_count=(2 * partial_matmuls) + matadd_count,
			export_req_count=partial_matmuls + matadd_count,
			export_beats=(partial_matmuls + matadd_count) * tile_export_beats,
			matadd_count=matadd_count,
			host_side_add_ops=0,
			notes=[
				"host 只负责把上一步 export 结果重新注册成下一次 MATADD 的 external C tile。",
				"MATADD 次数 = output_tiles * (K_tiles - 1)。",
			],
		),
	]


def _build_unsupported_paths(problem: ProblemSpec) -> List[UnsupportedPath]:
	if not problem.supports_same_id_swap:
		return [
			UnsupportedPath(
				name="same_id_k_slice_swap",
				status="not_applicable",
				description="尝试复用同一个 ctrl_id 在同一个输出 tile 上轮换 K-slice。",
				note="K 只有一个 tile，没有下一个 K-slice 可用于轮换实验。",
			)
		]
	return [
		UnsupportedPath(
			name="same_id_k_slice_swap",
			description="尝试复用同一个 ctrl_id，在同一个输出 tile 上轮换到新的 Ai/Bi K-slice。",
			status="unsupported",
			note="A/B residency 是 cache-by-id；不换 ctrl_id 时不会形成预期的新 A/B reload。",
		)
	]


def _lookup_metric(payloads: Dict[str, Any], keys: Sequence[str]) -> Optional[Dict[str, Any]]:
	for key in keys:
		payload = payloads.get(key)
		if payload is not None:
			return payload
	return None


def build_recommendation(
	problem: ProblemSpec,
	metrics_path: Optional[Path] = None,
	verify_metrics: Optional[Dict[str, Any]] = None,
	target: str = DEFAULT_APP_TARGET,
) -> Recommendation:
	problem.validate()
	normalized_target = normalize_app_target(target)
	target_label = app_target_label(normalized_target)
	active_metrics_path = metrics_path or default_metrics_path(problem, normalized_target)
	metrics = verify_metrics or load_verify_metrics(active_metrics_path)

	candidates = _build_candidates(problem)
	unsupported_paths = _build_unsupported_paths(problem)

	measured_algorithms = metrics.get("algorithms", {})
	measured_tests = metrics.get("tests", {})
	for candidate in candidates:
		payload = _lookup_metric(measured_algorithms, candidate.metric_keys)
		if payload is None:
			payload = _lookup_metric(measured_tests, candidate.metric_keys)
		if payload:
			candidate.merge_measured(payload)

	measured_unsupported = metrics.get("unsupported_paths", {})
	for item in unsupported_paths:
		payload = _lookup_metric(measured_unsupported, item.metric_keys)
		if payload:
			item.merge_measured(payload)

	winner_candidate = min(candidates, key=lambda item: item.ranking_cycles)
	measured_count = sum(1 for item in candidates if item.measured_cycles is not None)
	if measured_count == len(candidates):
		ranking_source = "measured"
	elif measured_count > 0:
		ranking_source = "mixed"
	else:
		ranking_source = "estimated"

	tile_summary = {
		"tile_dim": TILE_DIM,
		"m_tiles": problem.m_tiles,
		"k_tiles": problem.k_tiles,
		"n_tiles": problem.n_tiles,
		"output_tiles": problem.output_tiles,
		"partial_matmuls": problem.partial_matmuls,
	}
	notes = [
		f"问题定义：A={problem.m_dim}x{problem.k_dim}，B={problem.k_dim}x{problem.n_dim}，C={problem.m_dim}x{problem.n_dim}。",
		f"当前 app target = {target_label}。",
		f"当前 PT primitive 固定为 {TILE_DIM}x{TILE_DIM}x{TILE_DIM} full-tile MATMUL。",
		f"因此完整问题会被分解成 M_tiles * K_tiles * N_tiles = {problem.partial_matmuls} 次 partial GEMM。",
		f"默认 per_tensor inverse scale 固定为 0x{INV_SCALE_WORD:08x}。",
	]
	if normalized_target == APP_TARGET_PT_DMA_TOP:
		notes.append("该 target 会经过 AXI-Lite CSR + DMA descriptor wrapper，再驱动内部 PT datapath。")
	if ranking_source == "measured":
		notes.append(f"当前 winner 基于 `{active_metrics_path}` 中的实测结果排序。")
	elif ranking_source == "mixed":
		notes.append(f"当前 winner 基于 `{active_metrics_path}` 中的部分实测结果与 fallback estimate 混合排序。")
	else:
		notes.append("当前 winner 基于 app 内的 fallback estimate 排序。")
	if normalized_target == APP_TARGET_PT_DMA_TOP and ranking_source != "measured":
		notes.append("当前 fallback estimate 仍主要基于 native PT datapath，不显式计入 wrapper AXI-Lite / descriptor 开销。")

	return Recommendation(
		target=normalized_target,
		target_label=target_label,
		problem_definition=problem.shape,
		notation=problem.notation,
		pt_tile_shape=f"{PT_PARAMS['GEMM_X_DIM']}x{PT_PARAMS['GEMM_Y_DIM']} full-tile MATMUL",
		per_tensor_inv_scale=f"0x{INV_SCALE_WORD:08x}",
		tile_summary=tile_summary,
		m_tiles=_build_axis_tiles("M", problem.m_dim),
		k_tiles=_build_axis_tiles("K", problem.k_dim),
		n_tiles=_build_axis_tiles("N", problem.n_dim),
		candidates=candidates,
		unsupported_paths=unsupported_paths,
		winner=winner_candidate.name,
		ranking_source=ranking_source,
		metrics_path=str(active_metrics_path),
		notes=notes,
	)


def _format_table(headers: Sequence[str], rows: Iterable[Sequence[object]], right_align: Optional[set[int]] = None) -> str:
	right_align = right_align or set()
	string_rows = [[str(cell) for cell in row] for row in rows]
	widths = [len(header) for header in headers]
	for row in string_rows:
		for index, cell in enumerate(row):
			widths[index] = max(widths[index], len(cell))

	def fmt_row(values: Sequence[str]) -> str:
		cells: List[str] = []
		for index, value in enumerate(values):
			if index in right_align:
				cells.append(value.rjust(widths[index]))
			else:
				cells.append(value.ljust(widths[index]))
		return "| " + " | ".join(cells) + " |"

	separator = "+-" + "-+-".join("-" * width for width in widths) + "-+"
	lines = [separator, fmt_row(headers), separator]
	for row in string_rows:
		lines.append(fmt_row(row))
	lines.append(separator)
	return "\n".join(lines)


def render_text(recommendation: Recommendation) -> str:
	problem_table = _format_table(
		headers=["Field", "Value"],
		rows=[
			["A", f"{recommendation.problem_definition['A'][0]}x{recommendation.problem_definition['A'][1]}"],
			["B", f"{recommendation.problem_definition['B'][0]}x{recommendation.problem_definition['B'][1]}"],
			["C", f"{recommendation.problem_definition['C'][0]}x{recommendation.problem_definition['C'][1]}"],
			["App target", recommendation.target_label],
			["Notation", recommendation.notation],
			["PT primitive", recommendation.pt_tile_shape],
			["per_tensor inv_scale", recommendation.per_tensor_inv_scale],
		],
	)
	tile_table = _format_table(
		headers=["Metric", "Value"],
		rows=[
			["Tile dim", recommendation.tile_summary["tile_dim"]],
			["M tiles", recommendation.tile_summary["m_tiles"]],
			["K tiles", recommendation.tile_summary["k_tiles"]],
			["N tiles", recommendation.tile_summary["n_tiles"]],
			["Output tiles", recommendation.tile_summary["output_tiles"]],
			["Partial GEMMs", recommendation.tile_summary["partial_matmuls"]],
		],
		right_align={1},
	)
	candidate_table = _format_table(
		headers=["Winner", "Algorithm", "Cycles", "Source", "Est", "DMA", "Export", "Beats", "MATADD", "Host Add Ops"],
		rows=[
			[
				"*" if item.name == recommendation.winner else "",
				item.name,
				f"{item.ranking_cycles:.1f}",
				item.ranking_source,
				f"{item.estimated_cycles:.1f}",
				item.measured_dma_req_count if item.measured_dma_req_count is not None else item.dma_req_count,
				item.measured_export_req_count if item.measured_export_req_count is not None else item.export_req_count,
				item.measured_export_beats if item.measured_export_beats is not None else item.export_beats,
				item.measured_matadd_count if item.measured_matadd_count is not None else item.matadd_count,
				item.host_side_add_ops,
			]
			for item in recommendation.candidates
		],
		right_align={2, 4, 5, 6, 7, 8, 9},
	)
	m_table = _format_table(headers=["M Tile", "Range", "Size"], rows=[[tile.label, tile.expr, tile.size] for tile in recommendation.m_tiles], right_align={2})
	k_table = _format_table(headers=["K Tile", "Range", "Size"], rows=[[tile.label, tile.expr, tile.size] for tile in recommendation.k_tiles], right_align={2})
	n_table = _format_table(headers=["N Tile", "Range", "Size"], rows=[[tile.label, tile.expr, tile.size] for tile in recommendation.n_tiles], right_align={2})
	unsupported_table = _format_table(
		headers=["Path", "Status", "DMA Inc", "Same Result", "Note"],
		rows=[
			[
				item.name,
				item.status,
				"-" if item.observed_dma_increment is None else item.observed_dma_increment,
				"-" if item.observed_same_result is None else item.observed_same_result,
				item.note,
			]
			for item in recommendation.unsupported_paths
		],
	)
	lines = [
		"Problem Summary",
		problem_table,
		"",
		"Tile Summary",
		tile_table,
		"",
		"M Tile Ranges",
		m_table,
		"",
		"K Tile Ranges",
		k_table,
		"",
		"N Tile Ranges",
		n_table,
		"",
		"Candidates",
		candidate_table,
		"",
		"Unsupported Paths",
		unsupported_table,
		"",
		f"Winner: {recommendation.winner} ({recommendation.ranking_source})",
		f"Metrics path: {recommendation.metrics_path}",
	]
	return "\n".join(lines)


def build_report_markdown(recommendation: Recommendation, verify_summary: Optional[Dict[str, Any]]) -> str:
	lines = [
		f"# PT Application Report ({recommendation.notation}, target={recommendation.target_label})",
		"",
		"## Corrected Shape / Notation",
		f"- A = {recommendation.problem_definition['A'][0]}x{recommendation.problem_definition['A'][1]}",
		f"- B = {recommendation.problem_definition['B'][0]}x{recommendation.problem_definition['B'][1]}",
		f"- C = {recommendation.problem_definition['C'][0]}x{recommendation.problem_definition['C'][1]}",
		f"- App target: `{recommendation.target_label}`",
		f"- Notation: `{recommendation.notation}`",
		f"- PT primitive: `{recommendation.pt_tile_shape}`",
		f"- per_tensor inverse scale: `{recommendation.per_tensor_inv_scale}`",
		"",
		"## Tile Summary",
		"| Metric | Value |",
		"| --- | ---: |",
	]
	for key, value in recommendation.tile_summary.items():
		lines.append(f"| `{key}` | {value} |")

	lines.extend(
		[
			"",
			"## K-Slice Decomposition",
			"### M Tiles",
			"| Tile | Range | Size |",
			"| --- | --- | ---: |",
		]
	)
	for tile in recommendation.m_tiles:
		lines.append(f"| `{tile.label}` | `{tile.expr}` | {tile.size} |")

	lines.extend(
		[
			"",
			"### K Tiles",
			"| Tile | Range | Size |",
			"| --- | --- | ---: |",
		]
	)
	for tile in recommendation.k_tiles:
		lines.append(f"| `{tile.label}` | `{tile.expr}` | {tile.size} |")

	lines.extend(
		[
			"",
			"### N Tiles",
			"| Tile | Range | Size |",
			"| --- | --- | ---: |",
		]
	)
	for tile in recommendation.n_tiles:
		lines.append(f"| `{tile.label}` | `{tile.expr}` | {tile.size} |")

	lines.extend(
		[
			"",
			"## Reduction Strategy Comparison",
			"| Algorithm | Ranking Cycles | Source | Estimated Cycles | DMA Reqs | Export Reqs | Export Beats | MATADD Count | Host Add Ops |",
			"| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
		]
	)
	for item in recommendation.candidates:
		dma_req = item.measured_dma_req_count if item.measured_dma_req_count is not None else item.dma_req_count
		export_req = item.measured_export_req_count if item.measured_export_req_count is not None else item.export_req_count
		export_beats = item.measured_export_beats if item.measured_export_beats is not None else item.export_beats
		matadd_count = item.measured_matadd_count if item.measured_matadd_count is not None else item.matadd_count
		lines.append(
			f"| `{item.name}` | {item.ranking_cycles:.1f} | {item.ranking_source} | {item.estimated_cycles:.1f} | "
			f"{dma_req} | {export_req} | {export_beats} | {matadd_count} | {item.host_side_add_ops} |"
		)

	lines.extend(
		[
			"",
			"## Recommendation",
			f"- Winner: `{recommendation.winner}`",
			f"- Ranking source: `{recommendation.ranking_source}`",
			"- Reasoning:",
		]
	)
	for note in recommendation.notes:
		lines.append(f"  - {note}")

	lines.extend(
		[
			"",
			"### Command Sequences",
		]
	)
	for item in recommendation.candidates:
		lines.append(f"- `{item.name}`")
		for step in item.command_sequence:
			lines.append(f"  - {step}")
		for note in item.notes:
			lines.append(f"  - Note: {note}")

	lines.extend(
		[
			"",
			"## Unsupported / Not Recommended Paths",
		]
	)
	for item in recommendation.unsupported_paths:
		lines.append(f"- `{item.name}`: {item.note}")
		if item.observed_dma_increment is not None:
			lines.append(f"  - observed_dma_increment: {item.observed_dma_increment}")
		if item.observed_same_result is not None:
			lines.append(f"  - observed_same_result: {item.observed_same_result}")

	lines.extend(
		[
			"",
			"## Verification Results",
		]
	)
	if verify_summary is None:
		lines.append("- 本次 report 未执行 verify，排序使用 fallback estimate。")
	else:
		lines.append(f"- success: {verify_summary.get('success')}")
		target = verify_summary.get("target")
		if target:
			lines.append(f"- target: `{app_target_label(str(target))}`")
		lines.append(f"- simulator: `{verify_summary.get('simulator', 'unknown')}`")
		lines.append(f"- tests: {verify_summary.get('tests', 0)}")
		lines.append(f"- failures: {verify_summary.get('failures', 0)}")
		lines.append(f"- errors: {verify_summary.get('errors', 0)}")
		message = verify_summary.get("message")
		if message:
			lines.append(f"- message: {message}")
		results_xml = verify_summary.get("results_xml")
		if results_xml:
			lines.append(f"- results_xml: `{results_xml}`")
		metrics_path = verify_summary.get("metrics_path")
		if metrics_path:
			lines.append(f"- metrics_path: `{metrics_path}`")

	return "\n".join(lines) + "\n"
