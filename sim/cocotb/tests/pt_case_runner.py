from __future__ import annotations

import os
import re
from typing import Callable, Dict, Iterable, List, Mapping, Sequence

import cocotb

from tests.pt_blackbox_env import (
	AbInjection,
	ConstantPattern,
	ExportInjection,
	create_env,
	flatten_pattern_matrix,
	repeating_matrix,
	setup_bases_and_passthrough_qcfg,
)
from tests.pt_case_catalog import ScenarioCase
from tests.pt_model import (
	PT_QGRAN_PER_TENSOR,
	PT_QGRAN_X_WISE,
	PT_QGRAN_X_WISE_DIV2,
	PT_QGRAN_Y_WISE,
	PT_QGRAN_Y_WISE_DIV2,
	PT_QTYPE_SYMMETRIC,
	PT_SCALE_FULL,
	build_load_inst,
	build_matadd_inst,
	build_matmul_inst,
	build_mwin_off,
	build_qcfg_header,
	constant_matrix,
	identity_matrix,
	pack_resp,
	qcfg_payload_count,
	to_unsigned,
	zero_matrix,
)


SUITE_CASE_OVERRIDES: Dict[str, Dict[str, Sequence[str]]] = {
	"smoke": {
		"smoke": (
			"test_pt_smoke_typical_dense_pos_balanced_01",
			"test_pt_smoke_typical_checkerboard_low_range_08",
			"test_pt_smoke_boundary_identity_a_passthrough_15",
			"test_pt_smoke_typical_matadd_chain_quant_plus_c_21",
		),
	},
	"ci": {
		"smoke": (
			"test_pt_smoke_typical_dense_pos_balanced_01",
			"test_pt_smoke_typical_checkerboard_low_range_08",
			"test_pt_smoke_boundary_identity_a_passthrough_15",
			"test_pt_smoke_typical_matadd_chain_quant_plus_c_21",
		),
		"numeric": (
			"test_pt_numeric_typical_zero_01",
			"test_pt_numeric_typical_mixed_sign_low_range_08",
			"test_pt_numeric_boundary_upper_sat_pos_09",
			"test_pt_numeric_boundary_div2_sign_mix_20",
		),
		"qcfg": (
			"test_pt_qcfg_typical_per_tensor_unity_01",
			"test_pt_qcfg_typical_x_wise_gradient_pos_03",
			"test_pt_qcfg_typical_y_wise_gradient_pos_05",
			"test_pt_qcfg_typical_x_div2_balanced_07",
			"test_pt_qcfg_typical_y_div2_balanced_08",
		),
		"protocol": (
			"test_pt_protocol_error_control_invalid_scale_all_04",
			"test_pt_protocol_error_align_bad_a_off_05",
			"test_pt_protocol_error_qcfg_bad_qtype_09",
			"test_pt_protocol_error_qcfg_id_mismatch_x_11",
			"test_pt_protocol_error_stream_wrong_tuser_a_13",
			"test_pt_protocol_error_stream_dma_error_b_short_16",
			"test_pt_protocol_error_export_error_mid_19",
			"test_pt_protocol_error_matadd_reserved_nonzero_24",
		),
		"protocol_edge": (
			"test_pt_protocol_edge_unknown_opcode_01",
			"test_pt_protocol_edge_qcfg_invalid_granularity_02",
			"test_pt_protocol_edge_dma_error_mid_a_03",
			"test_pt_protocol_edge_single_side_hit_mix_07",
			"test_pt_protocol_edge_single_side_mwindow_mix_08",
			"test_pt_protocol_edge_bslot_overwritten_by_c_then_b_reloads_09",
		),
		"state": (
			"test_pt_state_reset_clear_idle_recovery_01",
			"test_pt_state_reset_clear_mid_export_recovery_02",
			"test_pt_state_cfg_a_base_hi_nonzero_03",
			"test_pt_state_cfg_b_base_hi_nonzero_04",
		),
	},
	"coverage": {
		"smoke": (
			"test_pt_smoke_typical_dense_pos_balanced_01",
			"test_pt_smoke_typical_checkerboard_low_range_08",
			"test_pt_smoke_boundary_zero_row_a_11",
			"test_pt_smoke_boundary_zero_col_b_14",
			"test_pt_smoke_boundary_identity_a_passthrough_15",
			"test_pt_smoke_typical_matadd_chain_quant_plus_c_21",
		),
		"numeric": (
			"test_pt_numeric_typical_zero_01",
			"test_pt_numeric_typical_mixed_sign_low_range_08",
			"test_pt_numeric_boundary_upper_sat_pos_09",
			"test_pt_numeric_boundary_upper_sat_neg_10",
			"test_pt_numeric_boundary_round_tie_pos_13",
			"test_pt_numeric_boundary_round_tie_neg_14",
			"test_pt_numeric_boundary_scale_sign_flip_18",
			"test_pt_numeric_boundary_div2_sign_mix_20",
		),
		"qcfg": (
			"test_pt_qcfg_typical_per_tensor_unity_01",
			"test_pt_qcfg_typical_per_tensor_half_02",
			"test_pt_qcfg_typical_x_wise_gradient_pos_03",
			"test_pt_qcfg_typical_y_wise_gradient_pos_05",
			"test_pt_qcfg_typical_x_div2_balanced_07",
			"test_pt_qcfg_typical_y_div2_balanced_08",
			"test_pt_qcfg_boundary_per_tensor_neg_unit_09",
			"test_pt_qcfg_boundary_x_div2_sign_flip_15",
		),
		"protocol": (
			"test_pt_protocol_error_control_invalid_scale_all_04",
			"test_pt_protocol_error_align_bad_a_off_05",
			"test_pt_protocol_error_qcfg_bad_qtype_09",
			"test_pt_protocol_error_qcfg_id_mismatch_x_11",
			"test_pt_protocol_error_qcfg_id_mismatch_y_12",
			"test_pt_protocol_error_stream_wrong_tuser_a_13",
			"test_pt_protocol_error_stream_dma_error_b_short_16",
			"test_pt_protocol_error_export_error_mid_19",
			"test_pt_protocol_error_matadd_reserved_nonzero_24",
		),
		"protocol_edge": (
			"test_pt_protocol_edge_unknown_opcode_01",
			"test_pt_protocol_edge_qcfg_invalid_granularity_02",
			"test_pt_protocol_edge_dma_error_mid_a_03",
			"test_pt_protocol_edge_dma_error_after_b_06",
			"test_pt_protocol_edge_single_side_hit_mix_07",
			"test_pt_protocol_edge_single_side_mwindow_mix_08",
			"test_pt_protocol_edge_bslot_overwritten_by_c_then_b_reloads_09",
		),
		"state": (
			"test_pt_state_reset_clear_idle_recovery_01",
			"test_pt_state_reset_clear_mid_export_recovery_02",
			"test_pt_state_cfg_a_base_hi_nonzero_03",
			"test_pt_state_cfg_b_base_hi_nonzero_04",
		),
	},
}

DMA_TOP_FILTERED_CASES = {
	"test_pt_protocol_error_stream_wrong_tuser_a_13",
	"test_pt_protocol_error_stream_wrong_tuser_b_14",
	"test_pt_protocol_error_stream_dma_error_a_short_15",
	"test_pt_protocol_error_stream_dma_error_b_short_16",
	"test_pt_protocol_error_stream_dma_error_b_long_17",
}


def _suite_name() -> str:
	return os.getenv("PT_SUITE_NAME", "full").strip() or "full"


def _is_dma_top() -> bool:
	return os.getenv("PT_TOPLEVEL", "PT") == "PT_DMA_TOP"


def _current_dims() -> tuple[int, int]:
	x_dim = int(os.getenv("PT_X_DIM", "4"))
	y_dim = int(os.getenv("PT_Y_DIM", str(x_dim)))
	return x_dim, y_dim


def _case_serial(case_name: str) -> int:
	match = re.search(r"_(\d+)$", case_name)
	return int(match.group(1)) if match else 0


def _matches_current_dims(case: ScenarioCase) -> bool:
	x_dim, y_dim = _current_dims()
	return x_dim == y_dim and x_dim in case.dims


def _selected_case_names(module_key: str) -> Sequence[str] | None:
	return SUITE_CASE_OVERRIDES.get(_suite_name(), {}).get(module_key)


def select_cases(module_key: str, cases: Iterable[ScenarioCase]) -> List[ScenarioCase]:
	candidates = [case for case in cases if _matches_current_dims(case)]
	if _is_dma_top():
		candidates = [case for case in candidates if case.case_name not in DMA_TOP_FILTERED_CASES]
	if _suite_name() == "coverage":
		return candidates
	selected_names = _selected_case_names(module_key)
	if selected_names is None:
		return candidates if _suite_name() == "full" else [case for case in candidates if _suite_name() in case.suite_tags]

	name_set = set(selected_names)
	return [case for case in candidates if case.case_name in name_set]


def install_catalog_tests(
	namespace: Mapping[str, object],
	module_key: str,
	cases: Iterable[ScenarioCase],
	runner: Callable[[object, ScenarioCase], object],
) -> None:
	for case in select_cases(module_key, cases):
		async def _generated(dut, _case=case):
			await runner(dut, _case)

		_generated.__name__ = case.case_name
		namespace[case.case_name] = cocotb.test(name=case.case_name)(_generated)


def _normalize_values(args) -> List[int]:
	if args is None:
		return []
	if isinstance(args, tuple) and len(args) == 1 and isinstance(args[0], (list, tuple)):
		return [int(value) for value in args[0]]
	if isinstance(args, (list, tuple)):
		return [int(value) for value in args]
	return [int(args)]


def _expand_scales(words: Sequence[int], payload_count: int) -> List[int]:
	values = [to_unsigned(int(word), 32) for word in words]
	assert values, "scale list must not be empty"
	if len(values) >= payload_count:
		return values[:payload_count]
	return [values[idx % len(values)] for idx in range(payload_count)]


def _checker_matrix(dim: int, lo: int, hi: int, bits: int) -> List[int]:
	values: List[int] = []
	for row in range(dim):
		for col in range(dim):
			values.append(to_unsigned(hi if ((row + col) & 0x1) else lo, bits))
	return values


def _single_hot_matrix(dim: int, index: int, value: int, bits: int) -> List[int]:
	values = [0] * (dim * dim)
	values[index % len(values)] = to_unsigned(value, bits)
	return values


def _apply_zero_row(matrix: Sequence[int], dim: int, row_idx: int) -> List[int]:
	values = list(matrix)
	row = row_idx % dim
	for col in range(dim):
		values[(row * dim) + col] = 0
	return values


def _apply_zero_col(matrix: Sequence[int], dim: int, col_idx: int) -> List[int]:
	values = list(matrix)
	col = col_idx % dim
	for row in range(dim):
		values[(row * dim) + col] = 0
	return values


def build_matrix(mode: str, args, dim: int, bits: int) -> List[int]:
	if mode == "pattern":
		row_gain, col_gain, bias = args
		return flatten_pattern_matrix(dim, int(row_gain), int(col_gain), int(bias), bits)
	if mode == "repeat":
		return repeating_matrix(dim, _normalize_values(args), bits)
	if mode == "checker":
		low, high = args
		return _checker_matrix(dim, int(low), int(high), bits)
	if mode == "single_hot":
		index, value = args
		return _single_hot_matrix(dim, int(index), int(value), bits)
	if mode == "zero_row_pattern":
		base_args, row_idx = args
		return _apply_zero_row(build_matrix("pattern", base_args, dim, bits), dim, int(row_idx))
	if mode == "zero_col_pattern":
		base_args, col_idx = args
		return _apply_zero_col(build_matrix("pattern", base_args, dim, bits), dim, int(col_idx))
	if mode == "identity":
		return identity_matrix(dim, bits)
	if mode == "zero":
		return zero_matrix(dim, dim)
	if mode == "constant":
		values = _normalize_values(args)
		return constant_matrix(dim, dim, values[0], bits)
	raise ValueError(f"unsupported matrix mode: {mode}")


def _ctrl_id(base: int, case: ScenarioCase) -> int:
	return base + _case_serial(case.case_name)


def _default_a_matrix(env, bias: int = 0) -> List[int]:
	return flatten_pattern_matrix(env.x_dim, 3 + (bias & 0x1), 1 + ((bias >> 1) & 0x1), bias, env.data_width)


def _default_b_matrix(env, bias: int = 0) -> List[int]:
	return flatten_pattern_matrix(env.y_dim, 2 + (bias & 0x1), 2 + ((bias >> 1) & 0x1), bias, env.data_width)


async def _run_matmul_once(env, ctrl_id: int, *, timeout_resp: int = 12000, timeout_export: int = 20000):
	plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
	assert not plan.err, f"{ctrl_id:#x}: unexpected matmul reject {plan.reject_reason}"
	snapshot = env.snapshot()
	await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
	resp = await env.wait_ctrl_resp(plan.response_word, timeout_resp)
	await env.wait_export_done(snapshot.export_done_count + 1, timeout_export)
	return plan, resp


async def run_smoke_case(dut, case: ScenarioCase) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		ctrl_id = _ctrl_id(0x1000, case)
		a_matrix = build_matrix(case.data.get("a_mode", "identity"), case.data.get("a_args", ()), env.x_dim, env.data_width)
		b_matrix = build_matrix(case.data.get("b_mode", "pattern"), case.data.get("b_args", (2, 1, 0)), env.y_dim, env.data_width)
		env.register_external_matrix("A", ctrl_id, a_matrix)
		env.register_external_matrix("B", ctrl_id, b_matrix)

		if case.data.get("kind") == "matadd_chain":
			c_matrix = build_matrix(case.data["c_mode"], case.data["c_args"], env.y_dim, env.data_width)
			env.register_external_matrix("C", ctrl_id, c_matrix)
			_, resp = await _run_matmul_once(env, ctrl_id)
			m_off = build_mwin_off((resp >> 30) & 0x1, 0)
			matadd = env.plan_matadd(ctrl_id, m_off)
			assert not matadd.err, f"{ctrl_id:#x}: unexpected matadd reject {matadd.reject_reason}"
			snapshot = env.snapshot()
			await env.send_ctrl(build_matadd_inst(m_off), ctrl_id)
			await env.wait_ctrl_resp(matadd.response_word, 4000)
			await env.wait_export_done(snapshot.export_done_count + 1, 12000)
			return

		first_plan, _ = await _run_matmul_once(env, ctrl_id)
		if "cache_reuse" in case.profile:
			second_plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
			assert not second_plan.err, f"{ctrl_id:#x}: unexpected cache-reuse reject {second_plan.reject_reason}"
			assert len(second_plan.expected_dma_loads) == 0, f"{ctrl_id:#x}: expected cache hit on second matmul"
			snapshot = env.snapshot()
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
			await env.wait_ctrl_resp(second_plan.response_word, 12000)
			await env.wait_export_done(snapshot.export_done_count + 1, 20000)
		else:
			assert len(first_plan.expected_dma_loads) == 2, f"{ctrl_id:#x}: expected cold miss A/B loads"
	finally:
		env.shutdown()


async def run_numeric_case(dut, case: ScenarioCase) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		ctrl_id = _ctrl_id(0x2000, case)
		payload_count = qcfg_payload_count(case.data["granularity"], env.x_dim, env.y_dim)
		assert payload_count is not None
		scales = _expand_scales(case.data["scales"], payload_count)
		await env.qcfg_success(case.data["granularity"], scales, ctrl_id - 1)
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix("B", ctrl_id, build_matrix(case.data["b_mode"], case.data.get("b_args", ()), env.y_dim, env.data_width))
		await _run_matmul_once(env, ctrl_id)
	finally:
		env.shutdown()


async def run_qcfg_case(dut, case: ScenarioCase) -> None:
	env = await create_env(dut)
	try:
		await env.cfg_base("A", env.a_base, 0x10)
		await env.cfg_base("B", env.b_base, 0x11)
		ctrl_id = _ctrl_id(0x3000, case)
		payload_count = qcfg_payload_count(case.data["granularity"], env.x_dim, env.y_dim)
		assert payload_count is not None
		await env.qcfg_success(case.data["granularity"], _expand_scales(case.data["scales"], payload_count), ctrl_id - 1)
		env.register_external_matrix("A", ctrl_id, identity_matrix(env.x_dim, env.data_width))
		env.register_external_matrix(
			"B",
			ctrl_id,
			repeating_matrix(env.x_dim, [int(value) for value in case.data["b_values"][: env.y_dim]], env.data_width),
		)
		await _run_matmul_once(env, ctrl_id)
	finally:
		env.shutdown()


async def _register_protocol_matrices(env, ctrl_id: int, *, include_c: bool = False, bias: int = 0) -> None:
	env.register_external_matrix("A", ctrl_id, _default_a_matrix(env, bias))
	env.register_external_matrix("B", ctrl_id, _default_b_matrix(env, bias + 1))
	if include_c:
		env.register_external_matrix("C", ctrl_id, repeating_matrix(env.x_dim, [1, 3, 5, 7, 9, 11, 13, 15][: env.y_dim], env.data_width))


async def _run_qcfg_id_mismatch(env, ctrl_id: int, granularity: int) -> None:
	payload_count = qcfg_payload_count(granularity, env.x_dim, env.y_dim)
	assert payload_count is not None and payload_count > 1
	await env.send_ctrl(build_qcfg_header(granularity, qtype=PT_QTYPE_SYMMETRIC), ctrl_id)
	await env.expect_no_ctrl_resp(2)
	await env.send_ctrl(0x0001_0000, ctrl_id)
	await env.expect_no_ctrl_resp(2)
	await env.send_ctrl(0x0001_0000, ctrl_id + 1)
	await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 500)


async def run_protocol_case(dut, case: ScenarioCase) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		ctrl_id = _ctrl_id(0x4000, case)
		kind = case.data["kind"]
		params = case.data.get("params", {})

		if kind == "invalid_scale":
			plan = env.plan_matmul(ctrl_id, m_scale=params["m_scale"], n_scale=params["n_scale"], k_scale=params["k_scale"])
			assert plan.err
			await env.send_ctrl(build_matmul_inst(params["m_scale"], params["n_scale"], params["k_scale"]), ctrl_id)
			await env.wait_ctrl_resp(plan.response_word, 500)
			return

		if kind == "bad_align":
			plan = env.plan_matmul(
				ctrl_id,
				m_scale=PT_SCALE_FULL,
				n_scale=PT_SCALE_FULL,
				k_scale=PT_SCALE_FULL,
				reserved_a=params["a_off"],
				reserved_b=params["b_off"],
			)
			assert plan.err
			await env.send_ctrl(
				build_matmul_inst(
					PT_SCALE_FULL,
					PT_SCALE_FULL,
					PT_SCALE_FULL,
					reserved_a=params["a_off"],
					reserved_b=params["b_off"],
				),
				ctrl_id,
			)
			await env.wait_ctrl_resp(plan.response_word, 500)
			return

		if kind == "bad_qtype":
			await env.send_ctrl(build_qcfg_header(PT_QGRAN_PER_TENSOR, qtype=params["qtype"]), ctrl_id)
			await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 500)
			return

		if kind == "qcfg_id_mismatch_x":
			await _run_qcfg_id_mismatch(env, ctrl_id, PT_QGRAN_X_WISE)
			return

		if kind == "qcfg_id_mismatch_y":
			await _run_qcfg_id_mismatch(env, ctrl_id, PT_QGRAN_Y_WISE)
			return

		if kind in {"wrong_tuser_a", "wrong_tuser_b", "dma_error_before_a", "dma_error_before_b"}:
			await _register_protocol_matrices(env, ctrl_id, bias=1)
			if kind == "wrong_tuser_a":
				env.queue_ab_injection(AbInjection(wrong_tuser=True))
			elif kind == "wrong_tuser_b":
				env.queue_ab_injection(AbInjection())
				env.queue_ab_injection(AbInjection(wrong_tuser=True))
			elif kind == "dma_error_before_a":
				env.queue_ab_injection(AbInjection(error_mode="before_stream", done_delay=int(params["delay"])))
			else:
				env.queue_ab_injection(AbInjection())
				env.queue_ab_injection(AbInjection(error_mode="before_stream", done_delay=int(params["delay"])))
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
			await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 4000)
			if _is_dma_top():
				await env.soft_clear()
			return

		if kind == "export_error":
			await _register_protocol_matrices(env, ctrl_id, bias=3)
			env.queue_export_injection(ExportInjection(error=True, done_delay=int(params["delay"])))
			plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
			assert not plan.err
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
			await env.wait_ctrl_resp(plan.response_word, 4000)
			await env.wait_export_error(1, 4000)
			await env.wait_ctrl_resp(pack_resp(True, plan.success_buffer or 0, ctrl_id), 4000)
			return

		if kind == "matadd_invalid":
			plan = env.plan_matadd(
				ctrl_id,
				params["m_off"],
				c_field=params["c_off"],
				reserved_hi=params.get("reserved_hi", 0),
				reserved_lo=params.get("reserved_lo", 0),
			)
			assert plan.err
			await env.send_ctrl(
				build_matadd_inst(
					params["m_off"],
					c_field=params["c_off"],
					reserved_hi=params.get("reserved_hi", 0),
					reserved_lo=params.get("reserved_lo", 0),
				),
				ctrl_id,
			)
			await env.wait_ctrl_resp(plan.response_word, 500)
			return

		raise AssertionError(f"unsupported protocol case kind: {kind}")
	finally:
		env.shutdown()


async def run_protocol_edge_case(dut, case: ScenarioCase) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		ctrl_id = _ctrl_id(0x5000, case)
		kind = case.data["kind"]
		params = case.data.get("params", {})

		if kind == "unknown_opcode":
			await env.send_ctrl(params["inst"], ctrl_id)
			await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 500)
			return

		if kind == "qcfg_invalid_granularity":
			await env.send_ctrl(build_qcfg_header(params["granularity"], qtype=PT_QTYPE_SYMMETRIC), ctrl_id)
			await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 500)
			return

		if kind in {"dma_error_mid_a", "dma_error_mid_b", "dma_error_after_a", "dma_error_after_b"}:
			await _register_protocol_matrices(env, ctrl_id, bias=5)
			if kind == "dma_error_mid_a":
				env.queue_ab_injection(
					AbInjection(error_mode="mid_stream", error_at_beat=int(params["error_at_beat"]), done_delay=int(params["delay"]))
				)
			elif kind == "dma_error_mid_b":
				env.queue_ab_injection(AbInjection())
				env.queue_ab_injection(
					AbInjection(error_mode="mid_stream", error_at_beat=int(params["error_at_beat"]), done_delay=int(params["delay"]))
				)
			elif kind == "dma_error_after_a":
				env.queue_ab_injection(AbInjection(error_mode="after_stream", done_delay=int(params["delay"])))
			else:
				env.queue_ab_injection(AbInjection())
				env.queue_ab_injection(AbInjection(error_mode="after_stream", done_delay=int(params["delay"])))
			plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
			assert not plan.err
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
			if kind.startswith("dma_error_mid"):
				await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 4000)
			else:
				snapshot = env.snapshot()
				await env.wait_ctrl_resp(plan.response_word, 4000)
				await env.wait_export_done(snapshot.export_done_count + 1, 12000)
			return

		if kind == "single_side_hit_mix":
			await _register_protocol_matrices(env, ctrl_id, bias=7)
			a_size = env.x_dim * env.x_dim
			b_size = env.y_dim * env.y_dim
			load = env.plan_load(ctrl_id, a_size, b_size, need_a=True, need_b=False)
			assert not load.err
			assert [req.kind for req in load.expected_dma_loads] == ["A"]
			await env.send_ctrl(build_load_inst(a_size, b_size, need_a=True, need_b=False), ctrl_id)
			await env.wait_ctrl_resp(load.response_word, 4000)
			matmul = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
			assert not matmul.err
			assert [req.kind for req in matmul.expected_dma_loads] == ["B"]
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
			await env.wait_ctrl_resp(matmul.response_word, 4000)
			await env.wait_export_done(1, 12000)
			return

		if kind == "single_side_mwindow_mix":
			await _register_protocol_matrices(env, ctrl_id, include_c=True, bias=9)
			_, resp = await _run_matmul_once(env, ctrl_id)
			m_off = build_mwin_off((resp >> 30) & 0x1, 0)
			matadd = env.plan_matadd(ctrl_id, m_off)
			assert not matadd.err
			assert [req.kind for req in matadd.expected_dma_loads] == ["C"]
			snapshot = env.snapshot()
			await env.send_ctrl(build_matadd_inst(m_off), ctrl_id)
			await env.wait_ctrl_resp(matadd.response_word, 4000)
			await env.wait_export_done(snapshot.export_done_count + 1, 12000)
			return

		if kind == "bslot_overwritten_by_c_then_b_reloads":
			await _register_protocol_matrices(env, ctrl_id, include_c=True, bias=11)
			load = env.plan_load(ctrl_id, env.x_dim * env.x_dim, env.y_dim * env.y_dim, need_a=True, need_b=True)
			assert not load.err
			await env.send_ctrl(build_load_inst(env.x_dim * env.x_dim, env.y_dim * env.y_dim, need_a=True, need_b=True), ctrl_id)
			await env.wait_ctrl_resp(load.response_word, 4000)
			matmul = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
			assert not matmul.err
			assert len(matmul.expected_dma_loads) == 0
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
			resp = await env.wait_ctrl_resp(matmul.response_word, 4000)
			await env.wait_export_done(1, 12000)
			m_off = build_mwin_off((resp >> 30) & 0x1, 0)
			matadd = env.plan_matadd(ctrl_id, m_off)
			assert not matadd.err
			assert [req.kind for req in matadd.expected_dma_loads] == ["C"]
			snapshot = env.snapshot()
			await env.send_ctrl(build_matadd_inst(m_off), ctrl_id)
			await env.wait_ctrl_resp(matadd.response_word, 4000)
			await env.wait_export_done(snapshot.export_done_count + 1, 12000)
			reload = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
			assert not reload.err
			assert [req.kind for req in reload.expected_dma_loads] == ["B"]
			snapshot = env.snapshot()
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
			await env.wait_ctrl_resp(reload.response_word, 4000)
			await env.wait_export_done(snapshot.export_done_count + 1, 12000)
			return

		raise AssertionError(f"unsupported protocol-edge case kind: {kind}")
	finally:
		env.shutdown()


async def run_state_case(dut, case: ScenarioCase) -> None:
	env = await create_env(dut)
	try:
		ctrl_id = _ctrl_id(0x6000, case)
		kind = case.data["kind"]
		params = case.data.get("params", {})

		if kind == "clear_idle_recovery":
			await setup_bases_and_passthrough_qcfg(env)
			await _register_protocol_matrices(env, ctrl_id, bias=13)
			first = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
			assert not first.err
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
			await env.wait_ctrl_resp(first.response_word, 4000)
			await env.wait_export_done(1, 12000)

			hit = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
			assert not hit.err
			assert len(hit.expected_dma_loads) == 0
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
			await env.wait_ctrl_resp(hit.response_word, 4000)
			await env.wait_export_done(2, 12000)

			await env.pulse_clear()
			assert env.read_csr_bases() == (0, 0)
			reload = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
			assert not reload.err
			assert [req.kind for req in reload.expected_dma_loads] == ["A", "B"]
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
			await env.wait_ctrl_resp(reload.response_word, 4000)
			await env.wait_export_done(3, 12000)
			return

		if kind == "clear_mid_export_recovery":
			env.configure_patterns(m_axis_ready=ConstantPattern(0))
			await setup_bases_and_passthrough_qcfg(env)
			await _register_protocol_matrices(env, ctrl_id, bias=15)
			plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
			assert not plan.err
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), ctrl_id)
			await env.wait_ctrl_resp(plan.response_word, 4000)
			await env.wait_export_req(1, 12000)
			await env.pulse_clear()
			await env.expect_no_ctrl_resp(8)
			env.configure_patterns(m_axis_ready=ConstantPattern(1))

			recovery_id = ctrl_id + 0x10
			await setup_bases_and_passthrough_qcfg(env)
			await _register_protocol_matrices(env, recovery_id, bias=17)
			snapshot = env.snapshot()
			recovery = env.plan_matmul(recovery_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
			assert not recovery.err
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL), recovery_id)
			await env.wait_ctrl_resp(recovery.response_word, 4000)
			await env.wait_export_done(snapshot.export_done_count + 1, 12000)
			return

		if kind == "cfg_base_hi":
			await setup_bases_and_passthrough_qcfg(env)
			await env.cfg_base32(params["kind"], params["value"], ctrl_id - 2)
			actual_a, actual_b = env.read_csr_bases()
			if params["kind"] == "A":
				assert actual_a == params["value"]
			else:
				assert actual_b == params["value"]
			await _register_protocol_matrices(env, ctrl_id, bias=19)
			await _run_matmul_once(env, ctrl_id)
			return

		raise AssertionError(f"unsupported state case kind: {kind}")
	finally:
		env.shutdown()
