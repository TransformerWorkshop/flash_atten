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
    q88_from_float,
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


def unpack_q88_tile_words(words: list[int], rows: int, cols: int) -> list[list[int]]:
    out = [[0 for _ in range(cols)] for _ in range(rows)]
    word_idx = 0
    for row in range(rows):
        for col in range(0, cols, 2):
            word = int(words[word_idx]) & 0xFFFF_FFFF
            lo = word & 0xFFFF
            hi = (word >> 16) & 0xFFFF
            if lo & 0x8000:
                lo -= 0x10000
            if hi & 0x8000:
                hi -= 0x10000
            out[row][col] = lo
            out[row][col + 1] = hi
            word_idx += 1
    return out


def flat_words(signal_value: int, count: int) -> list[int]:
    return [(signal_value >> (idx * 32)) & 0xFFFF_FFFF for idx in range(count)]


async def wait_signal_high(dut, signal, timeout_cycles: int = 4000) -> None:
    for _ in range(timeout_cycles):
        if int(signal.value):
            return
        await ClockCycles(dut.clk, 1)
    raise AssertionError("signal did not go high before timeout")


def expected_v_pv_layout_words(v_matrix: list[list[float]]) -> list[int]:
    words = [0 for _ in range(32 * 16)]
    for row in range(16):
        k_pair = row >> 1
        hi_half = row & 0x1
        for col in range(64):
            blk = col // 16
            lane = col % 16
            addr = (blk * 8) + k_pair
            idx = (addr * 16) + lane
            raw = q88_from_float(v_matrix[row][col]) & 0xFFFF
            if hi_half:
                words[idx] = (words[idx] & 0x0000_FFFF) | (raw << 16)
            else:
                words[idx] = (words[idx] & 0xFFFF_0000) | raw
    return words


def expected_qk_tile_words(q_matrix: list[list[float]], k_matrix: list[list[float]]) -> list[int]:
    out: list[int] = []
    for row in range(16):
        for col in range(16):
            acc = 0
            for dim in range(64):
                acc += q88_from_float(q_matrix[row][dim]) * q88_from_float(k_matrix[col][dim])
            if acc > 0x7FFF_FFFF:
                acc = 0x7FFF_FFFF
            elif acc < -0x8000_0000:
                acc = -0x8000_0000
            out.append(acc & 0xFFFF_FFFF)
    return out


def expected_pv_tile_words(p_words: list[int], v_matrix: list[list[float]]) -> list[int]:
    p_raw = unpack_q88_tile_words(p_words, 16, 16)
    out_words = [0 for _ in range(16 * 32)]
    for row in range(16):
        for col in range(64):
            acc = 0
            for k_idx in range(16):
                acc += p_raw[row][k_idx] * q88_from_float(v_matrix[k_idx][col])
            if acc >= 0:
                rounded = acc + 128
            else:
                rounded = acc - 128
            shifted = rounded >> 8
            if shifted > 32767:
                shifted = 32767
            elif shifted < -32768:
                shifted = -32768
            word_idx = ((row * 64) + col) >> 1
            if col & 0x1:
                out_words[word_idx] = (out_words[word_idx] & 0x0000_FFFF) | ((shifted & 0xFFFF) << 16)
            else:
                out_words[word_idx] = (out_words[word_idx] & 0xFFFF_0000) | (shifted & 0xFFFF)
    return out_words


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
async def test_fa_baseline_vbuf_pv_layout(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q, k, v = make_single_tile_case(250)
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        for _ in range(1500):
            if len(env.rd_desc_log) >= 3 and env.rd_desc_log[2].tag == RD_TAG_V:
                break
            await ClockCycles(dut.clk, 1)
        for _ in range(700):
            await ClockCycles(dut.clk, 1)
        actual_words = flat_words(int(dut.u_v_buf_pv.layout_flat.value), 32 * 16)
        expected_words = expected_v_pv_layout_words(v[:16])
        assert actual_words == expected_words
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_qk_core_real_tile(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q, k, v = make_single_tile_case(260)
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        await wait_signal_high(dut, dut.u_qk_core.resp_valid, timeout_cycles=6000)
        actual_words = flat_words(int(dut.u_qk_core.result_tile_flat.value), 16 * 16)
        expected_words = expected_qk_tile_words(q[:16], k[:16])
        assert actual_words == expected_words
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_pv_core_real_tile(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q, k, v = make_single_tile_case(270)
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        await wait_signal_high(dut, dut.u_pv_core.resp_valid, timeout_cycles=12000)
        p_words = flat_words(int(dut.u_p_buf.tile_flat.value), 16 * 8)
        actual_words = flat_words(int(dut.u_pv_core.result_tile_flat.value), 16 * 32)
        expected_words = expected_pv_tile_words(p_words, v[:16])
        assert actual_words == expected_words
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
