from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles

from tests.pt_blackbox_env import (
	AbInjection,
	ConstantPattern,
	ExportInjection,
	create_env,
	flatten_pattern_matrix,
	repeating_matrix,
	setup_bases_and_passthrough_qcfg,
)
from tests.pt_model import (
	PT_QGRAN_PER_TENSOR,
	PT_QGRAN_X_WISE,
	PT_QGRAN_X_WISE_DIV2,
	PT_QGRAN_Y_WISE,
	PT_QGRAN_Y_WISE_DIV2,
	PT_QTYPE_SYMMETRIC,
	PT_SCALE_FULL,
	build_load_inst,
	build_matadd_inst,
	build_matmul_inst,
	build_mwin_off,
	build_qcfg_header,
	constant_matrix,
	identity_matrix,
	pack_resp,
	qcfg_payload_count,
	zero_matrix,
)


async def _prepare_env(dut):
	env = await create_env(dut)
	await setup_bases_and_passthrough_qcfg(env)
	return env


@cocotb.test()
async def test_pt_smoke_cold_miss_then_same_id_hit(dut) -> None:
	env = await _prepare_env(dut)
	try:
		ctrl_id = 0x41
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, flatten_pattern_matrix(env.y_dim, 2, 1, 0))

		start = env.snapshot()
		first = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert len(first.expected_dma_loads) == 2
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(first.response_word)
		await env.wait_export_done(start.export_done_count + 1)
		assert env.dma_req_count - start.dma_req_count == 2

		hit_start = env.snapshot()
		second = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert len(second.expected_dma_loads) == 0
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(second.response_word)
		await env.wait_export_done(hit_start.export_done_count + 1)
		assert env.dma_req_count - hit_start.dma_req_count == 0
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_smoke_matadd_c_miss_then_c_hit(dut) -> None:
	env = await _prepare_env(dut)
	try:
		ctrl_id = 0x42
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, repeating_matrix(env.x_dim, [2, 4, 6, 8, 10, 12, 14, 16][: env.y_dim], env.data_width))
		env.register_external_matrix("C", ctrl_id, flatten_pattern_matrix(env.y_dim, 1, 2, 3))

		matmul = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		resp = await env.wait_ctrl_resp(matmul.response_word)
		await env.wait_export_done(1)

		m_off = build_mwin_off((resp >> 30) & 0x1, 0)
		start = env.snapshot()
		add_miss = env.plan_matadd(ctrl_id, m_off)
		assert [req.kind for req in add_miss.expected_dma_loads] == ["C"]
		await env.send_ctrl(build_matadd_inst(m_off), ctrl_id)
		await env.wait_ctrl_resp(add_miss.response_word)
		await env.wait_export_done(start.export_done_count + 1)
		assert env.dma_req_count - start.dma_req_count == 1

		m_off_hit = build_mwin_off(add_miss.success_buffer or 0, 0)
		hit_start = env.snapshot()
		add_hit = env.plan_matadd(ctrl_id, m_off_hit)
		assert len(add_hit.expected_dma_loads) == 0
		await env.send_ctrl(build_matadd_inst(m_off_hit), ctrl_id)
		await env.wait_ctrl_resp(add_hit.response_word)
		await env.wait_export_done(hit_start.export_done_count + 1)
		assert env.dma_req_count - hit_start.dma_req_count == 0
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_numeric_quant_per_tensor_saturation(dut) -> None:
	env = await _prepare_env(dut)
	try:
		ctrl_id = 0x80
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, constant_matrix(env.x_dim, env.y_dim, (1 << 30), env.data_width))
		await env.qcfg_success(0, [0x0002_0000], 0x40)
		plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(plan.response_word)
		await env.wait_export_done(1)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_numeric_axis_qcfg_modes(dut) -> None:
	env = await _prepare_env(dut)
	try:
		ctrl_id = 0x81
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, repeating_matrix(env.x_dim, [3, -2, 5, -4, 7, -6, 9, -8][: env.y_dim], env.data_width))

		await env.qcfg_success(PT_QGRAN_X_WISE, [0x0001_0000] * env.x_dim, 0x41)
		plan_x = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(plan_x.response_word)
		await env.wait_export_done(1)

		ctrl_id_y = 0x82
		env.register_external_matrix("A", ctrl_id_y, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id_y, zero_matrix(env.x_dim, env.y_dim))
		await env.qcfg_success(PT_QGRAN_Y_WISE, [0x0001_0000] * env.y_dim, 0x42)
		plan_y = env.plan_matmul(ctrl_id_y, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id_y)
		await env.wait_ctrl_resp(plan_y.response_word)
		await env.wait_export_done(2)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_qcfg_supported_granularity_sweep(dut) -> None:
	env = await create_env(dut)
	try:
		await env.cfg_base("A", env.a_base, 0x10)
		await env.cfg_base("B", env.b_base, 0x11)

		ctrl_id = 0x140
		target_done = 0
		for idx, granularity in enumerate(
			[PT_QGRAN_PER_TENSOR, PT_QGRAN_X_WISE, PT_QGRAN_Y_WISE, PT_QGRAN_X_WISE_DIV2, PT_QGRAN_Y_WISE_DIV2]
		):
			payload_count = qcfg_payload_count(granularity, env.x_dim, env.y_dim)
			if payload_count is None:
				continue
			scales = [0x0001_0000 + (idx * 0x1000)] * payload_count
			await env.qcfg_success(granularity, scales, 0x100 + idx)
			env.register_external_matrix("A", ctrl_id + idx, identity_matrix(env.x_dim, env.data_width))
			env.register_external_matrix(
				"B",
				ctrl_id + idx,
				repeating_matrix(env.x_dim, [idx + 1, idx + 2, idx + 3, idx + 4][: env.y_dim], env.data_width),
			)
			plan = env.plan_matmul(ctrl_id + idx, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id + idx)
			await env.wait_ctrl_resp(plan.response_word)
			target_done += 1
			await env.wait_export_done(target_done)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_protocol_rejects_nonzero_reserved_matmul_and_bad_qtype(dut) -> None:
	env = await _prepare_env(dut)
	try:
		start = env.snapshot()
		plan = env.plan_matmul(0x200, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL, reserved_a=1)
		assert plan.err
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, reserved_a=1), 0x200)
		await env.wait_ctrl_resp(plan.response_word, 500)
		await ClockCycles(dut.clk, 4)
		assert env.dma_req_count == start.dma_req_count
		assert env.irq_count == start.irq_count + 1

		await env.send_ctrl(build_qcfg_header(PT_QGRAN_PER_TENSOR, qtype=PT_QTYPE_SYMMETRIC ^ 0b01), 0x201)
		await env.wait_ctrl_resp(pack_resp(True, 0, 0x201), 500)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_protocol_rejects_invalid_matadd_encoding(dut) -> None:
	env = await _prepare_env(dut)
	try:
		plan = env.plan_matadd(0x210, 0, c_field=1)
		assert plan.err
		await env.send_ctrl(build_matadd_inst(0, c_field=1), 0x210)
		await env.wait_ctrl_resp(plan.response_word, 500)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_protocol_handles_wrong_tuser_and_dma_error(dut) -> None:
	env = await _prepare_env(dut)
	try:
		ctrl_id = 0x220
		env.register_external_matrix("A", ctrl_id, flatten_pattern_matrix(env.x_dim, 1, 1, 0))
		env.register_external_matrix("B", ctrl_id, flatten_pattern_matrix(env.y_dim, 2, 1, 0))

		env.queue_ab_injection(AbInjection(wrong_tuser=True))
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 3000)

		ctrl_id = 0x221
		env.register_external_matrix("A", ctrl_id, flatten_pattern_matrix(env.x_dim, 1, 1, 0))
		env.register_external_matrix("B", ctrl_id, flatten_pattern_matrix(env.y_dim, 2, 1, 0))
		env.queue_ab_injection(AbInjection(error_mode="before_stream", done_delay=1))
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 3000)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_protocol_surfaces_export_error_after_success(dut) -> None:
	env = await _prepare_env(dut)
	try:
		ctrl_id = 0x230
		env.register_external_matrix("A", ctrl_id, flatten_pattern_matrix(env.x_dim, 1, 1, 0))
		env.register_external_matrix("B", ctrl_id, flatten_pattern_matrix(env.y_dim, 2, 1, 0))
		env.queue_export_injection(ExportInjection(error=True, done_delay=1))
		plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(plan.response_word, 4000)
		await env.wait_export_error(1, 4000)
		await env.wait_ctrl_resp(pack_resp(True, plan.success_buffer or 0, ctrl_id), 4000)
	finally:
		env.shutdown()


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

		matmul_hit = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert len(matmul_hit.expected_dma_loads) == 0
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		matmul_resp = await env.wait_ctrl_resp(matmul_hit.response_word)
		await env.wait_export_done(1)

		m_off = build_mwin_off((matmul_resp >> 30) & 0x1, 0)
		matadd = env.plan_matadd(ctrl_id, m_off)
		assert [req.kind for req in matadd.expected_dma_loads] == ["C"]
		await env.send_ctrl(build_matadd_inst(m_off), ctrl_id)
		await env.wait_ctrl_resp(matadd.response_word)
		await env.wait_export_done(2)

		reload_b = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert [req.kind for req in reload_b.expected_dma_loads] == ["B"]
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(reload_b.response_word)
		await env.wait_export_done(3)
	finally:
		env.shutdown()


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
		await env.wait_export_done(1)

		hit = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert len(hit.expected_dma_loads) == 0
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(hit.response_word)
		await env.wait_export_done(2)

		await env.pulse_clear()
		reload = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert len(reload.expected_dma_loads) == 2
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(reload.response_word)
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
		await env.wait_export_done(1)
	finally:
		env.shutdown()
