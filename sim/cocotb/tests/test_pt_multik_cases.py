from __future__ import annotations

import cocotb

from tests.pt_blackbox_env import create_env, setup_bases_and_passthrough_qcfg
from tests.pt_model import PT_TILES_1, PT_TILES_2, PT_TILES_4, build_matmul_inst, matmul_row_major, to_unsigned


def make_a_matrix(x_dim: int, k_tiles: int, bits: int) -> list[int]:
	k_dim = x_dim * k_tiles
	return [
		to_unsigned(1 + ((row * 3) + (col % x_dim) + (col // x_dim)) % 11, bits)
		for row in range(x_dim)
		for col in range(k_dim)
	]


def make_b_matrix(y_dim: int, k_tiles: int, bits: int) -> list[int]:
	k_dim = y_dim * k_tiles
	return [
		to_unsigned(1 + ((col * 2) + (row % y_dim) + (row // y_dim)) % 13, bits)
		for row in range(k_dim)
		for col in range(y_dim)
	]


async def run_multik_case(env, ctrl_id: int, k_tiles: int) -> None:
	k_dim = env.x_dim * k_tiles
	a_matrix = make_a_matrix(env.x_dim, k_tiles, env.data_width)
	b_matrix = make_b_matrix(env.y_dim, k_tiles, env.data_width)
	golden = [
		to_unsigned(value, env.data_width)
		for value in matmul_row_major(a_matrix, b_matrix, env.x_dim, env.y_dim, k_dim)
	]

	env.register_external_matrix("A", ctrl_id, a_matrix)
	env.register_external_matrix("B", ctrl_id, b_matrix)
	plan = env.plan_matmul(ctrl_id, m_scale=PT_TILES_1, n_scale=PT_TILES_1, k_scale=k_tiles)
	assert not plan.err
	assert len(plan.expected_dma_loads) == 2
	assert plan.result_matrix == golden

	await env.send_ctrl(build_matmul_inst(PT_TILES_1, PT_TILES_1, k_tiles), ctrl_id)
	await env.wait_ctrl_resp(plan.response_word, 4000)
	env.model.commit_success(plan)
	await env.wait_export_done(env.export_done_count + 1, 8000)


@cocotb.test()
async def test_pt_multik_numeric_k2(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		await run_multik_case(env, 0xA20, PT_TILES_2)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_multik_numeric_k4(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		await run_multik_case(env, 0xA40, PT_TILES_4)
	finally:
		env.shutdown()
