from __future__ import annotations

import cocotb

from tests.fa_baseline_case_utils import assert_matrix_close
from tests.fa_baseline_env import HEAD_DIM, SEQ_LEN, attention_golden, create_env, random_q88_matrix


@cocotb.test()
async def test_fa_numeric_full_causal_end_to_end(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q = random_q88_matrix(SEQ_LEN, HEAD_DIM, 1021, amplitude=48)
        k = random_q88_matrix(SEQ_LEN, HEAD_DIM, 1022, amplitude=48)
        v = random_q88_matrix(SEQ_LEN, HEAD_DIM, 1023, amplitude=48)
        env.load_qkv(q, k, v)
        await env.start_run(causal=True)
        await env.wait_done()
        actual = env.read_output_matrix()
        expected = attention_golden(q, k, v, scale=0.125, causal=True)
        assert_matrix_close(actual, expected)
    finally:
        env.shutdown()
