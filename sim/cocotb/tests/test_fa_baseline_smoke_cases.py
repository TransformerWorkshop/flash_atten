from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles

from tests.fa_baseline_case_utils import assert_matrix_close, make_single_tile_case
from tests.fa_baseline_env import ADDR_RD_BYTES, ADDR_STATUS, ADDR_WR_BYTES, STATUS_DONE, STATUS_ERROR, attention_golden_rows, create_env


@cocotb.test()
async def test_fa_smoke_basic_run_and_counters(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q, k, v = make_single_tile_case(900)
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        status = await env.wait_done()
        assert status & STATUS_DONE
        assert (status & STATUS_ERROR) == 0
        assert len(env.rd_desc_log) > 0
        assert len(env.wr_desc_log) > 0
        assert await env.axil_read(ADDR_RD_BYTES) > 0
        assert await env.axil_read(ADDR_WR_BYTES) > 0
        actual = env.read_output_matrix()
        expected = attention_golden_rows(q, k, v, scale=0.125, causal=False, q_start=0, q_rows=16)
        assert_matrix_close(actual[:16], expected)
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_smoke_status_stable_after_done(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q, k, v = make_single_tile_case(910)
        env.load_qkv(q, k, v)
        await env.start_run(causal=True)
        status = await env.wait_done()
        assert status & STATUS_DONE
        assert (status & STATUS_ERROR) == 0
        rd_count = len(env.rd_desc_log)
        wr_count = len(env.wr_desc_log)
        await ClockCycles(dut.clk, 32)
        status_again = await env.axil_read(ADDR_STATUS)
        assert status_again & STATUS_DONE
        assert len(env.rd_desc_log) == rd_count
        assert len(env.wr_desc_log) == wr_count
    finally:
        env.shutdown()
