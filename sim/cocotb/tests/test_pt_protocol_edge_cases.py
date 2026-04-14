from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles

from tests.pt_blackbox_env import AbInjection, create_env, flatten_pattern_matrix, repeating_matrix, setup_bases_and_passthrough_qcfg
from tests.pt_model import (
	PT_SCALE_FULL,
	build_matadd_inst,
	build_load_inst,
	build_matmul_inst,
	build_mwin_off,
	identity_matrix,
	pack_resp,
)


async def _prepare_env(dut):
	env = await create_env(dut)
	await setup_bases_and_passthrough_qcfg(env)
	return env


@cocotb.test()
async def test_pt_protocol_edge_unknown_opcode_and_midstream_dma_error(dut) -> None:
	env = await _prepare_env(dut)
	try:
		await env.send_ctrl(0x0000_0000, 0x700)
		await env.wait_ctrl_resp(pack_resp(True, 0, 0x700), 500)

		ctrl_id = 0x701
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, flatten_pattern_matrix(env.y_dim, 2, 1, 0))
		env.queue_ab_injection(AbInjection(error_mode="mid_stream", error_at_beat=1, done_delay=1))
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 4000)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_protocol_edge_bslot_overwritten_by_c_then_b_reloads(dut) -> None:
	env = await _prepare_env(dut)
	try:
		ctrl_id = 0x702
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, flatten_pattern_matrix(env.y_dim, 2, 1, 0))
		env.register_external_matrix("C", ctrl_id, repeating_matrix(env.x_dim, [1, 3, 5, 7, 9, 11, 13, 15][: env.y_dim], env.data_width))

		load = env.plan_load(ctrl_id, env.x_dim * env.x_dim, env.y_dim * env.y_dim, need_a=True, need_b=True)
		await env.send_ctrl(build_load_inst(env.x_dim * env.x_dim, env.y_dim * env.y_dim, need_a=True, need_b=True), ctrl_id)
		await env.wait_ctrl_resp(load.response_word)
		env.model.commit_load_success(load)

		matmul_hit = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert len(matmul_hit.expected_dma_loads) == 0
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		matmul_resp = await env.wait_ctrl_resp(matmul_hit.response_word)
		env.model.commit_success(matmul_hit)
		await env.wait_export_done(1)

		m_off = build_mwin_off((matmul_resp >> 30) & 0x1, 0)
		matadd = env.plan_matadd(ctrl_id, m_off)
		assert [req.kind for req in matadd.expected_dma_loads] == ["C"]
		await env.send_ctrl(build_matadd_inst(m_off), ctrl_id)
		await env.wait_ctrl_resp(matadd.response_word)
		env.model.commit_success(matadd)
		await env.wait_export_done(2)

		reload_b = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert [req.kind for req in reload_b.expected_dma_loads] == ["B"]
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(reload_b.response_word)
		env.model.commit_success(reload_b)
		await env.wait_export_done(3)
	finally:
		env.shutdown()
