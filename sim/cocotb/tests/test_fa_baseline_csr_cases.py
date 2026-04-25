from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles

from tests.fa_baseline_env import (
    ADDR_CFG,
    ADDR_CTRL,
    ADDR_K_BASE_H,
    ADDR_K_BASE_L,
    ADDR_NEG_LARGE,
    ADDR_O_BASE_H,
    ADDR_O_BASE_L,
    ADDR_Q_BASE_H,
    ADDR_Q_BASE_L,
    ADDR_SCALE,
    ADDR_STATUS,
    ADDR_STRIDE_BYTES,
    ADDR_V_BASE_H,
    ADDR_V_BASE_L,
    CFG_CAUSAL_EN,
    CTRL_IRQ_EN,
    CTRL_START,
    STATUS_ERROR,
    create_env,
    random_q88_matrix,
)


@cocotb.test()
async def test_fa_csr_programming_pattern_sweep(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        base_patterns = [
            (ADDR_Q_BASE_L, ADDR_Q_BASE_H, 0x0000_1000_0000_2000),
            (ADDR_K_BASE_L, ADDR_K_BASE_H, 0x0000_3000_0000_4010),
            (ADDR_V_BASE_L, ADDR_V_BASE_H, 0x0000_5000_0000_6020),
            (ADDR_O_BASE_L, ADDR_O_BASE_H, 0x0000_7000_0000_8030),
        ]
        for addr_lo, addr_hi, value in base_patterns:
            await env.axil_write(addr_lo, value & 0xFFFF_FFFF)
            await env.axil_write(addr_hi, (value >> 32) & 0xFFFF_FFFF)
            assert await env.axil_read(addr_lo) == (value & 0xFFFF_FFFF)
            assert await env.axil_read(addr_hi) == ((value >> 32) & 0xFFFF_FFFF)

        for stride in (128, 256, 512, 2048):
            await env.axil_write(ADDR_STRIDE_BYTES, stride)
            assert await env.axil_read(ADDR_STRIDE_BYTES) == stride

        for cfg in (0, CFG_CAUSAL_EN):
            await env.axil_write(ADDR_CFG, cfg)
            assert await env.axil_read(ADDR_CFG) == cfg

        for value in (0x0001_0000, 0xFFFF_0000, 0x0000_8000, 0xFFFC_0000):
            await env.axil_write(ADDR_SCALE, value)
            assert await env.axil_read(ADDR_SCALE) == (value & 0xFFFF_FFFF)
            await env.axil_write(ADDR_NEG_LARGE, value)
            assert await env.axil_read(ADDR_NEG_LARGE) == (value & 0xFFFF_FFFF)
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_csr_alignment_error_blocks_start(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q = random_q88_matrix(256, 64, 1031, amplitude=32)
        k = random_q88_matrix(256, 64, 1032, amplitude=32)
        v = random_q88_matrix(256, 64, 1033, amplitude=32)
        env.load_qkv(q, k, v)
        await env.program_common_regs(causal=False)
        await env.axil_write(ADDR_STRIDE_BYTES, 130)
        await env.axil_write(ADDR_CTRL, CTRL_IRQ_EN)
        await env.axil_write(ADDR_CTRL, CTRL_IRQ_EN | CTRL_START)
        await env.axil_write(ADDR_CTRL, CTRL_IRQ_EN)
        await ClockCycles(dut.clk, 16)
        status = await env.axil_read(ADDR_STATUS)
        assert status & STATUS_ERROR
        assert not env.rd_desc_log
        assert not env.wr_desc_log
    finally:
        env.shutdown()
