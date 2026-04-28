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
