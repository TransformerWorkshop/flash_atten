from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles

from tests.pt_blackbox_env import create_env, repeating_matrix, setup_bases_and_passthrough_qcfg
from tests.pt_model import PT_SCALE_FULL, build_load_inst, build_matmul_inst, identity_matrix


@cocotb.test()
async def test_pt_load_ab_reuse_then_matmul_hit(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		ctrl_id = 0x900
		a_matrix = identity_matrix(env.x_dim, env.data_width)
		b_matrix = repeating_matrix(env.x_dim, [2, 4, 6, 8, 10, 12, 14, 16][: env.y_dim], env.data_width)
		env.register_external_matrix("A", ctrl_id, a_matrix)
		env.register_external_matrix("B", ctrl_id, b_matrix)

		start = env.snapshot()
		load_plan = env.plan_load(ctrl_id, len(a_matrix), len(b_matrix), need_a=True, need_b=True)
		assert not load_plan.err
		assert [req.kind for req in load_plan.expected_dma_loads] == ["A", "B"]
		await env.send_ctrl(build_load_inst(len(a_matrix), len(b_matrix), need_a=True, need_b=True), ctrl_id)
		await env.wait_ctrl_resp(load_plan.response_word)
		env.model.commit_load_success(load_plan)
		await ClockCycles(dut.clk, 8)
		assert env.dma_req_count - start.dma_req_count == 2
		assert env.export_req_count == start.export_req_count
		assert env.irq_count == start.irq_count

		matmul_start = env.snapshot()
		matmul_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert not matmul_plan.err
		assert len(matmul_plan.expected_dma_loads) == 0
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(matmul_plan.response_word)
		env.model.commit_success(matmul_plan)
		await env.wait_export_done(matmul_start.export_done_count + 1)
		assert env.dma_req_count - matmul_start.dma_req_count == 0
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_load_a_only_then_single_side_matmul_miss(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		ctrl_id = 0x901
		a_matrix = identity_matrix(env.x_dim, env.data_width)
		b_matrix = repeating_matrix(env.x_dim, [3, 5, 7, 9, 11, 13, 15, 17][: env.y_dim], env.data_width)
		env.register_external_matrix("A", ctrl_id, a_matrix)
		env.register_external_matrix("B", ctrl_id, b_matrix)

		load_start = env.snapshot()
		load_plan = env.plan_load(ctrl_id, len(a_matrix), len(b_matrix), need_a=True, need_b=False)
		assert not load_plan.err
		assert len(load_plan.expected_dma_loads) == 1
		assert load_plan.expected_dma_loads[0].kind == "A"
		await env.send_ctrl(build_load_inst(len(a_matrix), len(b_matrix), need_a=True, need_b=False), ctrl_id)
		await env.wait_ctrl_resp(load_plan.response_word)
		env.model.commit_load_success(load_plan)
		await ClockCycles(dut.clk, 8)
		assert env.dma_req_count - load_start.dma_req_count == 1
		assert env.irq_count == load_start.irq_count

		matmul_start = env.snapshot()
		matmul_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		assert not matmul_plan.err
		assert len(matmul_plan.expected_dma_loads) == 1
		assert matmul_plan.expected_dma_loads[0].kind == "B"
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
		await env.wait_ctrl_resp(matmul_plan.response_word)
		env.model.commit_success(matmul_plan)
		await env.wait_export_done(matmul_start.export_done_count + 1)
		assert env.dma_req_count - matmul_start.dma_req_count == 1
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_load_rejects_empty_side_mask(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		start = env.snapshot()
		load_plan = env.plan_load(0x902, 0, 0, need_a=False, need_b=False)
		assert load_plan.err
		await env.send_ctrl(build_load_inst(0, 0, need_a=False, need_b=False), 0x902)
		await env.wait_ctrl_resp(load_plan.response_word, 500)
		await ClockCycles(dut.clk, 8)
		assert env.dma_req_count == start.dma_req_count
		assert env.export_req_count == start.export_req_count
		assert env.irq_count == start.irq_count + 1
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_load_rejects_oversize_and_same_id_reload_size_mismatch(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		ctrl_id = 0x903
		a_matrix = identity_matrix(env.x_dim, env.data_width)
		env.register_external_matrix("A", ctrl_id, a_matrix)

		start = env.snapshot()
		oversize_len = env.a_capacity_elems + 1
		oversize = env.plan_load(ctrl_id, oversize_len, 0, need_a=True, need_b=False)
		assert oversize.err
		await env.send_ctrl(build_load_inst(oversize_len, 0, need_a=True, need_b=False), ctrl_id)
		await env.wait_ctrl_resp(oversize.response_word, 500)
		await ClockCycles(dut.clk, 8)
		assert env.dma_req_count == start.dma_req_count
		assert env.export_req_count == start.export_req_count
		assert env.irq_count == start.irq_count + 1

		ok = env.plan_load(ctrl_id, len(a_matrix), 0, need_a=True, need_b=False)
		assert not ok.err
		await env.send_ctrl(build_load_inst(len(a_matrix), 0, need_a=True, need_b=False), ctrl_id)
		await env.wait_ctrl_resp(ok.response_word)
		env.model.commit_load_success(ok)

		mismatch = env.plan_load(ctrl_id, len(a_matrix) + env.x_dim, 0, need_a=True, need_b=False)
		assert mismatch.err
		await env.send_ctrl(build_load_inst(len(a_matrix) + env.x_dim, 0, need_a=True, need_b=False), ctrl_id)
		await env.wait_ctrl_resp(mismatch.response_word, 500)
	finally:
		env.shutdown()
