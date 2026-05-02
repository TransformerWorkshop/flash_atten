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
    nonzero_row_indices,
    q16_16_from_float,
    random_q88_matrix,
    record_shape_coverage,
    unpack_q88_row_major_words,
    zero_matrix,
)
from tests.fa_functional_coverage import FunctionalCoverageRecorder

AXI_DATA_BYTES = 16
AXI_WORDS_PER_BEAT = AXI_DATA_BYTES // 4
MATRIX_BYTES = SEQ_LEN * HEAD_DIM * 2
MATRIX_WORDS = SEQ_LEN * (HEAD_DIM // 2)


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


def pattern_values(pattern) -> list[int]:
    if isinstance(pattern, ConstantPattern):
        return [pattern.value]
    return list(getattr(pattern, "values", []))


def pattern_has_stall(pattern) -> bool:
    return any(value == 0 for value in pattern_values(pattern))


class FABaselineAxiEnv:
    def __init__(self, dut):
        self.dut = dut
        self.case_name = discover_case_name()
        self.coverage = FunctionalCoverageRecorder(case_name=self.case_name)
        self.seed = 10
        self.rng = random.Random(self.seed)
        self.q_base = 0x0000_1000
        self.k_base = self.q_base + MATRIX_BYTES
        self.v_base = self.k_base + MATRIX_BYTES
        self.o_base = self.v_base + MATRIX_BYTES
        self.stride_bytes = HEAD_DIM * 2
        self.scale_word = q16_16_from_float(1.0 / (HEAD_DIM ** 0.5))
        self.neg_large_word = q16_16_from_float(-64.0)
        self.q_words = [0 for _ in range(MATRIX_WORDS)]
        self.k_words = [0 for _ in range(MATRIX_WORDS)]
        self.v_words = [0 for _ in range(MATRIX_WORDS)]
        self.o_words = [0 for _ in range(MATRIX_WORDS)]
        self.rd_bursts: List[AxiReadBurstLog] = []
        self.wr_bursts: List[AxiWriteBurstLog] = []
        self._agent_error: AssertionError | None = None
        self._started = False
        self._tasks = []
        self._arready_pattern = ConstantPattern(1)
        self._rvalid_pattern = ConstantPattern(1)
        self._awready_pattern = ConstantPattern(1)
        self._wready_pattern = ConstantPattern(1)
        self._bvalid_pattern = ConstantPattern(1)
        self._read_fault_early_last_beat: int | None = None
        self._read_fault_suppress_final_last = False

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
        self.coverage.dump()

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
        self._agent_error = None
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
            if pattern_has_stall(arready):
                self.coverage.hit("axi.read_backpressure", channel="arready", pattern=pattern_values(arready))
        if rvalid is not None:
            self._rvalid_pattern = rvalid
            if pattern_has_stall(rvalid):
                self.coverage.hit("axi.read_backpressure", channel="rvalid", pattern=pattern_values(rvalid))
        if awready is not None:
            self._awready_pattern = awready
            if pattern_has_stall(awready):
                self.coverage.hit("axi.write_backpressure", channel="awready", pattern=pattern_values(awready))
        if wready is not None:
            self._wready_pattern = wready
            if pattern_has_stall(wready):
                self.coverage.hit("axi.write_backpressure", channel="wready", pattern=pattern_values(wready))
        if bvalid is not None:
            self._bvalid_pattern = bvalid
            if pattern_has_stall(bvalid):
                self.coverage.hit("axi.response_backpressure", channel="bvalid", pattern=pattern_values(bvalid))

    def set_read_faults(
        self,
        *,
        early_last_beat: int | None = None,
        suppress_final_last: bool = False,
    ) -> None:
        self._read_fault_early_last_beat = early_last_beat
        self._read_fault_suppress_final_last = bool(suppress_final_last)
        if early_last_beat is not None:
            self.coverage.hit("axi.read_fault_early_last", early_last_beat=early_last_beat)
        if suppress_final_last:
            self.coverage.hit("axi.read_fault_missing_final_last")

    def clear_read_faults(self) -> None:
        self._read_fault_early_last_beat = None
        self._read_fault_suppress_final_last = False

    def load_qkv(self, q_matrix, k_matrix, v_matrix) -> None:
        self.q_words = make_full_memory_words(q_matrix)
        self.k_words = make_full_memory_words(k_matrix)
        self.v_words = make_full_memory_words(v_matrix)
        self.o_words = [0 for _ in range(MATRIX_WORDS)]
        record_shape_coverage(self.coverage, q_matrix, k_matrix, v_matrix)
        if (
            len(nonzero_row_indices(q_matrix)) >= SEQ_LEN
            and len(nonzero_row_indices(k_matrix)) >= SEQ_LEN
            and len(nonzero_row_indices(v_matrix)) >= SEQ_LEN
        ):
            self.coverage.hit("axi.full_sequence")

    async def axil_write(self, addr: int, data: int, wstrb: int = 0xF) -> int:
        self._raise_agent_error_if_any()
        if addr == ADDR_STRIDE_BYTES and data % AXI_DATA_BYTES:
            self.coverage.hit("axi.alignment_error", stride_bytes=data)
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
        self._raise_agent_error_if_any()
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
        self.coverage.hit("csr.programming.basic", causal=causal)
        self.coverage.hit("mode.causal" if causal else "mode.noncausal")
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
        if causal:
            self.coverage.hit("mask.causal_boundary")
        await self.axil_write(ADDR_CTRL, CTRL_IRQ_EN)
        await self.axil_write(ADDR_CTRL, CTRL_IRQ_EN | CTRL_START)
        await self.axil_write(ADDR_CTRL, CTRL_IRQ_EN)

    async def soft_reset(self) -> None:
        self.coverage.hit("csr.soft_reset")
        self.coverage.hit("axi.soft_reset_mid_transfer")
        await self.axil_write(ADDR_CTRL, CTRL_IRQ_EN | CTRL_SOFT_RESET)
        await self.axil_write(ADDR_CTRL, CTRL_IRQ_EN)

    async def wait_done(self, timeout_cycles: int = 800000) -> int:
        for _ in range(timeout_cycles):
            self._raise_agent_error_if_any()
            status = await self.axil_read(ADDR_STATUS)
            if status & STATUS_DONE:
                self.coverage.hit("csr.start_done", status=status)
                self._record_axi_burst_coverage()
                return status
            if status & STATUS_ERROR:
                return status
            await RisingEdge(self.dut.clk)
        raise AssertionError("run timeout")

    async def wait_busy(self, expected: bool, timeout_cycles: int = 4000) -> None:
        for _ in range(timeout_cycles):
            self._raise_agent_error_if_any()
            status = await self.axil_read(ADDR_STATUS)
            if bool(status & STATUS_BUSY) == expected:
                return
            await RisingEdge(self.dut.clk)
        raise AssertionError(f"busy did not become {expected}")

    def read_output_matrix(self):
        return unpack_q88_row_major_words(self.o_words, SEQ_LEN, HEAD_DIM)

    def _record_axi_burst_coverage(self) -> None:
        if self.rd_bursts:
            self.coverage.hit("axi.read_burst", bursts=len(self.rd_bursts))
        if self.wr_bursts:
            self.coverage.hit("axi.write_burst", bursts=len(self.wr_bursts))
        if any(burst.beats == 16 for burst in self.rd_bursts):
            self.coverage.hit("axi.max_read_burst")
        if any(burst.beats == 16 for burst in self.wr_bursts):
            self.coverage.hit("axi.max_write_burst")

    def _agent_assert(self, condition: bool, message: str) -> None:
        if condition:
            return
        exc = AssertionError(message)
        self._agent_error = exc
        raise exc

    def _raise_agent_error_if_any(self) -> None:
        if self._agent_error is not None:
            raise AssertionError(f"AXI memory agent failed: {self._agent_error}") from self._agent_error

    def _check_axi_read_request(self, addr: int, beats: int) -> None:
        arsize = value_to_int(self.dut.m_axi_arsize.value)
        arburst = value_to_int(self.dut.m_axi_arburst.value)
        self._agent_assert(1 <= beats <= 16, f"AXI read burst beats out of range: {beats}")
        self._agent_assert(arsize == 4, f"AXI read arsize={arsize}, expected 4 for 128-bit beats")
        self._agent_assert(arburst == 1, f"AXI read arburst={arburst}, expected INCR")
        self._agent_assert((addr % AXI_DATA_BYTES) == 0, f"AXI read addr 0x{addr:x} is not 16-byte aligned")

    def _check_axi_write_request(self, addr: int, beats: int) -> None:
        awsize = value_to_int(self.dut.m_axi_awsize.value)
        awburst = value_to_int(self.dut.m_axi_awburst.value)
        self._agent_assert(1 <= beats <= 16, f"AXI write burst beats out of range: {beats}")
        self._agent_assert(awsize == 4, f"AXI write awsize={awsize}, expected 4 for 128-bit beats")
        self._agent_assert(awburst == 1, f"AXI write awburst={awburst}, expected INCR")
        self._agent_assert((addr % AXI_DATA_BYTES) == 0, f"AXI write addr 0x{addr:x} is not 16-byte aligned")

    def _select_read_memory(self, addr: int, beats: int):
        if self.q_base <= addr < self.k_base:
            mem = self.q_words
            base = self.q_base
            region = "Q"
        elif self.k_base <= addr < self.v_base:
            mem = self.k_words
            base = self.k_base
            region = "K"
        elif self.v_base <= addr < self.o_base:
            mem = self.v_words
            base = self.v_base
            region = "V"
        else:
            self._agent_assert(False, f"AXI read addr 0x{addr:x} outside Q/K/V regions")

        word_base = (addr - base) // 4
        word_count = beats * AXI_WORDS_PER_BEAT
        self._agent_assert(word_base + word_count <= len(mem), (
            f"AXI read {region} burst overruns memory: addr=0x{addr:x} beats={beats}"
        ))
        return mem, word_base

    def _select_write_memory(self, addr: int, beats: int) -> int:
        if not (self.o_base <= addr < self.o_base + MATRIX_BYTES):
            self._agent_assert(False, f"AXI write addr 0x{addr:x} outside O region")
        word_base = (addr - self.o_base) // 4
        word_count = beats * AXI_WORDS_PER_BEAT
        self._agent_assert(word_base + word_count <= len(self.o_words), (
            f"AXI write burst overruns O memory: addr=0x{addr:x} beats={beats}"
        ))
        return word_base

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
                    self._check_axi_read_request(addr, beats)
                    mem, word_base = self._select_read_memory(addr, beats)
                    active = (addr, beats, mem, word_base)
                    beat_idx = 0
                    beat_valid = False
                    self.rd_bursts.append(AxiReadBurstLog(addr=addr, beats=beats))
            else:
                base_addr, beats, mem, word_base = active
                if beat_valid and value_to_int(self.dut.m_axi_rready.value):
                    beat_idx += 1
                    beat_valid = False
                    if beat_idx >= beats:
                        active = None
                if active is not None and not beat_valid and self._rvalid_pattern.next():
                    beat_data = 0
                    for lane in range(AXI_WORDS_PER_BEAT):
                        beat_data |= (mem[word_base + (beat_idx * AXI_WORDS_PER_BEAT) + lane] & 0xFFFF_FFFF) << (lane * 32)
                    normal_last = (beat_idx + 1) == beats
                    fault_early_last = (
                        self._read_fault_early_last_beat is not None
                        and beat_idx == self._read_fault_early_last_beat
                        and not normal_last
                    )
                    fault_missing_last = self._read_fault_suppress_final_last and normal_last
                    self.dut.m_axi_rdata.value = beat_data
                    self.dut.m_axi_rresp.value = 0
                    self.dut.m_axi_rlast.value = int((normal_last and not fault_missing_last) or fault_early_last)
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
            if bvalid_pending and value_to_int(self.dut.m_axi_bvalid.value) and value_to_int(self.dut.m_axi_bready.value):
                bvalid_pending = False
                self.dut.m_axi_bvalid.value = 0
            elif not bvalid_pending:
                self.dut.m_axi_bvalid.value = 0
            if active is None and value_to_int(self.dut.m_axi_awvalid.value) and value_to_int(self.dut.m_axi_awready.value):
                addr = value_to_int(self.dut.m_axi_awaddr.value)
                beats = value_to_int(self.dut.m_axi_awlen.value) + 1
                self._check_axi_write_request(addr, beats)
                word_base = self._select_write_memory(addr, beats)
                active = (addr, beats, word_base)
                beat_idx = 0
                self.wr_bursts.append(AxiWriteBurstLog(addr=addr, beats=beats))

            if active is not None:
                base_addr, beats, word_base = active
                if value_to_int(self.dut.m_axi_wvalid.value) and value_to_int(self.dut.m_axi_wready.value):
                    beat_data = value_to_int(self.dut.m_axi_wdata.value)
                    expected_last = (beat_idx + 1) == beats
                    actual_last = bool(value_to_int(self.dut.m_axi_wlast.value))
                    self._agent_assert(actual_last == expected_last, (
                        f"AXI WLAST mismatch at addr=0x{base_addr:x} beat={beat_idx} "
                        f"beats={beats} actual={int(actual_last)}"
                    ))
                    beat_word_base = word_base + (beat_idx * AXI_WORDS_PER_BEAT)
                    for lane in range(AXI_WORDS_PER_BEAT):
                        self.o_words[beat_word_base + lane] = (beat_data >> (lane * 32)) & 0xFFFF_FFFF
                    beat_idx += 1
                    if expected_last:
                        active = None
                        bvalid_pending = True
                        self.dut.m_axi_bresp.value = 0
            if bvalid_pending and not value_to_int(self.dut.m_axi_bvalid.value):
                self.dut.m_axi_bvalid.value = 1 if self._bvalid_pattern.next() else 0


async def create_env(dut) -> FABaselineAxiEnv:
    env = FABaselineAxiEnv(dut)
    await env.start()
    return env
