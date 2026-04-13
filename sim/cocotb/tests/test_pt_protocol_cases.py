from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles

from tests.pt_blackbox_env import AbInjection, ExportInjection, create_env, flatten_pattern_matrix, setup_bases_and_passthrough_qcfg
from tests.pt_case_catalog import PROTOCOL_CASES, ScenarioCase
from tests.pt_model import (
	PT_QGRAN_X_WISE,
	PT_QGRAN_Y_WISE,
	PT_QTYPE_SYMMETRIC,
	PT_SCALE_FULL,
	build_matadd_inst,
	build_matmul_inst,
	build_qcfg_header,
	pack_resp,
)


async def _prepare_env(dut):
	env = await create_env(dut)
	await setup_bases_and_passthrough_qcfg(env)
	env.register_external_matrix("A", 0, flatten_pattern_matrix(env.x_dim, 1, 1, 0))
	env.register_external_matrix("B", 0, flatten_pattern_matrix(env.y_dim, 2, 1, 0))
	return env


async def _run_protocol_case(dut, case: ScenarioCase) -> None:
	env = await _prepare_env(dut)
	ctrl_id = 0x200
	kind = case.data["kind"]
	params = case.data["params"]
	try:
		if kind == "invalid_scale":
			start = env.snapshot()
			plan = env.plan_matmul(ctrl_id, 0x000, 0x000, **params)
			assert plan.err
			await env.send_ctrl(build_matmul_inst(params["m_scale"], params["n_scale"], params["k_scale"], 0x000, 0x000), ctrl_id)
			await env.wait_ctrl_resp(plan.response_word, 500)
			await ClockCycles(dut.clk, 8)
			assert env.dma_req_count == start.dma_req_count
			assert env.export_req_count == start.export_req_count
			assert env.irq_count == start.irq_count + 1
			return

		if kind == "bad_align":
			start = env.snapshot()
			plan = env.plan_matmul(ctrl_id, params["a_off"], params["b_off"])
			assert plan.err
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, params["a_off"], params["b_off"]), ctrl_id)
			await env.wait_ctrl_resp(plan.response_word, 500)
			await ClockCycles(dut.clk, 8)
			assert env.dma_req_count == start.dma_req_count
			assert env.export_req_count == start.export_req_count
			assert env.irq_count == start.irq_count + 1
			return

		if kind == "bad_qtype":
			start = env.snapshot()
			await env.send_ctrl(build_qcfg_header(PT_QGRAN_X_WISE, qtype=params["qtype"]), ctrl_id)
			await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 500)
			await ClockCycles(dut.clk, 8)
			assert env.export_req_count == start.export_req_count
			assert env.irq_count == start.irq_count + 1
			return

		if kind == "qcfg_id_mismatch_x":
			start = env.snapshot()
			await env.send_ctrl(build_qcfg_header(PT_QGRAN_X_WISE, qtype=PT_QTYPE_SYMMETRIC), ctrl_id)
			await env.expect_no_ctrl_resp(4)
			await env.send_ctrl(0x0001_0000, ctrl_id)
			await env.expect_no_ctrl_resp(4)
			await env.send_ctrl(0x0001_0000, ctrl_id + 1)
			await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 500)
			await ClockCycles(dut.clk, 8)
			assert env.export_req_count == start.export_req_count
			assert env.irq_count == start.irq_count + 1
			return

		if kind == "qcfg_id_mismatch_y":
			start = env.snapshot()
			await env.send_ctrl(build_qcfg_header(PT_QGRAN_Y_WISE, qtype=PT_QTYPE_SYMMETRIC), ctrl_id)
			await env.expect_no_ctrl_resp(4)
			await env.send_ctrl(0x0001_0000, ctrl_id)
			await env.expect_no_ctrl_resp(4)
			await env.send_ctrl(0x0002_0000, ctrl_id + 1)
			await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 500)
			await ClockCycles(dut.clk, 8)
			assert env.export_req_count == start.export_req_count
			assert env.irq_count == start.irq_count + 1
			return

		if kind == "wrong_tuser_a":
			start = env.snapshot()
			env.queue_ab_injection(AbInjection(wrong_tuser=True))
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), ctrl_id)
			await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 2000)
			await ClockCycles(dut.clk, 8)
			assert env.dma_req_count >= start.dma_req_count + 1
			assert env.export_req_count == start.export_req_count
			assert env.irq_count == start.irq_count + 1
			return

		if kind == "wrong_tuser_b":
			start = env.snapshot()
			env.queue_ab_injection(AbInjection())
			env.queue_ab_injection(AbInjection(wrong_tuser=True))
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), ctrl_id)
			await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 3000)
			await ClockCycles(dut.clk, 8)
			assert env.dma_req_count >= start.dma_req_count + 2
			assert env.export_req_count == start.export_req_count
			assert env.irq_count == start.irq_count + 1
			return

		if kind == "dma_error_before_a":
			start = env.snapshot()
			env.queue_ab_injection(AbInjection(error_mode="before_stream", done_delay=params["delay"]))
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), ctrl_id)
			await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 3000)
			await ClockCycles(dut.clk, 8)
			assert env.dma_req_count >= start.dma_req_count + 1
			assert env.export_req_count == start.export_req_count
			assert env.irq_count == start.irq_count + 1
			return

		if kind == "dma_error_before_b":
			start = env.snapshot()
			env.queue_ab_injection(AbInjection())
			env.queue_ab_injection(AbInjection(error_mode="before_stream", done_delay=params["delay"]))
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), ctrl_id)
			await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 3000)
			await ClockCycles(dut.clk, 8)
			assert env.dma_req_count >= start.dma_req_count + 2
			assert env.export_req_count == start.export_req_count
			assert env.irq_count == start.irq_count + 1
			return

			if kind == "export_error":
				start = env.snapshot()
				env.queue_export_injection(ExportInjection(error=True, done_delay=params["delay"]))
				plan = env.plan_matmul(ctrl_id, 0x000, 0x000)
				await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), ctrl_id)
				await env.wait_ctrl_resp(plan.response_word, 4000)
				env.model.commit_success(plan)
				await env.wait_export_error(start.export_error_count + 1)
				await env.wait_ctrl_resp(pack_resp(True, plan.success_buffer, ctrl_id), 4000)
				assert env.export_req_count == start.export_req_count + 1
				assert env.irq_count == start.irq_count + 2
				return

			if kind == "matadd_invalid":
				start = env.snapshot()
				plan = env.plan_matadd(
					ctrl_id,
					params["m_off"],
					params["c_off"],
					reserved_hi=params.get("reserved_hi", 0),
					reserved_lo=params.get("reserved_lo", 0),
				)
				assert plan.err
				await env.send_ctrl(
					build_matadd_inst(
						params["m_off"],
						params["c_off"],
						reserved_hi=params.get("reserved_hi", 0),
						reserved_lo=params.get("reserved_lo", 0),
					),
					ctrl_id,
				)
				await env.wait_ctrl_resp(plan.response_word, 500)
				await ClockCycles(dut.clk, 8)
				assert env.dma_req_count == start.dma_req_count
				assert env.export_req_count == start.export_req_count
				assert env.irq_count == start.irq_count + 1
				return

			raise AssertionError(f"unsupported protocol case kind={kind}")
	finally:
		env.shutdown()


def _register_protocol_case(case: ScenarioCase) -> None:
	async def _test(dut) -> None:
		await _run_protocol_case(dut, case)

	_test.__name__ = case.case_name
	globals()[case.case_name] = cocotb.test(name=case.case_name)(_test)


for _case in PROTOCOL_CASES:
	_register_protocol_case(_case)
