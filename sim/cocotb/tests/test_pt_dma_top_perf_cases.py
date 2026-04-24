from __future__ import annotations

import math

import cocotb
from cocotb.triggers import ClockCycles

from tests.pt_dma_top_env import (
	ADDR_CTRL,
	ADDR_STATUS,
	ConstantPattern,
	STATUS_CMD_OVERFLOW,
	STATUS_DESC_OVERFLOW,
	create_env,
	setup_bases_and_passthrough_qcfg,
)
from tests.pt_model import (
	DMA_KIND_A,
	DMA_KIND_B,
	DMA_KIND_C,
	PT_SCALE_FULL,
	build_cfg_inst,
	build_matadd_inst,
	build_matmul_inst,
	build_mwin_off,
	identity_matrix,
)


AXIL_WRITE_LATENCY_CYCLES = 4
AXIL_PUSH_TO_PT_ACCEPT_CYCLES = 3
PT_FRONTEND_OVERHEAD_CYCLES = 6
DMA_REQ_DONE_OVERHEAD_CYCLES = 4


def sequential_row_major(dim: int) -> list[list[int]]:
	value = 1
	matrix: list[list[int]] = []
	for _ in range(dim):
		row: list[int] = []
		for _ in range(dim):
			row.append(value)
			value += 1
		matrix.append(row)
	return matrix


def repeating_matrix(dim: int, seed: int) -> list[int]:
	return [seed + (idx % dim) for idx in range(dim * dim)]


def _is_v3_wrapper(env) -> bool:
	return env._pt_root_prefix().endswith("u_pt_v3")


def _expected_matmul_internal_cycles(env) -> int:
	writeback_cycles = 0 if env.m_write_lanes >= env.y_dim else (env.x_dim * math.ceil(env.y_dim / env.m_write_lanes))
	return 1 + 1 + env.x_dim + env.x_dim + writeback_cycles + 1


def _expected_native_matmul_ctrl_resp_cycles(env, cold_miss: bool) -> int:
	input_cycles = 0
	if cold_miss:
		input_cycles = (
			math.ceil((env.x_dim * env.x_dim) / env.a_load_lanes) + DMA_REQ_DONE_OVERHEAD_CYCLES
			+ math.ceil((env.y_dim * env.y_dim) / env.b_load_lanes) + DMA_REQ_DONE_OVERHEAD_CYCLES
		)
	return PT_FRONTEND_OVERHEAD_CYCLES + input_cycles + _expected_matmul_internal_cycles(env)


def _expected_native_matadd_ctrl_resp_cycles(env) -> int:
	c_load_cycles = math.ceil((env.y_dim * env.y_dim) / env.b_load_lanes) + DMA_REQ_DONE_OVERHEAD_CYCLES
	add_store_cycles = math.ceil(env.y_dim / env.m_write_lanes)
	# Single-port SRAM inserts a one-cycle bubble between each row store and the
	# next row fetch, so MATADD pays an extra (x_dim - 1) cycles.
	add_compute_cycles = (env.x_dim * (4 + add_store_cycles)) - 1 + max(env.x_dim - 1, 0)
	return PT_FRONTEND_OVERHEAD_CYCLES + c_load_cycles + add_compute_cycles


def _assert_desc_trace_sane(trace, expected_writes: int) -> None:
	assert trace.axil_writes == expected_writes, f"expected {expected_writes} writes, got {trace.axil_writes}"
	assert trace.axil_reads == 0
	assert (trace.return_cycle - trace.ctrl_write_start_cycle) == AXIL_WRITE_LATENCY_CYCLES


def _expected_first_write_to_resp_cycles(trace, native_ctrl_resp_cycles: int, wrapper_cycles: int) -> int:
	return (AXIL_WRITE_LATENCY_CYCLES * (trace.axil_writes - 1)) + wrapper_cycles + native_ctrl_resp_cycles


def _expected_push_to_resp_cycles(native_ctrl_resp_cycles: int, wrapper_cycles: int) -> int:
	return wrapper_cycles + native_ctrl_resp_cycles


def _expected_rd_desc_to_last_beat(beats: int) -> int:
	return beats + 1


def _expected_wr_desc_to_tlast(env, beats: int) -> int:
	return beats + env.x_dim + 1


def _expected_wr_desc_to_done(env, beats: int) -> int:
	return _expected_wr_desc_to_tlast(env, beats) + 1


def _assert_rd_transfer_shape(env, trace) -> None:
	if not _is_v3_wrapper(env):
		assert (trace.last_beat_cycle - trace.desc_cycle) == _expected_rd_desc_to_last_beat(trace.beats)
	else:
		assert trace.first_beat_cycle > trace.desc_cycle
		assert trace.last_beat_cycle >= trace.first_beat_cycle


def _assert_wr_transfer_shape(env, trace) -> None:
	if not _is_v3_wrapper(env):
		assert (trace.last_beat_cycle - trace.desc_cycle) == _expected_wr_desc_to_tlast(env, trace.beats)
		assert (trace.done_cycle - trace.desc_cycle) == _expected_wr_desc_to_done(env, trace.beats)
	else:
		assert trace.first_beat_cycle > trace.desc_cycle
		assert trace.last_beat_cycle >= trace.first_beat_cycle
		assert trace.done_cycle == (trace.last_beat_cycle + 1)


@cocotb.test()
async def test_pt_dma_top_perf_matmul_latency_breakdown(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)

		ctrl_id = 0xD100
		matmul_inst = build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL)
		env.register_external_matrix("A", ctrl_id, sequential_row_major(env.x_dim))
		env.register_external_matrix("B", ctrl_id, identity_matrix(env.y_dim, env.data_width))

		cold_trace = await env.send_desc_command_timed(
			matmul_inst,
			ctrl_id,
			a_addr=0x1000_1000,
			b_addr=0x1000_2000,
			m_addr=0x1000_3000,
			mode="full",
		)
		cold_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		cold_accept = await env.wait_pt_ctrl_accept(ctrl_id, after_cycle=cold_trace.ctrl_write_start_cycle)
		cold_resp = await env.wait_resp_visible(cold_plan.response_word, after_cycle=cold_trace.ctrl_write_start_cycle)
		cold_rd_a = await env.wait_rd_transfer(ctrl_id, DMA_KIND_A, after_cycle=cold_trace.ctrl_write_start_cycle)
		cold_rd_b = await env.wait_rd_transfer(ctrl_id, DMA_KIND_B, after_cycle=cold_trace.ctrl_write_start_cycle)
		cold_wr = await env.wait_wr_transfer(ctrl_id, after_cycle=cold_trace.ctrl_write_start_cycle)
		await env.wait_and_pop_resp(cold_plan.response_word, 40000)
		await env.wait_export_done(1, 80000)

		_assert_desc_trace_sane(cold_trace, 11)
		assert (cold_accept.cycle - cold_trace.ctrl_write_start_cycle) == AXIL_PUSH_TO_PT_ACCEPT_CYCLES
		if not _is_v3_wrapper(env):
			assert (cold_resp.cycle - cold_trace.ctrl_write_start_cycle) == _expected_push_to_resp_cycles(_expected_native_matmul_ctrl_resp_cycles(env, True), 2)
			assert (cold_resp.cycle - cold_trace.first_write_start_cycle) == _expected_first_write_to_resp_cycles(cold_trace, _expected_native_matmul_ctrl_resp_cycles(env, True), 2)
		else:
			assert cold_resp.cycle > cold_accept.cycle
			assert cold_resp.cycle > cold_trace.first_write_start_cycle
		_assert_rd_transfer_shape(env, cold_rd_a)
		_assert_rd_transfer_shape(env, cold_rd_b)
		_assert_wr_transfer_shape(env, cold_wr)

		dut._log.info(
			"pt_dma_top_perf cold ctrl_id=0x%08x first_write_to_resp=%d push_to_resp=%d rd_a=%d rd_b=%d wr_tlast=%d wr_done=%d",
			ctrl_id,
			cold_resp.cycle - cold_trace.first_write_start_cycle,
			cold_resp.cycle - cold_trace.ctrl_write_start_cycle,
			cold_rd_a.last_beat_cycle - cold_rd_a.desc_cycle,
			cold_rd_b.last_beat_cycle - cold_rd_b.desc_cycle,
			cold_wr.last_beat_cycle - cold_wr.desc_cycle,
			cold_wr.done_cycle - cold_wr.desc_cycle,
		)

		hit_trace = await env.send_desc_command_timed(
			matmul_inst,
			ctrl_id,
			a_addr=0x1000_1000,
			b_addr=0x1000_2000,
			m_addr=0x1000_3000,
			mode="full",
		)
		hit_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		hit_accept = await env.wait_pt_ctrl_accept(ctrl_id, after_cycle=hit_trace.ctrl_write_start_cycle)
		hit_resp = await env.wait_resp_visible(hit_plan.response_word, after_cycle=hit_trace.ctrl_write_start_cycle)
		hit_wr = await env.wait_wr_transfer(ctrl_id, after_cycle=hit_trace.ctrl_write_start_cycle)
		rd_before = env.rd_desc_count
		await env.wait_and_pop_resp(hit_plan.response_word, 40000)
		await env.wait_export_done(2, 80000)
		await ClockCycles(dut.clk, 4)

		_assert_desc_trace_sane(hit_trace, 11)
		assert (hit_accept.cycle - hit_trace.ctrl_write_start_cycle) == AXIL_PUSH_TO_PT_ACCEPT_CYCLES
		if not _is_v3_wrapper(env):
			assert (hit_resp.cycle - hit_trace.ctrl_write_start_cycle) == _expected_push_to_resp_cycles(_expected_native_matmul_ctrl_resp_cycles(env, False), 4)
			assert (hit_resp.cycle - hit_trace.first_write_start_cycle) == _expected_first_write_to_resp_cycles(hit_trace, _expected_native_matmul_ctrl_resp_cycles(env, False), 4)
		else:
			assert hit_resp.cycle > hit_accept.cycle
			assert (hit_resp.cycle - hit_trace.ctrl_write_start_cycle) < (cold_resp.cycle - cold_trace.ctrl_write_start_cycle)
		assert env.rd_desc_count == rd_before
		_assert_wr_transfer_shape(env, hit_wr)

		dut._log.info(
			"pt_dma_top_perf hit ctrl_id=0x%08x first_write_to_resp=%d push_to_resp=%d wr_tlast=%d wr_done=%d",
			ctrl_id,
			hit_resp.cycle - hit_trace.first_write_start_cycle,
			hit_resp.cycle - hit_trace.ctrl_write_start_cycle,
			hit_wr.last_beat_cycle - hit_wr.desc_cycle,
			hit_wr.done_cycle - hit_wr.desc_cycle,
		)

		delta_trace = await env.send_desc_command_timed(
			matmul_inst,
			ctrl_id,
			a_addr=0x1000_1000,
			b_addr=0x1000_2000,
			m_addr=0x1000_3000,
			mode="delta",
		)
		delta_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		delta_accept = await env.wait_pt_ctrl_accept(ctrl_id, after_cycle=delta_trace.ctrl_write_start_cycle)
		delta_resp = await env.wait_resp_visible(delta_plan.response_word, after_cycle=delta_trace.ctrl_write_start_cycle)
		delta_wr = await env.wait_wr_transfer(ctrl_id, after_cycle=delta_trace.ctrl_write_start_cycle)
		rd_before = env.rd_desc_count
		await env.wait_and_pop_resp(delta_plan.response_word, 40000)
		await env.wait_export_done(3, 80000)
		await ClockCycles(dut.clk, 4)

		_assert_desc_trace_sane(delta_trace, 1)
		assert delta_trace.write_addrs == (ADDR_CTRL,)
		assert (delta_accept.cycle - delta_trace.ctrl_write_start_cycle) == AXIL_PUSH_TO_PT_ACCEPT_CYCLES
		if not _is_v3_wrapper(env):
			assert (delta_resp.cycle - delta_trace.ctrl_write_start_cycle) == _expected_push_to_resp_cycles(_expected_native_matmul_ctrl_resp_cycles(env, False), 4)
			assert (delta_resp.cycle - delta_trace.first_write_start_cycle) == _expected_first_write_to_resp_cycles(delta_trace, _expected_native_matmul_ctrl_resp_cycles(env, False), 4)
		else:
			assert delta_resp.cycle > delta_accept.cycle
			assert (delta_resp.cycle - delta_trace.ctrl_write_start_cycle) <= (hit_resp.cycle - hit_trace.ctrl_write_start_cycle)
		assert env.rd_desc_count == rd_before
		_assert_wr_transfer_shape(env, delta_wr)
		assert (hit_resp.cycle - hit_trace.first_write_start_cycle) - (delta_resp.cycle - delta_trace.first_write_start_cycle) == (
			AXIL_WRITE_LATENCY_CYCLES * (hit_trace.axil_writes - delta_trace.axil_writes)
		)

		dut._log.info(
			"pt_dma_top_perf hit_delta ctrl_id=0x%08x full_writes=%d full_cycles=%d delta_writes=%d delta_cycles=%d",
			ctrl_id,
			hit_trace.axil_writes,
			hit_resp.cycle - hit_trace.first_write_start_cycle,
			delta_trace.axil_writes,
			delta_resp.cycle - delta_trace.first_write_start_cycle,
		)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_dma_top_perf_retained_m_matadd_latency(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)

		ctrl_id = 0xD200
		matmul_inst = build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL)
		env.register_external_matrix("A", ctrl_id, sequential_row_major(env.x_dim))
		env.register_external_matrix("B", ctrl_id, identity_matrix(env.y_dim, env.data_width))

		seed_trace = await env.send_desc_command_timed(
			matmul_inst,
			ctrl_id,
			a_addr=0x2000_1000,
			b_addr=0x2000_2000,
			m_addr=0x2000_3000,
			mode="full",
		)
		seed_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		seed_resp = await env.wait_resp_visible(seed_plan.response_word, after_cycle=seed_trace.ctrl_write_start_cycle)
		await env.wait_wr_transfer(ctrl_id, after_cycle=seed_trace.ctrl_write_start_cycle)
		await env.wait_and_pop_resp(seed_plan.response_word, 40000)
		await env.wait_export_done(1, 80000)

		first_resp_word = seed_resp.word
		first_m_off = build_mwin_off((first_resp_word >> 30) & 0x1, 0)
		matadd_inst = build_matadd_inst(first_m_off)

		env.register_external_matrix("C", ctrl_id, repeating_matrix(env.y_dim, 17))
		full_trace = await env.send_desc_command_timed(
			matadd_inst,
			ctrl_id,
			c_addr=0x2000_4000,
			m_addr=0x2000_3000,
			mode="full",
		)
		full_plan = env.plan_matadd(ctrl_id, first_m_off)
		full_accept = await env.wait_pt_ctrl_accept(ctrl_id, after_cycle=full_trace.ctrl_write_start_cycle)
		full_resp = await env.wait_resp_visible(full_plan.response_word, after_cycle=full_trace.ctrl_write_start_cycle)
		full_rd = await env.wait_rd_transfer(ctrl_id, DMA_KIND_C, after_cycle=full_trace.ctrl_write_start_cycle)
		full_wr = await env.wait_wr_transfer(ctrl_id, after_cycle=full_trace.ctrl_write_start_cycle)
		await env.wait_and_pop_resp(full_plan.response_word, 40000)
		await env.wait_export_done(2, 80000)

		_assert_desc_trace_sane(full_trace, 11)
		assert (full_accept.cycle - full_trace.ctrl_write_start_cycle) == AXIL_PUSH_TO_PT_ACCEPT_CYCLES
		if not _is_v3_wrapper(env):
			assert (full_resp.cycle - full_trace.ctrl_write_start_cycle) == _expected_push_to_resp_cycles(_expected_native_matadd_ctrl_resp_cycles(env), 2)
			assert (full_resp.cycle - full_trace.first_write_start_cycle) == _expected_first_write_to_resp_cycles(full_trace, _expected_native_matadd_ctrl_resp_cycles(env), 2)
		else:
			assert full_resp.cycle > full_accept.cycle
			assert full_resp.cycle > seed_resp.cycle
		_assert_rd_transfer_shape(env, full_rd)
		_assert_wr_transfer_shape(env, full_wr)

		dut._log.info(
			"pt_dma_top_perf matadd ctrl_id=0x%08x writes=%d first_write_to_resp=%d push_to_resp=%d rd_c=%d wr_tlast=%d wr_done=%d",
			ctrl_id,
			full_trace.axil_writes,
			full_resp.cycle - full_trace.first_write_start_cycle,
			full_resp.cycle - full_trace.ctrl_write_start_cycle,
			full_rd.last_beat_cycle - full_rd.desc_cycle,
			full_wr.last_beat_cycle - full_wr.desc_cycle,
			full_wr.done_cycle - full_wr.desc_cycle,
		)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_dma_top_perf_cmd_fifo_headroom_under_dma_backpressure(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)

		ctrl_id = 0xD300
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, repeating_matrix(env.y_dim, 5))
		matmul_inst = build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL)
		env.configure_patterns(dma_req_ready=ConstantPattern(0))

		push_count = 0
		while True:
			push_count += 1
			await env.send_desc_command(
				matmul_inst,
				ctrl_id,
				a_addr=0x3000_1000,
				b_addr=0x3000_2000,
				m_addr=0x3000_3000,
			)
			status = await env.axil_read(ADDR_STATUS)
			if status & STATUS_CMD_OVERFLOW:
				break

		assert push_count == 10, f"expected cmd overflow on 10th push, got {push_count}"
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_dma_top_perf_descriptor_lut_limit_is_eight_live_ids(dut) -> None:
	env = await create_env(dut)
	try:
		overflow_push = 0
		for idx in range(1, 16):
			overflow_push = idx
			await env.send_desc_command(build_cfg_inst(0, idx), 0xE000 + idx)
			status = await env.axil_read(ADDR_STATUS)
			if status & STATUS_DESC_OVERFLOW:
				break

		assert overflow_push == 9, f"expected desc overflow on 9th unique id, got {overflow_push}"
	finally:
		env.shutdown()
