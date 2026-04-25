from __future__ import annotations

import json
import os
from pathlib import Path

import cocotb
from cocotb.handle import Force, Release
from cocotb.triggers import RisingEdge

from tests.fa_baseline_env import create_env


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
    signal.value = Force(1)
    await RisingEdge(dut.clk)
    signal.value = Release()


async def measure_cycles_to_pulse(dut, signal, timeout_cycles: int) -> int:
    for cycles in range(1, timeout_cycles + 1):
        await RisingEdge(dut.clk)
        if int(signal.value):
            return cycles
    raise AssertionError("pulse did not arrive before timeout")


def dump_report(report: dict[str, int]) -> None:
    output_path = os.getenv("FA_ROWSTATE_PROFILE_JSON")
    if not output_path:
        return
    path = Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


@cocotb.test()
async def test_fa_baseline_rowstate_latency_samples(dut) -> None:
    env = await create_env(dut)
    core = dut.u_core
    try:
        await env.reset()
        await env.program_common_regs(causal=False)

        masked_tile_words = [env.neg_large_word & 0xFFFF_FFFF for _ in range(16 * 16)]
        valid_tile_words = [0 for _ in range(16 * 16)]
        report: dict[str, int] = {}

        core.u_row_state.masked_score_tile_flat.value = Force(pack_words_to_int(masked_tile_words))
        await pulse_for_one_cycle(dut, core.u_row_state.init_valid)
        await wait_signal_high(dut, core.u_row_state.init_done_pulse, timeout_cycles=32)
        await pulse_for_one_cycle(dut, core.u_row_state.update_valid)
        report["masked_row_state_cycles"] = await measure_cycles_to_pulse(dut, core.u_row_state.done_pulse, timeout_cycles=256)
        await wait_signal_high(dut, core.u_p_buf.load_done_pulse, timeout_cycles=32)
        report["masked_row_update_cycles"] = report["masked_row_state_cycles"] + 9

        core.u_row_state.masked_score_tile_flat.value = Force(pack_words_to_int(valid_tile_words))
        await pulse_for_one_cycle(dut, core.u_row_state.init_valid)
        await wait_signal_high(dut, core.u_row_state.init_done_pulse, timeout_cycles=32)
        await pulse_for_one_cycle(dut, core.u_row_state.update_valid)
        report["valid_row_state_cycles"] = await measure_cycles_to_pulse(dut, core.u_row_state.done_pulse, timeout_cycles=2048)
        await wait_signal_high(dut, core.u_p_buf.load_done_pulse, timeout_cycles=32)
        report["valid_row_update_cycles"] = report["valid_row_state_cycles"] + 9

        dump_report(report)
    finally:
        for handle in (
            core.u_row_state.masked_score_tile_flat,
            core.u_row_state.init_valid,
            core.u_row_state.update_valid,
        ):
            try:
                handle.value = Release()
            except Exception:
                pass
        env.shutdown()
