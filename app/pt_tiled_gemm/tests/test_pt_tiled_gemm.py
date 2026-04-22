from __future__ import annotations

import json
import math
import os
import sys
from pathlib import Path
from typing import Dict, List, Tuple

import cocotb
from cocotb.utils import get_sim_time

REPO_ROOT = Path(__file__).resolve().parents[3]
COCOTB_ROOT = REPO_ROOT / "sim" / "cocotb"
if str(REPO_ROOT) not in sys.path:
	sys.path.insert(0, str(REPO_ROOT))
if str(COCOTB_ROOT) not in sys.path:
	sys.path.insert(0, str(COCOTB_ROOT))

from app.pt_tiled_gemm import ProblemSpec, TILE_DIM, app_target_label, normalize_app_target
from app.pt_tiled_gemm.submission import CommandSubmitter, normalize_submission_mode
from tests.pt_model import (
	PT_SCALE_FULL,
	PT_TILES_1,
	PT_TILES_2,
	DMA_KIND_A,
	DMA_KIND_B,
	build_load_inst,
	build_matadd_inst,
	build_matmul_inst,
	build_mwin_off,
	matmul_row_major,
	to_unsigned,
)

APP_TARGET = normalize_app_target(os.getenv("PT_APP_TARGET", "pt"))
SUBMISSION_MODE = normalize_submission_mode(os.getenv("PT_APP_SUBMISSION_MODE", "legacy"))
if APP_TARGET in {"pt_dma_top", "pt_dma_top_v3"}:
	from tests.pt_dma_top_env import create_env, setup_bases_and_passthrough_qcfg
else:
	from tests.pt_blackbox_env import create_env, setup_bases_and_passthrough_qcfg


CLK_PERIOD_NS = 10


def env_int(name: str, default: int) -> int:
	return int(os.getenv(name, str(default)))


PROBLEM = ProblemSpec(
	m_dim=env_int("PT_APP_M_DIM", 16),
	k_dim=env_int("PT_APP_K_DIM", 64),
	n_dim=env_int("PT_APP_N_DIM", 16),
)
PROBLEM.validate()

PT_X_DIM = env_int("PT_X_DIM", TILE_DIM)
PT_Y_DIM = env_int("PT_Y_DIM", TILE_DIM)
PT_M_EXPORT_LANES = env_int("PT_M_EXPORT_LANES", TILE_DIM)
EXPORT_BEATS_PER_TILE = PT_X_DIM * math.ceil(PT_Y_DIM / PT_M_EXPORT_LANES)
CTRL_ID_POOL_SIZE = env_int("PT_APP_CTRL_ID_POOL_SIZE", env_int("PT_LUT_DEPTH", 8))
CTRL_ID_POOL_BASE = env_int("PT_APP_CTRL_ID_BASE", 0x500)
RECYCLE_INTERVAL = env_int("PT_VERIFY_RECYCLE_INTERVAL", env_int("PT_LUT_DEPTH", 8))


def cycle_now() -> int:
	return int(get_sim_time("ns") // CLK_PERIOD_NS)


def record_metric(section: str, key: str, payload: Dict[str, object]) -> None:
	metrics_path = os.getenv("PT_APP_METRICS_PATH")
	if not metrics_path:
		return
	path = Path(metrics_path)
	path.parent.mkdir(parents=True, exist_ok=True)
	if path.exists():
		try:
			data = json.loads(path.read_text(encoding="utf-8"))
		except json.JSONDecodeError:
			data = {}
	else:
		data = {}
	data.setdefault(section, {})[key] = payload
	path.write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")


def build_submitter(env, *, ctrl_id_base: int) -> CommandSubmitter:
	return CommandSubmitter(
		env,
		target=APP_TARGET,
		submission_mode=SUBMISSION_MODE,
		ctrl_id_base=ctrl_id_base,
		ctrl_id_pool_size=CTRL_ID_POOL_SIZE,
	)


async def recycle_runtime_if_needed(env, commands_in_window: int, commands_needed: int, *, phase: str) -> int:
	if (commands_in_window != 0) and ((commands_in_window + commands_needed) > RECYCLE_INTERVAL):
		if APP_TARGET in {"pt_dma_top", "pt_dma_top_v3"}:
			await env.soft_clear()
		else:
			await env.pulse_clear(phase=phase)
			await setup_bases_and_passthrough_qcfg(env)
		return 0
	return commands_in_window


async def submission_metrics(env, submitter: CommandSubmitter, perf_counter_base=None) -> Dict[str, object]:
	payload: Dict[str, object] = {
		"submission_mode": submitter.submission_mode,
		"command_count": submitter.stats.command_count,
		"axil_writes_total": submitter.stats.axil_writes_total,
		"axil_writes_per_command": submitter.stats.axil_writes_per_command,
		"descriptor_push_count": submitter.stats.descriptor_push_count,
	}
	if APP_TARGET in {"pt_dma_top", "pt_dma_top_v3"} and hasattr(env, "read_perf_counters"):
		counters = await env.read_perf_counters()
		if perf_counter_base is not None:
			counters = counters.delta(perf_counter_base)
		payload.update(
			{
				"perf_axil_write_count": counters.axil_write_count,
				"perf_command_push_count": counters.command_push_count,
				"perf_pt_accept_count": counters.pt_accept_count,
				"perf_resp_enqueue_count": counters.resp_enqueue_count,
				"perf_wr_dma_done_count": counters.wr_dma_done_count,
				"perf_compact_commit_count": counters.compact_commit_count,
				"perf_push_to_accept_cycles": counters.push_to_accept_cycles,
				"perf_accept_to_resp_cycles": counters.accept_to_resp_cycles,
				"perf_resp_to_done_cycles": counters.resp_to_done_cycles,
			}
		)
	return payload


def build_problem(problem: ProblemSpec) -> Tuple[List[int], List[int]]:
	a_matrix = [
		to_unsigned(1 + (((row % 5) + 2 * (col // TILE_DIM) + ((col % TILE_DIM) % 3)) % 8), 32)
		for row in range(problem.m_dim)
		for col in range(problem.k_dim)
	]
	b_matrix = [
		to_unsigned(1 + (((col % 5) + 3 * (row // TILE_DIM) + ((row % TILE_DIM) % 4)) % 8), 32)
		for row in range(problem.k_dim)
		for col in range(problem.n_dim)
	]
	return a_matrix, b_matrix


def extract_a_tile(problem: ProblemSpec, a_matrix: List[int], m_tile: int, k_tile: int) -> List[int]:
	row_base = m_tile * TILE_DIM
	col_base = k_tile * TILE_DIM
	return [
		a_matrix[(row_base + row) * problem.k_dim + (col_base + col)]
		for row in range(TILE_DIM)
		for col in range(TILE_DIM)
	]


def extract_b_tile(problem: ProblemSpec, b_matrix: List[int], k_tile: int, n_tile: int) -> List[int]:
	row_base = k_tile * TILE_DIM
	col_base = n_tile * TILE_DIM
	return [
		b_matrix[(row_base + row) * problem.n_dim + (col_base + col)]
		for row in range(TILE_DIM)
		for col in range(TILE_DIM)
	]


def place_c_tile(problem: ProblemSpec, c_matrix: List[int], tile: List[int], m_tile: int, n_tile: int) -> None:
	row_base = m_tile * TILE_DIM
	col_base = n_tile * TILE_DIM
	for row in range(TILE_DIM):
		for col in range(TILE_DIM):
			c_matrix[(row_base + row) * problem.n_dim + (col_base + col)] = tile[row * TILE_DIM + col]


def reduce_partials(partials: List[List[int]]) -> List[int]:
	if not partials:
		return []
	result: List[int] = []
	for elem_idx in range(len(partials[0])):
		total = 0
		for partial in partials:
			total += int(partial[elem_idx])
		result.append(to_unsigned(total, 32))
	return result


def make_perf_a_matrix(x_dim: int, m_tiles: int, k_tiles: int) -> List[int]:
	m_dim = x_dim * m_tiles
	k_dim = x_dim * k_tiles
	return [
		((row * 3) + (col % x_dim) + (row // x_dim) * 5 + (col // x_dim) * 7 + 1)
		for row in range(m_dim)
		for col in range(k_dim)
	]


def make_perf_b_matrix(y_dim: int, k_tiles: int, n_tiles: int) -> List[int]:
	k_dim = y_dim * k_tiles
	n_dim = y_dim * n_tiles
	return [
		((col * 2) + (row % y_dim) + (col // y_dim) * 4 + (row // y_dim) * 6 + 1)
		for row in range(k_dim)
		for col in range(n_dim)
	]


async def run_matmul_tile(env, submitter: CommandSubmitter, ctrl_id: int, a_tile: List[int], b_tile: List[int]) -> Tuple[List[int], int, int]:
	env.register_external_matrix("A", ctrl_id, a_tile)
	env.register_external_matrix("B", ctrl_id, b_tile)
	plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
	assert not plan.err
	await submitter.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
	accept_cycle = cycle_now()
	resp = await env.wait_ctrl_resp(plan.response_word, 40000)
	env.model.commit_success(plan)
	await env.wait_export_done(env.export_done_count + 1, 80000)
	assert plan.result_matrix is not None
	return list(plan.result_matrix), (resp >> 30) & 0x1, accept_cycle


async def run_matadd_tile(env, submitter: CommandSubmitter, ctrl_id: int, m_buf: int, ext_matrix: List[int]) -> List[int]:
	env.register_external_matrix("C", ctrl_id, ext_matrix)
	m_off = build_mwin_off(m_buf, 0)
	plan = env.plan_matadd(ctrl_id, m_off)
	assert not plan.err
	await submitter.send_ctrl(build_matadd_inst(m_off), ctrl_id)
	await env.wait_ctrl_resp(plan.response_word, 40000)
	env.model.commit_success(plan)
	await env.wait_export_done(env.export_done_count + 1, 80000)
	assert plan.result_matrix is not None
	return list(plan.result_matrix)


async def prepare_env(env) -> Tuple[List[int], List[int], List[int]]:
	await env.reset()
	await setup_bases_and_passthrough_qcfg(env)
	a_full, b_full = build_problem(PROBLEM)
	golden = [to_unsigned(value, 32) for value in matmul_row_major(a_full, b_full, PROBLEM.m_dim, PROBLEM.n_dim, PROBLEM.k_dim)]
	record_metric(
		"metadata",
		"problem",
		{
			"target": APP_TARGET,
			"target_label": app_target_label(APP_TARGET),
			"submission_mode": SUBMISSION_MODE,
			"m_dim": PROBLEM.m_dim,
			"k_dim": PROBLEM.k_dim,
			"n_dim": PROBLEM.n_dim,
			"m_tiles": PROBLEM.m_tiles,
			"k_tiles": PROBLEM.k_tiles,
			"n_tiles": PROBLEM.n_tiles,
		},
	)
	return a_full, b_full, golden


async def run_host_reduce_direct(env, submitter: CommandSubmitter, a_full: List[int], b_full: List[int]) -> Dict[str, object]:
	snapshot = env.snapshot()
	start_cycle = None
	c_full = [0] * (PROBLEM.m_dim * PROBLEM.n_dim)
	ctrl_seed = 0
	commands_in_window = 0
	for m_tile in range(PROBLEM.m_tiles):
		for n_tile in range(PROBLEM.n_tiles):
			commands_in_window = await recycle_runtime_if_needed(
				env,
				commands_in_window,
				PROBLEM.k_tiles,
				phase="verify_host_reduce_direct",
			)
			partials: List[List[int]] = []
			for k_tile in range(PROBLEM.k_tiles):
				ctrl_id = submitter.acquire_ctrl_id(0x500 + ctrl_seed)
				ctrl_seed += 1
				partial, _, accept_cycle = await run_matmul_tile(
					env,
					submitter,
					ctrl_id,
					extract_a_tile(PROBLEM, a_full, m_tile, k_tile),
					extract_b_tile(PROBLEM, b_full, k_tile, n_tile),
				)
				if start_cycle is None:
					start_cycle = accept_cycle
				partials.append(partial)
				submitter.release_ctrl_id(ctrl_id)
			place_c_tile(PROBLEM, c_full, reduce_partials(partials), m_tile, n_tile)
			commands_in_window += PROBLEM.k_tiles
	assert start_cycle is not None
	return {
		"name": "host_reduce_direct_tiled_matmul",
		"total_cycles": cycle_now() - start_cycle,
		"dma_req_count": env.dma_req_count - snapshot.dma_req_count,
		"export_req_count": env.export_req_count - snapshot.export_req_count,
		"export_beats": (env.export_req_count - snapshot.export_req_count) * EXPORT_BEATS_PER_TILE,
		"matadd_count": 0,
		"final_matrix": c_full,
	}


async def run_host_reduce_direct_pipelined(env, submitter: CommandSubmitter, a_full: List[int], b_full: List[int]) -> Dict[str, object]:
	"""Like run_host_reduce_direct but keeps up to 2 MATMULs in-flight
	(limited by M_PHYSICAL_COPIES=2).  The next MATMUL is dispatched before
	draining the previous one, so the DUT can overlap DMA-fill of tile N+1
	with compute/export of tile N."""
	snapshot = env.snapshot()
	start_cycle = None
	c_full = [0] * (PROBLEM.m_dim * PROBLEM.n_dim)
	ctrl_seed = 0
	pipeline_depth = 2
	commands_in_window = 0
	for m_tile in range(PROBLEM.m_tiles):
		for n_tile in range(PROBLEM.n_tiles):
			commands_in_window = await recycle_runtime_if_needed(
				env,
				commands_in_window,
				PROBLEM.k_tiles,
				phase="verify_host_reduce_direct_pipelined",
			)
			inflight: List[Tuple] = []
			partials: List[List[int]] = []
			export_base = env.export_done_count
			n_sent = 0
			for k_tile in range(PROBLEM.k_tiles):
				# drain oldest if window is full
				if len(inflight) >= pipeline_depth:
					plan_old, exp_target, done_ctrl_id = inflight.pop(0)
					await env.wait_ctrl_resp(plan_old.response_word, 80000)
					env.model.commit_success(plan_old)
					await env.wait_export_done(exp_target, 80000)
					assert plan_old.result_matrix is not None
					partials.append(list(plan_old.result_matrix))
					submitter.release_ctrl_id(done_ctrl_id)
				ctrl_id = submitter.acquire_ctrl_id(0xA00 + ctrl_seed)
				ctrl_seed += 1
				env.register_external_matrix("A", ctrl_id, extract_a_tile(PROBLEM, a_full, m_tile, k_tile))
				env.register_external_matrix("B", ctrl_id, extract_b_tile(PROBLEM, b_full, k_tile, n_tile))
				plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
				assert not plan.err
				await submitter.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
				if start_cycle is None:
					start_cycle = cycle_now()
				n_sent += 1
				inflight.append((plan, export_base + n_sent, ctrl_id))
			# drain remaining
			for plan_rem, exp_target, done_ctrl_id in inflight:
				await env.wait_ctrl_resp(plan_rem.response_word, 80000)
				env.model.commit_success(plan_rem)
				await env.wait_export_done(exp_target, 80000)
				assert plan_rem.result_matrix is not None
				partials.append(list(plan_rem.result_matrix))
				submitter.release_ctrl_id(done_ctrl_id)
			place_c_tile(PROBLEM, c_full, reduce_partials(partials), m_tile, n_tile)
			commands_in_window += PROBLEM.k_tiles
	assert start_cycle is not None
	return {
		"name": "host_reduce_direct_pipelined",
		"total_cycles": cycle_now() - start_cycle,
		"dma_req_count": env.dma_req_count - snapshot.dma_req_count,
		"export_req_count": env.export_req_count - snapshot.export_req_count,
		"export_beats": (env.export_req_count - snapshot.export_req_count) * EXPORT_BEATS_PER_TILE,
		"matadd_count": 0,
		"final_matrix": c_full,
	}


async def run_host_reduce_load_then_matmul(env, submitter: CommandSubmitter, a_full: List[int], b_full: List[int]) -> Dict[str, object]:
	snapshot = env.snapshot()
	start_cycle = None
	c_full = [0] * (PROBLEM.m_dim * PROBLEM.n_dim)
	ctrl_seed = 0
	commands_in_window = 0
	for m_tile in range(PROBLEM.m_tiles):
		for n_tile in range(PROBLEM.n_tiles):
			commands_in_window = await recycle_runtime_if_needed(
				env,
				commands_in_window,
				2 * PROBLEM.k_tiles,
				phase="verify_load_then_matmul",
			)
			partials: List[List[int]] = []
			for k_tile in range(PROBLEM.k_tiles):
				ctrl_id = submitter.acquire_ctrl_id(0x900 + ctrl_seed)
				ctrl_seed += 1
				a_tile = extract_a_tile(PROBLEM, a_full, m_tile, k_tile)
				b_tile = extract_b_tile(PROBLEM, b_full, k_tile, n_tile)
				env.register_external_matrix("A", ctrl_id, a_tile)
				env.register_external_matrix("B", ctrl_id, b_tile)
				load_plan = env.plan_load(ctrl_id, len(a_tile), len(b_tile), need_a=True, need_b=True)
				assert not load_plan.err
				await submitter.send_ctrl(build_load_inst(len(a_tile), len(b_tile), need_a=True, need_b=True), ctrl_id)
				if start_cycle is None:
					start_cycle = cycle_now()
				await env.wait_ctrl_resp(load_plan.response_word, 40000)
				env.model.commit_load_success(load_plan)

				matmul_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
				assert not matmul_plan.err
				assert len(matmul_plan.expected_dma_loads) == 0
				await submitter.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
				await env.wait_ctrl_resp(matmul_plan.response_word, 40000)
				env.model.commit_success(matmul_plan)
				await env.wait_export_done(env.export_done_count + 1, 80000)
				assert matmul_plan.result_matrix is not None
				partials.append(list(matmul_plan.result_matrix))
				submitter.release_ctrl_id(ctrl_id)
			place_c_tile(PROBLEM, c_full, reduce_partials(partials), m_tile, n_tile)
			commands_in_window += 2 * PROBLEM.k_tiles
	assert start_cycle is not None
	return {
		"name": "host_reduce_load_then_matmul",
		"total_cycles": cycle_now() - start_cycle,
		"dma_req_count": env.dma_req_count - snapshot.dma_req_count,
		"export_req_count": env.export_req_count - snapshot.export_req_count,
		"export_beats": (env.export_req_count - snapshot.export_req_count) * EXPORT_BEATS_PER_TILE,
		"matadd_count": 0,
		"final_matrix": c_full,
	}


async def run_pt_matadd_reduce(env, submitter: CommandSubmitter, a_full: List[int], b_full: List[int]) -> Dict[str, object]:
	snapshot = env.snapshot()
	start_cycle = None
	c_full = [0] * (PROBLEM.m_dim * PROBLEM.n_dim)
	ctrl_seed = 0
	add_seed = 0
	matadd_count = 0
	commands_in_window = 0
	for m_tile in range(PROBLEM.m_tiles):
		for n_tile in range(PROBLEM.n_tiles):
			commands_in_window = await recycle_runtime_if_needed(
				env,
				commands_in_window,
				PROBLEM.k_tiles + max(0, PROBLEM.k_tiles - 1),
				phase="verify_pt_matadd_reduce",
			)
			running_sum: List[int] | None = None
			for k_tile in range(PROBLEM.k_tiles):
				ctrl_id = submitter.acquire_ctrl_id(0xD00 + ctrl_seed)
				ctrl_seed += 1
				partial, m_buf, accept_cycle = await run_matmul_tile(
					env,
					submitter,
					ctrl_id,
					extract_a_tile(PROBLEM, a_full, m_tile, k_tile),
					extract_b_tile(PROBLEM, b_full, k_tile, n_tile),
				)
				if start_cycle is None:
					start_cycle = accept_cycle
				if running_sum is None:
					running_sum = partial
					submitter.release_ctrl_id(ctrl_id)
					continue
				submitter.release_ctrl_id(ctrl_id)
				add_ctrl_id = submitter.acquire_ctrl_id(0xE00 + add_seed)
				running_sum = await run_matadd_tile(env, submitter, add_ctrl_id, m_buf, running_sum)
				submitter.release_ctrl_id(add_ctrl_id)
				add_seed += 1
				matadd_count += 1
			assert running_sum is not None
			place_c_tile(PROBLEM, c_full, running_sum, m_tile, n_tile)
			commands_in_window += PROBLEM.k_tiles + max(0, PROBLEM.k_tiles - 1)
	assert start_cycle is not None
	return {
		"name": "pt_matadd_reduce",
		"total_cycles": cycle_now() - start_cycle,
		"dma_req_count": env.dma_req_count - snapshot.dma_req_count,
		"export_req_count": env.export_req_count - snapshot.export_req_count,
		"export_beats": (env.export_req_count - snapshot.export_req_count) * EXPORT_BEATS_PER_TILE,
		"matadd_count": matadd_count,
		"final_matrix": c_full,
	}


@cocotb.test()
async def test_numeric_host_reduce_per_tensor(dut) -> None:
	env = await create_env(dut)
	try:
		submitter = build_submitter(env, ctrl_id_base=CTRL_ID_POOL_BASE)
		a_full, b_full, golden = await prepare_env(env)
		perf_counter_base = await env.read_perf_counters() if APP_TARGET in {"pt_dma_top", "pt_dma_top_v3"} and hasattr(env, "read_perf_counters") else None
		result = await run_host_reduce_direct(env, submitter, a_full, b_full)
		assert result["final_matrix"] == golden
		metric_payload = {"status": "passed", "total_cycles": result["total_cycles"]}
		metric_payload.update(await submission_metrics(env, submitter, perf_counter_base))
		record_metric("tests", "numeric_host_reduce_per_tensor", metric_payload)
	finally:
		env.shutdown()


@cocotb.test()
async def test_numeric_host_reduce_pipelined(dut) -> None:
	env = await create_env(dut)
	try:
		submitter = build_submitter(env, ctrl_id_base=CTRL_ID_POOL_BASE + 0x100)
		a_full, b_full, golden = await prepare_env(env)
		perf_counter_base = await env.read_perf_counters() if APP_TARGET in {"pt_dma_top", "pt_dma_top_v3"} and hasattr(env, "read_perf_counters") else None
		result = await run_host_reduce_direct_pipelined(env, submitter, a_full, b_full)
		assert result["final_matrix"] == golden
		metric_payload = {"status": "passed", "total_cycles": result["total_cycles"]}
		metric_payload.update(await submission_metrics(env, submitter, perf_counter_base))
		record_metric("tests", "numeric_host_reduce_pipelined", metric_payload)
	finally:
		env.shutdown()


@cocotb.test()
async def test_numeric_pt_matadd_reduce_per_tensor(dut) -> None:
	env = await create_env(dut)
	try:
		submitter = build_submitter(env, ctrl_id_base=CTRL_ID_POOL_BASE + 0x200)
		a_full, b_full, golden = await prepare_env(env)
		perf_counter_base = await env.read_perf_counters() if APP_TARGET in {"pt_dma_top", "pt_dma_top_v3"} and hasattr(env, "read_perf_counters") else None
		result = await run_pt_matadd_reduce(env, submitter, a_full, b_full)
		assert result["final_matrix"] == golden
		metric_payload = {"status": "passed", "total_cycles": result["total_cycles"]}
		metric_payload.update(await submission_metrics(env, submitter, perf_counter_base))
		record_metric("tests", "numeric_pt_matadd_reduce_per_tensor", metric_payload)
	finally:
		env.shutdown()


@cocotb.test()
async def test_same_id_cannot_rotate_k_slice_operands(dut) -> None:
	env = await create_env(dut)
	try:
		submitter = build_submitter(env, ctrl_id_base=CTRL_ID_POOL_BASE + 0x300)
		a_full, b_full, _ = await prepare_env(env)
		if not PROBLEM.supports_same_id_swap:
			record_metric(
				"unsupported_paths",
				"same_id_k_slice_swap",
				{"status": "not_applicable", "reason": "K has only one tile"},
			)
			return

		ctrl_id = 0x5C0
		a_tile0 = extract_a_tile(PROBLEM, a_full, 0, 0)
		b_tile0 = extract_b_tile(PROBLEM, b_full, 0, 0)
		a_tile1 = extract_a_tile(PROBLEM, a_full, 0, 1)
		b_tile1 = extract_b_tile(PROBLEM, b_full, 1, 0)

		expected_slice1 = [to_unsigned(value, 32) for value in matmul_row_major(a_tile1, b_tile1, TILE_DIM, TILE_DIM, TILE_DIM)]
		first_result, _, _ = await run_matmul_tile(env, submitter, ctrl_id, a_tile0, b_tile0)
		assert first_result != expected_slice1
		dma_after_first = env.dma_req_count

		env.register_external_matrix("A", ctrl_id, a_tile1)
		env.register_external_matrix("B", ctrl_id, b_tile1)
		second_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert not second_plan.err
		assert len(second_plan.expected_dma_loads) == 0
		await submitter.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(second_plan.response_word, 40000)
		env.model.commit_success(second_plan)
		await env.wait_export_done(env.export_done_count + 1, 80000)
		assert second_plan.result_matrix is not None
		assert env.dma_req_count == dma_after_first
		assert list(second_plan.result_matrix) == first_result
		assert list(second_plan.result_matrix) != expected_slice1

		record_metric(
			"unsupported_paths",
			"same_id_k_slice_swap",
			{
				"status": "unsupported",
				"observed_dma_increment": env.dma_req_count - dma_after_first,
				"observed_same_result": list(second_plan.result_matrix) == first_result,
				"observed_result_changed": list(second_plan.result_matrix) == expected_slice1,
			},
		)
	finally:
		env.shutdown()


@cocotb.test()
async def test_algorithm_compare_reduction_strategies(dut) -> None:
	env = await create_env(dut)
	try:
		submitter = build_submitter(env, ctrl_id_base=CTRL_ID_POOL_BASE + 0x400)
		a_full, b_full, golden = await prepare_env(env)
		perf_counter_base = await env.read_perf_counters() if APP_TARGET in {"pt_dma_top", "pt_dma_top_v3"} and hasattr(env, "read_perf_counters") else None
		direct = await run_host_reduce_direct(env, submitter, a_full, b_full)
		assert direct["final_matrix"] == golden
		record_metric(
			"algorithms",
			direct["name"],
			{
				"total_cycles": direct["total_cycles"],
				"dma_req_count": direct["dma_req_count"],
				"export_req_count": direct["export_req_count"],
				"export_beats": direct["export_beats"],
				"matadd_count": direct["matadd_count"],
				**(await submission_metrics(env, submitter, perf_counter_base)),
			},
		)

		submitter = build_submitter(env, ctrl_id_base=CTRL_ID_POOL_BASE + 0x500)
		a_full, b_full, golden = await prepare_env(env)
		perf_counter_base = await env.read_perf_counters() if APP_TARGET in {"pt_dma_top", "pt_dma_top_v3"} and hasattr(env, "read_perf_counters") else None
		load_then = await run_host_reduce_load_then_matmul(env, submitter, a_full, b_full)
		assert load_then["final_matrix"] == golden
		record_metric(
			"algorithms",
			load_then["name"],
			{
				"total_cycles": load_then["total_cycles"],
				"dma_req_count": load_then["dma_req_count"],
				"export_req_count": load_then["export_req_count"],
				"export_beats": load_then["export_beats"],
				"matadd_count": load_then["matadd_count"],
				**(await submission_metrics(env, submitter, perf_counter_base)),
			},
		)

		submitter = build_submitter(env, ctrl_id_base=CTRL_ID_POOL_BASE + 0x600)
		a_full, b_full, golden = await prepare_env(env)
		perf_counter_base = await env.read_perf_counters() if APP_TARGET in {"pt_dma_top", "pt_dma_top_v3"} and hasattr(env, "read_perf_counters") else None
		pt_reduce = await run_pt_matadd_reduce(env, submitter, a_full, b_full)
		assert pt_reduce["final_matrix"] == golden
		record_metric(
			"algorithms",
			pt_reduce["name"],
			{
				"total_cycles": pt_reduce["total_cycles"],
				"dma_req_count": pt_reduce["dma_req_count"],
				"export_req_count": pt_reduce["export_req_count"],
				"export_beats": pt_reduce["export_beats"],
				"matadd_count": pt_reduce["matadd_count"],
				**(await submission_metrics(env, submitter, perf_counter_base)),
			},
		)

		submitter = build_submitter(env, ctrl_id_base=CTRL_ID_POOL_BASE + 0x700)
		a_full, b_full, golden = await prepare_env(env)
		perf_counter_base = await env.read_perf_counters() if APP_TARGET in {"pt_dma_top", "pt_dma_top_v3"} and hasattr(env, "read_perf_counters") else None
		pipelined = await run_host_reduce_direct_pipelined(env, submitter, a_full, b_full)
		assert pipelined["final_matrix"] == golden
		record_metric(
			"algorithms",
			pipelined["name"],
			{
				"total_cycles": pipelined["total_cycles"],
				"dma_req_count": pipelined["dma_req_count"],
				"export_req_count": pipelined["export_req_count"],
				"export_beats": pipelined["export_beats"],
				"matadd_count": pipelined["matadd_count"],
				**(await submission_metrics(env, submitter, perf_counter_base)),
			},
		)

		assert pt_reduce["total_cycles"] >= direct["total_cycles"]
		assert load_then["total_cycles"] >= direct["total_cycles"]
		assert direct["total_cycles"] >= pipelined["total_cycles"]
		winner = pipelined["name"] if pipelined["total_cycles"] < direct["total_cycles"] else direct["name"]
		record_metric("tests", "algorithm_compare_reduction_strategies", {"status": "passed", "winner": winner})
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_dma_top_ce_md_block_breakdown(dut) -> None:
	if APP_TARGET not in {"pt_dma_top", "pt_dma_top_v3"}:
		record_metric(
			"diagnostics",
			"pt_ce_md_block_breakdown",
			{"status": "skipped", "reason": "PT_DMA_TOP only"},
		)
		return

	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)

		cases = [
			{
				"name": "m1_n1_k2",
				"ctrl_id": 0xF100,
				"m_tiles": PT_TILES_1,
				"n_tiles": PT_TILES_1,
				"k_tiles": PT_TILES_2,
			},
			{
				"name": "m2_n2_k1",
				"ctrl_id": 0xF200,
				"m_tiles": PT_TILES_2,
				"n_tiles": PT_TILES_2,
				"k_tiles": PT_TILES_1,
			},
		]

		results: Dict[str, object] = {}
		for case in cases:
			ctrl_id = case["ctrl_id"]
			m_tiles = case["m_tiles"]
			n_tiles = case["n_tiles"]
			k_tiles = case["k_tiles"]
			inst = build_matmul_inst(m_tiles, n_tiles, k_tiles)
			env.register_external_matrix("A", ctrl_id, make_perf_a_matrix(env.x_dim, m_tiles, k_tiles))
			env.register_external_matrix("B", ctrl_id, make_perf_b_matrix(env.y_dim, k_tiles, n_tiles))

			trace = await env.send_desc_command_timed(
				inst,
				ctrl_id,
				a_addr=0x1000_1000 + ((ctrl_id & 0xFF) << 8),
				b_addr=0x2000_1000 + ((ctrl_id & 0xFF) << 8),
				m_addr=0x4000_1000 + ((ctrl_id & 0xFF) << 8),
				mode="compact",
			)
			plan = env.plan_matmul(ctrl_id, m_scale=m_tiles, n_scale=n_tiles, k_scale=k_tiles)

			accept = await env.wait_pt_ctrl_accept(ctrl_id, after_cycle=trace.ctrl_write_start_cycle)
			malloc_issue = await env.wait_malloc_issue(ctrl_id, after_cycle=accept.cycle)

			fill_req_a = await env.wait_fill_req(ctrl_id, DMA_KIND_A, after_cycle=malloc_issue.cycle)
			rd_a = await env.wait_rd_transfer(ctrl_id, DMA_KIND_A, after_cycle=fill_req_a.cycle)
			fill_done_a = await env.wait_fill_done(ctrl_id, DMA_KIND_A, after_cycle=rd_a.last_beat_cycle)

			fill_req_b = await env.wait_fill_req(ctrl_id, DMA_KIND_B, after_cycle=fill_done_a.cycle)
			rd_b = await env.wait_rd_transfer(ctrl_id, DMA_KIND_B, after_cycle=fill_req_b.cycle)
			fill_done_b = await env.wait_fill_done(ctrl_id, DMA_KIND_B, after_cycle=rd_b.last_beat_cycle)

			ce_cmd = await env.wait_ce_cmd(ctrl_id, after_cycle=fill_done_b.cycle)
			ce_resp = await env.wait_ce_resp(plan.response_word, after_cycle=ce_cmd.cycle)

			ce_exec_reqs = [
				item for item in env.ce_exec_req_log
				if item.ctrl_id == (ctrl_id & 0xFFFF_FFFF) and (ce_cmd.cycle <= item.cycle <= ce_resp.cycle)
			]
			ce_exec_rsps = [
				item for item in env.ce_exec_rsp_log
				if item.ctrl_id == (ctrl_id & 0xFFFF_FFFF) and (ce_cmd.cycle <= item.cycle <= ce_resp.cycle)
			]
			ce_exec_completes = [
				item for item in env.ce_exec_complete_log
				if item.ctrl_id == (ctrl_id & 0xFFFF_FFFF) and (ce_cmd.cycle <= item.cycle <= ce_resp.cycle)
			]
			ce_drain_accepts = [
				item for item in env.ce_drain_accept_log
				if item.ctrl_id == (ctrl_id & 0xFFFF_FFFF) and (ce_cmd.cycle <= item.cycle <= ce_resp.cycle)
			]
			ce_drain_completes = [
				item for item in env.ce_drain_complete_log
				if item.ctrl_id == (ctrl_id & 0xFFFF_FFFF) and (ce_cmd.cycle <= item.cycle <= ce_resp.cycle)
			]

			assert ce_exec_reqs
			assert ce_exec_rsps
			assert ce_exec_completes
			assert ce_drain_accepts
			assert ce_drain_completes

			ce_exec_req_first = ce_exec_reqs[0]
			ce_exec_rsp_first = ce_exec_rsps[0]
			ce_exec_complete_last = ce_exec_completes[-1]
			ce_drain_accept_first = ce_drain_accepts[0]
			ce_drain_complete_last = ce_drain_completes[-1]

			export_done_target = env.export_done_count + 1
			wr_transfer = await env.wait_wr_transfer(ctrl_id, after_cycle=ce_resp.cycle)
			ctrl_resp = await env.wait_resp_visible(plan.response_word, after_cycle=ce_resp.cycle)
			await env.wait_and_pop_resp(plan.response_word, 40000)
			await env.wait_export_done(export_done_target, 80000)

			results[case["name"]] = {
				"shape_tiles": {
					"m_tiles": m_tiles,
					"n_tiles": n_tiles,
					"k_tiles": k_tiles,
				},
				"top_level": {
					"accept_to_ctrl_resp": ctrl_resp.cycle - accept.cycle,
					"ce_resp_to_ctrl_resp": ctrl_resp.cycle - ce_resp.cycle,
					"ctrl_resp_to_wr_desc": wr_transfer.desc_cycle - ctrl_resp.cycle,
				},
				"pt_md_v2": {
					"accept_to_malloc_issue": malloc_issue.cycle - accept.cycle,
					"a_fill": {
						"fill_req_to_rd_desc": rd_a.desc_cycle - fill_req_a.cycle,
						"rd_desc_to_first_beat": rd_a.first_beat_cycle - rd_a.desc_cycle,
						"first_beat_to_last_beat": rd_a.last_beat_cycle - rd_a.first_beat_cycle,
						"last_beat_to_fill_done": fill_done_a.cycle - rd_a.last_beat_cycle,
						"fill_req_to_fill_done": fill_done_a.cycle - fill_req_a.cycle,
					},
					"b_fill": {
						"fill_req_to_rd_desc": rd_b.desc_cycle - fill_req_b.cycle,
						"rd_desc_to_first_beat": rd_b.first_beat_cycle - rd_b.desc_cycle,
						"first_beat_to_last_beat": rd_b.last_beat_cycle - rd_b.first_beat_cycle,
						"last_beat_to_fill_done": fill_done_b.cycle - rd_b.last_beat_cycle,
						"fill_req_to_fill_done": fill_done_b.cycle - fill_req_b.cycle,
					},
					"export": {
						"ce_resp_to_wr_desc": wr_transfer.desc_cycle - ce_resp.cycle,
						"wr_desc_to_first_beat": wr_transfer.first_beat_cycle - wr_transfer.desc_cycle,
						"first_beat_to_last_beat": wr_transfer.last_beat_cycle - wr_transfer.first_beat_cycle,
						"last_beat_to_done": wr_transfer.done_cycle - wr_transfer.last_beat_cycle,
						"ce_resp_to_wr_done": wr_transfer.done_cycle - ce_resp.cycle,
					},
				},
				"pt_ce_v2": {
					"exec_req_count": len(ce_exec_reqs),
					"exec_rsp_count": len(ce_exec_rsps),
					"drain_accept_count": len(ce_drain_accepts),
					"drain_complete_count": len(ce_drain_completes),
					"ce_cmd_to_first_exec_req": ce_exec_req_first.cycle - ce_cmd.cycle,
					"first_exec_req_to_first_exec_rsp": ce_exec_rsp_first.cycle - ce_exec_req_first.cycle,
					"first_exec_rsp_to_first_drain_accept": ce_drain_accept_first.cycle - ce_exec_rsp_first.cycle,
					"first_exec_rsp_to_last_exec_complete": ce_exec_complete_last.cycle - ce_exec_rsp_first.cycle,
					"first_drain_accept_to_last_drain_complete": ce_drain_complete_last.cycle - ce_drain_accept_first.cycle,
					"last_exec_complete_to_last_drain_complete_tail": ce_drain_complete_last.cycle - ce_exec_complete_last.cycle,
					"last_drain_complete_to_ce_resp": ce_resp.cycle - ce_drain_complete_last.cycle,
					"ce_cmd_to_ce_resp": ce_resp.cycle - ce_cmd.cycle,
				},
			}

		record_metric("diagnostics", "pt_ce_md_block_breakdown", {"status": "passed", "cases": results})
	finally:
		env.shutdown()
