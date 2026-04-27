from __future__ import annotations

import cocotb

from tests.fa_baseline_case_utils import assert_matrix_close
from tests.fa_baseline_axi_env import SequencePattern, create_env
from tests.fa_baseline_env import HEAD_DIM, SEQ_LEN, STATUS_ERROR, attention_golden, random_q88_matrix


@cocotb.test()
async def test_fa_baseline_axi_full_causal_end_to_end(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q = random_q88_matrix(SEQ_LEN, HEAD_DIM, 761, amplitude=40)
        k = random_q88_matrix(SEQ_LEN, HEAD_DIM, 762, amplitude=40)
        v = random_q88_matrix(SEQ_LEN, HEAD_DIM, 763, amplitude=40)
        env.load_qkv(q, k, v)
        await env.start_run(causal=True)
        status = await env.wait_done()
        assert (status & STATUS_ERROR) == 0
        actual = env.read_output_matrix()
        expected = attention_golden(q, k, v, scale=(1.0 / (64 ** 0.5)), causal=True)
        assert_matrix_close(actual, expected)
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_axi_full_noncausal_end_to_end(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q = random_q88_matrix(SEQ_LEN, HEAD_DIM, 771, amplitude=40)
        k = random_q88_matrix(SEQ_LEN, HEAD_DIM, 772, amplitude=40)
        v = random_q88_matrix(SEQ_LEN, HEAD_DIM, 773, amplitude=40)
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        status = await env.wait_done()
        assert (status & STATUS_ERROR) == 0
        actual = env.read_output_matrix()
        expected = attention_golden(q, k, v, scale=(1.0 / (64 ** 0.5)), causal=False)
        assert_matrix_close(actual, expected)
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_axi_full_backpressure_numeric(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        env.set_axi_patterns(
            arready=SequencePattern([1, 0, 1, 1, 0, 1, 1]),
            rvalid=SequencePattern([1, 1, 0, 1, 0, 1, 1, 1]),
            awready=SequencePattern([1, 0, 1, 1, 1]),
            wready=SequencePattern([1, 0, 1, 1, 0, 1]),
            bvalid=SequencePattern([0, 1, 1, 1]),
        )
        q = random_q88_matrix(SEQ_LEN, HEAD_DIM, 781, amplitude=36)
        k = random_q88_matrix(SEQ_LEN, HEAD_DIM, 782, amplitude=36)
        v = random_q88_matrix(SEQ_LEN, HEAD_DIM, 783, amplitude=36)
        env.load_qkv(q, k, v)
        await env.start_run(causal=True)
        status = await env.wait_done()
        assert (status & STATUS_ERROR) == 0
        actual = env.read_output_matrix()
        expected = attention_golden(q, k, v, scale=(1.0 / (64 ** 0.5)), causal=True)
        assert_matrix_close(actual, expected)
    finally:
        env.shutdown()
