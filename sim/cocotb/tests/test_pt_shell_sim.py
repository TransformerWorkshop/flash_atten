from __future__ import annotations

from typing import List, Sequence, Tuple

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from tests.pt_model import (
	PTBlackBoxModel,
	PT_TILES_1,
	PT_TILES_2,
	PT_TILES_4,
	build_load_inst,
	build_matadd_inst,
	build_matmul_inst,
	build_mwin_off,
	pack_resp,
	to_signed,
	to_unsigned,
)
from tests.pt_shell_sim_env import (
	SHELL_KIND_A,
	SHELL_KIND_B,
	SHELL_KIND_C,
	create_env,
	scalar_matrix_to_a_words,
	scalar_matrix_to_b_words,
	scalar_matrix_to_c_words,
)


def make_matrix(rows: int, cols: int, row_gain: int, col_gain: int, bias: int) -> List[int]:
	return [
		((row * row_gain) + (col * col_gain) + bias) & 0xFF
		for row in range(rows)
		for col in range(cols)
	]


def slice_a(matrix: Sequence[int], full_k_dim: int, row_base: int, col_base: int, rows: int, cols: int) -> List[int]:
	return [int(matrix[(row_base + r) * full_k_dim + (col_base + c)]) for r in range(rows) for c in range(cols)]


def slice_b(matrix: Sequence[int], full_n_dim: int, row_base: int, col_base: int, rows: int, cols: int) -> List[int]:
	return [int(matrix[(row_base + r) * full_n_dim + (col_base + c)]) for r in range(rows) for c in range(cols)]


def model_for(env) -> PTBlackBoxModel:
	return PTBlackBoxModel(
		env.x_dim,
		env.y_dim,
		a_bank_depth=16,
		b_bank_depth=16,
		data_width=env.data_width,
		lut_depth=8,
		pack_lanes=env.pack_lanes,
		elem_width=env.elem_width,
	)


def sat_add_packed_words(lhs_words: Sequence[int], rhs_words: Sequence[int]) -> List[int]:
	assert len(lhs_words) == len(rhs_words)
	result: List[int] = []
	for lhs_word, rhs_word in zip(lhs_words, rhs_words):
		word = 0
		for lane_idx in range(4):
			lhs_lane = to_signed((int(lhs_word) >> (lane_idx * 8)) & 0xFF, 8)
			rhs_lane = to_signed((int(rhs_word) >> (lane_idx * 8)) & 0xFF, 8)
			sum_lane = lhs_lane + rhs_lane
			if sum_lane > 127:
				sum_lane = 127
			elif sum_lane < -128:
				sum_lane = -128
			word |= to_unsigned(sum_lane, 8) << (lane_idx * 8)
		result.append(word & 0xFFFF_FFFF)
	return result


def assert_words_equal(actual: Sequence[int], expected: Sequence[int]) -> None:
	assert len(actual) == len(expected), f"word length mismatch actual={len(actual)} expected={len(expected)}"
	for idx, (lhs, rhs) in enumerate(zip(actual, expected)):
		assert int(lhs) == int(rhs), f"word mismatch at idx={idx}: actual=0x{int(lhs):08x} expected=0x{int(rhs):08x}"


async def assert_no_output_meta(env, cycles: int = 20) -> None:
	for _ in range(cycles):
		status = await env.read_shell_status()
		assert (status & (1 << 4)) == 0
		await RisingEdge(env.dut.clk)


async def inject_ab(env, *, ctrl_id: int, m_tiles: int, n_tiles: int, k_tiles: int, a_words: Sequence[int], b_words: Sequence[int], k_tile_off: int = 0) -> None:
	await env.push_ingress_words(
		kind=SHELL_KIND_A,
		ctrl_id=ctrl_id,
		m_tile_off=0,
		n_tile_off=0,
		k_tile_off=k_tile_off,
		m_tiles=m_tiles,
		n_tiles=0,
		k_tiles=k_tiles,
		words=a_words,
	)
	await env.push_ingress_words(
		kind=SHELL_KIND_B,
		ctrl_id=ctrl_id,
		m_tile_off=0,
		n_tile_off=0,
		k_tile_off=k_tile_off,
		m_tiles=0,
		n_tiles=n_tiles,
		k_tiles=k_tiles,
		words=b_words,
	)


async def load_ab(env, *, ctrl_id: int, m_tiles: int, n_tiles: int, k_tiles: int, a_words: Sequence[int], b_words: Sequence[int]) -> None:
	await env.send_command(
		build_load_inst(len(a_words), len(b_words), need_a=True, need_b=True, m_tiles=m_tiles, n_tiles=n_tiles, k_tiles=k_tiles),
		ctrl_id,
	)
	resp = await env.wait_resp()
	assert resp == pack_resp(False, 0, ctrl_id)
	await env.pop_resp()


async def run_matmul(env, *, ctrl_id: int, m_tiles: int, n_tiles: int, k_tiles: int) -> int:
	await env.send_command(build_matmul_inst(m_tiles, n_tiles, k_tiles), ctrl_id)
	resp = await env.wait_resp()
	await env.pop_resp()
	assert ((resp >> 31) & 0x1) == 0
	return (resp >> 30) & 0x1


@cocotb.test()
async def test_shell_reset_smoke(dut) -> None:
	env = await create_env(dut)
	try:
		await env.reset()
		status = await env.read_shell_status()
		assert (status & (1 << 2)) == 0
	finally:
		env.shutdown()


@cocotb.test()
async def test_shell_matmul_single_tile(dut) -> None:
	env = await create_env(dut)
	try:
		await env.reset()

		ctrl_id = 0x101
		a_matrix = make_matrix(env.x_dim, env.x_dim * 2, 3, 5, 1)
		b_matrix = make_matrix(env.x_dim * 2, env.y_dim, 7, 2, 3)
		a_words = scalar_matrix_to_a_words(a_matrix, x_dim=env.x_dim, m_tiles=PT_TILES_1, k_tiles=PT_TILES_2, pack_lanes=env.pack_lanes, data_width=env.data_width, elem_width=env.elem_width)
		b_words = scalar_matrix_to_b_words(b_matrix, y_dim=env.y_dim, k_tiles=PT_TILES_2, n_tiles=PT_TILES_1, pack_lanes=env.pack_lanes, data_width=env.data_width, elem_width=env.elem_width)

		model = model_for(env)
		plan = model.issue_matmul(ctrl_id, {ctrl_id: a_matrix}, {ctrl_id: b_matrix}, m_tiles=PT_TILES_1, n_tiles=PT_TILES_1, k_tiles=PT_TILES_2)
		assert not plan.err
		expected_words = scalar_matrix_to_c_words(plan.result_matrix, y_dim=env.y_dim, pack_lanes=env.pack_lanes, data_width=env.data_width, elem_width=env.elem_width)

		await env.set_shell_mode(forward_m=False, emit_intermediate=False)
		await inject_ab(env, ctrl_id=ctrl_id, m_tiles=PT_TILES_1, n_tiles=PT_TILES_1, k_tiles=PT_TILES_2, a_words=a_words, b_words=b_words)
		await load_ab(env, ctrl_id=ctrl_id, m_tiles=PT_TILES_1, n_tiles=PT_TILES_1, k_tiles=PT_TILES_2, a_words=a_words, b_words=b_words)
		_ = await run_matmul(env, ctrl_id=ctrl_id, m_tiles=PT_TILES_1, n_tiles=PT_TILES_1, k_tiles=PT_TILES_2)
		meta = await env.wait_output_meta()
		assert meta.ctrl_id == ctrl_id
		assert meta.is_final
		packet_words = await env.read_output_packet_words(meta.word_count)
		assert_words_equal(packet_words, expected_words)
		await env.pop_output_meta()
	finally:
		env.shutdown()


@cocotb.test()
async def test_shell_matadd_single_tile(dut) -> None:
	env = await create_env(dut)
	try:
		await env.reset()

		ctrl_id = 0x202
		a_matrix = make_matrix(env.x_dim, env.x_dim, 5, 3, 1)
		b_matrix = make_matrix(env.x_dim, env.y_dim, 2, 7, 4)
		c_matrix = make_matrix(env.x_dim, env.y_dim, 1, 1, 9)
		a_words = scalar_matrix_to_a_words(a_matrix, x_dim=env.x_dim, m_tiles=PT_TILES_1, k_tiles=PT_TILES_1, pack_lanes=env.pack_lanes, data_width=env.data_width, elem_width=env.elem_width)
		b_words = scalar_matrix_to_b_words(b_matrix, y_dim=env.y_dim, k_tiles=PT_TILES_1, n_tiles=PT_TILES_1, pack_lanes=env.pack_lanes, data_width=env.data_width, elem_width=env.elem_width)
		c_words = scalar_matrix_to_c_words(c_matrix, y_dim=env.y_dim, pack_lanes=env.pack_lanes, data_width=env.data_width, elem_width=env.elem_width)

		model = model_for(env)
		matmul_plan = model.issue_matmul(ctrl_id, {ctrl_id: a_matrix}, {ctrl_id: b_matrix}, m_tiles=PT_TILES_1, n_tiles=PT_TILES_1, k_tiles=PT_TILES_1)
		assert not matmul_plan.err
		expected_words = sat_add_packed_words(
			scalar_matrix_to_c_words(matmul_plan.result_matrix, y_dim=env.y_dim, pack_lanes=env.pack_lanes, data_width=env.data_width, elem_width=env.elem_width),
			c_words,
		)

		await env.set_shell_mode(forward_m=True, emit_intermediate=False)
		await inject_ab(env, ctrl_id=ctrl_id, m_tiles=PT_TILES_1, n_tiles=PT_TILES_1, k_tiles=PT_TILES_1, a_words=a_words, b_words=b_words)
		await load_ab(env, ctrl_id=ctrl_id, m_tiles=PT_TILES_1, n_tiles=PT_TILES_1, k_tiles=PT_TILES_1, a_words=a_words, b_words=b_words)
		slot = await run_matmul(env, ctrl_id=ctrl_id, m_tiles=PT_TILES_1, n_tiles=PT_TILES_1, k_tiles=PT_TILES_1)
		await assert_no_output_meta(env)

		await env.push_ingress_words(
			kind=SHELL_KIND_C,
			ctrl_id=ctrl_id,
			m_tile_off=0,
			n_tile_off=0,
			k_tile_off=0,
			m_tiles=PT_TILES_1,
			n_tiles=PT_TILES_1,
			k_tiles=0,
			words=c_words,
		)
		await env.send_command(build_load_inst(0, len(c_words), need_a=False, need_b=True, m_tiles=PT_TILES_1, n_tiles=PT_TILES_1, k_tiles=PT_TILES_1), ctrl_id)
		resp = await env.wait_resp()
		assert resp == pack_resp(False, 0, ctrl_id)
		await env.pop_resp()

		await env.send_command(build_matadd_inst(build_mwin_off(slot, 0)), ctrl_id)
		resp = await env.wait_resp()
		assert ((resp >> 31) & 0x1) == 0
		await env.pop_resp()
		meta = await env.wait_output_meta()
		assert meta.is_final
		packet_words = await env.read_output_packet_words(meta.word_count)
		assert_words_equal(packet_words, expected_words)
		await env.pop_output_meta()
	finally:
		env.shutdown()


@cocotb.test()
async def test_shell_forward_m_local_reduce(dut) -> None:
	env = await create_env(dut)
	try:
		await env.reset()
		await env.set_shell_mode(forward_m=True, emit_intermediate=False)

		ctrl_id = 0x303
		a_full = make_matrix(env.x_dim, env.x_dim * 2, 3, 5, 2)
		b_full = make_matrix(env.x_dim * 2, env.y_dim, 4, 6, 1)
		a0 = slice_a(a_full, env.x_dim * 2, 0, 0, env.x_dim, env.x_dim)
		a1 = slice_a(a_full, env.x_dim * 2, 0, env.x_dim, env.x_dim, env.x_dim)
		b0 = slice_b(b_full, env.y_dim, 0, 0, env.y_dim, env.y_dim)
		b1 = slice_b(b_full, env.y_dim, env.y_dim, 0, env.y_dim, env.y_dim)
		a0_words = scalar_matrix_to_a_words(a0, x_dim=env.x_dim, m_tiles=PT_TILES_1, k_tiles=PT_TILES_1, pack_lanes=env.pack_lanes, data_width=env.data_width, elem_width=env.elem_width)
		a1_words = scalar_matrix_to_a_words(a1, x_dim=env.x_dim, m_tiles=PT_TILES_1, k_tiles=PT_TILES_1, pack_lanes=env.pack_lanes, data_width=env.data_width, elem_width=env.elem_width)
		b0_words = scalar_matrix_to_b_words(b0, y_dim=env.y_dim, k_tiles=PT_TILES_1, n_tiles=PT_TILES_1, pack_lanes=env.pack_lanes, data_width=env.data_width, elem_width=env.elem_width)
		b1_words = scalar_matrix_to_b_words(b1, y_dim=env.y_dim, k_tiles=PT_TILES_1, n_tiles=PT_TILES_1, pack_lanes=env.pack_lanes, data_width=env.data_width, elem_width=env.elem_width)

		model = model_for(env)
		plan0 = model.issue_matmul(ctrl_id, {ctrl_id: a0}, {ctrl_id: b0}, m_tiles=PT_TILES_1, n_tiles=PT_TILES_1, k_tiles=PT_TILES_1)
		plan1 = model.issue_matmul(ctrl_id + 1, {ctrl_id + 1: a1}, {ctrl_id + 1: b1}, m_tiles=PT_TILES_1, n_tiles=PT_TILES_1, k_tiles=PT_TILES_1)
		assert not plan0.err
		assert not plan1.err
		expected_words = sat_add_packed_words(
			scalar_matrix_to_c_words(plan0.result_matrix, y_dim=env.y_dim, pack_lanes=env.pack_lanes, data_width=env.data_width, elem_width=env.elem_width),
			scalar_matrix_to_c_words(plan1.result_matrix, y_dim=env.y_dim, pack_lanes=env.pack_lanes, data_width=env.data_width, elem_width=env.elem_width),
		)

		await inject_ab(env, ctrl_id=ctrl_id, m_tiles=PT_TILES_1, n_tiles=PT_TILES_1, k_tiles=PT_TILES_1, a_words=a0_words, b_words=b0_words, k_tile_off=0)
		await load_ab(env, ctrl_id=ctrl_id, m_tiles=PT_TILES_1, n_tiles=PT_TILES_1, k_tiles=PT_TILES_1, a_words=a0_words, b_words=b0_words)
		slot = await run_matmul(env, ctrl_id=ctrl_id, m_tiles=PT_TILES_1, n_tiles=PT_TILES_1, k_tiles=PT_TILES_1)
		await assert_no_output_meta(env)

		await inject_ab(env, ctrl_id=ctrl_id, m_tiles=PT_TILES_1, n_tiles=PT_TILES_1, k_tiles=PT_TILES_1, a_words=a1_words, b_words=b1_words, k_tile_off=1)
		await load_ab(env, ctrl_id=ctrl_id, m_tiles=PT_TILES_1, n_tiles=PT_TILES_1, k_tiles=PT_TILES_1, a_words=a1_words, b_words=b1_words)
		_ = await run_matmul(env, ctrl_id=ctrl_id, m_tiles=PT_TILES_1, n_tiles=PT_TILES_1, k_tiles=PT_TILES_1)
		await assert_no_output_meta(env)

		await env.send_command(build_matadd_inst(build_mwin_off(slot, 0)), ctrl_id)
		resp = await env.wait_resp()
		assert ((resp >> 31) & 0x1) == 0
		await env.pop_resp()
		meta = await env.wait_output_meta()
		assert meta.is_final
		packet_words = await env.read_output_packet_words(meta.word_count)
		assert_words_equal(packet_words, expected_words)
		await env.pop_output_meta()
	finally:
		env.shutdown()


@cocotb.test()
async def test_shell_fixed_shape_regression(dut) -> None:
	env = await create_env(dut)
	try:
		await env.reset()
		await env.set_shell_mode(forward_m=False, emit_intermediate=False)

		shapes: List[Tuple[int, int, int, int]] = [
			(0x401, 16, 32, 16),
			(0x402, 32, 32, 32),
		]
		for ctrl_id, m_dim, k_dim, n_dim in shapes:
			m_tiles = m_dim // env.x_dim
			k_tiles = k_dim // env.x_dim
			n_tiles = n_dim // env.y_dim
			a_matrix = make_matrix(m_dim, k_dim, 2, 3, ctrl_id & 0xFF)
			b_matrix = make_matrix(k_dim, n_dim, 5, 7, (ctrl_id >> 4) & 0xFF)
			a_words = scalar_matrix_to_a_words(a_matrix, x_dim=env.x_dim, m_tiles=m_tiles, k_tiles=k_tiles, pack_lanes=env.pack_lanes, data_width=env.data_width, elem_width=env.elem_width)
			b_words = scalar_matrix_to_b_words(b_matrix, y_dim=env.y_dim, k_tiles=k_tiles, n_tiles=n_tiles, pack_lanes=env.pack_lanes, data_width=env.data_width, elem_width=env.elem_width)

			model = model_for(env)
			plan = model.issue_matmul(ctrl_id, {ctrl_id: a_matrix}, {ctrl_id: b_matrix}, m_tiles=m_tiles, n_tiles=n_tiles, k_tiles=k_tiles)
			assert not plan.err
			expected_words = scalar_matrix_to_c_words(plan.result_matrix, y_dim=n_dim, pack_lanes=env.pack_lanes, data_width=env.data_width, elem_width=env.elem_width)

			await inject_ab(env, ctrl_id=ctrl_id, m_tiles=m_tiles, n_tiles=n_tiles, k_tiles=k_tiles, a_words=a_words, b_words=b_words)
			await load_ab(env, ctrl_id=ctrl_id, m_tiles=m_tiles, n_tiles=n_tiles, k_tiles=k_tiles, a_words=a_words, b_words=b_words)
			_ = await run_matmul(env, ctrl_id=ctrl_id, m_tiles=m_tiles, n_tiles=n_tiles, k_tiles=k_tiles)
			meta = await env.wait_output_meta(timeout_cycles=20000)
			assert meta.ctrl_id == ctrl_id
			assert meta.is_final
			packet_words = await env.read_output_packet_words(meta.word_count, timeout_cycles=40000)
			assert_words_equal(packet_words, expected_words)
			await env.pop_output_meta()
			await env.soft_clear()
			await ClockCycles(env.dut.clk, 4)
	finally:
		env.shutdown()


@cocotb.test()
async def test_shell_ingress_word_count_mismatch(dut) -> None:
	env = await create_env(dut)
	try:
		await env.reset()
		words = [0x01020304] * 8
		await env.push_ingress_words(
			kind=SHELL_KIND_A,
			ctrl_id=0x505,
			m_tile_off=0,
			n_tile_off=0,
			k_tile_off=0,
			m_tiles=PT_TILES_1,
			n_tiles=0,
			k_tiles=PT_TILES_1,
			words=words,
			declared_word_count=len(words) + 4,
		)
		status = await env.read_shell_status()
		assert status & (1 << 6)
		await env.clear_flags()
	finally:
		env.shutdown()
