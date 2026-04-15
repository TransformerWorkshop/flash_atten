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

from app.pt_tiled_gemm import ProblemSpec, TILE_DIM
from tests.pt_blackbox_env import create_env, setup_bases_and_passthrough_qcfg
from tests.pt_model import (
	PT_SCALE_FULL,
	build_load_inst,
	build_matadd_inst,
	build_matmul_inst,
	build_mwin_off,
	matmul_row_major,
	to_unsigned,
)


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


async def run_matmul_tile(env, ctrl_id: int, a_tile: List[int], b_tile: List[int]) -> Tuple[List[int], int, int]:
	env.register_external_matrix("A", ctrl_id, a_tile)
	env.register_external_matrix("B", ctrl_id, b_tile)
	plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
	assert not plan.err
	await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
	accept_cycle = cycle_now()
	resp = await env.wait_ctrl_resp(plan.response_word, 40000)
	env.model.commit_success(plan)
	await env.wait_export_done(env.export_done_count + 1, 80000)
	assert plan.result_matrix is not None
	return list(plan.result_matrix), (resp >> 30) & 0x1, accept_cycle


async def run_matadd_tile(env, ctrl_id: int, m_buf: int, ext_matrix: List[int]) -> List[int]:
	env.register_external_matrix("C", ctrl_id, ext_matrix)
	m_off = build_mwin_off(m_buf, 0)
	plan = env.plan_matadd(ctrl_id, m_off)
	assert not plan.err
	await env.send_ctrl(build_matadd_inst(m_off), ctrl_id)
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
			"m_dim": PROBLEM.m_dim,
			"k_dim": PROBLEM.k_dim,
			"n_dim": PROBLEM.n_dim,
			"m_tiles": PROBLEM.m_tiles,
			"k_tiles": PROBLEM.k_tiles,
			"n_tiles": PROBLEM.n_tiles,
		},
	)
	return a_full, b_full, golden


async def run_host_reduce_direct(env, a_full: List[int], b_full: List[int]) -> Dict[str, object]:
	snapshot = env.snapshot()
	start_cycle = None
	c_full = [0] * (PROBLEM.m_dim * PROBLEM.n_dim)
	ctrl_seed = 0
	for m_tile in range(PROBLEM.m_tiles):
		for n_tile in range(PROBLEM.n_tiles):
			partials: List[List[int]] = []
			for k_tile in range(PROBLEM.k_tiles):
				ctrl_id = 0x500 + ctrl_seed
				ctrl_seed += 1
				partial, _, accept_cycle = await run_matmul_tile(
					env,
					ctrl_id,
					extract_a_tile(PROBLEM, a_full, m_tile, k_tile),
					extract_b_tile(PROBLEM, b_full, k_tile, n_tile),
				)
				if start_cycle is None:
					start_cycle = accept_cycle
				partials.append(partial)
			place_c_tile(PROBLEM, c_full, reduce_partials(partials), m_tile, n_tile)
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


async def run_host_reduce_load_then_matmul(env, a_full: List[int], b_full: List[int]) -> Dict[str, object]:
	snapshot = env.snapshot()
	start_cycle = None
	c_full = [0] * (PROBLEM.m_dim * PROBLEM.n_dim)
	ctrl_seed = 0
	for m_tile in range(PROBLEM.m_tiles):
		for n_tile in range(PROBLEM.n_tiles):
			partials: List[List[int]] = []
			for k_tile in range(PROBLEM.k_tiles):
				ctrl_id = 0x900 + ctrl_seed
				ctrl_seed += 1
				a_tile = extract_a_tile(PROBLEM, a_full, m_tile, k_tile)
				b_tile = extract_b_tile(PROBLEM, b_full, k_tile, n_tile)
				env.register_external_matrix("A", ctrl_id, a_tile)
				env.register_external_matrix("B", ctrl_id, b_tile)
				load_plan = env.plan_load(ctrl_id, len(a_tile), len(b_tile), need_a=True, need_b=True)
				assert not load_plan.err
				await env.send_ctrl(build_load_inst(len(a_tile), len(b_tile), need_a=True, need_b=True), ctrl_id)
				if start_cycle is None:
					start_cycle = cycle_now()
				await env.wait_ctrl_resp(load_plan.response_word, 40000)
				env.model.commit_load_success(load_plan)

				matmul_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
				assert not matmul_plan.err
				assert len(matmul_plan.expected_dma_loads) == 0
				await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
				await env.wait_ctrl_resp(matmul_plan.response_word, 40000)
				env.model.commit_success(matmul_plan)
				await env.wait_export_done(env.export_done_count + 1, 80000)
				assert matmul_plan.result_matrix is not None
				partials.append(list(matmul_plan.result_matrix))
			place_c_tile(PROBLEM, c_full, reduce_partials(partials), m_tile, n_tile)
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


async def run_pt_matadd_reduce(env, a_full: List[int], b_full: List[int]) -> Dict[str, object]:
	snapshot = env.snapshot()
	start_cycle = None
	c_full = [0] * (PROBLEM.m_dim * PROBLEM.n_dim)
	ctrl_seed = 0
	add_seed = 0
	matadd_count = 0
	for m_tile in range(PROBLEM.m_tiles):
		for n_tile in range(PROBLEM.n_tiles):
			running_sum: List[int] | None = None
			for k_tile in range(PROBLEM.k_tiles):
				ctrl_id = 0xD00 + ctrl_seed
				ctrl_seed += 1
				partial, m_buf, accept_cycle = await run_matmul_tile(
					env,
					ctrl_id,
					extract_a_tile(PROBLEM, a_full, m_tile, k_tile),
					extract_b_tile(PROBLEM, b_full, k_tile, n_tile),
				)
				if start_cycle is None:
					start_cycle = accept_cycle
				if running_sum is None:
					running_sum = partial
					continue
				running_sum = await run_matadd_tile(env, 0xE00 + add_seed, m_buf, running_sum)
				add_seed += 1
				matadd_count += 1
			assert running_sum is not None
			place_c_tile(PROBLEM, c_full, running_sum, m_tile, n_tile)
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
		a_full, b_full, golden = await prepare_env(env)
		result = await run_host_reduce_direct(env, a_full, b_full)
		assert result["final_matrix"] == golden
		record_metric("tests", "numeric_host_reduce_per_tensor", {"status": "passed", "total_cycles": result["total_cycles"]})
	finally:
		env.shutdown()


@cocotb.test()
async def test_numeric_pt_matadd_reduce_per_tensor(dut) -> None:
	env = await create_env(dut)
	try:
		a_full, b_full, golden = await prepare_env(env)
		result = await run_pt_matadd_reduce(env, a_full, b_full)
		assert result["final_matrix"] == golden
		record_metric("tests", "numeric_pt_matadd_reduce_per_tensor", {"status": "passed", "total_cycles": result["total_cycles"]})
	finally:
		env.shutdown()


@cocotb.test()
async def test_same_id_cannot_rotate_k_slice_operands(dut) -> None:
	env = await create_env(dut)
	try:
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
		first_result, _, _ = await run_matmul_tile(env, ctrl_id, a_tile0, b_tile0)
		assert first_result != expected_slice1
		dma_after_first = env.dma_req_count

		env.register_external_matrix("A", ctrl_id, a_tile1)
		env.register_external_matrix("B", ctrl_id, b_tile1)
		second_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert not second_plan.err
		assert len(second_plan.expected_dma_loads) == 0
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
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
		a_full, b_full, golden = await prepare_env(env)
		direct = await run_host_reduce_direct(env, a_full, b_full)
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
			},
		)

		a_full, b_full, golden = await prepare_env(env)
		load_then = await run_host_reduce_load_then_matmul(env, a_full, b_full)
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
			},
		)

		a_full, b_full, golden = await prepare_env(env)
		pt_reduce = await run_pt_matadd_reduce(env, a_full, b_full)
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
			},
		)

		assert pt_reduce["total_cycles"] > direct["total_cycles"]
		assert load_then["total_cycles"] >= direct["total_cycles"]
		record_metric("tests", "algorithm_compare_reduction_strategies", {"status": "passed", "winner": direct["name"]})
	finally:
		env.shutdown()
