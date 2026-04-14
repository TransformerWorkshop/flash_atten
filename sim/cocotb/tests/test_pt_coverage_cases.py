from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles

from tests.pt_blackbox_env import (
	ExportInjection,
	create_env,
	flatten_pattern_matrix,
	repeating_matrix,
	setup_bases_and_passthrough_qcfg,
)
from tests.pt_model import (
	PT_SCALE_FULL,
	build_load_inst,
	build_matadd_inst,
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
async def test_pt_coverage_load_fit_nofit_and_size_mismatch(dut) -> None:
	env = await _prepare_env(dut)
	try:
		ctrl_id = 0x900
		a_matrix = identity_matrix(env.x_dim, env.data_width)
		env.register_external_matrix("A", ctrl_id, a_matrix)

		ok = env.plan_load(ctrl_id, len(a_matrix), 0, need_a=True, need_b=False)
		assert not ok.err
		await env.send_ctrl(build_load_inst(len(a_matrix), 0, need_a=True, need_b=False), ctrl_id)
		await env.wait_ctrl_resp(ok.response_word)
		env.model.commit_load_success(ok)

		mismatch = env.plan_load(ctrl_id, len(a_matrix) + env.x_dim, 0, need_a=True, need_b=False)
		assert mismatch.err
		await env.send_ctrl(build_load_inst(len(a_matrix) + env.x_dim, 0, need_a=True, need_b=False), ctrl_id)
		await env.wait_ctrl_resp(mismatch.response_word, 500)

		oversize = env.plan_load(0x8EE, env.a_bank_depth * env.x_dim * 3, 0, need_a=True, need_b=False)
		assert oversize.err
		await env.send_ctrl(build_load_inst(env.a_bank_depth * env.x_dim * 3, 0, need_a=True, need_b=False), 0x8EE)
		await env.wait_ctrl_resp(pack_resp(True, 0, 0x8EE), 500)

		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, 0, PT_SCALE_FULL), 0x8F0)
		await env.wait_ctrl_resp(pack_resp(True, 0, 0x8F0), 500)
		await env.send_ctrl(build_matadd_inst(0, c_field=1), 0x8F1)
		await env.wait_ctrl_resp(pack_resp(True, 0, 0x8F1), 500)
	finally:
		env.shutdown()

@cocotb.test()
async def test_pt_coverage_bslot_c_overwrite_and_export_error(dut) -> None:
	env = await _prepare_env(dut)
	try:
		ctrl_id = 0x901
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, flatten_pattern_matrix(env.y_dim, 2, 1, 0))
		env.register_external_matrix("C", ctrl_id, repeating_matrix(env.x_dim, [1, 2, 3, 4][: env.y_dim], env.data_width))
		matmul = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		resp = await env.wait_ctrl_resp(matmul.response_word)
		env.model.commit_success(matmul)
		await env.wait_export_done(1)

		m_off = build_mwin_off((resp >> 30) & 0x1, 0)
		matadd = env.plan_matadd(ctrl_id, m_off)
		await env.send_ctrl(build_matadd_inst(m_off), ctrl_id)
		await env.wait_ctrl_resp(matadd.response_word)
		env.model.commit_success(matadd)
		await env.wait_export_done(2)

		reload_b = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert [req.kind for req in reload_b.expected_dma_loads] == ["B"]
		env.queue_export_injection(ExportInjection(error=True, done_delay=1))
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(reload_b.response_word)
		env.model.commit_success(reload_b)
		await env.wait_export_error(1, 4000)
		await env.wait_ctrl_resp(pack_resp(True, reload_b.success_buffer or 0, ctrl_id), 4000)
	finally:
		env.shutdown()
