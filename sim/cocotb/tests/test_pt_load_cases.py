from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles

from tests.pt_blackbox_env import create_env, repeating_matrix, setup_bases_and_passthrough_qcfg
from tests.pt_model import PT_SCALE_FULL, build_load_inst, build_matmul_inst, build_mwin_off, identity_matrix


@cocotb.test()
async def test_pt_load_ab_reuse_then_matmul_hit(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		a_off = 0x000
		b_off = 0x000
		env.register_external_matrix("A", a_off, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", b_off, repeating_matrix(env.x_dim, [2, 4, 6, 8, 10, 12, 14, 16][: env.y_dim], env.data_width))

		start = env.snapshot()
		load_plan = env.plan_load(0x900, a_off, b_off, need_a=True, need_b=True)
		assert not load_plan.err
		assert [req.kind for req in load_plan.expected_dma_loads] == ["A", "B"]
		await env.send_ctrl(build_load_inst(a_off, b_off, need_a=True, need_b=True), 0x900)
		await env.wait_ctrl_resp(load_plan.response_word)
		env.model.commit_load_success(load_plan)
		await ClockCycles(dut.clk, 8)
		assert env.dma_req_count - start.dma_req_count == 2
		assert env.export_req_count == start.export_req_count
		assert env.irq_count == start.irq_count

		matmul_start = env.snapshot()
		matmul_plan = env.plan_matmul(0x900, a_off, b_off)
		assert not matmul_plan.err
		assert len(matmul_plan.expected_dma_loads) == 0
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, a_off, b_off), 0x900)
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
		a_off = 0x000
		b_off = env.y_dim
		env.register_external_matrix("A", a_off, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", b_off, repeating_matrix(env.x_dim, [3, 5, 7, 9, 11, 13, 15, 17][: env.y_dim], env.data_width))

		load_start = env.snapshot()
		load_plan = env.plan_load(0x901, a_off, b_off, need_a=True, need_b=False)
		assert not load_plan.err
		assert len(load_plan.expected_dma_loads) == 1
		assert load_plan.expected_dma_loads[0].kind == "A"
		await env.send_ctrl(build_load_inst(a_off, b_off, need_a=True, need_b=False), 0x901)
		await env.wait_ctrl_resp(load_plan.response_word)
		env.model.commit_load_success(load_plan)
		await ClockCycles(dut.clk, 8)
		assert env.dma_req_count - load_start.dma_req_count == 1
		assert env.irq_count == load_start.irq_count

		matmul_start = env.snapshot()
		matmul_plan = env.plan_matmul(0x901, a_off, b_off)
		assert not matmul_plan.err
		assert len(matmul_plan.expected_dma_loads) == 1
		assert matmul_plan.expected_dma_loads[0].kind == "B"
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, a_off, b_off), 0x901)
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
		load_plan = env.plan_load(0x902, 0x000, 0x000, need_a=False, need_b=False)
		assert load_plan.err
		await env.send_ctrl(build_load_inst(0x000, 0x000, need_a=False, need_b=False), 0x902)
		await env.wait_ctrl_resp(load_plan.response_word, 500)
		await ClockCycles(dut.clk, 8)
		assert env.dma_req_count == start.dma_req_count
		assert env.export_req_count == start.export_req_count
		assert env.irq_count == start.irq_count + 1
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_load_rejects_mwindow_offset(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		start = env.snapshot()
		mwin_off = build_mwin_off(0, 0)
		load_plan = env.plan_load(0x903, mwin_off, 0x000, need_a=True, need_b=False)
		assert load_plan.err
		await env.send_ctrl(build_load_inst(mwin_off, 0x000, need_a=True, need_b=False), 0x903)
		await env.wait_ctrl_resp(load_plan.response_word, 500)
		await ClockCycles(dut.clk, 8)
		assert env.dma_req_count == start.dma_req_count
		assert env.export_req_count == start.export_req_count
		assert env.irq_count == start.irq_count + 1
	finally:
		env.shutdown()
