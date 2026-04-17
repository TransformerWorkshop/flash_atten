from __future__ import annotations

import cocotb

from tests.pt_dma_top_env import create_env, setup_bases_and_passthrough_qcfg
from tests.pt_model import PT_SCALE_FULL, build_matmul_inst, identity_matrix


def sequential_row_major(dim: int) -> list[list[int]]:
	value = 1
	matrix: list[list[int]] = []
	for _ in range(dim):
		row: list[int] = []
		for _ in range(dim):
			row.append(value)
			value += 1
		matrix.append(row)
	return matrix


@cocotb.test()
async def test_pt_dma_top_direct_matmul_identity(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		ctrl_id = 0xD00
		env.register_external_matrix("A", ctrl_id, sequential_row_major(env.x_dim))
		env.register_external_matrix("B", ctrl_id, identity_matrix(env.y_dim, env.data_width))
		await env.send_desc_command(
			build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL),
			ctrl_id,
			a_addr=0x1000_1000,
			b_addr=0x1000_2000,
			m_addr=0x1000_3000,
		)
		plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		await env.wait_and_pop_resp(plan.response_word, 40000)
		await env.wait_export_done(1, 80000)
	finally:
		env.shutdown()
