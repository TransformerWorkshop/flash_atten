from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from tests.pt_blackbox_env import (
	ConstantPattern,
	ExportInjection,
	SequencePattern,
	create_env,
	flatten_pattern_matrix,
	repeating_matrix,
	setup_bases_and_passthrough_qcfg,
	value_to_int,
)
from tests.pt_case_catalog import COVERAGE_CASES, ScenarioCase
from tests.pt_model import (
	PT_QGRAN_PER_TENSOR,
	PT_QGRAN_X_WISE,
	PT_QGRAN_X_WISE_DIV2,
	PT_QGRAN_Y_WISE,
	PT_QGRAN_Y_WISE_DIV2,
	PT_SCALE_FULL,
	build_cfg_inst,
	build_matadd_inst,
	build_matmul_inst,
	build_mwin_off,
	build_qcfg_header,
	identity_matrix,
	pack_resp,
	qcfg_payload_count,
)


def _scale_words(count: int, *, offset: int = 0):
	base = [0x0001_0000, 0x0000_8000, 0xFFFF_0000, 0x0001_8000, 0x0002_0000, 0xFFFF_8000]
	return [base[(idx + offset) % len(base)] for idx in range(count)]


async def _prepare_env(dut):
	env = await create_env(dut)
	await setup_bases_and_passthrough_qcfg(env)
	env.register_external_matrix("A", 0x000, identity_matrix(env.x_dim, env.data_width))
	env.register_external_matrix("B", 0x000, flatten_pattern_matrix(env.y_dim, 2, 1, 0))
	env.register_external_matrix("A", env.x_dim, repeating_matrix(env.x_dim, [1, 0, 2, 0, 3, 0, 4, 0][: env.x_dim], env.data_width))
	env.register_external_matrix("B", env.y_dim, flatten_pattern_matrix(env.y_dim, 3, 2, 1))
	return env


async def _reseed_after_clear(env) -> None:
	await env.cfg_base("A", env.a_base, 0x900)
	await env.cfg_base("B", env.b_base, 0x901)
	await env.qcfg_success(PT_QGRAN_PER_TENSOR, [0x0001_0000], 0x902)
	env.register_external_matrix("A", 0x000, identity_matrix(env.x_dim, env.data_width))
	env.register_external_matrix("B", 0x000, flatten_pattern_matrix(env.y_dim, 2, 1, 0))
	env.register_external_matrix("A", env.x_dim, repeating_matrix(env.x_dim, [1, 0, 2, 0, 3, 0, 4, 0][: env.x_dim], env.data_width))
	env.register_external_matrix("B", env.y_dim, flatten_pattern_matrix(env.y_dim, 3, 2, 1))


async def _run_coverage_case(dut, case: ScenarioCase) -> None:
	env = await _prepare_env(dut)
	kind = case.data["kind"]
	try:
		if kind == "cfg_selector_default_noop":
			for selector, ctrl_id in ((0x4, 0x800), (0x8, 0x801), (0xE, 0x802)):
				await env.send_ctrl(build_cfg_inst(selector, 0xA55A ^ selector), ctrl_id)
				await env.wait_ctrl_resp(pack_resp(False, 0, ctrl_id), 500)
			return

		if kind == "ctrl_inst_bit_sweep":
			for bit in range(28):
				ctrl_id = (1 << bit) | 0x800
				await env.send_ctrl((0x8 << 28) | (1 << bit), ctrl_id)
				await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 500)

			# Explicitly toggle the opcode nibble with a mix of legal and illegal transactions.
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, 0, PT_SCALE_FULL, 0x000, 0x000), 0x1000_0840)
			await env.wait_ctrl_resp(pack_resp(True, 0, 0x1000_0840), 500)

			await env.send_ctrl(build_qcfg_header(PT_QGRAN_PER_TENSOR), 0x2000_0841)
			await env.expect_no_ctrl_resp(2)
			await env.send_ctrl(0x0001_0000, 0x2000_0841)
			await env.wait_ctrl_resp(pack_resp(False, 0, 0x2000_0841), 500)

			await env.send_ctrl(0x4000_0000, 0x3000_0842)
			await env.wait_ctrl_resp(pack_resp(True, 0, 0x3000_0842), 500)

			await env.send_ctrl(0x8000_0000, 0x3FFF_FFFE)
			await env.wait_ctrl_resp(pack_resp(True, 0, 0x3FFF_FFFE), 500)
			return

		if kind == "qcfg_header_variant_sweep":
			granularities = [
				PT_QGRAN_PER_TENSOR,
				PT_QGRAN_X_WISE,
				PT_QGRAN_Y_WISE,
				PT_QGRAN_X_WISE_DIV2,
				PT_QGRAN_Y_WISE_DIV2,
			]
			ctrl_id = 0x850
			for offset, granularity in enumerate(granularities):
				payload_count = qcfg_payload_count(granularity, env.x_dim, env.y_dim)
				assert payload_count is not None
				await env.qcfg_success(granularity, _scale_words(payload_count, offset=offset), ctrl_id)
				plan = env.plan_matmul(ctrl_id + 0x40, 0x000, 0x000)
				await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), ctrl_id + 0x40)
				await env.wait_ctrl_resp(plan.response_word)
				env.model.commit_success(plan)
				await env.wait_export_done(offset + 1)
				ctrl_id += 1

			await env.send_ctrl(build_qcfg_header(PT_QGRAN_X_WISE), 0x85F)
			await env.expect_no_ctrl_resp(2)
			await env.send_ctrl(0x0001_0000, 0x85F)
			await env.expect_no_ctrl_resp(2)
			await env.send_ctrl(0x0002_0000, 0x860)
			await env.wait_ctrl_resp(pack_resp(True, 0, 0x85F), 500)
			return

		if kind == "clear_phase_sweep":
			# idle
			await env.pulse_clear()
			await _reseed_after_clear(env)

			# qcfg load
			await env.send_ctrl(build_qcfg_header(PT_QGRAN_X_WISE), 0x860)
			await env.expect_no_ctrl_resp(2)
			await env.send_ctrl(0x0001_0000, 0x860)
			await env.expect_no_ctrl_resp(2)
			await env.pulse_clear()
			await _reseed_after_clear(env)

			# dma recv
			env.configure_patterns(s_axis_valid=SequencePattern([1, 0, 1, 0, 1, 1, 0, 1]))
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x861)
			await env.wait_dma_req(1)
			await env.wait_signal_value("s_axis_tvalid", 1)
			await env.pulse_clear()
			await _reseed_after_clear(env)
			env.configure_patterns(s_axis_valid=ConstantPattern(1))

			# export req
			env.configure_patterns(m_dma_req_ready=ConstantPattern(0))
			plan = env.plan_matmul(0x862, 0x000, 0x000)
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x862)
			await env.wait_ctrl_resp(plan.response_word)
			env.model.commit_success(plan)
			await env.wait_signal_value("m_dma_req_valid", 1)
			await env.pulse_clear()
			await _reseed_after_clear(env)
			env.configure_patterns(m_dma_req_ready=ConstantPattern(1))

			# export stream
			env.configure_patterns(m_axis_ready=ConstantPattern(1))
			plan = env.plan_matmul(0x863, 0x000, 0x000)
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x863)
			await env.wait_ctrl_resp(plan.response_word)
			env.model.commit_success(plan)
			await env.wait_signal_value("m_axis_tvalid", 1)
			await env.pulse_clear()
			await _reseed_after_clear(env)

			# export wait_done
			export_req_start = env.export_req_count
			export_done_start = env.export_done_count
			env.queue_export_injection(ExportInjection(done_delay=6))
			plan = env.plan_matmul(0x864, 0x000, 0x000)
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x864)
			await env.wait_ctrl_resp(plan.response_word)
			env.model.commit_success(plan)
			while True:
				await RisingEdge(dut.clk)
				if (
					env.export_req_count >= export_req_start + 1
					and value_to_int(env.dut.m_axis_tvalid.value) == 0
					and env.export_done_count == export_done_start
				):
					break
			await env.pulse_clear()
			await _reseed_after_clear(env)
			return

		if kind == "operand_source_matrix":
			await env.cfg_base32("A", 0xA5A5_1000, 0x870)
			await env.cfg_base32("B", 0x5A5A_2000, 0x872)
			env.register_external_matrix("A", 0x000, identity_matrix(env.x_dim, env.data_width))
			env.register_external_matrix("B", 0x000, flatten_pattern_matrix(env.y_dim, 2, 1, 0))
			env.register_external_matrix("A", env.x_dim, repeating_matrix(env.x_dim, [1, 0, 2, 0, 3, 0, 4, 0][: env.x_dim], env.data_width))
			env.register_external_matrix("B", env.y_dim, flatten_pattern_matrix(env.y_dim, 3, 2, 1))
			env.register_external_matrix("A", 2 * env.x_dim, flatten_pattern_matrix(env.x_dim, 5, 1, 3))
			env.register_external_matrix("B", 2 * env.y_dim, flatten_pattern_matrix(env.y_dim, 1, 4, 2))
			env.register_external_matrix("A", 3 * env.x_dim, flatten_pattern_matrix(env.x_dim, 7, 2, 1))
			env.register_external_matrix("B", 3 * env.y_dim, flatten_pattern_matrix(env.y_dim, 2, 5, 4))

			first = env.plan_matmul(0xC000_0100, 0x000, 0x000)
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0xC000_0100)
			first_resp = await env.wait_ctrl_resp(first.response_word)
			env.model.commit_success(first)
			await env.wait_export_done(1)
			mwin_buf = (first_resp >> 30) & 0x1
			mwin_off = build_mwin_off(mwin_buf, 0)

			combos = [
				(0x8000_0101, 0x000, 0x000),
				(0x4000_0102, 0x000, env.y_dim),
				(0xC000_0103, env.x_dim, env.y_dim),
				(0x8000_0104, mwin_off, env.y_dim),
				(0x4000_0105, env.x_dim, mwin_off),
				(0xC000_0106, mwin_off, mwin_off),
				(0x8000_0107, 2 * env.x_dim, 2 * env.y_dim),
				(0x4000_0108, 3 * env.x_dim, 3 * env.y_dim),
			]
			target_done = 1
			for ctrl_id, a_off, b_off in combos:
				plan = env.plan_matmul(ctrl_id, a_off, b_off)
				await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, a_off, b_off), ctrl_id)
				await env.wait_ctrl_resp(plan.response_word)
				env.model.commit_success(plan)
				target_done += 1
				await env.wait_export_done(target_done)
			return

			if kind == "export_path_sweep":
				env.configure_patterns(
					m_dma_req_ready=SequencePattern([0, 0, 1, 0, 1, 1]),
					m_axis_ready=SequencePattern([1, 0, 1, 1, 0, 1, 1]),
				)
				success = env.plan_matmul(0x880, 0x000, 0x000)
				await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x880)
				await env.wait_ctrl_resp(success.response_word)
				env.model.commit_success(success)
				await env.wait_export_done(1, 12000)

				env.queue_export_injection(ExportInjection(error=True, done_delay=2))
				error_plan = env.plan_matmul(0x881, 0x000, 0x000)
				await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x881)
				await env.wait_ctrl_resp(error_plan.response_word)
				env.model.commit_success(error_plan)
				await env.wait_export_error(1, 12000)
				await env.wait_ctrl_resp(pack_resp(True, error_plan.success_buffer, 0x881), 12000)
				return

			if kind == "matadd_path_sweep":
				env.register_external_matrix("B", env.y_dim, flatten_pattern_matrix(env.y_dim, 1, 2, 3))
				matmul = env.plan_matmul(0x890, 0x000, 0x000)
				await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x890)
				await env.wait_ctrl_resp(matmul.response_word)
				env.model.commit_success(matmul)
				await env.wait_export_done(1)

				m_off = build_mwin_off(matmul.success_buffer, 0)
				matadd_miss = env.plan_matadd(0x891, m_off, env.y_dim)
				await env.send_ctrl(build_matadd_inst(m_off, env.y_dim), 0x891)
				await env.wait_ctrl_resp(matadd_miss.response_word)
				env.model.commit_success(matadd_miss)
				await env.wait_export_done(2)

				m_off_hit = build_mwin_off(matadd_miss.success_buffer, 0)
				matadd_hit = env.plan_matadd(0x891, m_off_hit, env.y_dim)
				await env.send_ctrl(build_matadd_inst(m_off_hit, env.y_dim), 0x891)
				await env.wait_ctrl_resp(matadd_hit.response_word)
				env.model.commit_success(matadd_hit)
				await env.wait_export_done(3)
				return

			raise AssertionError(f"unsupported coverage case kind={kind}")
	finally:
		env.shutdown()


def _register_coverage_case(case: ScenarioCase) -> None:
	async def _test(dut) -> None:
		await _run_coverage_case(dut, case)

	_test.__name__ = case.case_name
	globals()[case.case_name] = cocotb.test(name=case.case_name)(_test)


for _case in COVERAGE_CASES:
	_register_coverage_case(_case)
