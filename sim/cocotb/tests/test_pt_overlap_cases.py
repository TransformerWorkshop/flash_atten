from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge

from tests.pt_blackbox_env import ConstantPattern, create_env, flatten_pattern_matrix, setup_bases_and_passthrough_qcfg, value_to_int
from tests.pt_model import PT_SCALE_FULL, build_load_inst, build_matmul_inst


async def _prepare_env(dut):
	env = await create_env(dut)
	await setup_bases_and_passthrough_qcfg(env)
	return env


def _register_ab(env, ctrl_id: int, bias: int) -> None:
	env.register_external_matrix("A", ctrl_id, flatten_pattern_matrix(env.x_dim, 3, 1, bias))
	env.register_external_matrix("B", ctrl_id, flatten_pattern_matrix(env.y_dim, 2, 2, bias + 1))


async def _warm_cache(env, ctrl_id: int, inst: int) -> None:
	plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
	assert not plan.err
	await env.send_ctrl(inst, ctrl_id)
	await env.wait_ctrl_resp(plan.response_word, 12000)
	await env.wait_export_done(1, 20000)


async def _wait_ce_overlap(dut, timeout_cycles: int = 4000) -> None:
	for _ in range(timeout_cycles):
		await RisingEdge(dut.clk)
		if value_to_int(dut.u_pt_v2.u_ce.u_ce_v2.exec_valid_r.value) and value_to_int(dut.u_pt_v2.u_ce.u_ce_v2.drain_valid_r.value):
			return
	raise AssertionError("timeout waiting CE exec/drain overlap")


@cocotb.test()
async def test_pt_overlap_second_matmul_accepts_before_first_resp(dut) -> None:
	env = await _prepare_env(dut)
	try:
		ctrl_id = 0xA10
		inst = build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL)
		_register_ab(env, ctrl_id, 3)
		await _warm_cache(env, ctrl_id, inst)

		first_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		second_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert not first_plan.err and not second_plan.err

		await env.send_ctrl_timed(inst, ctrl_id, 4000)
		second_send = cocotb.start_soon(env.send_ctrl_timed(inst, ctrl_id, 12000))
		second_trace = await second_send
		assert second_trace.wait_cycles >= 1
		assert not env.ctrl_resp_queue, "second MATMUL should be accepted before first ctrl_resp is observed"

		await _wait_ce_overlap(dut, 4000)
		await env.wait_ctrl_resp(first_plan.response_word, 12000)
		await env.wait_ctrl_resp(second_plan.response_word, 12000)
		await env.wait_export_done(3, 20000)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_overlap_export_backpressure_keeps_second_matmul_running(dut) -> None:
	env = await _prepare_env(dut)
	try:
		ctrl_id = 0xA20
		inst = build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL)
		_register_ab(env, ctrl_id, 5)
		await _warm_cache(env, ctrl_id, inst)

		snapshot = env.snapshot()
		env.configure_patterns(m_axis_ready=ConstantPattern(0))

		first_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		second_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert not first_plan.err and not second_plan.err

		await env.send_ctrl(inst, ctrl_id)
		await env.send_ctrl(inst, ctrl_id)
		await env.wait_ctrl_resp(first_plan.response_word, 12000)
		await env.wait_ctrl_resp(second_plan.response_word, 12000)
		assert env.export_done_count == snapshot.export_done_count, "export backpressure should keep both new exports pending"

		env.configure_patterns(m_axis_ready=ConstantPattern(1))
		await env.wait_export_done(snapshot.export_done_count + 2, 20000)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_overlap_third_matmul_backpressured_when_no_m_buffer_free(dut) -> None:
	env = await _prepare_env(dut)
	try:
		ctrl_id = 0xA30
		inst = build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL)
		_register_ab(env, ctrl_id, 7)
		await _warm_cache(env, ctrl_id, inst)

		env.configure_patterns(m_axis_ready=ConstantPattern(0))
		first_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		second_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert not first_plan.err and not second_plan.err

		await env.send_ctrl(inst, ctrl_id)
		await env.send_ctrl(inst, ctrl_id)
		third_send = cocotb.start_soon(env.send_ctrl_timed(inst, ctrl_id, 12000))

		await env.wait_ctrl_resp(first_plan.response_word, 12000)
		await env.wait_ctrl_resp(second_plan.response_word, 12000)
		for _ in range(4):
			await RisingEdge(dut.clk)
		assert value_to_int(dut.u_pt_v2.m_alloc_ready.value) == 0, "allocator should report no free M buffer"
		assert value_to_int(dut.u_pt_v2.u_malloc.state_r.value) == 5, "third MATMUL should stall in PT_MALLOC ST_CE_REQ while waiting for a free M buffer"
		await env.expect_no_ctrl_resp(8)

		try:
			third_send.kill()
		except Exception:
			pass
		await env.pulse_clear(phase="two_inflight_overlap")
		await env.expect_no_ctrl_resp(8)

		await setup_bases_and_passthrough_qcfg(env)
		recovery_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert not recovery_plan.err
		await env.send_ctrl(inst, ctrl_id)
		await env.wait_ctrl_resp(recovery_plan.response_word, 12000)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_overlap_non_matmul_waits_until_overlap_drains(dut) -> None:
	env = await _prepare_env(dut)
	try:
		ctrl_id = 0xA40
		load_id = 0xA41
		inst = build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL)
		_register_ab(env, ctrl_id, 9)
		env.register_external_matrix("A", load_id, flatten_pattern_matrix(env.x_dim, 1, 1, 4))
		await _warm_cache(env, ctrl_id, inst)

		first_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		second_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		load_plan = env.plan_load(load_id, env.x_dim * env.x_dim, 0, need_a=True, need_b=False)
		assert not first_plan.err and not second_plan.err and not load_plan.err

		await env.send_ctrl(inst, ctrl_id)
		await env.send_ctrl(inst, ctrl_id)
		load_send = cocotb.start_soon(env.send_ctrl_timed(build_load_inst(env.x_dim * env.x_dim, 0, need_a=True, need_b=False), load_id, 12000))

		await env.wait_ctrl_resp(first_plan.response_word, 12000)
		await env.wait_ctrl_resp(second_plan.response_word, 12000)
		load_trace = await load_send
		assert load_trace.wait_cycles >= 1
		await env.wait_ctrl_resp(load_plan.response_word, 12000)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_overlap_clear_recovers_from_two_inflight_matmuls(dut) -> None:
	env = await _prepare_env(dut)
	try:
		ctrl_id = 0xA50
		inst = build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL)
		_register_ab(env, ctrl_id, 11)
		await _warm_cache(env, ctrl_id, inst)

		first_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		second_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert not first_plan.err and not second_plan.err

		await env.send_ctrl(inst, ctrl_id)
		await env.send_ctrl(inst, ctrl_id)
		await _wait_ce_overlap(dut, 4000)
		await env.pulse_clear(phase="overlap_two_matmul")
		await env.expect_no_ctrl_resp(8)

		await setup_bases_and_passthrough_qcfg(env)
		recovery_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert not recovery_plan.err
		await env.send_ctrl(inst, ctrl_id)
		await env.wait_ctrl_resp(recovery_plan.response_word, 12000)
	finally:
		env.shutdown()
