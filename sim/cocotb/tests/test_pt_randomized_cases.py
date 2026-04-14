from __future__ import annotations

import os

import cocotb

from tests.pt_blackbox_env import (
	AbInjection,
	ExportInjection,
	RandomPattern,
	create_env,
	flatten_pattern_matrix,
	repeating_matrix,
	setup_bases_and_passthrough_qcfg,
)
from tests.pt_model import (
	PT_SCALE_FULL,
	build_matmul_inst,
	identity_matrix,
	pack_resp,
)


def _weighted_choice(rng, weights):
	choices = list(weights.keys())
	values = [weights[key] for key in choices]
	return rng.choices(choices, weights=values, k=1)[0]


@cocotb.test()
async def test_pt_randomized_profile(dut) -> None:
	env = await create_env(dut)
	try:
		random_cases = int(os.getenv("PT_RANDOM_CASES", "12"))
		env.configure_patterns(
			dma_req_ready=RandomPattern(env.rng, 0.75),
			m_dma_req_ready=RandomPattern(env.rng, 0.8),
			m_axis_ready=RandomPattern(env.rng, 0.7),
			s_axis_valid=RandomPattern(env.rng, 0.8),
		)
		await setup_bases_and_passthrough_qcfg(env)

		patterns = [
			flatten_pattern_matrix(env.x_dim, 2, 1, 0),
			flatten_pattern_matrix(env.x_dim, 3, 2, 1),
			repeating_matrix(env.x_dim, [1, 2, 3, 4, 5, 6, 7, 8][: env.x_dim], env.data_width),
			repeating_matrix(env.x_dim, [1, 0, 2, 0, 3, 0, 4, 0][: env.x_dim], env.data_width),
		]
		next_ctrl_id = 0x400
		export_target = 0

		for _case_idx in range(random_cases):
			choice = _weighted_choice(env.rng, {"valid": 6, "invalid": 1, "wrong_tuser": 1, "export_error": 1})
			ctrl_id = next_ctrl_id
			next_ctrl_id += 1
			env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
			env.register_external_matrix("B", ctrl_id, patterns[env.rng.randrange(len(patterns))])

			if choice == "invalid":
				plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL, a_field=1)
				await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x001, 0x000), ctrl_id)
				await env.wait_ctrl_resp(plan.response_word, 1000)
				continue

			plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
			if choice == "wrong_tuser":
				env.queue_ab_injection(AbInjection(wrong_tuser=True))
				await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
				await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 4000)
				continue

			if choice == "export_error":
				env.queue_export_injection(ExportInjection(error=True, done_delay=1))
				await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
				await env.wait_ctrl_resp(plan.response_word, 4000)
				env.model.commit_success(plan)
				await env.wait_export_error(env.export_error_count + 1)
				await env.wait_ctrl_resp(pack_resp(True, plan.success_buffer or 0, ctrl_id), 4000)
				continue

			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
			await env.wait_ctrl_resp(plan.response_word, 4000)
			env.model.commit_success(plan)
			export_target += 1
			await env.wait_export_done(export_target, 12000)
	finally:
		env.shutdown()
