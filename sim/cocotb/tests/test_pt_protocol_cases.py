from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles

from tests.pt_blackbox_env import AbInjection, ExportInjection, create_env, flatten_pattern_matrix, setup_bases_and_passthrough_qcfg
from tests.pt_model import (
	PT_QGRAN_PER_TENSOR,
	PT_QTYPE_SYMMETRIC,
	PT_SCALE_FULL,
	build_matadd_inst,
	build_matmul_inst,
	build_qcfg_header,
	pack_resp,
)


async def _prepare_env(dut):
	env = await create_env(dut)
	await setup_bases_and_passthrough_qcfg(env)
	return env


@cocotb.test()
async def test_pt_protocol_rejects_nonzero_reserved_matmul_and_bad_qtype(dut) -> None:
	env = await _prepare_env(dut)
	try:
		start = env.snapshot()
		plan = env.plan_matmul(0x200, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL, a_field=1)
		assert plan.err
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, a_field=1), 0x200)
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
		env.model.commit_success(plan)
		await env.wait_export_error(1, 4000)
		await env.wait_ctrl_resp(pack_resp(True, plan.success_buffer or 0, ctrl_id), 4000)
	finally:
		env.shutdown()
