from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles

from tests.fa_baseline_case_utils import make_single_tile_case
from tests.fa_baseline_env import ADDR_CTRL, ADDR_CYCLES, ADDR_RD_BYTES, ADDR_STATUS, ADDR_WR_BYTES, CTRL_IRQ_EN, CTRL_START, STATUS_BUSY, STATUS_DONE, STATUS_ERROR, create_env


@cocotb.test()
async def test_fa_state_done_sticky_until_next_start(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q, k, v = make_single_tile_case(1300)
        env.load_qkv(q, k, v)
        status = 0
        await env.start_run(causal=False)
        status = await env.wait_done()
        assert status & STATUS_DONE
        status_again = await env.axil_read(ADDR_STATUS)
        assert status_again & STATUS_DONE

        await env.start_run(causal=False)
        await env.wait_busy(True)
        status_during_run = await env.axil_read(ADDR_STATUS)
        assert status_during_run & STATUS_BUSY
        assert (status_during_run & STATUS_DONE) == 0
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_state_soft_reset_clears_status_and_counters(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q, k, v = make_single_tile_case(1310)
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        await env.wait_busy(True)
        await ClockCycles(dut.clk, 32)
        assert await env.axil_read(ADDR_CYCLES) > 0
        assert await env.axil_read(ADDR_RD_BYTES) > 0
        await env.soft_reset()
        await env.wait_busy(False)
        assert await env.axil_read(ADDR_STATUS) == 0
        assert await env.axil_read(ADDR_CYCLES) == 0
        assert await env.axil_read(ADDR_RD_BYTES) == 0
        assert await env.axil_read(ADDR_WR_BYTES) == 0
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_state_noncausal_restart_after_soft_reset_no_error(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q, k, v = make_single_tile_case(1315)
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        await env.wait_busy(True)
        await ClockCycles(dut.clk, 64)
        await env.soft_reset()
        await env.wait_busy(False)
        assert await env.axil_read(ADDR_STATUS) == 0

        await env.start_run(causal=False)
        status = await env.wait_done()
        assert status & STATUS_DONE
        assert (status & STATUS_ERROR) == 0
        assert await env.axil_read(ADDR_RD_BYTES) > 0
        assert await env.axil_read(ADDR_WR_BYTES) > 0
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_state_start_while_busy_is_ignored(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q, k, v = make_single_tile_case(1320)
        env.load_qkv(q, k, v)
        await env.start_run(causal=True)
        await env.wait_busy(True)
        await ClockCycles(dut.clk, 24)
        cycles_before = await env.axil_read(ADDR_CYCLES)
        await env.axil_write(ADDR_CTRL, CTRL_IRQ_EN)
        await env.axil_write(ADDR_CTRL, CTRL_IRQ_EN | CTRL_START)
        await env.axil_write(ADDR_CTRL, CTRL_IRQ_EN)
        await ClockCycles(dut.clk, 16)
        cycles_after = await env.axil_read(ADDR_CYCLES)
        status_mid = await env.axil_read(ADDR_STATUS)
        assert status_mid & STATUS_BUSY
        assert (status_mid & STATUS_ERROR) == 0
        assert cycles_after > cycles_before
        await env.wait_done()
    finally:
        env.shutdown()
