from __future__ import annotations

import math
import os

import cocotb
from cocotb.triggers import RisingEdge

from tests.pt_blackbox_env import create_env, repeating_matrix, setup_bases_and_passthrough_qcfg, value_to_int
from tests.pt_model import PT_SCALE_FULL, build_matmul_inst, identity_matrix


async def _prepare_env(dut):
	env = await create_env(dut)
	await setup_bases_and_passthrough_qcfg(env)
	return env


def _is_dma_top() -> bool:
	return os.getenv("PT_TOPLEVEL", "PT") == "PT_DMA_TOP"


def _expected_internal_ctrl_resp_cycles(env) -> int:
	# GEMM now streams rows directly from PE FIFOs, so there is no extra
	# collect bubble between feed completion and row capture.
	writeback_cycles = 0 if env.m_write_lanes >= env.y_dim else (env.x_dim * math.ceil(env.y_dim / env.m_write_lanes))
	return 1 + 1 + env.x_dim + env.x_dim + writeback_cycles + 1


def _register_ab(env, ctrl_id: int, bias: int = 0) -> None:
	env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
	env.register_external_matrix(
		"B",
		ctrl_id,
		repeating_matrix(env.y_dim, [1 + bias + idx for idx in range(env.y_dim)], env.data_width),
	)


async def _measure_ctrl_resp_after_accept(env, expected_word: int, timeout_cycles: int = 4000) -> int:
	cycles = 0
	while cycles < timeout_cycles:
		if env.ctrl_resp_queue:
			actual = env.ctrl_resp_queue.popleft()
			assert actual == expected_word, f"ctrl_resp mismatch exp=0x{expected_word:08x} got=0x{actual:08x}"
			return cycles
		await RisingEdge(env.dut.clk)
		cycles += 1
	raise AssertionError(f"ctrl_resp timeout waiting for 0x{expected_word:08x}")


async def _measure_export_req_to_last(env, timeout_cycles: int = 4000) -> int:
	started = False
	cycles_since_req = 0
	while cycles_since_req < timeout_cycles:
		await RisingEdge(env.dut.clk)
		if _is_dma_top():
			req_fire = value_to_int(env.dut.wr_dma_desc_valid.value) and value_to_int(env.dut.wr_dma_desc_ready.value)
		else:
			req_fire = value_to_int(env.dut.m_dma_req_valid.value) and value_to_int(env.dut.m_dma_req_ready.value)
		beat_fire = value_to_int(env.dut.m_axis_tvalid.value) and value_to_int(env.dut.m_axis_tready.value)
		if not started:
			if req_fire:
				started = True
				cycles_since_req = 0
			continue
		cycles_since_req += 1
		if beat_fire and value_to_int(env.dut.m_axis_tlast.value):
			return cycles_since_req
	raise AssertionError("export request-to-last timeout")


@cocotb.test()
async def test_pt_perf_cache_hit_ctrl_resp_scales_with_m_write_lanes(dut) -> None:
	env = await _prepare_env(dut)
	try:
		# Exec responses now bypass PT_MALLOC and surface directly at PT top,
		# trimming the previous front-end bookkeeping tail by 3 cycles.
		frontend_overhead_cycles = 6
		ctrl_id = 0x900
		_register_ab(env, ctrl_id, bias=3)
		matmul_inst = build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL)

		cold_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert not cold_plan.err
		await env.send_ctrl(matmul_inst, ctrl_id)
		await env.wait_ctrl_resp(cold_plan.response_word, 12000)
		await env.wait_export_done(1, 20000)

		hit_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert not hit_plan.err
		await env.send_ctrl(matmul_inst, ctrl_id)
		ctrl_resp_cycles = await _measure_ctrl_resp_after_accept(env, hit_plan.response_word, 12000)
		await env.wait_export_done(2, 20000)

		expected_cycles = frontend_overhead_cycles + _expected_internal_ctrl_resp_cycles(env)
		if _is_dma_top():
			expected_cycles += 4
		assert ctrl_resp_cycles == expected_cycles, (
			f"cache-hit ctrl_resp cycles mismatch x={env.x_dim} y={env.y_dim} "
			f"m_write_lanes={env.m_write_lanes}: exp={expected_cycles} got={ctrl_resp_cycles}"
		)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_perf_cold_miss_ctrl_resp_scales_with_ab_load_lanes(dut) -> None:
	env = await _prepare_env(dut)
	try:
		frontend_overhead_cycles = 6
		load_req_done_overhead = 4
		ctrl_id = 0x940
		_register_ab(env, ctrl_id, bias=7)
		matmul_inst = build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL)

		plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert not plan.err
		await env.send_ctrl(matmul_inst, ctrl_id)
		ctrl_resp_cycles = await _measure_ctrl_resp_after_accept(env, plan.response_word, 20000)
		await env.wait_export_done(1, 20000)

		input_cycles = (
			math.ceil((env.x_dim * env.x_dim) / env.a_load_lanes) + load_req_done_overhead
			+ math.ceil((env.y_dim * env.y_dim) / env.b_load_lanes) + load_req_done_overhead
		)
		internal_cycles = _expected_internal_ctrl_resp_cycles(env)
		expected_cycles = frontend_overhead_cycles + input_cycles + internal_cycles
		if _is_dma_top():
			expected_cycles += 2
		assert ctrl_resp_cycles == expected_cycles, (
			f"cold-miss ctrl_resp cycles mismatch x={env.x_dim} y={env.y_dim} "
			f"a_load_lanes={env.a_load_lanes} b_load_lanes={env.b_load_lanes}: "
			f"exp={expected_cycles} got={ctrl_resp_cycles}"
		)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_perf_cold_miss_export_scales_with_m_export_lanes(dut) -> None:
	env = await _prepare_env(dut)
	try:
		ctrl_id = 0x980
		_register_ab(env, ctrl_id, bias=11)
		matmul_inst = build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL)

		plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert not plan.err
		export_watch = cocotb.start_soon(_measure_export_req_to_last(env, 20000))
		await env.send_ctrl(matmul_inst, ctrl_id)
		await env.wait_ctrl_resp(plan.response_word, 20000)
		export_cycles = await export_watch
		await env.wait_export_done(1, 20000)

		expected_beats = env.x_dim * math.ceil(env.y_dim / env.m_export_lanes)
		expected_cycles = expected_beats + env.x_dim + 1
		assert export_cycles == expected_cycles, (
			f"export req-to-last mismatch x={env.x_dim} y={env.y_dim} "
			f"m_export_lanes={env.m_export_lanes}: exp={expected_cycles} got={export_cycles}"
		)
	finally:
		env.shutdown()
