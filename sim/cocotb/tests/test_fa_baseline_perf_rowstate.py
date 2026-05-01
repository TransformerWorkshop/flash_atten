from __future__ import annotations

import json
import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

from tests.fa_functional_coverage import record_module_hits

ROWS_PER_BLOCK = 4
COLS_PER_TILE = 16
WORDS_PER_BLOCK = ROWS_PER_BLOCK * COLS_PER_TILE


def pack_words_to_int(words: list[int]) -> int:
    value = 0
    for idx, word in enumerate(words):
        value |= (int(word) & 0xFFFF_FFFF) << (idx * 32)
    return value


def q16_16_from_float(value: float) -> int:
    scaled = int(round(value * 65536.0))
    if scaled < 0:
        scaled += 1 << 32
    return scaled & 0xFFFF_FFFF


async def wait_signal_high(dut, signal, timeout_cycles: int) -> None:
    for _ in range(timeout_cycles):
        if int(signal.value):
            return
        await RisingEdge(dut.clk)
    raise AssertionError("signal did not assert before timeout")


async def pulse_for_one_cycle(dut, signal) -> None:
    signal.value = 1
    await RisingEdge(dut.clk)
    signal.value = 0


async def measure_cycles_to_pulse(dut, signal, timeout_cycles: int) -> int:
    for cycles in range(1, timeout_cycles + 1):
        await RisingEdge(dut.clk)
        if int(signal.value):
            return cycles
    raise AssertionError("pulse did not arrive before timeout")


async def reset_row_state(dut) -> None:
    dut.rstn.value = 0
    dut.clear.value = 0
    dut.init_valid.value = 0
    dut.update_valid.value = 0
    dut.neg_large_word.value = 0xFFC0_0000
    dut.update_row_base.value = 0
    dut.masked_score_block_valid.value = 0
    dut.masked_score_block_flat.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rstn.value = 1
    for _ in range(2):
        await RisingEdge(dut.clk)


def dump_report(report: dict[str, int]) -> None:
    output_path = os.getenv("FA_ROWSTATE_PROFILE_JSON")
    if not output_path:
        return
    path = Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def history_score_words() -> list[int]:
    words: list[int] = []
    for row in range(16):
        if row < 8:
            row_max = q16_16_from_float(-1.0)
        else:
            row_max = q16_16_from_float(16.0)
        for col in range(16):
            words.append(row_max if col == 0 else q16_16_from_float(-2.0 - (col / 16.0)))
    return words


def exp_lut_sweep_words(start_idx: int) -> list[int]:
    words: list[int] = []
    for row in range(16):
        words.append(q16_16_from_float(0.0))
        for col in range(1, 16):
            idx = min(start_idx + row * 15 + (col - 1), 256)
            words.append((-idx * 2048) & 0xFFFF_FFFF)
    return words


def block_valid_mask(block_words: list[int], neg_large_word: int) -> int:
    mask = 0
    neg = neg_large_word & 0xFFFF_FFFF
    for idx, word in enumerate(block_words):
        if (int(word) & 0xFFFF_FFFF) != neg:
            mask |= 1 << idx
    return mask


async def run_block_update_and_measure(dut, row_base: int, block_words: list[int], timeout_cycles: int) -> int:
    await wait_signal_high(dut, dut.update_ready, timeout_cycles=timeout_cycles)
    dut.update_row_base.value = row_base
    dut.masked_score_block_valid.value = block_valid_mask(block_words, int(dut.neg_large_word.value))
    dut.masked_score_block_flat.value = pack_words_to_int(block_words)
    await pulse_for_one_cycle(dut, dut.update_valid)
    return await measure_cycles_to_pulse(dut, dut.done_pulse, timeout_cycles=timeout_cycles)


async def run_tile_update_and_measure(dut, tile_words: list[int], timeout_cycles: int = 4096) -> int:
    cycles = 0
    for block_idx in range(4):
        start = block_idx * WORDS_PER_BLOCK
        end = start + WORDS_PER_BLOCK
        cycles += await run_block_update_and_measure(
            dut,
            block_idx * ROWS_PER_BLOCK,
            tile_words[start:end],
            timeout_cycles,
        )
        await RisingEdge(dut.clk)
    return cycles


async def run_update_and_wait_done(dut, tile_words: list[int], timeout_cycles: int = 4096) -> None:
    await run_tile_update_and_measure(dut, tile_words, timeout_cycles=timeout_cycles)
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_fa_baseline_rowstate_latency_samples(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_row_state(dut)

    neg_large_word = 0xFFC0_0000
    masked_tile_words = [neg_large_word for _ in range(16 * 16)]
    valid_tile_words = [0 for _ in range(16 * 16)]
    extra_cycles = int(os.getenv("FA_ROW_UPDATE_EXTRA_CYCLES", "0"))
    report: dict[str, int] = {}

    await pulse_for_one_cycle(dut, dut.init_valid)
    await wait_signal_high(dut, dut.init_done_pulse, timeout_cycles=32)
    report["masked_row_state_cycles"] = await run_tile_update_and_measure(dut, masked_tile_words, timeout_cycles=256)
    report["masked_row_update_cycles"] = report["masked_row_state_cycles"] + extra_cycles
    await RisingEdge(dut.clk)

    await pulse_for_one_cycle(dut, dut.init_valid)
    await wait_signal_high(dut, dut.init_done_pulse, timeout_cycles=32)
    report["valid_row_state_cycles"] = await run_tile_update_and_measure(dut, valid_tile_words, timeout_cycles=2048)
    report["valid_row_update_cycles"] = report["valid_row_state_cycles"] + extra_cycles

    record_module_hits(
        ("row_state.init", "row_state.masked_row", "row_state.valid_row", "row_state.accumulate"),
        evidence=report,
    )
    dump_report(report)


@cocotb.test()
async def test_fa_baseline_rowstate_history_clear_and_resp_stall(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_row_state(dut)

    dut.clear.value = 1
    await RisingEdge(dut.clk)
    dut.clear.value = 0
    await RisingEdge(dut.clk)

    initial_tile_words = [q16_16_from_float(0.0) for _ in range(16 * 16)]
    await pulse_for_one_cycle(dut, dut.init_valid)
    await wait_signal_high(dut, dut.init_done_pulse, timeout_cycles=32)

    await run_update_and_wait_done(dut, initial_tile_words, timeout_cycles=2048)
    await RisingEdge(dut.clk)
    assert int(dut.debug_row_seen.value) == 0xFFFF

    await run_update_and_wait_done(dut, history_score_words(), timeout_cycles=2048)
    await RisingEdge(dut.clk)
    assert int(dut.debug_row_seen.value) == 0xFFFF
    assert int(dut.rescale_vec_flat.value) != 0

    await run_update_and_wait_done(dut, [int(dut.neg_large_word.value) for _ in range(16 * 16)])
    assert int(dut.debug_row_seen.value) == 0xFFFF
    assert int(dut.rescale_vec_flat.value) != 0

    record_module_hits(
        ("row_state.init", "row_state.valid_row", "row_state.accumulate"),
        history_update=True,
        masked_history=True,
    )


@cocotb.test()
async def test_fa_baseline_rowstate_exp_lut_index_sweep(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_row_state(dut)

    await pulse_for_one_cycle(dut, dut.init_valid)
    await wait_signal_high(dut, dut.init_done_pulse, timeout_cycles=32)

    await run_update_and_wait_done(dut, exp_lut_sweep_words(1))

    await run_update_and_wait_done(dut, exp_lut_sweep_words(241))

    assert int(dut.debug_row_seen.value) == 0xFFFF
    record_module_hits(
        ("row_state.init", "row_state.valid_row", "row_state.accumulate"),
        exp_lut_sweep=True,
    )
