from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles

from tests.fa_baseline_axi_env import ConstantPattern, SequencePattern, create_env
from tests.fa_baseline_env import (
    ADDR_CTRL,
    ADDR_CFG,
    ADDR_RD_BYTES,
    ADDR_STATUS,
    ADDR_STRIDE_BYTES,
    ADDR_WR_BYTES,
    CFG_CAUSAL_EN,
    CTRL_IRQ_EN,
    CTRL_START,
    STATUS_DONE,
    STATUS_ERROR,
    random_q88_matrix,
)


@cocotb.test()
async def test_fa_baseline_axi_smoke(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q = random_q88_matrix(16, 64, 701, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        k = random_q88_matrix(16, 64, 702, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        v = random_q88_matrix(16, 64, 703, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        status = await env.wait_done()
        assert (status & STATUS_ERROR) == 0
        assert status & STATUS_DONE
        assert len(env.rd_bursts) > 0
        assert len(env.wr_bursts) > 0
        assert await env.axil_read(ADDR_RD_BYTES) > 0
        assert await env.axil_read(ADDR_WR_BYTES) > 0
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_axi_read_burst_split(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q = random_q88_matrix(16, 64, 711, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        k = random_q88_matrix(16, 64, 712, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        v = random_q88_matrix(16, 64, 713, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        await env.wait_done()
        assert any(burst.beats == 16 for burst in env.rd_bursts)
        assert len(env.rd_bursts) >= 8
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_axi_write_burst_split(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q = random_q88_matrix(16, 64, 721, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        k = random_q88_matrix(16, 64, 722, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        v = random_q88_matrix(16, 64, 723, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        await env.wait_done()
        assert any(burst.beats == 16 for burst in env.wr_bursts)
        assert len(env.wr_bursts) >= 8
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_axi_backpressure(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        env.set_axi_patterns(
            arready=SequencePattern([1, 0, 1, 1, 0, 1]),
            rvalid=SequencePattern([1, 1, 0, 1, 0, 1]),
            awready=SequencePattern([1, 0, 1, 1]),
            wready=SequencePattern([1, 0, 1, 1, 0, 1]),
            bvalid=SequencePattern([0, 1, 1]),
        )
        q = random_q88_matrix(16, 64, 731, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        k = random_q88_matrix(16, 64, 732, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        v = random_q88_matrix(16, 64, 733, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        status = await env.wait_done()
        assert (status & STATUS_ERROR) == 0
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_axi_soft_reset_mid_transfer(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        env.set_axi_patterns(rvalid=SequencePattern([0, 0, 0, 1, 1, 1]))
        q = random_q88_matrix(16, 64, 741, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        k = random_q88_matrix(16, 64, 742, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        v = random_q88_matrix(16, 64, 743, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        await ClockCycles(dut.clk, 32)
        await env.soft_reset()
        status = await env.axil_read(ADDR_STATUS)
        assert (status & STATUS_ERROR) == 0
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_axi_alignment_error(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q = random_q88_matrix(16, 64, 751, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        k = random_q88_matrix(16, 64, 752, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        v = random_q88_matrix(16, 64, 753, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        env.load_qkv(q, k, v)
        await env.program_common_regs(causal=False)
        await env.axil_write(ADDR_STRIDE_BYTES, 130)
        await env.axil_write(ADDR_CTRL, CTRL_IRQ_EN)
        await env.axil_write(ADDR_CTRL, CTRL_IRQ_EN | CTRL_START)
        await env.axil_write(ADDR_CTRL, CTRL_IRQ_EN)
        await ClockCycles(dut.clk, 10)
        status = await env.axil_read(ADDR_STATUS)
        assert status & STATUS_ERROR
        assert not env.rd_bursts
        assert not env.wr_bursts
    finally:
        env.shutdown()
