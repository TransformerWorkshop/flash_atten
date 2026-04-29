from __future__ import annotations

import cocotb

from tests.fa_baseline_case_utils import assert_matrix_close, make_single_q_full_kv_case_at_row, make_single_tile_case
from tests.fa_baseline_env import HEAD_DIM, SEQ_LEN, attention_golden_rows, create_env, q88_to_float, zero_matrix


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
        for case_idx, q_row_start in enumerate((0, 112, 240)):
            await env.reset()
            q, k, v = make_single_q_full_kv_case_at_row(1010 + case_idx * 20, q_row_start)
            env.load_qkv(q, k, v)
            await env.start_run(causal=True)
            await env.wait_done()
            actual = env.read_output_matrix()
            expected = attention_golden_rows(q, k, v, scale=0.125, causal=True, q_start=q_row_start, q_rows=16)
            assert_matrix_close(actual[q_row_start : q_row_start + 16], expected)
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_numeric_valid_score_equals_neg_large_noncausal(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q = zero_matrix(SEQ_LEN, HEAD_DIM)
        k = zero_matrix(SEQ_LEN, HEAD_DIM)
        v = zero_matrix(SEQ_LEN, HEAD_DIM)

        q_raw = [1024, 255]
        k_raw = [(-32767) & 0xFFFF, (-4) & 0xFFFF]
        for row in range(16):
            q[row][0] = q88_to_float(q_raw[0])
            q[row][1] = q88_to_float(q_raw[1])
        for row in range(SEQ_LEN):
            k[row][0] = q88_to_float(k_raw[0])
            k[row][1] = q88_to_float(k_raw[1])
            for col in range(HEAD_DIM):
                v[row][col] = 0.5

        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        await env.wait_done()

        actual = env.read_output_matrix()
        expected = attention_golden_rows(q, k, v, scale=0.125, causal=False, q_start=0, q_rows=16)
        assert_matrix_close(actual[:16], expected)
    finally:
        env.shutdown()
