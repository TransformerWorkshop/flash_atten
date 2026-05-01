from __future__ import annotations

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

from tests.fa_functional_coverage import record_module_hits

ROWS_PER_BLOCK = 4
WORDS_PER_ROW = 32
WORDS_PER_BLOCK = ROWS_PER_BLOCK * WORDS_PER_ROW


def s32(raw: int) -> int:
    raw &= 0xFFFF_FFFF
    if raw & 0x8000_0000:
        raw -= 0x1_0000_0000
    return raw


def s16(raw: int) -> int:
    raw &= 0xFFFF
    if raw & 0x8000:
        raw -= 0x10000
    return raw


def pack_words_to_int(words: list[int], word_bits: int = 32) -> int:
    value = 0
    mask = (1 << word_bits) - 1
    for idx, word in enumerate(words):
        value |= (int(word) & mask) << (idx * word_bits)
    return value


def flat_words(signal_value: int, count: int, word_bits: int = 16) -> list[int]:
    mask = (1 << word_bits) - 1
    return [(int(signal_value) >> (idx * word_bits)) & mask for idx in range(count)]


def q16_mul_rn_sat_py(lhs: int, rhs: int) -> int:
    prod = s32(lhs) * s32(rhs)
    rounded = prod + 32768 if prod >= 0 else prod - 32768
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


def q88_raw_to_q16_word(raw: int) -> int:
    return (s16(raw) << 8) & 0xFFFF_FFFF


def q412_raw_to_q16_word(raw: int) -> int:
    return (s16(raw) << 4) & 0xFFFF_FFFF


def q16_to_q412_rn_sat_py(value: int) -> int:
    value_s = s32(value)
    rounded = value_s + 8 if value_s >= 0 else value_s - 8
    shifted = rounded >> 4
    if shifted > 32767:
        shifted = 32767
    elif shifted < -32768:
        shifted = -32768
    return shifted & 0xFFFF


def expected_oacc_update_q412_words(
    old_q412_words: list[int],
    rescale_words: list[int],
    partial_words: list[int],
) -> list[int]:
    out_words = [0 for _ in range(16 * 64)]
    for row in range(16):
        scale_raw = rescale_words[row]
        for col in range(64):
            word_idx = ((row * 64) + col) >> 1
            part_word = partial_words[word_idx]
            part_raw = (part_word >> 16) & 0xFFFF if col & 1 else part_word & 0xFFFF
            old_q16 = q412_raw_to_q16_word(old_q412_words[(row * 64) + col])
            scaled_old_q16 = q16_mul_rn_sat_py(old_q16, scale_raw)
            next_q16 = q16_add_sat_py(scaled_old_q16, q88_raw_to_q16_word(part_raw))
            out_words[(row * 64) + col] = q16_to_q412_rn_sat_py(next_q16)
    return out_words


async def reset_dut(dut) -> None:
    dut.rstn.value = 0
    dut.clear.value = 0
    dut.req_valid.value = 0
    dut.req_row_base.value = 0
    dut.rescale_vec_flat.value = 0
    dut.partial_o_block_flat.value = 0
    dut.oacc_row_rd_valid.value = 0
    dut.oacc_row_rd_data.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    for _ in range(2):
        await RisingEdge(dut.clk)


async def row_memory_agent(dut, rows: list[list[int]], writes: dict[int, list[int]]) -> None:
    while True:
        await RisingEdge(dut.clk)
        if int(dut.oacc_row_wr_en.value):
            writes[int(dut.oacc_row_wr_addr.value)] = flat_words(dut.oacc_row_wr_data.value, 64, word_bits=16)
        if int(dut.oacc_row_rd_en.value):
            row_idx = int(dut.oacc_row_rd_addr.value)
            dut.oacc_row_rd_data.value = pack_words_to_int(rows[row_idx], word_bits=16)
            dut.oacc_row_rd_valid.value = 1
        else:
            dut.oacc_row_rd_valid.value = 0


async def wait_done_pulse(dut, timeout_cycles: int = 512) -> None:
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.done_pulse.value):
            return
    raise AssertionError("OACC update did not finish")


async def wait_signal_high(dut, signal, timeout_cycles: int = 512) -> None:
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(signal.value):
            return
    raise AssertionError("signal did not assert before timeout")


async def run_oacc_block(dut, row_base: int, partial_words: list[int]) -> None:
    await wait_signal_high(dut, dut.req_ready)
    dut.req_row_base.value = row_base
    dut.partial_o_block_flat.value = pack_words_to_int(partial_words)
    dut.req_valid.value = 1
    await RisingEdge(dut.clk)
    dut.req_valid.value = 0
    await wait_done_pulse(dut)


async def run_oacc_tile(dut, partial_words: list[int]) -> None:
    for block_idx in range(4):
        start = block_idx * WORDS_PER_BLOCK
        end = start + WORDS_PER_BLOCK
        await run_oacc_block(dut, block_idx * ROWS_PER_BLOCK, partial_words[start:end])


@cocotb.test()
async def test_fa_oacc_update_q412_rounding_saturation_boundaries(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    q412_patterns = [
        0x7FFF,
        0x7FF0,
        0x7000,
        0x0018,
        0x0008,
        0x0007,
        0x0000,
        0xFFF9,
        0xFFF8,
        0xFFE8,
        0x9000,
        0x8000,
        0xF000,
        0x1000,
        0x0108,
        0xFEF8,
    ]
    partial_raws = [
        0x7FFF,
        0x8000,
        0x0800,
        0xF800,
        0x0080,
        0xFF80,
        0x0001,
        0xFFFF,
        0x0000,
        0x0101,
        0xFEFF,
        0x0400,
        0xFC00,
        0x0010,
        0xFFF0,
        0x0008,
    ]
    rescale_patterns = [
        0x0000_0000,
        0x0000_8000,
        0x0001_0000,
        0x0001_8000,
        0x0002_0000,
        0x0000_4000,
        0x0000_C000,
        0x0001_4000,
    ]
    old_q412_words = [q412_patterns[idx % len(q412_patterns)] for idx in range(16 * 64)]
    old_rows = [old_q412_words[row * 64 : (row + 1) * 64] for row in range(16)]
    partial_words = []
    for word_idx in range(16 * 32):
        lo = partial_raws[(word_idx * 2) % len(partial_raws)]
        hi = partial_raws[(word_idx * 2 + 1) % len(partial_raws)]
        partial_words.append((lo & 0xFFFF) | ((hi & 0xFFFF) << 16))
    rescale_words = [rescale_patterns[row % len(rescale_patterns)] for row in range(16)]
    expected_words = expected_oacc_update_q412_words(old_q412_words, rescale_words, partial_words)
    expected_rows = [expected_words[row * 64 : (row + 1) * 64] for row in range(16)]
    writes: dict[int, list[int]] = {}
    memory_task = cocotb.start_soon(row_memory_agent(dut, old_rows, writes))
    try:
        dut.rescale_vec_flat.value = pack_words_to_int(rescale_words)
        await run_oacc_tile(dut, partial_words)
        await Timer(1, unit="ps")

        assert sorted(writes) == list(range(16))
        for row in range(16):
            assert writes[row] == expected_rows[row]
        record_module_hits(
            ("module.oacc_update", "module.oacc_rounding", "module.oacc_saturation"),
            rows_written=len(writes),
        )
    finally:
        memory_task.cancel()


@cocotb.test()
async def test_fa_oacc_update_clear_and_extreme_saturation(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_dut(dut)

    dut.clear.value = 1
    await RisingEdge(dut.clk)
    dut.clear.value = 0
    await RisingEdge(dut.clk)

    old_q412_words = [
        0x7FFF if idx % 4 in (0, 1) else 0x8000
        for idx in range(16 * 64)
    ]
    old_rows = [old_q412_words[row * 64 : (row + 1) * 64] for row in range(16)]
    partial_words = []
    for word_idx in range(16 * 32):
        lo = 0x7FFF if word_idx & 1 else 0x8000
        hi = 0x7FFF if word_idx & 2 else 0x8000
        partial_words.append((lo & 0xFFFF) | ((hi & 0xFFFF) << 16))
    rescale_words = [0x7FFF_FFFF for _ in range(16)]
    writes: dict[int, list[int]] = {}
    memory_task = cocotb.start_soon(row_memory_agent(dut, old_rows, writes))
    try:
        dut.rescale_vec_flat.value = pack_words_to_int(rescale_words)
        await run_oacc_tile(dut, partial_words)
        await Timer(1, unit="ps")

        assert sorted(writes) == list(range(16))
        flat_writes = [word for row in range(16) for word in writes[row]]
        assert 0x7FFF in flat_writes
        assert 0x8000 in flat_writes
        record_module_hits(
            ("module.oacc_update", "module.oacc_rounding", "module.oacc_saturation"),
            rows_written=len(writes),
            extreme_saturation=True,
        )
    finally:
        memory_task.cancel()
