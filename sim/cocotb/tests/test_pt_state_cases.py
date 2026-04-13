from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles

from tests.pt_blackbox_env import ConstantPattern, create_env, repeating_matrix, setup_bases_and_passthrough_qcfg
from tests.pt_case_catalog import STATE_CASES, ScenarioCase
from tests.pt_model import (
	PT_QGRAN_X_WISE,
	PT_QGRAN_PER_TENSOR,
	PT_SCALE_FULL,
	build_matmul_inst,
	build_mwin_off,
	identity_matrix,
	qcfg_payload_count,
	zero_matrix,
)


def _scale_pattern(count: int):
	base = [0x0001_0000, 0x0000_8000, 0xFFFF_0000, 0x0001_8000]
	return [base[idx % len(base)] for idx in range(count)]


async def _run_state_case(dut, case: ScenarioCase) -> None:
	env = await create_env(dut)
	kind = case.data["kind"]
	params = case.data["params"]
	try:
		if kind == "clear_idle_recovery":
			await env.cfg_base32("A", 0x1111_1000, 0x500)
			await env.cfg_base32("B", 0x2222_2000, 0x510)
			await env.qcfg_success(PT_QGRAN_X_WISE, _scale_pattern(qcfg_payload_count(PT_QGRAN_X_WISE, env.x_dim, env.y_dim) or 0), 0x520)

			custom_a = identity_matrix(env.x_dim, env.data_width)
			custom_b = repeating_matrix(env.x_dim, [3, 5, 7, 9, 11, 13, 15, 17][: env.y_dim], env.data_width)
			env.register_external_matrix("A", 0, custom_a)
			env.register_external_matrix("B", 0, custom_b)

			first_start = env.snapshot()
			first = env.plan_matmul(0x530, 0x000, 0x000)
			assert len(first.expected_dma_loads) == 2
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x530)
			await env.wait_ctrl_resp(first.response_word)
			env.model.commit_success(first)
			await env.wait_export_done(first_start.export_done_count + 1)

			hit_start = env.snapshot()
			hit = env.plan_matmul(0x530, 0x000, 0x000)
			assert len(hit.expected_dma_loads) == 0
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x530)
			hit_resp = await env.wait_ctrl_resp(hit.response_word)
			env.model.commit_success(hit)
			await env.wait_export_done(hit_start.export_done_count + 1)
			assert env.dma_req_count - hit_start.dma_req_count == 0
			cleared_buf = (hit_resp >> 30) & 0x1
			retained_matrix = list(hit.result_matrix or [])

			await env.pulse_clear()
			env.model.m_buffers[cleared_buf] = retained_matrix

			cleared_start = env.snapshot()
			cleared_mwin = env.plan_matmul(0x531, build_mwin_off(cleared_buf, 0), build_mwin_off(cleared_buf, 0))
			assert len(cleared_mwin.expected_dma_loads) == 0
			await env.send_ctrl(
				build_matmul_inst(
					PT_SCALE_FULL,
					PT_SCALE_FULL,
					PT_SCALE_FULL,
					build_mwin_off(cleared_buf, 0),
					build_mwin_off(cleared_buf, 0),
				),
				0x531,
			)
			await env.wait_ctrl_resp(cleared_mwin.response_word)
			env.model.commit_success(cleared_mwin)
			await env.wait_export_done(cleared_start.export_done_count + 1)

			default_a = identity_matrix(env.x_dim, env.data_width)
			default_b = repeating_matrix(env.x_dim, [2, 4, 6, 8, 10, 12, 14, 16][: env.y_dim], env.data_width)
			env.register_external_matrix("A", 0, default_a)
			env.register_external_matrix("B", 0, default_b)

			recovery_start = env.snapshot()
			recovery = env.plan_matmul(0x532, 0x000, 0x000)
			assert len(recovery.expected_dma_loads) == 2
			assert recovery.result_matrix == default_b
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x532)
			await env.wait_ctrl_resp(recovery.response_word)
			env.model.commit_success(recovery)
			await env.wait_export_done(recovery_start.export_done_count + 1)
			assert env.dma_req_count - recovery_start.dma_req_count == 2
			return

		if kind == "clear_mid_export_recovery":
			env.configure_patterns(m_axis_ready=ConstantPattern(0))
			await setup_bases_and_passthrough_qcfg(env)

			env.register_external_matrix("A", 0, identity_matrix(env.x_dim, env.data_width))
			env.register_external_matrix("B", 0, repeating_matrix(env.x_dim, [1, 3, 5, 7, 9, 11, 13, 15][: env.y_dim], env.data_width))

			start = env.snapshot()
			plan = env.plan_matmul(0x540, 0x000, 0x000)
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x540)
			await env.wait_ctrl_resp(plan.response_word)
			env.model.commit_success(plan)
			await env.wait_export_req(start.export_req_count + 1)
			await ClockCycles(dut.clk, 4)

			await env.pulse_clear()
			await ClockCycles(dut.clk, 8)
			assert env.export_done_count == start.export_done_count
			assert env.export_error_count == start.export_error_count
			assert env.irq_count == start.irq_count + 1
			assert not env.ctrl_resp_queue

			env.configure_patterns(m_axis_ready=ConstantPattern(1))
			env.register_external_matrix("A", 0, identity_matrix(env.x_dim, env.data_width))
			env.register_external_matrix("B", 0, repeating_matrix(env.x_dim, [2, 6, 10, 14, 18, 22, 26, 30][: env.y_dim], env.data_width))

			recovery_start = env.snapshot()
			recovery = env.plan_matmul(0x541, 0x000, 0x000)
			assert len(recovery.expected_dma_loads) == 2
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x541)
			await env.wait_ctrl_resp(recovery.response_word)
			env.model.commit_success(recovery)
			await env.wait_export_done(recovery_start.export_done_count + 1)
			assert env.export_req_count == recovery_start.export_req_count + 1
			return

		if kind == "cfg_base_hi":
			target_kind = params["kind"]
			target_value = params["value"]
			await env.cfg_base32(target_kind, target_value, 0x560)
			if target_kind == "A":
				await env.cfg_base("B", env.b_base, 0x570)
			else:
				await env.cfg_base("A", env.a_base, 0x570)
			await env.qcfg_success(PT_QGRAN_PER_TENSOR, [0x0001_0000], 0x580)

			env.register_external_matrix("A", 0, identity_matrix(env.x_dim, env.data_width))
			env.register_external_matrix("B", 0, repeating_matrix(env.x_dim, [4, 8, 12, 16, 20, 24, 28, 32][: env.y_dim], env.data_width))

			plan = env.plan_matmul(0x581, 0x000, 0x000)
			assert len(plan.expected_dma_loads) == 2
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x581)
			await env.wait_ctrl_resp(plan.response_word)
			env.model.commit_success(plan)
			await env.wait_export_done(1)
			return

		raise AssertionError(f"unsupported state case kind={kind}")
	finally:
		env.shutdown()


def _register_state_case(case: ScenarioCase) -> None:
	async def _test(dut) -> None:
		await _run_state_case(dut, case)

	_test.__name__ = case.case_name
	globals()[case.case_name] = cocotb.test(name=case.case_name)(_test)


for _case in STATE_CASES:
	_register_state_case(_case)
