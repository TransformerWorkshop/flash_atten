from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge

from tests.fa_baseline_case_utils import make_single_tile_case
from tests.fa_baseline_env import ADDR_STATUS, STATUS_DONE, STATUS_ERROR, create_env


async def wait_for_error_status(env, timeout_cycles: int = 20000) -> int:
    for _ in range(timeout_cycles):
        status = await env.axil_read(ADDR_STATUS)
        if status & STATUS_ERROR:
            return status
        if status & STATUS_DONE:
            raise AssertionError(f"unexpected DONE before ERROR status=0x{status:08x}")
        await RisingEdge(env.dut.clk)
    raise AssertionError("timeout waiting for STATUS.ERROR")


@cocotb.test()
async def test_fa_protocol_edge_early_rd_last_sets_error(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        env.set_read_faults(early_last_beat=7)
        q, k, v = make_single_tile_case(1200)
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        status = await wait_for_error_status(env)
        assert status & STATUS_ERROR
    finally:
        env.clear_read_faults()
        env.shutdown()


@cocotb.test()
async def test_fa_protocol_edge_missing_final_rd_last_sets_error(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        env.set_read_faults(suppress_final_last=True)
        q, k, v = make_single_tile_case(1210)
        env.load_qkv(q, k, v)
        await env.start_run(causal=True)
        status = await wait_for_error_status(env)
        assert status & STATUS_ERROR
    finally:
        env.clear_read_faults()
        env.shutdown()
