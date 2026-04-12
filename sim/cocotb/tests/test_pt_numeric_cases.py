from __future__ import annotations

import cocotb

from tests.pt_blackbox_env import create_env, repeating_matrix, setup_bases_and_passthrough_qcfg
from tests.pt_case_catalog import NUMERIC_CASES, ScenarioCase
from tests.pt_model import (
	PT_SCALE_FULL,
	build_matmul_inst,
	constant_matrix,
	identity_matrix,
	qcfg_payload_count,
	zero_matrix,
)


def _expand_case_scales(scales, count: int):
	if len(scales) == count:
		return list(scales)
	return [scales[idx % len(scales)] for idx in range(count)]


def _materialize_numeric_b(env, mode: str, args):
	if mode == "zero":
		return zero_matrix(env.x_dim, env.y_dim)
	if mode == "constant":
		return constant_matrix(env.x_dim, env.y_dim, args[0], env.data_width)
	if mode == "identity":
		return identity_matrix(env.x_dim, env.data_width)
	if mode == "repeat":
		return repeating_matrix(env.x_dim, args[0], env.data_width)
	raise AssertionError(f"unsupported numeric matrix mode {mode}")


async def _run_numeric_case(dut, case: ScenarioCase) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)

		identity = identity_matrix(env.x_dim, env.data_width)
		env.register_external_matrix("A", 0, identity)

		granularity = case.data["granularity"]
		payload_count = qcfg_payload_count(granularity, env.x_dim, env.y_dim)
		assert payload_count is not None
		scales = _expand_case_scales(case.data["scales"], payload_count)
		b_matrix = _materialize_numeric_b(env, case.data["b_mode"], case.data.get("b_args", ()))

		await env.qcfg_success(granularity, scales, 0x40)
		env.register_external_matrix("B", 0, b_matrix)
		plan = env.plan_matmul(0x80, 0x000, 0x000)
		assert not plan.err
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x80)
		await env.wait_ctrl_resp(plan.response_word)
		env.model.commit_success(plan)
		await env.wait_export_done(1)
	finally:
		env.shutdown()


def _register_numeric_case(case: ScenarioCase) -> None:
	async def _test(dut) -> None:
		await _run_numeric_case(dut, case)

	_test.__name__ = case.case_name
	globals()[case.case_name] = cocotb.test(name=case.case_name)(_test)


for _case in NUMERIC_CASES:
	_register_numeric_case(_case)
