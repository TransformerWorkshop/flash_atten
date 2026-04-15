from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles

from tests.pt_blackbox_env import (
	AbInjection,
	ExportInjection,
	SequencePattern,
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

		oversize_id = 0x8EE
		oversize_len = env.a_capacity_elems + 1
		env.register_external_matrix("A", oversize_id, [0] * oversize_len)
		oversize = env.plan_load(0x8EE, oversize_len, 0, need_a=True, need_b=False)
		assert oversize.err
		await env.send_ctrl(build_load_inst(oversize_len, 0, need_a=True, need_b=False), oversize_id)
		await env.wait_ctrl_resp(pack_resp(True, 0, oversize_id), 500)

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
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(reload_b.response_word)
		if reload_b.err:
			assert reload_b.expected_dma_loads == []
		else:
			assert [req.kind for req in reload_b.expected_dma_loads] == ["B"]
			env.queue_export_injection(ExportInjection(error=True, done_delay=1))
			env.model.commit_success(reload_b)
			await env.wait_export_error(1, 4000)
			await env.wait_ctrl_resp(pack_resp(True, reload_b.success_buffer or 0, ctrl_id), 4000)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_coverage_wide_load_tail_and_fill_error_matrix(dut) -> None:
	env = await _prepare_env(dut)
	try:
		a_tail_len = env.a_load_lanes + 1
		b_tail_len = env.b_load_lanes + 1
		b_wrong_len = max(1, env.b_load_lanes)

		a_ok_id = 0x902
		a_ok_matrix = [idx + 1 for idx in range(a_tail_len)]
		env.register_external_matrix("A", a_ok_id, a_ok_matrix)
		a_ok = env.plan_load(a_ok_id, a_tail_len, 0, need_a=True, need_b=False)
		assert not a_ok.err
		await env.send_ctrl(build_load_inst(a_tail_len, 0, need_a=True, need_b=False), a_ok_id)
		await env.wait_ctrl_resp(a_ok.response_word, 4000)
		env.model.commit_load_success(a_ok)

		if env.b_load_lanes == 1:
			b_wrong_id = 0x903
			b_wrong_matrix = [idx + 0x20 for idx in range(b_wrong_len)]
			env.register_external_matrix("B", b_wrong_id, b_wrong_matrix)
			env.queue_ab_injection(AbInjection(wrong_tuser=True))
			await env.send_ctrl(build_load_inst(0, b_wrong_len, need_a=False, need_b=True), b_wrong_id)
			await env.wait_ctrl_resp(pack_resp(True, 0, b_wrong_id), 4000)

			b_err_id = 0x904
			b_err_matrix = [idx + 0x40 for idx in range(b_tail_len)]
			env.register_external_matrix("B", b_err_id, b_err_matrix)
			env.queue_ab_injection(AbInjection(error_mode="mid_stream", error_at_beat=0, done_delay=1))
			await env.send_ctrl(build_load_inst(0, b_tail_len, need_a=False, need_b=True), b_err_id)
			await env.wait_ctrl_resp(pack_resp(True, 0, b_err_id), 4000)

		b_ok_id = 0x905
		b_ok_matrix = [idx + 0x60 for idx in range(b_tail_len)]
		env.register_external_matrix("B", b_ok_id, b_ok_matrix)
		b_ok = env.plan_load(b_ok_id, 0, b_tail_len, need_a=False, need_b=True)
		assert not b_ok.err
		await env.send_ctrl(build_load_inst(0, b_tail_len, need_a=False, need_b=True), b_ok_id)
		await env.wait_ctrl_resp(b_ok.response_word, 4000)
		env.model.commit_load_success(b_ok)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_coverage_export_ready_and_error_phase_sweep(dut) -> None:
	env = await _prepare_env(dut)
	try:
		env.configure_patterns(
			m_dma_req_ready=SequencePattern([0, 0, 1, 1, 1, 1]),
			m_axis_ready=SequencePattern([0, 1, 0, 1, 1, 0, 1, 1]),
		)

		ctrl_id = 0x906
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, flatten_pattern_matrix(env.y_dim, 3, 1, 2))
		plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert not plan.err
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(plan.response_word, 12000)
		env.model.commit_success(plan)
		await env.wait_export_done(1, 20000)

		err_id = 0x907
		env.register_external_matrix("A", err_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", err_id, flatten_pattern_matrix(env.y_dim, 2, 2, 5))
		env.queue_export_injection(ExportInjection(error=True, done_delay=2))
		err_plan = env.plan_matmul(err_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert not err_plan.err
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), err_id)
		await env.wait_ctrl_resp(err_plan.response_word, 12000)
		env.model.commit_success(err_plan)
		await env.wait_export_error(1, 20000)
		await env.wait_ctrl_resp(pack_resp(True, err_plan.success_buffer or 0, err_id), 4000)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_coverage_qcfg_entropy_and_base_hi_sweep(dut) -> None:
	env = await _prepare_env(dut)
	try:
		await env.cfg_base32("A", 0x1234_1000, 0x930)
		await env.cfg_base32("B", 0xFEDC_2000, 0x932)

		x_scales = [
			0x0001_0000,
			0xFFFF_0000,
			0x1234_5678,
			0x8000_0001,
			0x7FFF_0000,
			0x00FF_0001,
			0xFF00_8000,
			0x1357_9BDF,
		][: env.x_dim]
		await env.qcfg_success(1, x_scales, 0x940)

		y_scales = [
			0x0000_8000,
			0xFFFF_8000,
			0x1111_0001,
			0xEEEE_0002,
			0x0001_FFFF,
			0x8000_7FFF,
			0x2468_ACF0,
			0x1357_0246,
		][: env.y_dim]
		await env.qcfg_success(2, y_scales, 0x941)

		ctrl_id = 0x942
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, flatten_pattern_matrix(env.y_dim, 4, 3, 1))
		plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert not plan.err
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(plan.response_word, 12000)
		env.model.commit_success(plan)
		await env.wait_export_done(1, 20000)
	finally:
		env.shutdown()
