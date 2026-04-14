from __future__ import annotations

import cocotb

from tests.pt_blackbox_env import create_env, repeating_matrix, setup_bases_and_passthrough_qcfg
from tests.pt_model import (
	PT_QGRAN_X_WISE,
	PT_QGRAN_Y_WISE,
	PT_SCALE_FULL,
	build_matmul_inst,
	constant_matrix,
	identity_matrix,
	zero_matrix,
)

@cocotb.test()
async def test_pt_numeric_quant_per_tensor_saturation(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		ctrl_id = 0x80
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, constant_matrix(env.x_dim, env.y_dim, (1 << 30), env.data_width))
		await env.qcfg_success(0, [0x0002_0000], 0x40)
		plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(plan.response_word)
		env.model.commit_success(plan)
		await env.wait_export_done(1)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_numeric_axis_qcfg_modes(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		ctrl_id = 0x81
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, repeating_matrix(env.x_dim, [3, -2, 5, -4, 7, -6, 9, -8][: env.y_dim], env.data_width))

		await env.qcfg_success(PT_QGRAN_X_WISE, [0x0001_0000] * env.x_dim, 0x41)
		plan_x = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(plan_x.response_word)
		env.model.commit_success(plan_x)
		await env.wait_export_done(1)

		ctrl_id_y = 0x82
		env.register_external_matrix("A", ctrl_id_y, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id_y, zero_matrix(env.x_dim, env.y_dim))
		await env.qcfg_success(PT_QGRAN_Y_WISE, [0x0001_0000] * env.y_dim, 0x42)
		plan_y = env.plan_matmul(ctrl_id_y, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id_y)
		await env.wait_ctrl_resp(plan_y.response_word)
		env.model.commit_success(plan_y)
		await env.wait_export_done(2)
	finally:
		env.shutdown()
