from __future__ import annotations

import cocotb

from tests.pt_blackbox_env import create_env, flatten_pattern_matrix, repeating_matrix, setup_bases_and_passthrough_qcfg
from tests.pt_model import PT_SCALE_FULL, build_matadd_inst, build_matmul_inst, build_mwin_off, identity_matrix


@cocotb.test()
async def test_pt_smoke_cold_miss_then_same_id_hit(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		ctrl_id = 0x41
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, flatten_pattern_matrix(env.y_dim, 2, 1, 0))

		start = env.snapshot()
		first = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert len(first.expected_dma_loads) == 2
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(first.response_word)
		env.model.commit_success(first)
		await env.wait_export_done(start.export_done_count + 1)
		assert env.dma_req_count - start.dma_req_count == 2

		hit_start = env.snapshot()
		second = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert len(second.expected_dma_loads) == 0
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(second.response_word)
		env.model.commit_success(second)
		await env.wait_export_done(hit_start.export_done_count + 1)
		assert env.dma_req_count - hit_start.dma_req_count == 0
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_smoke_matadd_c_miss_then_c_hit(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		ctrl_id = 0x42
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, repeating_matrix(env.x_dim, [2, 4, 6, 8, 10, 12, 14, 16][: env.y_dim], env.data_width))
		env.register_external_matrix("C", ctrl_id, flatten_pattern_matrix(env.y_dim, 1, 2, 3))

		matmul = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		resp = await env.wait_ctrl_resp(matmul.response_word)
		env.model.commit_success(matmul)
		await env.wait_export_done(1)

		m_off = build_mwin_off((resp >> 30) & 0x1, 0)
		start = env.snapshot()
		add_miss = env.plan_matadd(ctrl_id, m_off)
		assert [req.kind for req in add_miss.expected_dma_loads] == ["C"]
		await env.send_ctrl(build_matadd_inst(m_off), ctrl_id)
		await env.wait_ctrl_resp(add_miss.response_word)
		env.model.commit_success(add_miss)
		await env.wait_export_done(start.export_done_count + 1)
		assert env.dma_req_count - start.dma_req_count == 1

		m_off_hit = build_mwin_off(add_miss.success_buffer or 0, 0)
		hit_start = env.snapshot()
		add_hit = env.plan_matadd(ctrl_id, m_off_hit)
		assert len(add_hit.expected_dma_loads) == 0
		await env.send_ctrl(build_matadd_inst(m_off_hit), ctrl_id)
		await env.wait_ctrl_resp(add_hit.response_word)
		env.model.commit_success(add_hit)
		await env.wait_export_done(hit_start.export_done_count + 1)
		assert env.dma_req_count - hit_start.dma_req_count == 0
	finally:
		env.shutdown()
