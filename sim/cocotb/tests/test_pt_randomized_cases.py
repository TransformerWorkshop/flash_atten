from __future__ import annotations

import os

import cocotb
from cocotb.triggers import RisingEdge

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
	PT_SCALE_FULL,
	build_matadd_inst,
	build_matmul_inst,
	build_mwin_off,
	identity_matrix,
	pack_resp,
	qcfg_payload_count,
)


def _weighted_choice(rng, weights):
	choices = list(weights.keys())
	values = [weights[key] for key in choices]
	return rng.choices(choices, weights=values, k=1)[0]


def _profile_for_env(env):
	profile_name = os.getenv("PT_RANDOM_PROFILE", f"balanced_mix_{env.x_dim}x{env.x_dim}")
	return RANDOMIZED_PROFILE_BY_NAME[profile_name]


def _is_dma_top() -> bool:
	return os.getenv("PT_TOPLEVEL", "PT") == "PT_DMA_TOP"


def _make_scales(env, granularity: int, salt: int):
	payload_count = qcfg_payload_count(granularity, env.x_dim, env.y_dim)
	assert payload_count is not None
	base_words = [0x0001_0000, 0x0000_8000, 0xFFFF_0000, 0x0002_0000, 0xFFFF_8000]
	return [base_words[(salt + idx) % len(base_words)] for idx in range(payload_count)]


async def _wait_ctrl_resp_success(env, expected_word: int, ctrl_id: int, timeout_cycles: int = 4000) -> int:
	if not _is_dma_top():
		return await env.wait_ctrl_resp(expected_word, timeout_cycles)
	for _ in range(timeout_cycles):
		if env.ctrl_resp_queue:
			actual = env.ctrl_resp_queue.popleft()
			assert (actual & 0xBFFF_FFFF) == (ctrl_id & 0xFFFF_FFFF), (
				f"ctrl_resp mismatch exp_id=0x{ctrl_id:08x} got=0x{actual:08x}"
			)
			await env.pop_resp()
			return actual
		await RisingEdge(env.dut.clk)
	raise AssertionError(f"ctrl_resp timeout waiting for ctrl_id=0x{ctrl_id:08x}")


@cocotb.test()
async def test_pt_randomized_profile(dut) -> None:
	env = await create_env(dut)
	try:
		profile = _profile_for_env(env)
		random_cases = int(os.getenv("PT_RANDOM_CASES", str(profile.data["random_cases"])))
		soak_mode = bool(int(os.getenv("PT_SOAK_MODE", "0")))
		clear_interval = int(os.getenv("PT_RANDOM_CLEAR_INTERVAL", "0"))
		clear_cycles = int(os.getenv("PT_RANDOM_CLEAR_CYCLES", "1"))
		dma_top_mode = _is_dma_top()
		if dma_top_mode and clear_interval == 0:
			clear_interval = 4

		ready_probs = dict(profile.data["ready_probs"])
		if soak_mode:
			for key in ready_probs:
				ready_probs[key] = max(0.45, ready_probs[key] - 0.10)
		env.configure_patterns(
			dma_req_ready=RandomPattern(env.rng, ready_probs["dma_req_ready"]),
			m_dma_req_ready=RandomPattern(env.rng, ready_probs["m_dma_req_ready"]),
			m_axis_ready=RandomPattern(env.rng, ready_probs["m_axis_ready"]),
			s_axis_valid=RandomPattern(env.rng, ready_probs["s_axis_valid"]),
		)
		await setup_bases_and_passthrough_qcfg(env)

		patterns = [
			flatten_pattern_matrix(env.x_dim, 2, 1, 0),
			flatten_pattern_matrix(env.x_dim, 3, 2, 1),
			repeating_matrix(env.x_dim, [1, 2, 3, 4, 5, 6, 7, 8][: env.x_dim], env.data_width),
			repeating_matrix(env.x_dim, [1, 0, 2, 0, 3, 0, 4, 0][: env.x_dim], env.data_width),
		]
		next_ctrl_id = 0x400
		max_fresh_ctrl_id = 0x403 if dma_top_mode else 0x7FFF_FFFF
		qcfg_ctrl_id = 0x200
		export_target = 0
		cached_ab_ids = set()
		mwindow_candidates = []

		for case_idx in range(random_cases):
			if clear_interval and case_idx and (case_idx % clear_interval) == 0:
				await env.pulse_clear(cycles=clear_cycles, phase="post_export")
				await setup_bases_and_passthrough_qcfg(env)
				next_ctrl_id = 0x400
				cached_ab_ids.clear()
				mwindow_candidates.clear()
				export_target = env.export_done_count

			choice = _weighted_choice(env.rng, profile.data["weights"])
			if choice == "hit" and not cached_ab_ids:
				choice = "legal"
			if choice == "mwindow" and not mwindow_candidates:
				choice = "legal"

			if choice == "qcfg":
				legal_modes = [mode for mode in range(5) if qcfg_payload_count(mode, env.x_dim, env.y_dim) is not None]
				granularity = legal_modes[case_idx % len(legal_modes)]
				await env.qcfg_success(granularity, _make_scales(env, granularity, case_idx), qcfg_ctrl_id if dma_top_mode else (0x200 + case_idx))
				continue

			if choice in {"legal", "invalid", "wrong_tuser", "export_error"}:
				ctrl_id = next_ctrl_id
				next_ctrl_id += 1
				if next_ctrl_id > max_fresh_ctrl_id:
					next_ctrl_id = 0x400
				env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
				env.register_external_matrix("B", ctrl_id, patterns[env.rng.randrange(len(patterns))])
				env.register_external_matrix("C", ctrl_id, patterns[(env.rng.randrange(len(patterns)) + 1) % len(patterns)])
			elif choice == "hit":
				ctrl_id = env.rng.choice(sorted(cached_ab_ids))
			else:
				ctrl_id = env.rng.choice(mwindow_candidates)[0]

			if choice == "invalid":
				plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL, reserved_a=1)
				await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x001, 0x000), ctrl_id)
				await env.wait_ctrl_resp(plan.response_word, 2000)
				continue

			if choice == "mwindow":
				ctrl_id, buffer = env.rng.choice(mwindow_candidates)
				env.register_external_matrix("C", ctrl_id, patterns[env.rng.randrange(len(patterns))])
				m_off = build_mwin_off(buffer, 0)
				plan = env.plan_matadd(ctrl_id, m_off)
				if plan.err:
					await env.send_ctrl(build_matadd_inst(m_off), ctrl_id)
					await env.wait_ctrl_resp(plan.response_word, 4000)
					continue
				resp = await env.send_ctrl(build_matadd_inst(m_off), ctrl_id)
				_ = resp
				actual = await _wait_ctrl_resp_success(env, plan.response_word, ctrl_id, 4000)
				export_target += 1
				await env.wait_export_done(export_target, 12000)
				new_buffer = (actual >> 30) & 0x1
				mwindow_candidates.append((ctrl_id, new_buffer))
				if ctrl_id in cached_ab_ids:
					cached_ab_ids.remove(ctrl_id)
				continue

			plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
			if plan.err:
				await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
				await env.wait_ctrl_resp(plan.response_word, 4000)
				continue

			if choice == "wrong_tuser":
				if plan.expected_dma_loads:
					env.queue_ab_injection(AbInjection(wrong_tuser=True))
					await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
					await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 4000)
					if dma_top_mode:
						await env.soft_clear()
						await setup_bases_and_passthrough_qcfg(env)
						next_ctrl_id = 0x400
						cached_ab_ids.clear()
						mwindow_candidates.clear()
						export_target = env.export_done_count
				else:
					await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
					resp = await _wait_ctrl_resp_success(env, plan.response_word, ctrl_id, 4000)
					export_target += 1
					await env.wait_export_done(export_target, 12000)
					cached_ab_ids.add(ctrl_id)
					mwindow_candidates.append((ctrl_id, (resp >> 30) & 0x1))
				continue

			if choice == "export_error":
				env.queue_export_injection(ExportInjection(error=True, done_delay=1))
				await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
				await _wait_ctrl_resp_success(env, plan.response_word, ctrl_id, 4000)
				await env.wait_export_error(env.export_error_count + 1, 12000)
				await env.wait_ctrl_resp(pack_resp(True, plan.success_buffer or 0, ctrl_id), 4000)
				if dma_top_mode:
					await env.soft_clear()
					await setup_bases_and_passthrough_qcfg(env)
					next_ctrl_id = 0x400
					cached_ab_ids.clear()
					mwindow_candidates.clear()
					export_target = env.export_done_count
				continue

			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
			resp = await _wait_ctrl_resp_success(env, plan.response_word, ctrl_id, 4000)
			export_target += 1
			await env.wait_export_done(export_target, 12000)
			cached_ab_ids.add(ctrl_id)
			mwindow_candidates.append((ctrl_id, (resp >> 30) & 0x1))
	finally:
		env.shutdown()
