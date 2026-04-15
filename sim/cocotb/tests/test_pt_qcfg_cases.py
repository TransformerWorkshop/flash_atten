from __future__ import annotations

import cocotb

from tests.pt_blackbox_env import create_env, repeating_matrix
from tests.pt_model import (
	PT_QGRAN_PER_TENSOR,
	PT_QGRAN_X_WISE,
	PT_QGRAN_Y_WISE,
	PT_QGRAN_X_WISE_DIV2,
	PT_QGRAN_Y_WISE_DIV2,
	PT_SCALE_FULL,
	build_matmul_inst,
	identity_matrix,
	qcfg_payload_count,
)


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
			env.register_external_matrix("B", ctrl_id + idx, repeating_matrix(env.x_dim, [idx + 1, idx + 2, idx + 3, idx + 4][: env.y_dim], env.data_width))
			plan = env.plan_matmul(ctrl_id + idx, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id + idx)
			await env.wait_ctrl_resp(plan.response_word)
			if not plan.err:
				env.model.commit_success(plan)
				target_done += 1
				await env.wait_export_done(target_done)
	finally:
		env.shutdown()
