from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from tests.fa_baseline_case_utils import assert_matrix_close
from tests.fa_baseline_axi_env import ConstantPattern, SequencePattern, create_env
from tests.fa_baseline_env import (
    ADDR_CTRL,
    ADDR_CFG,
    ADDR_CYCLES,
    ADDR_RD_BYTES,
    ADDR_STATUS,
    ADDR_STRIDE_BYTES,
    ADDR_WR_BYTES,
    CFG_CAUSAL_EN,
    CTRL_IRQ_EN,
    CTRL_START,
    STATUS_BUSY,
    STATUS_DONE,
    STATUS_ERROR,
    attention_golden_rows,
    random_q88_matrix,
)

TOTAL_Q_BLOCKS = 16
TOTAL_CAUSAL_KV_BLOCKS = sum(range(1, TOTAL_Q_BLOCKS + 1))
TILE_BYTES = 16 * 64 * 2
TOTAL_WR_BYTES = TOTAL_Q_BLOCKS * TILE_BYTES
TOTAL_CAUSAL_RD_BYTES = (TOTAL_Q_BLOCKS + (2 * TOTAL_CAUSAL_KV_BLOCKS)) * TILE_BYTES


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
        actual = env.read_output_matrix()
        expected = attention_golden_rows(q, k, v, scale=0.125, causal=False, q_start=0, q_rows=16)
        assert_matrix_close(actual[:16], expected)
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
        actual = env.read_output_matrix()
        expected = attention_golden_rows(q, k, v, scale=0.125, causal=False, q_start=0, q_rows=16)
        assert_matrix_close(actual[:16], expected)
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

        q = random_q88_matrix(16, 64, 744, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        k = random_q88_matrix(16, 64, 745, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        v = random_q88_matrix(16, 64, 746, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        env.load_qkv(q, k, v)
        env.set_axi_patterns(rvalid=ConstantPattern(1))
        await env.start_run(causal=False)
        status = await env.wait_done()
        assert (status & STATUS_ERROR) == 0
        actual = env.read_output_matrix()
        expected = attention_golden_rows(q, k, v, scale=0.125, causal=False, q_start=0, q_rows=16)
        assert_matrix_close(actual[:16], expected)
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


@cocotb.test()
async def test_fa_baseline_axi_byte_counters_exact(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q = random_q88_matrix(16, 64, 7611, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        k = random_q88_matrix(16, 64, 7612, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        v = random_q88_matrix(16, 64, 7613, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        env.load_qkv(q, k, v)
        await env.start_run(causal=True)
        status = await env.wait_done()
        assert (status & STATUS_ERROR) == 0
        assert status & STATUS_DONE
        assert await env.axil_read(ADDR_RD_BYTES) == TOTAL_CAUSAL_RD_BYTES
        assert await env.axil_read(ADDR_WR_BYTES) == TOTAL_WR_BYTES
        env.coverage.hit("csr.byte_counters_exact")
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_axi_no_extra_after_done(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q = random_q88_matrix(16, 64, 7621, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        k = random_q88_matrix(16, 64, 7622, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        v = random_q88_matrix(16, 64, 7623, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        status = await env.wait_done()
        assert (status & STATUS_ERROR) == 0
        assert status & STATUS_DONE
        rd_count = len(env.rd_bursts)
        wr_count = len(env.wr_bursts)
        rd_bytes = await env.axil_read(ADDR_RD_BYTES)
        wr_bytes = await env.axil_read(ADDR_WR_BYTES)
        await ClockCycles(dut.clk, 32)
        assert len(env.rd_bursts) == rd_count
        assert len(env.wr_bursts) == wr_count
        assert await env.axil_read(ADDR_RD_BYTES) == rd_bytes
        assert await env.axil_read(ADDR_WR_BYTES) == wr_bytes
        env.coverage.hit("axi.no_extra_after_done")
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_axi_start_while_busy_is_ignored(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q = random_q88_matrix(16, 64, 7631, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        k = random_q88_matrix(16, 64, 7632, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        v = random_q88_matrix(16, 64, 7633, amplitude=48) + [[0.0] * 64 for _ in range(240)]
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
        env.coverage.hit("csr.start_while_busy")
        await env.wait_done()
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_axi_read_fault_early_last_sets_error(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        env.set_read_faults(early_last_beat=7)
        q = random_q88_matrix(16, 64, 7641, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        k = random_q88_matrix(16, 64, 7642, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        v = random_q88_matrix(16, 64, 7643, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        status = await wait_for_error_status(env)
        assert status & STATUS_ERROR
    finally:
        env.clear_read_faults()
        env.shutdown()


@cocotb.test()
async def test_fa_baseline_axi_read_fault_missing_final_last_sets_error(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        env.set_read_faults(suppress_final_last=True)
        q = random_q88_matrix(16, 64, 7651, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        k = random_q88_matrix(16, 64, 7652, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        v = random_q88_matrix(16, 64, 7653, amplitude=48) + [[0.0] * 64 for _ in range(240)]
        env.load_qkv(q, k, v)
        await env.start_run(causal=True)
        status = await wait_for_error_status(env)
        assert status & STATUS_ERROR
    finally:
        env.clear_read_faults()
        env.shutdown()
