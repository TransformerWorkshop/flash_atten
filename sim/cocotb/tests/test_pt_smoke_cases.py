from __future__ import annotations

import cocotb

from tests.pt_blackbox_env import create_env, flatten_pattern_matrix, repeating_matrix, setup_bases_and_passthrough_qcfg
from tests.pt_case_catalog import SMOKE_CASES, ScenarioCase
from tests.pt_model import PT_SCALE_FULL, build_matmul_inst, build_mwin_off, identity_matrix, to_unsigned, zero_matrix


def _materialize_matrix(env, mode: str, args):
	if mode == "pattern":
		return flatten_pattern_matrix(env.x_dim, row_gain=args[0], col_gain=args[1], bias=args[2], bits=env.data_width)
	if mode == "repeat":
		return repeating_matrix(env.x_dim, args, env.data_width)
	if mode == "identity":
		return identity_matrix(env.x_dim, env.data_width)
	if mode == "single_hot":
		matrix = zero_matrix(env.x_dim, env.y_dim)
		index = args[0] % len(matrix)
		matrix[index] = to_unsigned(args[1], env.data_width)
		return matrix
	if mode == "checker":
		low = to_unsigned(args[0], env.data_width)
		high = to_unsigned(args[1], env.data_width)
		return [
			high if ((row + col) & 0x1) else low
			for row in range(env.x_dim)
			for col in range(env.y_dim)
		]
	if mode == "zero_row_pattern":
		base_spec, row_idx = args
		matrix = flatten_pattern_matrix(env.x_dim, row_gain=base_spec[0], col_gain=base_spec[1], bias=base_spec[2], bits=env.data_width)
		row = row_idx % env.x_dim
		for col in range(env.y_dim):
			matrix[row * env.y_dim + col] = 0
		return matrix
	if mode == "zero_col_pattern":
		base_spec, col_idx = args
		matrix = flatten_pattern_matrix(env.x_dim, row_gain=base_spec[0], col_gain=base_spec[1], bias=base_spec[2], bits=env.data_width)
		col = col_idx % env.y_dim
		for row in range(env.x_dim):
			matrix[row * env.y_dim + col] = 0
		return matrix
	raise AssertionError(f"unsupported smoke matrix mode {mode}")


async def _run_smoke_case(dut, case: ScenarioCase) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)

		a_matrix = _materialize_matrix(env, case.data["a_mode"], case.data["a_args"])
		b_matrix = _materialize_matrix(env, case.data["b_mode"], case.data["b_args"])
		env.register_external_matrix("A", 0, a_matrix)
		env.register_external_matrix("B", 0, b_matrix)

		start = env.snapshot()
		plan = env.plan_matmul(0x01, 0x000, 0x000)
		assert not plan.err
		assert len(plan.expected_dma_loads) == 2
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x01)
		resp = await env.wait_ctrl_resp(plan.response_word)
		assert ((resp >> 30) & 0x1) == plan.success_buffer
		env.model.commit_success(plan)
		await env.wait_export_done(start.export_done_count + 1)
		assert env.dma_req_count - start.dma_req_count == 2
		assert env.export_req_count - start.export_req_count == 1
		assert env.irq_count - start.irq_count == 1

		start = env.snapshot()
		hit_plan = env.plan_matmul(0x01, 0x000, 0x000)
		assert not hit_plan.err
		assert len(hit_plan.expected_dma_loads) == 0
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x01)
		resp = await env.wait_ctrl_resp(hit_plan.response_word)
		hit_buf = (resp >> 30) & 0x1
		env.model.commit_success(hit_plan)
		await env.wait_export_done(start.export_done_count + 1)
		assert env.dma_req_count - start.dma_req_count == 0
		assert env.export_req_count - start.export_req_count == 1
		assert env.irq_count - start.irq_count == 1

		start = env.snapshot()
		mwin_off = build_mwin_off(hit_buf, 0)
		mwin_plan = env.plan_matmul(0x03, mwin_off, mwin_off)
		assert not mwin_plan.err
		assert len(mwin_plan.expected_dma_loads) == 0
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, mwin_off, mwin_off), 0x03)
		await env.wait_ctrl_resp(mwin_plan.response_word)
		env.model.commit_success(mwin_plan)
		await env.wait_export_done(start.export_done_count + 1)
		assert env.dma_req_count - start.dma_req_count == 0
		assert env.export_req_count - start.export_req_count == 1
		assert env.irq_count - start.irq_count == 1
	finally:
		env.shutdown()


def _register_smoke_case(case: ScenarioCase) -> None:
	async def _test(dut) -> None:
		await _run_smoke_case(dut, case)

	_test.__name__ = case.case_name
	globals()[case.case_name] = cocotb.test(name=case.case_name)(_test)


for _case in SMOKE_CASES:
	_register_smoke_case(_case)
