from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.fa_functional_coverage import record_module_hits


def pack_words_to_int(words: list[int]) -> int:
    value = 0
    for idx, word in enumerate(words):
        value |= (int(word) & 0xFFFF_FFFF) << (idx * 32)
    return value


def flat_words(signal_value: int, count: int) -> list[int]:
    return [(signal_value >> (idx * 32)) & 0xFFFF_FFFF for idx in range(count)]


def pack_q88_pair(lo_raw: int, hi_raw: int) -> int:
    return (lo_raw & 0xFFFF) | ((hi_raw & 0xFFFF) << 16)


def clamp_s32(value: int) -> int:
    if value > 0x7FFF_FFFF:
        value = 0x7FFF_FFFF
    elif value < -0x8000_0000:
        value = -0x8000_0000
    return value & 0xFFFF_FFFF


def q16_to_q88_sat(value: int) -> int:
    rounded = value + 128 if value >= 0 else value - 128
    shifted = rounded >> 8
    if shifted > 32767:
        shifted = 32767
    elif shifted < -32768:
        shifted = -32768
    return shifted & 0xFFFF


def pack_qk_read_data(matrix: list[list[int]], addr: int) -> int:
    dim_lo = addr * 2
    return pack_words_to_int(
        [pack_q88_pair(matrix[row][dim_lo], matrix[row][dim_lo + 1]) for row in range(16)]
    )


def pack_p_read_data(matrix: list[list[int]], addr: int) -> int:
    col_lo = addr * 2
    return pack_words_to_int(
        [pack_q88_pair(matrix[row][col_lo], matrix[row][col_lo + 1]) for row in range(16)]
    )


def pack_v_pv_read_data(matrix: list[list[int]], addr: int) -> int:
    col_blk = addr >> 3
    row_pair = addr & 0x7
    row_lo = row_pair * 2
    col_base = col_blk * 16
    return pack_words_to_int(
        [pack_q88_pair(matrix[row_lo][col_base + lane], matrix[row_lo + 1][col_base + lane]) for lane in range(16)]
    )


def expected_qk_words(q_matrix: list[list[int]], k_matrix: list[list[int]]) -> list[int]:
    words: list[int] = []
    for row in range(16):
        for col in range(16):
            acc = 0
            for dim in range(64):
                acc += q_matrix[row][dim] * k_matrix[col][dim]
            words.append(clamp_s32(acc))
    return words


def expected_pv_words(p_matrix: list[list[int]], v_matrix: list[list[int]]) -> list[int]:
    words = [0 for _ in range(16 * 32)]
    for row in range(16):
        for col in range(64):
            acc = 0
            for k_idx in range(16):
                acc += p_matrix[row][k_idx] * v_matrix[k_idx][col]
            raw = q16_to_q88_sat(acc)
            word_idx = ((row * 64) + col) >> 1
            if col & 1:
                words[word_idx] = (words[word_idx] & 0x0000_FFFF) | (raw << 16)
            else:
                words[word_idx] = (words[word_idx] & 0xFFFF_0000) | raw
    return words


async def patterned_read_driver(
    dut,
    q_matrix: list[list[int]],
    k_matrix: list[list[int]],
    p_matrix: list[list[int]],
    v_matrix: list[list[int]],
) -> None:
    q_en = k_en = p_en = v_en = 0
    q_addr = k_addr = p_addr = v_addr = 0
    while True:
        await RisingEdge(dut.clk)
        dut.q_rd_valid.value = q_en
        dut.k_rd_valid.value = k_en
        dut.p_rd_valid.value = p_en
        dut.v_rd_valid.value = v_en
        dut.q_rd_data.value = pack_qk_read_data(q_matrix, q_addr) if q_en else 0
        dut.k_rd_data.value = pack_qk_read_data(k_matrix, k_addr) if k_en else 0
        dut.p_rd_data.value = pack_p_read_data(p_matrix, p_addr) if p_en else 0
        dut.v_rd_data.value = pack_v_pv_read_data(v_matrix, v_addr) if v_en else 0
        await Timer(1, unit="ps")
        q_en = int(dut.q_rd_en.value)
        k_en = int(dut.k_rd_en.value)
        p_en = int(dut.p_rd_en.value)
        v_en = int(dut.v_rd_en.value)
        q_addr = int(dut.q_rd_addr.value)
        k_addr = int(dut.k_rd_addr.value)
        p_addr = int(dut.p_rd_addr.value)
        v_addr = int(dut.v_rd_addr.value)


async def wait_signal_high(dut, signal, timeout_cycles: int = 20000) -> None:
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(signal.value):
            return
    raise AssertionError("signal did not assert before timeout")


async def run_qk_transaction(dut, q_word: int, k_word: int) -> int:
    dut.q_rd_data.value = pack_words_to_int([q_word for _ in range(16)])
    dut.k_rd_data.value = pack_words_to_int([k_word for _ in range(16)])
    dut.q_rd_valid.value = 1
    dut.k_rd_valid.value = 1
    dut.qk_resp_ready.value = 1
    dut.qk_req_valid.value = 1
    await RisingEdge(dut.clk)
    dut.qk_req_valid.value = 0
    await wait_signal_high(dut, dut.qk_done_pulse)
    result = int(dut.qk_result_tile_flat.value)
    dut.q_rd_valid.value = 0
    dut.k_rd_valid.value = 0
    await RisingEdge(dut.clk)
    return result


async def run_pv_transaction(dut, p_word: int, v_word: int) -> int:
    dut.p_rd_data.value = pack_words_to_int([p_word for _ in range(16)])
    dut.v_rd_data.value = pack_words_to_int([v_word for _ in range(16)])
    dut.p_rd_valid.value = 1
    dut.v_rd_valid.value = 1
    dut.pv_resp_ready.value = 1
    dut.pv_req_valid.value = 1
    await RisingEdge(dut.clk)
    dut.pv_req_valid.value = 0
    await wait_signal_high(dut, dut.pv_done_pulse)
    result = int(dut.pv_result_tile_flat.value)
    dut.p_rd_valid.value = 0
    dut.v_rd_valid.value = 0
    await RisingEdge(dut.clk)
    return result


async def reset_dut(dut) -> None:
    dut.rstn.value = 0
    dut.clear.value = 0
    dut.qk_req_valid.value = 0
    dut.pv_req_valid.value = 0
    dut.q_rd_valid.value = 0
    dut.k_rd_valid.value = 0
    dut.p_rd_valid.value = 0
    dut.v_rd_valid.value = 0
    dut.q_rd_data.value = 0
    dut.k_rd_data.value = 0
    dut.p_rd_data.value = 0
    dut.v_rd_data.value = 0
    dut.qk_resp_ready.value = 1
    dut.pv_resp_ready.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    for _ in range(2):
        await RisingEdge(dut.clk)
    await Timer(1, unit="ps")


@cocotb.test()
async def test_fa_shared_gemm_qk_priority_on_simultaneous_request(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    assert int(dut.qk_req_ready.value) == 1
    assert int(dut.pv_req_ready.value) == 1

    dut.qk_req_valid.value = 1
    dut.pv_req_valid.value = 1
    await Timer(1, unit="ps")
    assert int(dut.qk_req_ready.value) == 1
    assert int(dut.pv_req_ready.value) == 0

    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    assert int(dut.q_rd_en.value) == 1
    assert int(dut.k_rd_en.value) == 1
    assert int(dut.p_rd_en.value) == 0
    assert int(dut.v_rd_en.value) == 0

    dut.clear.value = 1
    dut.qk_req_valid.value = 0
    dut.pv_req_valid.value = 0
    await RisingEdge(dut.clk)
    dut.clear.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")

    dut.pv_req_valid.value = 1
    await Timer(1, unit="ps")
    assert int(dut.pv_req_ready.value) == 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    assert int(dut.p_rd_en.value) == 1
    assert int(dut.v_rd_en.value) == 1
    assert int(dut.q_rd_en.value) == 0
    assert int(dut.k_rd_en.value) == 0
    record_module_hits(("module.shared_gemm", "module.shared_gemm_qk_priority", "module.shared_gemm_pv_path"))


@cocotb.test()
async def test_fa_shared_gemm_qk_and_pv_complete_streams(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    one_pair_word = 0x0100_0100
    source_tile = pack_words_to_int([one_pair_word for _ in range(16)])

    dut.q_rd_data.value = source_tile
    dut.k_rd_data.value = source_tile
    dut.q_rd_valid.value = 1
    dut.k_rd_valid.value = 1
    dut.qk_resp_ready.value = 0
    dut.qk_req_valid.value = 1
    await RisingEdge(dut.clk)
    dut.qk_req_valid.value = 0

    await wait_signal_high(dut, dut.qk_resp_valid)
    await Timer(1, unit="ps")
    assert int(dut.qk_result_tile_flat.value) != 0
    assert int(dut.qk_done_pulse.value) == 0

    dut.qk_resp_ready.value = 1
    await wait_signal_high(dut, dut.qk_done_pulse)
    dut.q_rd_valid.value = 0
    dut.k_rd_valid.value = 0

    dut.p_rd_data.value = source_tile
    dut.v_rd_data.value = source_tile
    dut.p_rd_valid.value = 1
    dut.v_rd_valid.value = 1
    dut.pv_resp_ready.value = 0
    dut.pv_req_valid.value = 1
    await RisingEdge(dut.clk)
    dut.pv_req_valid.value = 0

    await wait_signal_high(dut, dut.pv_resp_valid)
    await Timer(1, unit="ps")
    assert int(dut.pv_result_tile_flat.value) != 0
    assert int(dut.pv_done_pulse.value) == 0

    dut.pv_resp_ready.value = 1
    await wait_signal_high(dut, dut.pv_done_pulse)
    dut.p_rd_valid.value = 0
    dut.v_rd_valid.value = 0
    record_module_hits(("module.shared_gemm", "module.shared_gemm_qk_priority", "module.shared_gemm_pv_path"))


@cocotb.test()
async def test_fa_shared_gemm_input_arbiter_selects_qk_and_pv_sources(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    q_matrix = [[1 + (row * 2) + (dim % 5) for dim in range(64)] for row in range(16)]
    k_matrix = [[2 + (row * 3) + (dim % 7) for dim in range(64)] for row in range(16)]
    p_matrix = [[1 + row + ((col * 3) % 5) for col in range(16)] for row in range(16)]
    v_matrix = [[3 + (row * 2) + (col % 11) for col in range(64)] for row in range(16)]

    driver_task = cocotb.start_soon(patterned_read_driver(dut, q_matrix, k_matrix, p_matrix, v_matrix))
    try:
        dut.qk_resp_ready.value = 1
        dut.qk_req_valid.value = 1
        await RisingEdge(dut.clk)
        dut.qk_req_valid.value = 0
        await wait_signal_high(dut, dut.qk_done_pulse)
        await Timer(1, unit="ps")
        assert flat_words(int(dut.qk_result_tile_flat.value), 16 * 16) == expected_qk_words(q_matrix, k_matrix)

        await RisingEdge(dut.clk)
        dut.pv_resp_ready.value = 1
        dut.pv_req_valid.value = 1
        await RisingEdge(dut.clk)
        dut.pv_req_valid.value = 0
        await wait_signal_high(dut, dut.pv_done_pulse)
        await Timer(1, unit="ps")
        assert flat_words(int(dut.pv_result_tile_flat.value), 16 * 32) == expected_pv_words(p_matrix, v_matrix)

        record_module_hits(("module.shared_gemm", "module.shared_gemm_qk_priority", "module.shared_gemm_pv_path"))
    finally:
        driver_task.cancel()


@cocotb.test()
async def test_fa_shared_gemm_positive_and_negative_saturation(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    max_pos_pair = 0x7FFF_7FFF
    max_neg_pair = 0x8000_8000

    assert await run_qk_transaction(dut, max_pos_pair, max_pos_pair) != 0
    assert await run_qk_transaction(dut, max_pos_pair, max_neg_pair) != 0
    assert await run_pv_transaction(dut, max_pos_pair, max_pos_pair) != 0
    assert await run_pv_transaction(dut, max_pos_pair, max_neg_pair) != 0

    record_module_hits(("module.shared_gemm", "module.shared_gemm_qk_priority", "module.shared_gemm_pv_path"))
