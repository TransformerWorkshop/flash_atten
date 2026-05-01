from __future__ import annotations

import sys
from pathlib import Path

import cocotb

for parent in Path(__file__).resolve().parents:
    if (parent / "scripts" / "fa_extreme_precision_analysis.py").exists():
        sys.path.insert(0, str(parent))
        break

from scripts.fa_extreme_precision_analysis import (
    analyze_extreme_case,
    deterministic_case_by_name,
    rtl_like_output_for_case,
)
from tests.fa_baseline_axi_env import create_env
from tests.fa_baseline_env import matrix_error


@cocotb.test()
async def test_fa_extreme_precision_qk_saturation_culprit(dut) -> None:
    case = deterministic_case_by_name("qk_saturation_tie_flip")
    report = analyze_extreme_case(case)
    assert report.worst_stage_by_max == "qk_saturation_scale"
    assert report.qk_saturation_scale.max_abs > 100.0
    assert report.total_vs_quantized_golden.max_abs > 100.0

    env = await create_env(dut)
    try:
        await env.reset()
        env.load_qkv(case.q_matrix, case.k_matrix, case.v_matrix)
        await env.start_run(causal=case.causal)
        await env.wait_done()
        actual = env.read_output_matrix()[case.q_row_start : case.q_row_start + 16]
        expected = rtl_like_output_for_case(case)
        mean_err, max_err = matrix_error(actual, expected)
        assert mean_err <= 1.0 / 256.0, f"mean_err={mean_err}"
        assert max_err <= 1.0 / 256.0, f"max_err={max_err}"
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_extreme_precision_oacc_range_culprit(dut) -> None:
    case = deterministic_case_by_name("causal_first_token_vmax")
    report = analyze_extreme_case(case)
    assert report.worst_stage_by_max == "oacc_quantization"
    assert report.oacc_quantization.max_abs > 100.0
    assert report.total_vs_quantized_golden.max_abs > 100.0

    env = await create_env(dut)
    try:
        await env.reset()
        env.load_qkv(case.q_matrix, case.k_matrix, case.v_matrix)
        await env.start_run(causal=case.causal)
        await env.wait_done()
        actual = env.read_output_matrix()[case.q_row_start : case.q_row_start + 16]
        expected = rtl_like_output_for_case(case)
        mean_err, max_err = matrix_error(actual, expected)
        assert mean_err <= 1.0 / 256.0, f"mean_err={mean_err}"
        assert max_err <= 1.0 / 256.0, f"max_err={max_err}"
    finally:
        env.shutdown()
