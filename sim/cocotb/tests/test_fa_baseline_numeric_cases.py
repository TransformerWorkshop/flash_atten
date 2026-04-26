from __future__ import annotations

import cocotb

from tests.fa_baseline_case_utils import assert_matrix_close, make_single_q_full_kv_case, make_single_tile_case
from tests.fa_baseline_env import attention_golden_rows, create_env


@cocotb.test()
async def test_fa_numeric_single_q_single_kv_noncausal(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q, k, v = make_single_tile_case(1000)
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        await env.wait_done()
        actual = env.read_output_matrix()
        expected = attention_golden_rows(q, k, v, scale=0.125, causal=False, q_start=0, q_rows=16)
        assert_matrix_close(actual[:16], expected)
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_numeric_single_q_full_kv_causal(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q_row_start = 0
        q, k, v = make_single_q_full_kv_case(1010)
        env.load_qkv(q, k, v)
        await env.start_run(causal=True)
        await env.wait_done()
        actual = env.read_output_matrix()
        expected = attention_golden_rows(q, k, v, scale=0.125, causal=True, q_start=q_row_start, q_rows=16)
        assert_matrix_close(actual[q_row_start : q_row_start + 16], expected)
    finally:
        env.shutdown()
