from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles

from tests.pt_blackbox_env import AbInjection, create_env, flatten_pattern_matrix, repeating_matrix, setup_bases_and_passthrough_qcfg
from tests.pt_case_catalog import PROTOCOL_EDGE_CASES, ScenarioCase
from tests.pt_model import (
	PT_QTYPE_SYMMETRIC,
	PT_SCALE_FULL,
	build_matmul_inst,
	build_mwin_off,
	build_qcfg_header,
	identity_matrix,
	pack_resp,
)


async def _prepare_env(dut):
	env = await create_env(dut)
	await setup_bases_and_passthrough_qcfg(env)
	env.register_external_matrix("A", 0x000, identity_matrix(env.x_dim, env.data_width))
	env.register_external_matrix("B", 0x000, flatten_pattern_matrix(env.y_dim, 2, 1, 0))
	env.register_external_matrix("A", env.x_dim, repeating_matrix(env.x_dim, [1, 0, 2, 0, 3, 0, 4, 0][: env.x_dim], env.data_width))
	env.register_external_matrix("B", env.y_dim, flatten_pattern_matrix(env.y_dim, 3, 2, 1))
	return env


async def _run_protocol_edge_case(dut, case: ScenarioCase) -> None:
	env = await _prepare_env(dut)
	kind = case.data["kind"]
	params = case.data["params"]
	try:
		if kind == "unknown_opcode":
			start = env.snapshot()
			await env.send_ctrl(params["inst"], 0x700)
			await env.wait_ctrl_resp(pack_resp(True, 0, 0x700), 500)
			await ClockCycles(dut.clk, 8)
			assert env.dma_req_count == start.dma_req_count
			assert env.export_req_count == start.export_req_count
			assert env.irq_count == start.irq_count + 1
			return

		if kind == "qcfg_invalid_granularity":
			start = env.snapshot()
			await env.send_ctrl(build_qcfg_header(params["granularity"], qtype=PT_QTYPE_SYMMETRIC), 0x701)
			await env.wait_ctrl_resp(pack_resp(True, 0, 0x701), 500)
			await ClockCycles(dut.clk, 8)
			assert env.dma_req_count == start.dma_req_count
			assert env.export_req_count == start.export_req_count
			assert env.irq_count == start.irq_count + 1
			return

		if kind == "dma_error_mid_a":
			start = env.snapshot()
			env.queue_ab_injection(AbInjection(error_mode="mid_stream", error_at_beat=params["error_at_beat"], done_delay=params["delay"]))
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x702)
			await env.wait_ctrl_resp(pack_resp(True, 0, 0x702), 4000)
			await ClockCycles(dut.clk, 8)
			assert env.dma_req_count >= start.dma_req_count + 1
			assert env.export_req_count == start.export_req_count
			assert env.irq_count == start.irq_count + 1
			return

		if kind == "dma_error_mid_b":
			start = env.snapshot()
			env.queue_ab_injection(AbInjection())
			env.queue_ab_injection(AbInjection(error_mode="mid_stream", error_at_beat=params["error_at_beat"], done_delay=params["delay"]))
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x703)
			await env.wait_ctrl_resp(pack_resp(True, 0, 0x703), 4000)
			await ClockCycles(dut.clk, 8)
			assert env.dma_req_count >= start.dma_req_count + 2
			assert env.export_req_count == start.export_req_count
			assert env.irq_count == start.irq_count + 1
			return

		if kind == "dma_error_after_a":
			start = env.snapshot()
			env.queue_ab_injection(AbInjection(error_mode="after_stream", done_delay=params["delay"]))
			plan = env.plan_matmul(0x704, 0x000, 0x000)
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x704)
			await env.wait_ctrl_resp(plan.response_word, 4000)
			env.model.commit_success(plan)
			await env.wait_export_done(start.export_done_count + 1)
			assert env.dma_req_count >= start.dma_req_count + 2
			assert env.export_req_count == start.export_req_count + 1
			assert env.irq_count == start.irq_count + 1
			return

		if kind == "dma_error_after_b":
			start = env.snapshot()
			env.queue_ab_injection(AbInjection())
			env.queue_ab_injection(AbInjection(error_mode="after_stream", done_delay=params["delay"]))
			plan = env.plan_matmul(0x705, 0x000, 0x000)
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x705)
			await env.wait_ctrl_resp(plan.response_word, 4000)
			env.model.commit_success(plan)
			await env.wait_export_done(start.export_done_count + 1)
			assert env.dma_req_count >= start.dma_req_count + 2
			assert env.export_req_count == start.export_req_count + 1
			assert env.irq_count == start.irq_count + 1
			return

		if kind == "single_side_hit_mix":
			first = env.plan_matmul(0x706, 0x000, 0x000)
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x706)
			await env.wait_ctrl_resp(first.response_word)
			env.model.commit_success(first)
			await env.wait_export_done(1)

			a_hit_b_miss_start = env.snapshot()
			a_hit_b_miss = env.plan_matmul(0x706, 0x000, env.y_dim)
			assert len(a_hit_b_miss.expected_dma_loads) == 1
			assert a_hit_b_miss.expected_dma_loads[0].kind == "B"
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, env.y_dim), 0x706)
			await env.wait_ctrl_resp(a_hit_b_miss.response_word)
			env.model.commit_success(a_hit_b_miss)
			await env.wait_export_done(a_hit_b_miss_start.export_done_count + 1)
			assert env.dma_req_count - a_hit_b_miss_start.dma_req_count == 1

			a_miss_b_hit_start = env.snapshot()
			a_miss_b_hit = env.plan_matmul(0x706, env.x_dim, env.y_dim)
			assert len(a_miss_b_hit.expected_dma_loads) == 1
			assert a_miss_b_hit.expected_dma_loads[0].kind == "A"
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, env.x_dim, env.y_dim), 0x706)
			await env.wait_ctrl_resp(a_miss_b_hit.response_word)
			env.model.commit_success(a_miss_b_hit)
			await env.wait_export_done(a_miss_b_hit_start.export_done_count + 1)
			assert env.dma_req_count - a_miss_b_hit_start.dma_req_count == 1
			return

		if kind == "single_side_mwindow_mix":
			first = env.plan_matmul(0x707, 0x000, 0x000)
			first_resp_expected = first.response_word
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x707)
			first_resp = await env.wait_ctrl_resp(first_resp_expected)
			env.model.commit_success(first)
			await env.wait_export_done(1)
			mwin_buf = (first_resp >> 30) & 0x1
			mwin_off = build_mwin_off(mwin_buf, 0)

			a_mwin_b_ext_start = env.snapshot()
			a_mwin_b_ext = env.plan_matmul(0x708, mwin_off, env.y_dim)
			assert len(a_mwin_b_ext.expected_dma_loads) == 1
			assert a_mwin_b_ext.expected_dma_loads[0].kind == "B"
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, mwin_off, env.y_dim), 0x708)
			await env.wait_ctrl_resp(a_mwin_b_ext.response_word)
			env.model.commit_success(a_mwin_b_ext)
			await env.wait_export_done(a_mwin_b_ext_start.export_done_count + 1)
			assert env.dma_req_count - a_mwin_b_ext_start.dma_req_count == 1

			a_ext_b_mwin_start = env.snapshot()
			a_ext_b_mwin = env.plan_matmul(0x709, env.x_dim, mwin_off)
			assert len(a_ext_b_mwin.expected_dma_loads) == 1
			assert a_ext_b_mwin.expected_dma_loads[0].kind == "A"
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, env.x_dim, mwin_off), 0x709)
			await env.wait_ctrl_resp(a_ext_b_mwin.response_word)
			env.model.commit_success(a_ext_b_mwin)
			await env.wait_export_done(a_ext_b_mwin_start.export_done_count + 1)
			assert env.dma_req_count - a_ext_b_mwin_start.dma_req_count == 1
			return

		raise AssertionError(f"unsupported protocol edge case kind={kind}")
	finally:
		env.shutdown()


def _register_protocol_edge_case(case: ScenarioCase) -> None:
	async def _test(dut) -> None:
		await _run_protocol_edge_case(dut, case)

	_test.__name__ = case.case_name
	globals()[case.case_name] = cocotb.test(name=case.case_name)(_test)


for _case in PROTOCOL_EDGE_CASES:
	_register_protocol_edge_case(_case)
