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
from tests.pt_case_catalog import RANDOMIZED_PROFILE_BY_NAME
from tests.pt_model import (
	PT_QGRAN_PER_TENSOR,
	PT_QGRAN_X_WISE,
	PT_QGRAN_Y_WISE,
	PT_SCALE_FULL,
	build_matmul_inst,
	build_mwin_off,
	identity_matrix,
	pack_resp,
	qcfg_payload_count,
)


PROFILE_NAME = os.getenv("PT_RANDOM_PROFILE", "balanced_mix_4x4")
PROFILE = RANDOMIZED_PROFILE_BY_NAME[PROFILE_NAME]


def _weighted_choice(rng, weights):
	choices = list(weights.keys())
	values = [weights[key] for key in choices]
	return rng.choices(choices, weights=values, k=1)[0]


@cocotb.test(name=PROFILE.case_name)
async def test_pt_randomized_profile(dut) -> None:
	env = await create_env(dut)
	try:
		random_cases = PROFILE.data["random_cases"]
		ready_probs = PROFILE.data["ready_probs"]
		env.configure_patterns(
			dma_req_ready=RandomPattern(env.rng, ready_probs["dma_req_ready"]),
			m_dma_req_ready=RandomPattern(env.rng, ready_probs["m_dma_req_ready"]),
			m_axis_ready=RandomPattern(env.rng, ready_probs["m_axis_ready"]),
			s_axis_valid=RandomPattern(env.rng, ready_probs["s_axis_valid"]),
		)
		await setup_bases_and_passthrough_qcfg(env)

		identity = identity_matrix(env.x_dim, env.data_width)
		patterns = [
			flatten_pattern_matrix(env.x_dim, 2, 1, 0),
			flatten_pattern_matrix(env.x_dim, 3, 2, 1),
			repeating_matrix(env.x_dim, [1, 2, 3, 4, 5, 6, 7, 8][: env.x_dim], env.data_width),
			repeating_matrix(env.x_dim, [1, 0, 2, 0, 3, 0, 4, 0][: env.x_dim], env.data_width),
		]
		last_hit_id = None
		next_ctrl_id = 0x400
		export_target = 0

		for _case_idx in range(random_cases):
			choice = _weighted_choice(env.rng, PROFILE.data["weights"])

			if choice == "qcfg":
				if env.rng.random() < 0.5:
					await env.qcfg_success(PT_QGRAN_PER_TENSOR, [env.rng.choice([0x0001_0000, 0x0000_8000, 0xFFFF_0000])], next_ctrl_id)
				else:
					mode = env.rng.choice([PT_QGRAN_X_WISE, PT_QGRAN_Y_WISE])
					payload_count = qcfg_payload_count(mode, env.x_dim, env.y_dim)
					scales = [env.rng.choice([0x0001_0000, 0x0000_8000, 0x0002_0000, 0xFFFF_0000]) for _ in range(payload_count or 0)]
					await env.qcfg_success(mode, scales, next_ctrl_id)
				next_ctrl_id += 1
				continue

			if choice == "invalid":
				plan = env.plan_matmul(next_ctrl_id, 0x001, 0x000)
				await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x001, 0x000), next_ctrl_id)
				await env.wait_ctrl_resp(plan.response_word, 1000)
				next_ctrl_id += 1
				continue

			matrix_idx = env.rng.randrange(len(patterns))
			env.register_external_matrix("A", 0, identity)
			env.register_external_matrix("B", 0, patterns[matrix_idx])

			if choice == "hit" and last_hit_id is not None:
				ctrl_id = last_hit_id
			else:
				ctrl_id = next_ctrl_id
				next_ctrl_id += 1
				last_hit_id = ctrl_id

			if choice == "mwindow" and any(matrix is not None for matrix in env.model.m_buffers.values()):
				mwin_buf = env.rng.choice([buf for buf, matrix in env.model.m_buffers.items() if matrix is not None])
				a_off = build_mwin_off(mwin_buf, 0)
				b_off = build_mwin_off(mwin_buf, 0)
			else:
				a_off = 0x000
				b_off = 0x000

			plan = env.plan_matmul(ctrl_id, a_off, b_off)
			if choice == "wrong_tuser":
				env.queue_ab_injection(AbInjection(wrong_tuser=True))
				await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, a_off, b_off), ctrl_id)
				await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 4000)
				continue

			if choice == "export_error":
				env.queue_export_injection(ExportInjection(error=True, done_delay=1))
				await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, a_off, b_off), ctrl_id)
				await env.wait_ctrl_resp(plan.response_word, 4000)
				env.model.commit_success(plan)
				await env.wait_export_error(env.export_error_count + 1)
				await env.wait_ctrl_resp(pack_resp(True, plan.success_buffer, ctrl_id), 4000)
				continue

			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, a_off, b_off), ctrl_id)
			await env.wait_ctrl_resp(plan.response_word, 4000)
			env.model.commit_success(plan)
			export_target += 1
			await env.wait_export_done(export_target, 12000)
	finally:
		env.shutdown()
