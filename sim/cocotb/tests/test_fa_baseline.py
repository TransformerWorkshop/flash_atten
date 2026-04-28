from __future__ import annotations

import math

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
    attention_golden_rows,
    create_env,
    matrix_error,
    pack_q88_row_major_words,
    q88_from_float,
    random_q88_matrix,
    zero_matrix,
)


def first_rows(matrix, rows: int):
    return matrix[:rows]


def core(dut):
    return dut.u_core


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
    return make_single_q_full_kv_case_at_row(seed_base, 0)


def make_single_q_full_kv_case_at_row(seed_base: int, q_row_start: int):
    if q_row_start < 0 or q_row_start + 16 > SEQ_LEN:
        raise ValueError(f"expected 0 <= q_row_start <= {SEQ_LEN - 16}, got {q_row_start}")
    q = zero_matrix(SEQ_LEN, HEAD_DIM)
    k = random_q88_matrix(SEQ_LEN, HEAD_DIM, seed_base + 11, amplitude=64)
    v = random_q88_matrix(SEQ_LEN, HEAD_DIM, seed_base + 12, amplitude=64)
    q_tile = random_q88_matrix(16, HEAD_DIM, seed_base + 10, amplitude=64)
    for row in range(16):
        q[q_row_start + row] = q_tile[row]
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


def pack_words_to_int(words: list[int]) -> int:
    value = 0
    for idx, word in enumerate(words):
        value |= (int(word) & 0xFFFF_FFFF) << (idx * 32)
    return value


def s32(raw: int) -> int:
    raw &= 0xFFFF_FFFF
    if raw & 0x8000_0000:
        raw -= 0x1_0000_0000
    return raw


def q16_mul_rn_sat_py(lhs: int, rhs: int) -> int:
    prod = s32(lhs) * s32(rhs)
    if prod >= 0:
        rounded = prod + 32768
    else:
        rounded = prod - 32768
    shifted = rounded >> 16
    if shifted > 0x7FFF_FFFF:
        shifted = 0x7FFF_FFFF
    elif shifted < -0x8000_0000:
        shifted = -0x8000_0000
    return shifted & 0xFFFF_FFFF


def q16_add_sat_py(lhs: int, rhs: int) -> int:
    value = s32(lhs) + s32(rhs)
    if value > 0x7FFF_FFFF:
        value = 0x7FFF_FFFF
    elif value < -0x8000_0000:
        value = -0x8000_0000
    return value & 0xFFFF_FFFF


def q16_to_q88_rn_sat_py(value: int) -> int:
    value_s = s32(value)
    if value_s >= 0:
        rounded = value_s + 128
    else:
        rounded = value_s - 128
    shifted = rounded >> 8
    if shifted > 32767:
        shifted = 32767
    elif shifted < -32768:
        shifted = -32768
    return shifted & 0xFFFF


def q88_raw_to_q16_word(raw: int) -> int:
    raw &= 0xFFFF
    if raw & 0x8000:
        raw -= 0x10000
    return (raw << 8) & 0xFFFF_FFFF


def s16(raw: int) -> int:
    raw &= 0xFFFF
    if raw & 0x8000:
        raw -= 0x10000
    return raw


def q88_raw_to_float(raw: int) -> float:
    return s16(raw) / 256.0


def packed_q88_words_to_floats(words: list[int]) -> list[float]:
    values: list[float] = []
    for word in words:
        values.append(q88_raw_to_float(word & 0xFFFF))
        values.append(q88_raw_to_float((word >> 16) & 0xFFFF))
    return values


def q16_to_q412_rn_sat_py(value: int) -> int:
    value_s = s32(value)
    if value_s >= 0:
        rounded = value_s + 8
    else:
        rounded = value_s - 8
    shifted = rounded >> 4
    if shifted > 32767:
        shifted = 32767
    elif shifted < -32768:
        shifted = -32768
    return shifted & 0xFFFF


def q88_raw_to_q412_word(raw: int) -> int:
    value = s16(raw) << 4
    if value > 32767:
        value = 32767
    elif value < -32768:
        value = -32768
    return value & 0xFFFF


def q412_raw_to_q16_word(raw: int) -> int:
    return (s16(raw) << 4) & 0xFFFF_FFFF


def q412_to_q88_rn_sat_py(raw: int) -> int:
    value = s16(raw)
    if value >= 0:
        rounded = value + 8
    else:
        rounded = value - 8
    shifted = rounded >> 4
    if shifted > 32767:
        shifted = 32767
    elif shifted < -32768:
        shifted = -32768
    return shifted & 0xFFFF


def q16_clamp_nonpos_neg8_py(value: int) -> int:
    value_s = s32(value)
    if value_s > 0:
        value_s = 0
    if value_s < -524288:
        value_s = -524288
    return value_s & 0xFFFF_FFFF


def q16_exp_lut_from_delta_py(delta: int) -> int:
    clamped = q16_clamp_nonpos_neg8_py(delta)
    idx = ((-s32(clamped)) + 1024) >> 11
    if idx < 0:
        idx = 0
    if idx > 256:
        idx = 256
    return int(round(math.exp(-idx / 32.0) * (1 << 16))) & 0xFFFF_FFFF


def q16_recip_floor_py(value: int) -> int:
    value_u = value & 0xFFFF_FFFF
    if (value_u == 0) or (value_u & 0x8000_0000):
        return 0
    quot = (1 << 32) // value_u
    if quot > 0x7FFF_FFFF:
        quot = 0x7FFF_FFFF
    return quot & 0xFFFF_FFFF


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


def expected_score_post_words(score_words: list[int], q_blk: int, kv_blk: int, *, causal: bool, scale_word: int, neg_large_word: int) -> list[int]:
    out = [0 for _ in range(16 * 16)]
    for row in range(16):
        global_q = (q_blk * 16) + row
        for col in range(16):
            global_k = (kv_blk * 16) + col
            idx = (row * 16) + col
            if causal and (global_k > global_q):
                out[idx] = neg_large_word & 0xFFFF_FFFF
            else:
                out[idx] = q16_mul_rn_sat_py(score_words[idx], scale_word)
    return out


def expected_row_state_update(
    masked_words: list[int],
    *,
    neg_large_word: int,
    m_state: list[int],
    l_state: list[int],
    row_seen: list[int],
) -> tuple[list[int], list[int], list[int], list[int], list[int]]:
    p_words = [0 for _ in range(16 * 8)]
    rescale_words = [0 for _ in range(16)]
    next_m = list(m_state)
    next_l = list(l_state)
    next_seen = list(row_seen)

    for row in range(16):
        row_scores = [masked_words[(row * 16) + col] for col in range(16)]
        valid_cols = [col for col in range(16) if (row_scores[col] & 0xFFFF_FFFF) != (neg_large_word & 0xFFFF_FFFF)]
        has_history = bool(row_seen[row])
        if not valid_cols:
            rescale_words[row] = 0x0001_0000 if has_history else 0
            for col in range(16):
                word_idx = ((row * 16) + col) >> 1
                if col & 1:
                    p_words[word_idx] = p_words[word_idx] | 0
                else:
                    p_words[word_idx] = p_words[word_idx] & 0xFFFF_0000
            if not has_history:
                next_m[row] = neg_large_word & 0xFFFF_FFFF
                next_l[row] = 0
                next_seen[row] = 0
            continue

        tile_row_max = row_scores[valid_cols[0]]
        for col in valid_cols[1:]:
            if s32(row_scores[col]) > s32(tile_row_max):
                tile_row_max = row_scores[col]

        if has_history:
            m_new = m_state[row] if s32(m_state[row]) > s32(tile_row_max) else tile_row_max
            alpha = q16_exp_lut_from_delta_py((m_state[row] - m_new) & 0xFFFF_FFFF)
            alpha_l_old = q16_mul_rn_sat_py(alpha, l_state[row])
        else:
            m_new = tile_row_max
            alpha = 0
            alpha_l_old = 0

        beta_words = [0 for _ in range(16)]
        sum_beta = 0
        for col in range(16):
            if col in valid_cols:
                beta_words[col] = q16_exp_lut_from_delta_py((row_scores[col] - m_new) & 0xFFFF_FFFF)
            else:
                beta_words[col] = 0
            sum_beta = q16_add_sat_py(sum_beta, beta_words[col])

        l_new = q16_add_sat_py(alpha_l_old, sum_beta)
        recip = q16_recip_floor_py(l_new)
        rescale_words[row] = q16_mul_rn_sat_py(alpha_l_old, recip)

        for col in range(16):
            p_q16 = q16_mul_rn_sat_py(beta_words[col], recip)
            p_q88 = q16_to_q88_rn_sat_py(p_q16)
            word_idx = ((row * 16) + col) >> 1
            if col & 1:
                p_words[word_idx] = (p_words[word_idx] & 0x0000_FFFF) | ((p_q88 & 0xFFFF) << 16)
            else:
                p_words[word_idx] = (p_words[word_idx] & 0xFFFF_0000) | (p_q88 & 0xFFFF)

        next_m[row] = m_new & 0xFFFF_FFFF
        next_l[row] = l_new & 0xFFFF_FFFF
        next_seen[row] = 1

    return p_words, rescale_words, next_m, next_l, next_seen


def expected_oacc_update_words(old_words: list[int], rescale_words: list[int], partial_words: list[int]) -> list[int]:
    old_q412_words = q412_oacc_words_from_q88_words(old_words)
    next_q412_words = expected_oacc_update_q412_words(old_q412_words, rescale_words, partial_words)
    return q412_oacc_words_to_q88_words(next_q412_words)


def q412_oacc_words_from_q88_words(words: list[int], rows: int = 16) -> list[int]:
    out_words = [0 for _ in range(rows * 64)]
    for row in range(rows):
        for col in range(64):
            word_idx = ((row * 64) + col) >> 1
            word = words[word_idx]
            if col & 1:
                raw = (word >> 16) & 0xFFFF
            else:
                raw = word & 0xFFFF
            out_words[(row * 64) + col] = q88_raw_to_q412_word(raw)
    return out_words


def q412_oacc_words_to_q88_words(q412_words: list[int], rows: int = 16) -> list[int]:
    out_words = [0 for _ in range(rows * 32)]
    for row in range(rows):
        for col in range(64):
            raw = q412_to_q88_rn_sat_py(q412_words[(row * 64) + col])
            word_idx = ((row * 64) + col) >> 1
            if col & 1:
                out_words[word_idx] = (out_words[word_idx] & 0x0000_FFFF) | ((raw & 0xFFFF) << 16)
            else:
                out_words[word_idx] = (out_words[word_idx] & 0xFFFF_0000) | (raw & 0xFFFF)
    return out_words


def expected_oacc_update_q412_words(old_q412_words: list[int], rescale_words: list[int], partial_words: list[int]) -> list[int]:
    out_words = [0 for _ in range(16 * 64)]
    for row in range(16):
        scale_raw = rescale_words[row]
        for col in range(64):
            word_idx = ((row * 64) + col) >> 1
            part_word = partial_words[word_idx]
            if col & 1:
                part_raw = (part_word >> 16) & 0xFFFF
            else:
                part_raw = part_word & 0xFFFF
            old_q16 = q412_raw_to_q16_word(old_q412_words[(row * 64) + col])
            scaled_old_q16 = q16_mul_rn_sat_py(old_q16, scale_raw)
            next_q16 = q16_add_sat_py(scaled_old_q16, q88_raw_to_q16_word(part_raw))
            out_words[(row * 64) + col] = q16_to_q412_rn_sat_py(next_q16)
    return out_words


q16_oacc_words_from_q88_words = q412_oacc_words_from_q88_words
q16_oacc_words_to_q88_words = q412_oacc_words_to_q88_words
expected_oacc_update_q16_words = expected_oacc_update_q412_words


def pack_row_words_to_int(words: list[int], word_bits: int = 16) -> int:
    value = 0
    mask = (1 << word_bits) - 1
    for idx, word in enumerate(words):
        value |= (int(word) & mask) << (idx * word_bits)
    return value


def oacc_update_debug_snapshot(dut) -> str:
    inst = core(dut).u_oacc_update
    buf = core(dut).u_oacc_buf
    tile_words = flat_words(int(buf.tile_flat.value), 16 * 32)
    return (
        f"state={int(inst.state_r.value)} row_idx={int(inst.row_idx_r.value)} "
        f"req_ready={int(inst.req_ready.value)} resp_valid={int(inst.resp_valid.value)} "
        f"done_pulse={int(inst.done_pulse.value)} row_rd_en={int(inst.oacc_row_rd_en.value)} "
        f"row_rd_valid={int(buf.row_rd_valid.value)} row_wr_en={int(inst.oacc_row_wr_en.value)} "
        f"tile0=0x{tile_words[0]:08x} tile1=0x{tile_words[1]:08x}"
    )


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

        assert len(core(dut).u_q_buf.tile_flat) == 16384
        assert len(core(dut).u_k_buf.tile_flat) == 16384
        assert len(core(dut).u_v_buf.tile_flat) == 16384
        assert len(core(dut).p_tile_flat) == 4096
        assert len(core(dut).u_oacc_buf.tile_flat) == 16384
        assert len(core(dut).u_score_post.masked_score_tile_flat) == 8192
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
        expected = attention_golden_rows(q, k, v, scale=0.125, causal=False, q_start=0, q_rows=16)
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
        saw_v_desc = False
        for _ in range(3000):
            if len(env.rd_desc_log) >= 3 and env.rd_desc_log[2].tag == RD_TAG_V:
                saw_v_desc = True
                break
            await ClockCycles(dut.clk, 1)
        assert saw_v_desc

        expected_words = expected_v_pv_layout_words(v[:16])
        actual_words = []
        for _ in range(2000):
            await ClockCycles(dut.clk, 1)
            actual_words = flat_words(int(core(dut).u_v_buf_pv.layout_flat.value), 32 * 16)
            if actual_words == expected_words:
                break
        assert actual_words == expected_words, next(
            (
                f"first mismatch idx={idx} exp=0x{exp:08x} got=0x{act:08x}"
                for idx, (act, exp) in enumerate(zip(actual_words, expected_words))
                if act != exp
            ),
            "layout length mismatch",
        )
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_qk_buf_banked_write_and_read_decode(dut) -> None:
    env = await create_env(dut)
    beat_local_addr = 2
    target_row = 3
    try:
        await env.reset()

        q = zero_matrix(SEQ_LEN, HEAD_DIM)
        k = zero_matrix(SEQ_LEN, HEAD_DIM)
        v = zero_matrix(SEQ_LEN, HEAD_DIM)
        base_col = beat_local_addr * 8
        q[target_row][base_col : base_col + 8] = [1.0, -2.0, 3.25, -4.5, 5.0, -6.0, 7.5, -8.25]
        k[target_row][base_col : base_col + 8] = [-1.5, 2.5, -3.0, 4.0, -5.25, 6.5, -7.0, 8.0]
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)

        base_word_idx = (target_row * 32) + (beat_local_addr * 4)
        q_words = pack_q88_row_major_words(q[:16])[base_word_idx : base_word_idx + 4]
        k_words = pack_q88_row_major_words(k[:16])[base_word_idx : base_word_idx + 4]
        for _ in range(3000):
            await ClockCycles(dut.clk, 1)
            q_tile_words = flat_words(int(core(dut).u_q_buf.tile_flat.value), 16 * 32)
            k_tile_words = flat_words(int(core(dut).u_k_buf.tile_flat.value), 16 * 32)
            if (
                q_tile_words[base_word_idx : base_word_idx + 4] == q_words
                and k_tile_words[base_word_idx : base_word_idx + 4] == k_words
            ):
                break
        else:
            assert q_tile_words[base_word_idx : base_word_idx + 4] == q_words
            assert k_tile_words[base_word_idx : base_word_idx + 4] == k_words
        # The real Q/K SRAM read handshake is covered by test_fa_baseline_qk_core_real_tile.

    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_v_buf_banked_write_mapping(dut) -> None:
    env = await create_env(dut)
    v_words = [0x0102_0304, 0x1112_1314, 0x2122_2324, 0x3132_3334]
    target_row = 5
    beat_local_addr = 4
    try:
        await env.reset()

        q = zero_matrix(SEQ_LEN, HEAD_DIM)
        k = zero_matrix(SEQ_LEN, HEAD_DIM)
        v = zero_matrix(SEQ_LEN, HEAD_DIM)
        base_col = beat_local_addr * 8
        v[target_row][base_col : base_col + 8] = packed_q88_words_to_floats(v_words)
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)

        base_word_idx = (target_row * 32) + (beat_local_addr * 4)
        for _ in range(3000):
            await ClockCycles(dut.clk, 1)
            v_tile_words = flat_words(int(core(dut).u_v_buf.tile_flat.value), 16 * 32)
            if v_tile_words[base_word_idx : base_word_idx + 4] == v_words:
                break
        else:
            v_tile_words = flat_words(int(core(dut).u_v_buf.tile_flat.value), 16 * 32)
        assert v_tile_words[base_word_idx : base_word_idx + 4] == v_words
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_vbuf_pv_source_beat_layout_mapping(dut) -> None:
    env = await create_env(dut)
    src_words = [0x1001_1000, 0x1003_1002, 0x1005_1004, 0x1007_1006]
    try:
        await env.reset()

        q = zero_matrix(SEQ_LEN, HEAD_DIM)
        k = zero_matrix(SEQ_LEN, HEAD_DIM)
        v = zero_matrix(SEQ_LEN, HEAD_DIM)
        v[0][0:8] = packed_q88_words_to_floats(src_words)
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)

        expected_words = [0 for _ in range(32 * 16)]
        expected_words[0] = 0x0000_1000
        expected_words[1] = 0x0000_1001
        expected_words[2] = 0x0000_1002
        expected_words[3] = 0x0000_1003
        expected_words[4] = 0x0000_1004
        expected_words[5] = 0x0000_1005
        expected_words[6] = 0x0000_1006
        expected_words[7] = 0x0000_1007
        for _ in range(3000):
            await ClockCycles(dut.clk, 1)
            actual_words = flat_words(int(core(dut).u_v_buf_pv.layout_flat.value), 32 * 16)
            if actual_words[:16] == expected_words[:16]:
                break
        else:
            actual_words = flat_words(int(core(dut).u_v_buf_pv.layout_flat.value), 32 * 16)
        assert actual_words[:16] == expected_words[:16]
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
        await wait_signal_high(dut, core(dut).u_qk_pv_core.qk_resp_valid, timeout_cycles=6000)
        actual_words = flat_words(int(core(dut).qk_result_tile_flat.value), 16 * 16)
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
        await wait_signal_high(dut, core(dut).u_qk_pv_core.pv_resp_valid, timeout_cycles=12000)
        p_words = flat_words(int(core(dut).p_tile_flat.value), 16 * 8)
        actual_words = flat_words(int(core(dut).pv_result_tile_flat.value), 16 * 32)
        expected_words = expected_pv_tile_words(p_words, v[:16])
        assert actual_words == expected_words
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_score_post_real_scale_mask(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q, k, v = make_single_tile_case(280)
        env.load_qkv(q, k, v)
        await env.start_run(causal=True)
        await wait_signal_high(dut, core(dut).u_score_post.resp_valid, timeout_cycles=12000)
        score_words = flat_words(int(core(dut).qk_result_tile_flat.value), 16 * 16)
        actual_words = flat_words(int(core(dut).u_score_post.masked_score_tile_flat.value), 16 * 16)
        expected_words = expected_score_post_words(
            score_words,
            0,
            0,
            causal=True,
            scale_word=env.scale_word,
            neg_large_word=env.neg_large_word,
        )
        assert actual_words == expected_words
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_row_state_real_init(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q, k, v = make_single_tile_case(285)
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        await wait_signal_high(dut, core(dut).u_row_state.init_done_pulse, timeout_cycles=6000)
        m_words = flat_words(int(core(dut).u_row_state.debug_m_state_flat.value), 16)
        l_words = flat_words(int(core(dut).u_row_state.debug_l_state_flat.value), 16)
        seen_bits = int(core(dut).u_row_state.debug_row_seen.value)
        assert m_words == [env.neg_large_word & 0xFFFF_FFFF for _ in range(16)]
        assert l_words == [0 for _ in range(16)]
        assert seen_bits == 0
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_row_state_real_update_single_tile(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q, k, v = make_single_tile_case(290)
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        await wait_signal_high(dut, core(dut).u_row_state.resp_valid, timeout_cycles=12000)
        masked_words = flat_words(int(core(dut).u_score_post.masked_score_tile_flat.value), 16 * 16)
        actual_p_words = flat_words(int(core(dut).u_row_state.p_tile_flat.value), 16 * 8)
        actual_rescale_words = flat_words(int(core(dut).u_row_state.rescale_vec_flat.value), 16)
        actual_m_words = flat_words(int(core(dut).u_row_state.debug_m_state_flat.value), 16)
        actual_l_words = flat_words(int(core(dut).u_row_state.debug_l_state_flat.value), 16)
        actual_seen = int(core(dut).u_row_state.debug_row_seen.value)
        expected_p_words, expected_rescale_words, expected_m_words, expected_l_words, expected_seen = expected_row_state_update(
            masked_words,
            neg_large_word=env.neg_large_word,
            m_state=[env.neg_large_word & 0xFFFF_FFFF for _ in range(16)],
            l_state=[0 for _ in range(16)],
            row_seen=[0 for _ in range(16)],
        )
        assert actual_p_words == expected_p_words
        assert actual_rescale_words == expected_rescale_words
        assert actual_m_words == expected_m_words
        assert actual_l_words == expected_l_words
        for idx in range(16):
            assert ((actual_seen >> idx) & 0x1) == expected_seen[idx]
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
        q_row_start = 0
        q, k, v = make_single_q_full_kv_case(300)
        env.load_qkv(q, k, v)
        await env.start_run(causal=True)
        await env.wait_done()
        actual = env.read_output_matrix()
        expected = attention_golden_rows(q, k, v, scale=0.125, causal=True, q_start=q_row_start, q_rows=16)
        mean_err, max_err = matrix_error(
            actual[q_row_start : q_row_start + 16],
            expected,
        )
        assert mean_err <= 0.03, f"mean_err={mean_err}"
        assert max_err <= 0.10, f"max_err={max_err}"
    finally:
        env.shutdown()
