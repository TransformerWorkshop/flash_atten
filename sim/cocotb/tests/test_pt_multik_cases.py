from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles

from tests.pt_blackbox_env import create_env, setup_bases_and_passthrough_qcfg
from tests.pt_model import (
	PT_TILES_1,
	PT_TILES_2,
	PT_TILES_4,
	build_load_inst,
	build_matadd_inst,
	build_matmul_inst,
	build_mwin_off,
	matmul_row_major,
	to_unsigned,
)


def make_a_matrix(x_dim: int, m_tiles: int, k_tiles: int, bits: int) -> list[int]:
	m_dim = x_dim * m_tiles
	k_dim = x_dim * k_tiles
	return [
		to_unsigned(1 + ((row * 3) + (col % x_dim) + (row // x_dim) * 5 + (col // x_dim) * 7) % 29, bits)
		for row in range(m_dim)
		for col in range(k_dim)
	]


def make_b_matrix(y_dim: int, k_tiles: int, n_tiles: int, bits: int) -> list[int]:
	k_dim = y_dim * k_tiles
	n_dim = y_dim * n_tiles
	return [
		to_unsigned(1 + ((col * 2) + (row % y_dim) + (col // y_dim) * 4 + (row // y_dim) * 6) % 31, bits)
		for row in range(k_dim)
		for col in range(n_dim)
	]


def can_encode_matmul_len(env, m_tiles: int, n_tiles: int, k_tiles: int) -> bool:
	a_len = (env.x_dim * env.x_dim) * m_tiles * k_tiles
	b_len = (env.y_dim * env.y_dim) * k_tiles * n_tiles
	return max(a_len, b_len) <= 0x3FF


async def run_multitile_case(env, ctrl_id: int, *, m_tiles: int, n_tiles: int, k_tiles: int, preload: bool = False) -> tuple[list[int], list[int], list[int]]:
	m_dim = env.x_dim * m_tiles
	k_dim = env.x_dim * k_tiles
	n_dim = env.y_dim * n_tiles
	a_matrix = make_a_matrix(env.x_dim, m_tiles, k_tiles, env.data_width)
	b_matrix = make_b_matrix(env.y_dim, k_tiles, n_tiles, env.data_width)
	golden = [
		to_unsigned(value, env.data_width)
		for value in matmul_row_major(a_matrix, b_matrix, m_dim, n_dim, k_dim)
	]

	env.register_external_matrix("A", ctrl_id, a_matrix)
	env.register_external_matrix("B", ctrl_id, b_matrix)
	if preload:
		load_plan = env.plan_load(ctrl_id, len(a_matrix), len(b_matrix), need_a=True, need_b=True, reserved_lo=build_load_inst(0, 0, need_a=True, need_b=True, m_tiles=m_tiles, n_tiles=n_tiles, k_tiles=k_tiles) & 0x3F)
		assert not load_plan.err
		await env.send_ctrl(build_load_inst(len(a_matrix), len(b_matrix), need_a=True, need_b=True, m_tiles=m_tiles, n_tiles=n_tiles, k_tiles=k_tiles), ctrl_id)
		await env.wait_ctrl_resp(load_plan.response_word, 4000)

	plan = env.plan_matmul(ctrl_id, m_scale=m_tiles, n_scale=n_tiles, k_scale=k_tiles)
	assert not plan.err
	assert len(plan.expected_dma_loads) == (0 if preload else 2)
	assert plan.result_matrix == golden

	await env.send_ctrl(build_matmul_inst(m_tiles, n_tiles, k_tiles), ctrl_id)
	await env.wait_ctrl_resp(plan.response_word, 4000)
	env.model.commit_success(plan)
	await env.wait_export_done(env.export_done_count + 1, 8000)
	return a_matrix, b_matrix, golden


@cocotb.test()
async def test_pt_multik_numeric_k2(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		await run_multitile_case(env, 0xA20, m_tiles=PT_TILES_1, n_tiles=PT_TILES_1, k_tiles=PT_TILES_2)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_multik_numeric_k4(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		await run_multitile_case(env, 0xA40, m_tiles=PT_TILES_1, n_tiles=PT_TILES_1, k_tiles=PT_TILES_4)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_multitile_numeric_m2_n1_k1(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		assert can_encode_matmul_len(env, PT_TILES_2, PT_TILES_1, PT_TILES_1)
		await run_multitile_case(env, 0xA60, m_tiles=PT_TILES_2, n_tiles=PT_TILES_1, k_tiles=PT_TILES_1)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_multitile_numeric_m1_n2_k1(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		assert can_encode_matmul_len(env, PT_TILES_1, PT_TILES_2, PT_TILES_1)
		await run_multitile_case(env, 0xA80, m_tiles=PT_TILES_1, n_tiles=PT_TILES_2, k_tiles=PT_TILES_1)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_multitile_numeric_m2_n2_k2(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		assert can_encode_matmul_len(env, PT_TILES_2, PT_TILES_2, PT_TILES_2)
		await run_multitile_case(env, 0xAA0, m_tiles=PT_TILES_2, n_tiles=PT_TILES_2, k_tiles=PT_TILES_2)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_multitile_numeric_m4_n4_k4_when_size_fits(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		if not can_encode_matmul_len(env, PT_TILES_4, PT_TILES_4, PT_TILES_4):
			return
		await run_multitile_case(env, 0xAC0, m_tiles=PT_TILES_4, n_tiles=PT_TILES_4, k_tiles=PT_TILES_4)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_multitile_load_then_matmul_hits_residency(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		await run_multitile_case(env, 0xAE0, m_tiles=PT_TILES_2, n_tiles=PT_TILES_2, k_tiles=PT_TILES_2, preload=True)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_multitile_shape_mismatch_reuses_are_rejected(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		ctrl_id = 0xB20
		a_matrix = make_a_matrix(env.x_dim, PT_TILES_2, PT_TILES_1, env.data_width)
		b_matrix = make_b_matrix(env.y_dim, PT_TILES_1, PT_TILES_1, env.data_width)
		env.register_external_matrix("A", ctrl_id, a_matrix)
		env.register_external_matrix("B", ctrl_id, b_matrix)

		load_plan = env.plan_load(ctrl_id, len(a_matrix), len(b_matrix), need_a=True, need_b=True, reserved_lo=build_load_inst(0, 0, need_a=True, need_b=True, m_tiles=PT_TILES_2, n_tiles=PT_TILES_1, k_tiles=PT_TILES_1) & 0x3F)
		assert not load_plan.err
		await env.send_ctrl(build_load_inst(len(a_matrix), len(b_matrix), need_a=True, need_b=True, m_tiles=PT_TILES_2, n_tiles=PT_TILES_1, k_tiles=PT_TILES_1), ctrl_id)
		await env.wait_ctrl_resp(load_plan.response_word, 4000)

		bad_plan = env.plan_matmul(ctrl_id, m_scale=PT_TILES_1, n_scale=PT_TILES_1, k_scale=PT_TILES_1)
		assert bad_plan.err
		await env.send_ctrl(build_matmul_inst(PT_TILES_1, PT_TILES_1, PT_TILES_1), ctrl_id)
		await env.wait_ctrl_resp(bad_plan.response_word, 4000)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_multitile_matadd_rejects_multitile_mwindow(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		ctrl_id = 0xB40
		await run_multitile_case(env, ctrl_id, m_tiles=PT_TILES_2, n_tiles=PT_TILES_1, k_tiles=PT_TILES_1)
		before_exports = env.export_done_count
		resp_word = env.ctrl_resp_queue[-1] if env.ctrl_resp_queue else None
		assert resp_word is None
		m_off = build_mwin_off(env.model.next_write_buf ^ 1, 0)
		add_plan = env.plan_matadd(ctrl_id + 1, m_off)
		assert add_plan.err
		assert add_plan.reject_reason == "reject:mwindow_multitile"
		await env.send_ctrl(build_matadd_inst(m_off), ctrl_id + 1)
		await env.wait_ctrl_resp(add_plan.response_word, 4000)
		await ClockCycles(dut.clk, 8)
		assert env.export_done_count == before_exports
	finally:
		env.shutdown()
