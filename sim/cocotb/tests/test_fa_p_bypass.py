from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer


def pack_words_to_int(words: list[int]) -> int:
    value = 0
    for idx, word in enumerate(words):
        value |= (int(word) & 0xFFFF_FFFF) << (idx * 32)
    return value


def flat_words(signal_value: int, count: int) -> list[int]:
    return [(int(signal_value) >> (idx * 32)) & 0xFFFF_FFFF for idx in range(count)]


async def reset_dut(dut) -> None:
    dut.rstn.value = 0
    dut.clear.value = 0
    dut.row_p_tile_flat.value = 0
    dut.rd_en.value = 0
    dut.rd_addr.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    for _ in range(2):
        await RisingEdge(dut.clk)


@cocotb.test()
async def test_fa_p_bypass_reads_each_pv_slice(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    row_p_words = [
        0xA500_0000 | ((row & 0xFF) << 8) | (addr & 0xFF)
        for row in range(16)
        for addr in range(8)
    ]
    dut.row_p_tile_flat.value = pack_words_to_int(row_p_words)

    for rd_addr in range(8):
        dut.rd_addr.value = rd_addr
        dut.rd_en.value = 1
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        actual_words = flat_words(dut.rd_data.value, 16)
        expected_words = [row_p_words[(row * 8) + rd_addr] for row in range(16)]
        assert int(dut.rd_valid.value) == 1
        assert actual_words == expected_words

    dut.rd_en.value = 0
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    assert int(dut.rd_valid.value) == 0

    dut.clear.value = 1
    dut.rd_en.value = 1
    await RisingEdge(dut.clk)
    await Timer(1, unit="ps")
    assert int(dut.rd_valid.value) == 0
    assert int(dut.rd_data.value) == 0
