from __future__ import annotations

import inspect
import os
import random
from dataclasses import dataclass
from typing import List, Sequence

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from tests.fa_baseline_env import (
    ADDR_CTRL,
    ADDR_CFG,
    ADDR_CYCLES,
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
    CTRL_SOFT_RESET,
    CTRL_START,
    HEAD_DIM,
    SEQ_LEN,
    STATUS_BUSY,
    STATUS_DONE,
    STATUS_ERROR,
    attention_golden,
    make_full_memory_words,
    matrix_error,
    q16_16_from_float,
    random_q88_matrix,
    unpack_q88_row_major_words,
    zero_matrix,
)


def discover_case_name() -> str:
    for frame_info in inspect.stack():
        if frame_info.function.startswith("test_"):
            return frame_info.function
    return os.getenv("COCOTB_TESTCASE", "unknown_test")


def value_to_int(value, default: int = 0) -> int:
    is_resolvable = getattr(value, "is_resolvable", True)
    return int(value) if is_resolvable else default


@dataclass
class AxiReadBurstLog:
    addr: int
    beats: int


@dataclass
class AxiWriteBurstLog:
    addr: int
    beats: int


class ConstantPattern:
    def __init__(self, value: int):
        self.value = 1 if value else 0

    def next(self) -> int:
        return self.value


class SequencePattern:
    def __init__(self, values: Sequence[int], hold_last: bool = True):
        self.values = [1 if value else 0 for value in values]
        self.hold_last = hold_last
        self.index = 0

    def next(self) -> int:
        if not self.values:
            return 1
        if self.index < len(self.values):
            value = self.values[self.index]
            self.index += 1
            return value
        return self.values[-1] if self.hold_last else self.values[(self.index - len(self.values)) % len(self.values)]


class FABaselineAxiEnv:
    def __init__(self, dut):
        self.dut = dut
        self.case_name = discover_case_name()
        self.seed = 10
        self.rng = random.Random(self.seed)
        self.q_base = 0x0000_1000
        self.k_base = 0x0000_3000
        self.v_base = 0x0000_5000
        self.o_base = 0x0000_7000
        self.stride_bytes = 16 * 4
        self.scale_word = q16_16_from_float(1.0 / (HEAD_DIM ** 0.5))
        self.neg_large_word = q16_16_from_float(-64.0)
        self.q_words = [0 for _ in range(SEQ_LEN * 32)]
        self.k_words = [0 for _ in range(SEQ_LEN * 32)]
        self.v_words = [0 for _ in range(SEQ_LEN * 32)]
        self.o_words = [0 for _ in range(SEQ_LEN * 32)]
        self.rd_bursts: List[AxiReadBurstLog] = []
        self.wr_bursts: List[AxiWriteBurstLog] = []
        self._started = False
        self._tasks = []
        self._arready_pattern = ConstantPattern(1)
        self._rvalid_pattern = ConstantPattern(1)
        self._awready_pattern = ConstantPattern(1)
        self._wready_pattern = ConstantPattern(1)
        self._bvalid_pattern = ConstantPattern(1)

    async def start(self) -> None:
        if self._started:
            return
        self._started = True
        self._drive_defaults()
        self._tasks = [
            cocotb.start_soon(Clock(self.dut.clk, 10, unit="ns").start()),
            cocotb.start_soon(self._axi_read_agent()),
            cocotb.start_soon(self._axi_write_agent()),
        ]

    def shutdown(self) -> None:
        self._drive_defaults()
        for task in self._tasks:
            try:
                task.cancel()
            except Exception:
                pass
        self._tasks = []
        self._started = False

    def _drive_defaults(self) -> None:
        self.dut.rstn.value = 0
        self.dut.clear.value = 0
        self.dut.s_axil_awaddr.value = 0
        self.dut.s_axil_awvalid.value = 0
        self.dut.s_axil_wdata.value = 0
        self.dut.s_axil_wstrb.value = 0
        self.dut.s_axil_wvalid.value = 0
        self.dut.s_axil_bready.value = 0
        self.dut.s_axil_araddr.value = 0
        self.dut.s_axil_arvalid.value = 0
        self.dut.s_axil_rready.value = 0
        self.dut.m_axi_arready.value = 1
        self.dut.m_axi_rdata.value = 0
        self.dut.m_axi_rresp.value = 0
        self.dut.m_axi_rlast.value = 0
        self.dut.m_axi_rvalid.value = 0
        self.dut.m_axi_awready.value = 1
        self.dut.m_axi_wready.value = 1
        self.dut.m_axi_bresp.value = 0
        self.dut.m_axi_bvalid.value = 0

    async def reset(self, cycles: int = 5) -> None:
        self._drive_defaults()
        await ClockCycles(self.dut.clk, cycles)
        self.dut.rstn.value = 1
        await ClockCycles(self.dut.clk, cycles)

    def set_axi_patterns(
        self,
        *,
        arready=None,
        rvalid=None,
        awready=None,
        wready=None,
        bvalid=None,
    ) -> None:
        if arready is not None:
            self._arready_pattern = arready
        if rvalid is not None:
            self._rvalid_pattern = rvalid
        if awready is not None:
            self._awready_pattern = awready
        if wready is not None:
            self._wready_pattern = wready
        if bvalid is not None:
            self._bvalid_pattern = bvalid

    def load_qkv(self, q_matrix, k_matrix, v_matrix) -> None:
        self.q_words = make_full_memory_words(q_matrix)
        self.k_words = make_full_memory_words(k_matrix)
        self.v_words = make_full_memory_words(v_matrix)
        self.o_words = [0 for _ in range(SEQ_LEN * 32)]

    async def axil_write(self, addr: int, data: int, wstrb: int = 0xF) -> int:
        self.dut.s_axil_awaddr.value = addr & 0x7F
        self.dut.s_axil_awvalid.value = 1
        self.dut.s_axil_wdata.value = data & 0xFFFF_FFFF
        self.dut.s_axil_wstrb.value = wstrb & 0xF
        self.dut.s_axil_wvalid.value = 1
        self.dut.s_axil_bready.value = 1
        for _ in range(400):
            await RisingEdge(self.dut.clk)
            if value_to_int(self.dut.s_axil_awready.value) and value_to_int(self.dut.s_axil_wready.value):
                self.dut.s_axil_awvalid.value = 0
                self.dut.s_axil_wvalid.value = 0
                break
        for _ in range(400):
            await RisingEdge(self.dut.clk)
            if value_to_int(self.dut.s_axil_bvalid.value):
                resp = value_to_int(self.dut.s_axil_bresp.value)
                await RisingEdge(self.dut.clk)
                self.dut.s_axil_bready.value = 0
                return resp
        raise AssertionError("AXI-Lite write timeout")

    async def axil_read(self, addr: int) -> int:
        self.dut.s_axil_araddr.value = addr & 0x7F
        self.dut.s_axil_arvalid.value = 1
        self.dut.s_axil_rready.value = 1
        for _ in range(400):
            await RisingEdge(self.dut.clk)
            if value_to_int(self.dut.s_axil_arready.value):
                self.dut.s_axil_arvalid.value = 0
                break
        for _ in range(400):
            await RisingEdge(self.dut.clk)
            if value_to_int(self.dut.s_axil_rvalid.value):
                data = value_to_int(self.dut.s_axil_rdata.value)
                await RisingEdge(self.dut.clk)
                self.dut.s_axil_rready.value = 0
                return data
        raise AssertionError("AXI-Lite read timeout")

    async def program_common_regs(self, *, causal: bool) -> None:
        await self.axil_write(ADDR_Q_BASE_L, self.q_base & 0xFFFF_FFFF)
        await self.axil_write(ADDR_Q_BASE_H, (self.q_base >> 32) & 0xFFFF_FFFF)
        await self.axil_write(ADDR_K_BASE_L, self.k_base & 0xFFFF_FFFF)
        await self.axil_write(ADDR_K_BASE_H, (self.k_base >> 32) & 0xFFFF_FFFF)
        await self.axil_write(ADDR_V_BASE_L, self.v_base & 0xFFFF_FFFF)
        await self.axil_write(ADDR_V_BASE_H, (self.v_base >> 32) & 0xFFFF_FFFF)
        await self.axil_write(ADDR_O_BASE_L, self.o_base & 0xFFFF_FFFF)
        await self.axil_write(ADDR_O_BASE_H, (self.o_base >> 32) & 0xFFFF_FFFF)
        await self.axil_write(ADDR_STRIDE_BYTES, self.stride_bytes)
        await self.axil_write(ADDR_NEG_LARGE, self.neg_large_word & 0xFFFF_FFFF)
        await self.axil_write(ADDR_SCALE, self.scale_word & 0xFFFF_FFFF)
        await self.axil_write(ADDR_CFG, CFG_CAUSAL_EN if causal else 0)

    async def start_run(self, *, causal: bool) -> None:
        await self.program_common_regs(causal=causal)
        await self.axil_write(ADDR_CTRL, CTRL_IRQ_EN)
        await self.axil_write(ADDR_CTRL, CTRL_IRQ_EN | CTRL_START)
        await self.axil_write(ADDR_CTRL, CTRL_IRQ_EN)

    async def soft_reset(self) -> None:
        await self.axil_write(ADDR_CTRL, CTRL_IRQ_EN | CTRL_SOFT_RESET)
        await self.axil_write(ADDR_CTRL, CTRL_IRQ_EN)

    async def wait_done(self, timeout_cycles: int = 800000) -> int:
        for _ in range(timeout_cycles):
            status = await self.axil_read(ADDR_STATUS)
            if status & STATUS_DONE:
                return status
            if status & STATUS_ERROR:
                return status
            await RisingEdge(self.dut.clk)
        raise AssertionError("run timeout")

    def read_output_matrix(self):
        return unpack_q88_row_major_words(self.o_words, SEQ_LEN, HEAD_DIM)

    async def _axi_read_agent(self) -> None:
        active = None
        beat_idx = 0
        beat_valid = False
        beat_data = 0
        while True:
            await RisingEdge(self.dut.clk)
            self.dut.m_axi_arready.value = self._arready_pattern.next()
            if active is None:
                self.dut.m_axi_rvalid.value = 0
                self.dut.m_axi_rlast.value = 0
                if value_to_int(self.dut.m_axi_arvalid.value) and value_to_int(self.dut.m_axi_arready.value):
                    addr = value_to_int(self.dut.m_axi_araddr.value)
                    beats = value_to_int(self.dut.m_axi_arlen.value) + 1
                    active = (addr, beats)
                    beat_idx = 0
                    beat_valid = False
                    self.rd_bursts.append(AxiReadBurstLog(addr=addr, beats=beats))
            else:
                base_addr, beats = active
                if beat_valid and value_to_int(self.dut.m_axi_rready.value):
                    beat_idx += 1
                    beat_valid = False
                    if beat_idx >= beats:
                        active = None
                if active is not None and not beat_valid and self._rvalid_pattern.next():
                    word_base = ((base_addr - self.q_base) // 4)
                    if self.q_base <= base_addr < self.k_base:
                        mem = self.q_words
                    elif self.k_base <= base_addr < self.v_base:
                        mem = self.k_words
                        word_base = ((base_addr - self.k_base) // 4)
                    elif self.v_base <= base_addr < self.o_base:
                        mem = self.v_words
                        word_base = ((base_addr - self.v_base) // 4)
                    else:
                        mem = [0] * (SEQ_LEN * 32)
                        word_base = 0
                    beat_data = 0
                    for lane in range(4):
                        beat_data |= (mem[word_base + (beat_idx * 4) + lane] & 0xFFFF_FFFF) << (lane * 32)
                    self.dut.m_axi_rdata.value = beat_data
                    self.dut.m_axi_rresp.value = 0
                    self.dut.m_axi_rlast.value = int((beat_idx + 1) == beats)
                    self.dut.m_axi_rvalid.value = 1
                    beat_valid = True
                elif active is not None and not beat_valid:
                    self.dut.m_axi_rvalid.value = 0
                    self.dut.m_axi_rlast.value = 0

    async def _axi_write_agent(self) -> None:
        active = None
        beat_idx = 0
        bvalid_pending = False
        while True:
            await RisingEdge(self.dut.clk)
            self.dut.m_axi_awready.value = self._awready_pattern.next()
            self.dut.m_axi_wready.value = self._wready_pattern.next()
            if not bvalid_pending:
                self.dut.m_axi_bvalid.value = 0
            if active is None:
                if value_to_int(self.dut.m_axi_awvalid.value) and value_to_int(self.dut.m_axi_awready.value):
                    addr = value_to_int(self.dut.m_axi_awaddr.value)
                    beats = value_to_int(self.dut.m_axi_awlen.value) + 1
                    active = (addr, beats)
                    beat_idx = 0
                    self.wr_bursts.append(AxiWriteBurstLog(addr=addr, beats=beats))
            else:
                base_addr, beats = active
                if value_to_int(self.dut.m_axi_wvalid.value) and value_to_int(self.dut.m_axi_wready.value):
                    beat_data = value_to_int(self.dut.m_axi_wdata.value)
                    word_base = ((base_addr - self.o_base) // 4) + (beat_idx * 4)
                    for lane in range(4):
                        self.o_words[word_base + lane] = (beat_data >> (lane * 32)) & 0xFFFF_FFFF
                    beat_idx += 1
                    if value_to_int(self.dut.m_axi_wlast.value):
                        active = None
                        bvalid_pending = True
                        self.dut.m_axi_bresp.value = 0
            if bvalid_pending and self._bvalid_pattern.next():
                self.dut.m_axi_bvalid.value = 1
                if value_to_int(self.dut.m_axi_bready.value):
                    self.dut.m_axi_bvalid.value = 0
                    bvalid_pending = False


async def create_env(dut) -> FABaselineAxiEnv:
    env = FABaselineAxiEnv(dut)
    await env.start()
    return env
