from __future__ import annotations

import cocotb
from cocotb.triggers import ClockCycles

from tests.fa_baseline_case_utils import make_single_tile_case
from tests.fa_baseline_env import ADDR_RD_BYTES, ADDR_STATUS, ADDR_WR_BYTES, RD_TAG_K, RD_TAG_Q, RD_TAG_V, STATUS_DONE, STATUS_ERROR, create_env


READ_DESC_PER_Q_BLK = 1 + 16 + 16
TOTAL_Q_BLKS = 16
TOTAL_RD_DESCS = TOTAL_Q_BLKS * READ_DESC_PER_Q_BLK
TOTAL_CAUSAL_KV_BLKS = sum(range(1, TOTAL_Q_BLKS + 1))
TOTAL_CAUSAL_RD_DESCS = TOTAL_Q_BLKS + (2 * TOTAL_CAUSAL_KV_BLKS)
TOTAL_WR_DESCS = TOTAL_Q_BLKS
BYTES_PER_TILE = 512 * 4


@cocotb.test()
async def test_fa_protocol_descriptor_order_and_exact_counts(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q, k, v = make_single_tile_case(1100)
        env.load_qkv(q, k, v)
        status = 0
        await env.start_run(causal=False)
        status = await env.wait_done()
        assert status & STATUS_DONE
        assert (status & STATUS_ERROR) == 0
        assert len(env.rd_desc_log) == TOTAL_RD_DESCS
        assert len(env.wr_desc_log) == TOTAL_WR_DESCS

        for q_blk in range(TOTAL_Q_BLKS):
            base = q_blk * READ_DESC_PER_Q_BLK
            assert env.rd_desc_log[base].tag == RD_TAG_Q
            assert env.rd_desc_log[base].words == 512
            for kv_blk in range(16):
                assert env.rd_desc_log[base + 1 + (2 * kv_blk)].tag == RD_TAG_K
                assert env.rd_desc_log[base + 2 + (2 * kv_blk)].tag == RD_TAG_V
                assert env.rd_desc_log[base + 1 + (2 * kv_blk)].words == 512
                assert env.rd_desc_log[base + 2 + (2 * kv_blk)].words == 512

        for q_blk, wr_desc in enumerate(env.wr_desc_log):
            assert wr_desc.words == 512
            assert wr_desc.addr == env.o_base + (q_blk * 16 * env.stride_bytes)
        env.coverage.hit("dma.descriptor_counts_exact", rd_descs=len(env.rd_desc_log), wr_descs=len(env.wr_desc_log))
        env.coverage.hit("dma.descriptor_order_qkv")
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_protocol_byte_counters_exact(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q, k, v = make_single_tile_case(1110)
        env.load_qkv(q, k, v)
        await env.start_run(causal=True)
        await env.wait_done()
        assert await env.axil_read(ADDR_RD_BYTES) == (TOTAL_CAUSAL_RD_DESCS * BYTES_PER_TILE)
        assert await env.axil_read(ADDR_WR_BYTES) == (TOTAL_WR_DESCS * BYTES_PER_TILE)
        env.coverage.hit("csr.byte_counters_exact")
    finally:
        env.shutdown()


@cocotb.test()
async def test_fa_protocol_no_extra_dma_after_done(dut) -> None:
    env = await create_env(dut)
    try:
        await env.reset()
        q, k, v = make_single_tile_case(1120)
        env.load_qkv(q, k, v)
        await env.start_run(causal=False)
        status = await env.wait_done()
        assert status & STATUS_DONE
        assert (status & STATUS_ERROR) == 0
        rd_count = len(env.rd_desc_log)
        wr_count = len(env.wr_desc_log)
        rd_bytes = await env.axil_read(ADDR_RD_BYTES)
        wr_bytes = await env.axil_read(ADDR_WR_BYTES)
        await ClockCycles(dut.clk, 32)
        assert len(env.rd_desc_log) == rd_count
        assert len(env.wr_desc_log) == wr_count
        assert await env.axil_read(ADDR_RD_BYTES) == rd_bytes
        assert await env.axil_read(ADDR_WR_BYTES) == wr_bytes
        env.coverage.hit("protocol.no_extra_dma_after_done")
    finally:
        env.shutdown()
