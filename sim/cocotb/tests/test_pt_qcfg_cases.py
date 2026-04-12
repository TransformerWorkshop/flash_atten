from __future__ import annotations

import cocotb

from tests.pt_blackbox_env import create_env, repeating_matrix
from tests.pt_case_catalog import QCFG_CASES, ScenarioCase
from tests.pt_model import PT_SCALE_FULL, build_matmul_inst, identity_matrix, qcfg_payload_count


def _expand_case_scales(scales, count: int):
	if len(scales) == count:
		return list(scales)
	return [scales[idx % len(scales)] for idx in range(count)]


async def _run_qcfg_case(dut, case: ScenarioCase) -> None:
	env = await create_env(dut)
	try:
		await env.cfg_base("A", env.a_base, 0x10)
		await env.cfg_base("B", env.b_base, 0x11)

		granularity = case.data["granularity"]
		payload_count = qcfg_payload_count(granularity, env.x_dim, env.y_dim)
		assert payload_count is not None
		scales = _expand_case_scales(case.data["scales"], payload_count)

		env.register_external_matrix("A", 0, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", 0, repeating_matrix(env.x_dim, case.data["b_values"][: env.y_dim], env.data_width))

		await env.qcfg_success(granularity, scales, 0x100)
		plan = env.plan_matmul(0x140, 0x000, 0x000)
		assert not plan.err
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x140)
		await env.wait_ctrl_resp(plan.response_word)
		env.model.commit_success(plan)
		await env.wait_export_done(1)
	finally:
		env.shutdown()


def _register_qcfg_case(case: ScenarioCase) -> None:
	async def _test(dut) -> None:
		await _run_qcfg_case(dut, case)

	_test.__name__ = case.case_name
	globals()[case.case_name] = cocotb.test(name=case.case_name)(_test)


for _case in QCFG_CASES:
	_register_qcfg_case(_case)
