from __future__ import annotations

import os

import cocotb
from cocotb.triggers import RisingEdge

from tests.pt_blackbox_env import ConstantPattern, create_env, flatten_pattern_matrix, repeating_matrix, setup_bases_and_passthrough_qcfg
from tests.pt_model import PT_SCALE_FULL, build_load_inst, build_matmul_inst, identity_matrix


def _is_dma_top() -> bool:
	return os.getenv("PT_TOPLEVEL", "PT") == "PT_DMA_TOP"


async def _prepare_env(dut):
	env = await create_env(dut)
	await setup_bases_and_passthrough_qcfg(env)
	return env


def _register_ab(env, ctrl_id: int, bias: int) -> None:
	env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
	env.register_external_matrix("B", ctrl_id, flatten_pattern_matrix(env.y_dim, 2 + (bias % 3), 1 + (bias % 2), bias))


@cocotb.test()
async def test_pt_stress_ctrl_queue_fill_and_recovery(dut) -> None:
	if _is_dma_top():
		return
	env = await _prepare_env(dut)
	try:
		env.configure_patterns(dma_req_ready=ConstantPattern(0))
		plans = []
		a_matrix = identity_matrix(env.x_dim, env.data_width)
		for idx in range(5):
			ctrl_id = 0xB00 + idx
			env.register_external_matrix("A", ctrl_id, a_matrix)
			plan = env.plan_load(ctrl_id, len(a_matrix), 0, need_a=True, need_b=False)
			assert not plan.err
			plans.append(plan)
			await env.send_ctrl(build_load_inst(len(a_matrix), 0, need_a=True, need_b=False), ctrl_id)

		stalled_id = 0xB05
		env.register_external_matrix("A", stalled_id, a_matrix)
		stalled_plan = env.plan_load(stalled_id, len(a_matrix), 0, need_a=True, need_b=False)
		assert not stalled_plan.err
		plans.append(stalled_plan)
		stalled_send = cocotb.start_soon(env.send_ctrl_timed(build_load_inst(len(a_matrix), 0, need_a=True, need_b=False), stalled_id, 12000))
		for _ in range(6):
			await RisingEdge(dut.clk)
		env.configure_patterns(dma_req_ready=ConstantPattern(1))
		stalled_trace = await stalled_send
		assert stalled_trace.ready_low_cycles > 0, "expected queue fill to deassert ctrl_ready"
		for plan in plans:
			await env.wait_ctrl_resp(plan.response_word, 20000)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_stress_slot_scan_nonzero_hit_free_and_lut_full_reject(dut) -> None:
	if _is_dma_top():
		return
	env = await _prepare_env(dut)
	try:
		a_matrix = identity_matrix(env.x_dim, env.data_width)
		b_matrix = repeating_matrix(env.y_dim, [1, 2, 3, 4, 5, 6, 7, 8][: env.y_dim], env.data_width)

		for offset, expected_free in enumerate((0, 1, 2)):
			ctrl_id = 0xC00 + offset
			env.register_external_matrix("A", ctrl_id, a_matrix)
			plan = env.plan_load(ctrl_id, len(a_matrix), 0, need_a=True, need_b=False)
			assert not plan.err
			await env.send_ctrl(build_load_inst(len(a_matrix), 0, need_a=True, need_b=False), ctrl_id)
			snapshot = await env.wait_malloc_slot_scan(ctrl_id)
			assert snapshot["slot_found"] == 0
			assert snapshot["free_found"] == 1
			assert snapshot["free_idx"] == expected_free
			assert snapshot["cmd_slot_idx"] == expected_free
			await env.wait_ctrl_resp(plan.response_word, 4000)

		hit_ctrl_id = 0xC01
		env.register_external_matrix("B", hit_ctrl_id, b_matrix)
		plan_hit = env.plan_load(hit_ctrl_id, 0, len(b_matrix), need_a=False, need_b=True)
		assert not plan_hit.err
		await env.send_ctrl(build_load_inst(0, len(b_matrix), need_a=False, need_b=True), hit_ctrl_id)
		hit_snapshot = await env.wait_malloc_slot_scan(hit_ctrl_id)
		assert hit_snapshot["slot_found"] == 1
		assert hit_snapshot["slot_idx"] == 1
		assert hit_snapshot["cmd_slot_idx"] == 1
		await env.wait_ctrl_resp(plan_hit.response_word, 4000)

		for offset in range(3, env.lut_depth):
			ctrl_id = 0xC00 + offset
			env.register_external_matrix("A", ctrl_id, a_matrix)
			plan = env.plan_load(ctrl_id, len(a_matrix), 0, need_a=True, need_b=False)
			assert not plan.err
			await env.send_ctrl(build_load_inst(len(a_matrix), 0, need_a=True, need_b=False), ctrl_id)
			await env.wait_ctrl_resp(plan.response_word, 4000)

		reject_id = 0xC80
		env.register_external_matrix("A", reject_id, a_matrix)
		reject_plan = env.plan_load(reject_id, len(a_matrix), 0, need_a=True, need_b=False)
		assert reject_plan.err
		assert reject_plan.reject_reason == "reject:lut_full_miss"
		await env.send_ctrl(build_load_inst(len(a_matrix), 0, need_a=True, need_b=False), reject_id)
		reject_snapshot = await env.wait_malloc_slot_scan(reject_id)
		assert reject_snapshot["slot_found"] == 0
		assert reject_snapshot["free_found"] == 0
		await env.wait_ctrl_resp(reject_plan.response_word, 4000)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_stress_near_full_b_capacity_reject(dut) -> None:
	if _is_dma_top():
		return
	env = await _prepare_env(dut)
	try:
		tile_elems = env.y_dim * env.y_dim
		reject_matrix = [idx & 0xFFFF_FFFF for idx in range(tile_elems)]
		target_fill = max(1, (2 * env.b_capacity_elems) - tile_elems + 1)
		fills_needed = (target_fill + tile_elems - 1) // tile_elems
		expected_reject = "reject:b_capacity" if fills_needed < env.lut_depth else "reject:lut_full_miss"
		filled = 0
		offset = 0

		while filled < target_fill:
			fill_matrix = [((idx + filled) & 0xFFFF_FFFF) for idx in range(tile_elems)]
			ctrl_id = 0xD00 + offset
			env.register_external_matrix("B", ctrl_id, fill_matrix)
			plan = env.plan_load(ctrl_id, 0, tile_elems, need_a=False, need_b=True)
			if plan.err:
				assert plan.reject_reason == expected_reject
				await env.send_ctrl(build_load_inst(0, tile_elems, need_a=False, need_b=True), ctrl_id)
				await env.wait_ctrl_resp(plan.response_word, 12000)
				return
			await env.send_ctrl(build_load_inst(0, tile_elems, need_a=False, need_b=True), ctrl_id)
			await env.wait_ctrl_resp(plan.response_word, 12000)
			filled += tile_elems
			offset += 1

		reject_id = 0xD10
		env.register_external_matrix("B", reject_id, reject_matrix)
		reject_plan = env.plan_load(reject_id, 0, len(reject_matrix), need_a=False, need_b=True)
		assert reject_plan.err
		assert reject_plan.reject_reason == expected_reject
		await env.send_ctrl(build_load_inst(0, len(reject_matrix), need_a=False, need_b=True), reject_id)
		await env.wait_ctrl_resp(reject_plan.response_word, 12000)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_stress_clear_recovery_phase_sweep(dut) -> None:
	env = await _prepare_env(dut)
	try:
		await env.pulse_clear(phase="pre_issue")
		await setup_bases_and_passthrough_qcfg(env)

		env.configure_patterns(dma_req_ready=ConstantPattern(0))
		inflight_id = 0xE00
		_register_ab(env, inflight_id, 1)
		inflight_plan = env.plan_matmul(inflight_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert not inflight_plan.err
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), inflight_id)
		await env.wait_signal_value("dma_req_valid", 1, 4000)
		await env.pulse_clear(phase="in_flight")
		await env.expect_no_ctrl_resp(8)

		env.configure_patterns(dma_req_ready=ConstantPattern(1))
		await setup_bases_and_passthrough_qcfg(env)

		recovery_id = 0xE10
		_register_ab(env, recovery_id, 2)
		recovery_plan = env.plan_matmul(recovery_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert not recovery_plan.err
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), recovery_id)
		await env.wait_ctrl_resp(recovery_plan.response_word, 12000)
		await env.wait_export_done(1, 20000)

		await env.pulse_clear(phase="post_export")
		await setup_bases_and_passthrough_qcfg(env)

		post_id = 0xE20
		_register_ab(env, post_id, 3)
		post_plan = env.plan_matmul(post_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert not post_plan.err
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), post_id)
		await env.wait_ctrl_resp(post_plan.response_word, 12000)
		await env.wait_export_done(2, 20000)
	finally:
		env.shutdown()
