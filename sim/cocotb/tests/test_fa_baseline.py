from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles

from tests.fa_baseline_env import (
    ADDR_CFG,
    ADDR_CYCLES,
    ADDR_K_BASE_L,
    ADDR_NEG_LARGE,
    ADDR_Q_BASE_L,
    ADDR_SCALE,
    ADDR_STATUS,
    ADDR_STRIDE_BYTES,
    ADDR_V_BASE_L,
    CFG_CAUSAL_EN,
    HEAD_DIM,
    RD_TAG_K,
    RD_TAG_Q,
    RD_TAG_V,
    SEQ_LEN,
    SequencePattern,
    attention_golden,
    create_env,
    matrix_error,
    random_q88_matrix,
    zero_matrix,
)


def first_rows(matrix, rows: int):
    return matrix[:rows]


def make_single_tile_case(seed_base: int):
    q = zero_matrix(SEQ_LEN, HEAD_DIM)
    k = zero_matrix(SEQ_LEN, HEAD_DIM)
    v = zero_matrix(SEQ_LEN, HEAD_DIM)
    q_tile = random_q88_matrix(16, HEAD_DIM, seed_base + 1, amplitude=72)
    k_tile = random_q88_matrix(16, HEAD_DIM, seed_base + 2, amplitude=72)
    v_tile = random_q88_matrix(16, HEAD_DIM, seed_base + 3, amplitude=72)
    for row in range(16):
        q[row] = q_tile[row]
        k[row] = k_tile[row]
        v[row] = v_tile[row]
    return q, k, v


def make_single_q_full_kv_case(seed_base: int):
    q = zero_matrix(SEQ_LEN, HEAD_DIM)
    k = random_q88_matrix(SEQ_LEN, HEAD_DIM, seed_base + 11, amplitude=64)
    v = random_q88_matrix(SEQ_LEN, HEAD_DIM, seed_base + 12, amplitude=64)
    q_tile = random_q88_matrix(16, HEAD_DIM, seed_base + 10, amplitude=64)
    for row in range(16):
        q[row] = q_tile[row]
    return q, k, v


@cocotb.test()
async def test_fa_baseline_csr_and_framework_smoke(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()

        assert await env.axil_read(ADDR_STATUS) == 0
        assert await env.axil_read(ADDR_Q_BASE_L) == 0
        assert await env.axil_read(ADDR_K_BASE_L) == 0
        assert await env.axil_read(ADDR_V_BASE_L) == 0
        assert await env.axil_read(ADDR_STRIDE_BYTES) == 0
        assert await env.axil_read(ADDR_NEG_LARGE) == 0
        assert await env.axil_read(ADDR_SCALE) == 0

        q, k, v = make_single_tile_case(100)
        env.load_qkv(q, k, v)

        await env.program_common_regs(causal=True)
        assert await env.axil_read(ADDR_CFG) == CFG_CAUSAL_EN
        assert await env.axil_read(ADDR_Q_BASE_L) == (env.q_base & 0xFFFF_FFFF)
        assert await env.axil_read(ADDR_STRIDE_BYTES) == env.stride_bytes
        assert await env.axil_read(ADDR_NEG_LARGE) == (env.neg_large_word & 0xFFFF_FFFF)
        assert await env.axil_read(ADDR_SCALE) == (env.scale_word & 0xFFFF_FFFF)

        await env.start_run(causal=True)
        await env.wait_busy(True)
        for _ in range(600):
            if len(env.rd_desc_log) >= 2:
                break
            await ClockCycles(dut.clk, 1)
        assert len(env.rd_desc_log) >= 2
        assert env.rd_desc_log[0].tag == RD_TAG_Q
        assert env.rd_desc_log[1].tag == RD_TAG_K
        assert env.rd_desc_log[0].words == 512
        assert env.rd_desc_log[1].words == 512
        assert await env.axil_read(ADDR_CYCLES) > 0
        await env.soft_reset()
        await env.wait_busy(False)
        status = await env.axil_read(ADDR_STATUS)
        assert (status & 0x7) == 0

        assert len(dut.u_q_buf.tile_flat) == 16384
        assert len(dut.u_k_buf.tile_flat) == 16384
        assert len(dut.u_v_buf.tile_flat) == 16384
        assert len(dut.u_p_buf.tile_flat) == 4096
        assert len(dut.u_oacc_buf.tile_flat) == 16384
        assert len(dut.u_score_post.masked_score_tile_flat) == 8192
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_single_q_single_kv_noncausal(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q, k, v = make_single_tile_case(200)
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        await env.wait_done()
        actual = env.read_output_matrix()
        expected = attention_golden(q, k, v, scale=0.125, causal=False)
        mean_err, max_err = matrix_error(first_rows(actual, 16), first_rows(expected, 16))
        assert mean_err <= 0.03, f"mean_err={mean_err}"
        assert max_err <= 0.10, f"max_err={max_err}"
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_single_q_full_kv_causal_with_backpressure(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        env.set_read_patterns(
            desc_ready=SequencePattern([1, 0, 1, 1, 0, 1]),
            data_valid=SequencePattern([1, 1, 0, 1, 0, 1, 1]),
        )
        env.set_write_patterns(
            desc_ready=SequencePattern([1, 0, 1, 1]),
            data_ready=SequencePattern([1, 0, 1, 1, 0, 1]),
        )
        q, k, v = make_single_q_full_kv_case(300)
        env.load_qkv(q, k, v)
        await env.start_run(causal=True)
        await env.wait_done()
        actual = env.read_output_matrix()
        expected = attention_golden(q, k, v, scale=0.125, causal=True)
        mean_err, max_err = matrix_error(first_rows(actual, 16), first_rows(expected, 16))
        assert mean_err <= 0.03, f"mean_err={mean_err}"
        assert max_err <= 0.10, f"max_err={max_err}"
    finally:
        env.shutdown()


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
