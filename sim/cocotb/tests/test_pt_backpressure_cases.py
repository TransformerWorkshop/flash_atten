from __future__ import annotations

import cocotb

from tests.pt_blackbox_env import SequencePattern, create_env, flatten_pattern_matrix, repeating_matrix, setup_bases_and_passthrough_qcfg
from tests.pt_case_catalog import BACKPRESSURE_CASES, ScenarioCase
from tests.pt_model import PT_SCALE_FULL, build_matmul_inst


async def _run_backpressure_case(dut, case: ScenarioCase) -> None:
	env = await create_env(dut)
	patterns = case.data["patterns"]
	try:
		env.configure_patterns(
			dma_req_ready=SequencePattern(patterns[0]),
			m_dma_req_ready=SequencePattern(patterns[1]),
			m_axis_ready=SequencePattern(patterns[2]),
			s_axis_valid=SequencePattern(patterns[3]),
		)
		await setup_bases_and_passthrough_qcfg(env)

		profile_index = case.data.get("matrix_profile", BACKPRESSURE_CASES.index(case) + 1)
		env.register_external_matrix("A", 0, flatten_pattern_matrix(env.x_dim, 5 + profile_index, 1 + (profile_index % 3), profile_index))
		env.register_external_matrix("B", 0, flatten_pattern_matrix(env.y_dim, 1 + (profile_index % 4), 3 + profile_index, 1))

		first = env.plan_matmul(0x301, 0x000, 0x000)
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x301)
		await env.wait_ctrl_resp(first.response_word)
		env.model.commit_success(first)

		second_a = repeating_matrix(env.x_dim, [1, 0, 2, 0, 3, 0, 4, 0, 5, 0], env.data_width)
		second_b = flatten_pattern_matrix(env.y_dim, 2 + profile_index, 2, 3)
		env.register_external_matrix("A", 0, second_a)
		env.register_external_matrix("B", 0, second_b)
		second = env.plan_matmul(0x302, 0x000, 0x000)
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x302)
		await env.wait_ctrl_resp(second.response_word)
		env.model.commit_success(second)

		await env.wait_export_done(2, 12000)
		assert env.export_req_count == 2
		assert env.irq_count == 2
	finally:
		env.shutdown()


def _register_backpressure_case(case: ScenarioCase) -> None:
	async def _test(dut) -> None:
		await _run_backpressure_case(dut, case)

	_test.__name__ = case.case_name
	globals()[case.case_name] = cocotb.test(name=case.case_name)(_test)


for _case in BACKPRESSURE_CASES:
	_register_backpressure_case(_case)
