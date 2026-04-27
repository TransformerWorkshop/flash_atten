from __future__ import annotations

import json
import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge


def pack_words_to_int(words: list[int]) -> int:
    value = 0
    for idx, word in enumerate(words):
        value |= (int(word) & 0xFFFF_FFFF) << (idx * 32)
    return value


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
    dut.masked_score_tile_flat.value = 0
    dut.resp_ready.value = 1
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


@cocotb.test()
async def test_fa_baseline_rowstate_latency_samples(dut) -> None:
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await reset_row_state(dut)

    neg_large_word = 0xFFC0_0000
    masked_tile_words = [neg_large_word for _ in range(16 * 16)]
    valid_tile_words = [0 for _ in range(16 * 16)]
    extra_cycles = int(os.getenv("FA_ROW_UPDATE_EXTRA_CYCLES", "0"))
    report: dict[str, int] = {}

    dut.masked_score_tile_flat.value = pack_words_to_int(masked_tile_words)
    await pulse_for_one_cycle(dut, dut.init_valid)
    await wait_signal_high(dut, dut.init_done_pulse, timeout_cycles=32)
    await pulse_for_one_cycle(dut, dut.update_valid)
    report["masked_row_state_cycles"] = await measure_cycles_to_pulse(dut, dut.done_pulse, timeout_cycles=256)
    report["masked_row_update_cycles"] = report["masked_row_state_cycles"] + extra_cycles
    await RisingEdge(dut.clk)

    dut.masked_score_tile_flat.value = pack_words_to_int(valid_tile_words)
    await pulse_for_one_cycle(dut, dut.init_valid)
    await wait_signal_high(dut, dut.init_done_pulse, timeout_cycles=32)
    await pulse_for_one_cycle(dut, dut.update_valid)
    report["valid_row_state_cycles"] = await measure_cycles_to_pulse(dut, dut.done_pulse, timeout_cycles=2048)
    report["valid_row_update_cycles"] = report["valid_row_state_cycles"] + extra_cycles

    dump_report(report)
