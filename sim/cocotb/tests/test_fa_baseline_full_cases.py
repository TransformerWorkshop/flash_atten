from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles

from tests.fa_baseline_env import ADDR_STATUS, HEAD_DIM, SEQ_LEN, attention_golden, create_env, matrix_error, random_q88_matrix


@cocotb.test()
async def test_fa_baseline_full_causal_end_to_end(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q = random_q88_matrix(SEQ_LEN, HEAD_DIM, 401, amplitude=48)
        k = random_q88_matrix(SEQ_LEN, HEAD_DIM, 402, amplitude=48)
        v = random_q88_matrix(SEQ_LEN, HEAD_DIM, 403, amplitude=48)
        env.load_qkv(q, k, v)
        await env.start_run(causal=True)
        await env.wait_done()
        actual = env.read_output_matrix()
        expected = attention_golden(q, k, v, scale=0.125, causal=True)
        mean_err, max_err = matrix_error(actual, expected)
        assert mean_err <= 0.03, f"mean_err={mean_err}"
        assert max_err <= 0.10, f"max_err={max_err}"
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_full_noncausal_and_soft_reset(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        await env.program_common_regs(causal=False)
        await env.soft_reset()
        status = await env.axil_read(ADDR_STATUS)
        assert (status & 0x7) == 0

        q = random_q88_matrix(SEQ_LEN, HEAD_DIM, 501, amplitude=40)
        k = random_q88_matrix(SEQ_LEN, HEAD_DIM, 502, amplitude=40)
        v = random_q88_matrix(SEQ_LEN, HEAD_DIM, 503, amplitude=40)
        env.load_qkv(q, k, v)

        await env.start_run(causal=False)
        await env.wait_busy(True)
        await ClockCycles(dut.clk, 64)
        await env.soft_reset()
        await env.wait_busy(False)
        status = await env.axil_read(ADDR_STATUS)
        assert (status & 0x7) == 0

        await env.start_run(causal=False)
        await env.wait_done()
        actual = env.read_output_matrix()
        expected = attention_golden(q, k, v, scale=0.125, causal=False)
        mean_err, max_err = matrix_error(actual, expected)
        assert mean_err <= 0.03, f"mean_err={mean_err}"
        assert max_err <= 0.10, f"max_err={max_err}"
    finally:
        env.shutdown()
