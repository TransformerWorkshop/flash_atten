from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles

from tests.pt_blackbox_env import ConstantPattern, create_env, repeating_matrix, setup_bases_and_passthrough_qcfg
from tests.pt_model import (
	PT_SCALE_FULL,
	build_matmul_inst,
	identity_matrix,
)

@cocotb.test()
async def test_pt_state_clear_drops_cache_and_requires_reload(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		ctrl_id = 0x530
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, repeating_matrix(env.x_dim, [3, 5, 7, 9, 11, 13, 15, 17][: env.y_dim], env.data_width))
		first = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(first.response_word)
		env.model.commit_success(first)
		await env.wait_export_done(1)

		hit = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert len(hit.expected_dma_loads) == 0
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(hit.response_word)
		env.model.commit_success(hit)
		await env.wait_export_done(2)

		await env.pulse_clear()
		reload = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert len(reload.expected_dma_loads) == 2
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(reload.response_word)
		env.model.commit_success(reload)
		await env.wait_export_done(3)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_state_clear_mid_export_recovers(dut) -> None:
	env = await create_env(dut)
	try:
		env.configure_patterns(m_axis_ready=ConstantPattern(0))
		await setup_bases_and_passthrough_qcfg(env)
		ctrl_id = 0x540
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, repeating_matrix(env.x_dim, [1, 3, 5, 7, 9, 11, 13, 15][: env.y_dim], env.data_width))
		plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(plan.response_word)
		env.model.commit_success(plan)
		await env.wait_export_req(1)
		await ClockCycles(dut.clk, 4)
		await env.pulse_clear()
		env.configure_patterns(m_axis_ready=ConstantPattern(1))
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_state_cfg_base_hi_lo_still_acknowledges(dut) -> None:
	env = await create_env(dut)
	try:
		await env.cfg_base32("A", 0x1234_1000, 0x560)
		await env.cfg_base32("B", 0x5678_2000, 0x562)
		ctrl_id = 0x581
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, repeating_matrix(env.x_dim, [4, 8, 12, 16, 20, 24, 28, 32][: env.y_dim], env.data_width))
		plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(plan.response_word)
		env.model.commit_success(plan)
		await env.wait_export_done(1)
	finally:
		env.shutdown()
