from __future__ import annotations

import inspect
import math
import os
import random
from dataclasses import dataclass
from typing import List, Sequence

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge


ADDR_CTRL = 0x00
ADDR_STATUS = 0x04
ADDR_CFG = 0x08
ADDR_Q_BASE_L = 0x14
ADDR_Q_BASE_H = 0x18
ADDR_K_BASE_L = 0x1C
ADDR_K_BASE_H = 0x20
ADDR_V_BASE_L = 0x24
ADDR_V_BASE_H = 0x28
ADDR_O_BASE_L = 0x2C
ADDR_O_BASE_H = 0x30
ADDR_STRIDE_BYTES = 0x34
ADDR_NEG_LARGE = 0x38
ADDR_SCALE = 0x3C
ADDR_CYCLES = 0x40
ADDR_RD_BYTES = 0x44
ADDR_WR_BYTES = 0x48

CTRL_START = 1 << 0
CTRL_SOFT_RESET = 1 << 1
CTRL_IRQ_EN = 1 << 2
CFG_CAUSAL_EN = 1 << 0

STATUS_BUSY = 1 << 0
STATUS_DONE = 1 << 1
STATUS_ERROR = 1 << 2

RD_TAG_Q = 0x1
RD_TAG_K = 0x2
RD_TAG_V = 0x3

SEQ_LEN = 256
HEAD_DIM = 64
TILE_ROWS = 16
WORDS_PER_ROW = 32
WORDS_PER_TILE = 512


def discover_case_name() -> str:
    for frame_info in inspect.stack():
        if frame_info.function.startswith("test_"):
            return frame_info.function
    return os.getenv("COCOTB_TESTCASE", "unknown_test")


def value_to_int(value, default: int = 0) -> int:
    is_resolvable = getattr(value, "is_resolvable", True)
    return int(value) if is_resolvable else default


def q88_from_float(value: float) -> int:
    scaled = int(round(value * 256.0))
    if scaled > 32767:
        return 32767
    if scaled < -32768:
        return -32768
    return scaled


def q88_to_float(raw: int) -> float:
    raw &= 0xFFFF
    if raw & 0x8000:
        raw -= 0x10000
    return raw / 256.0


def q16_16_from_float(value: float) -> int:
    scaled = int(round(value * 65536.0))
    if scaled > 0x7FFF_FFFF:
        return 0x7FFF_FFFF
    if scaled < -0x8000_0000:
        return -0x8000_0000
    return scaled


def q16_16_to_float(raw: int) -> float:
    raw &= 0xFFFF_FFFF
    if raw & 0x8000_0000:
        raw -= 0x1_0000_0000
    return raw / 65536.0


def pack_q88_row_major_words(matrix: Sequence[Sequence[float]]) -> List[int]:
    rows = len(matrix)
    cols = len(matrix[0]) if matrix else 0
    if cols != HEAD_DIM:
        raise ValueError(f"expected cols={HEAD_DIM}, got {cols}")
    words: List[int] = []
    for row_idx in range(rows):
        for col_idx in range(0, cols, 2):
            lo = q88_from_float(matrix[row_idx][col_idx]) & 0xFFFF
            hi = q88_from_float(matrix[row_idx][col_idx + 1]) & 0xFFFF
            words.append(lo | (hi << 16))
    return words


def unpack_q88_row_major_words(words: Sequence[int], rows: int, cols: int) -> List[List[float]]:
    result: List[List[float]] = [[0.0 for _ in range(cols)] for _ in range(rows)]
    word_idx = 0
    for row_idx in range(rows):
        for col_idx in range(0, cols, 2):
            word = int(words[word_idx]) & 0xFFFF_FFFF
            result[row_idx][col_idx] = q88_to_float(word & 0xFFFF)
            result[row_idx][col_idx + 1] = q88_to_float((word >> 16) & 0xFFFF)
            word_idx += 1
    return result


def make_full_memory_words(matrix: Sequence[Sequence[float]]) -> List[int]:
    if len(matrix) != SEQ_LEN:
        raise ValueError(f"expected {SEQ_LEN} rows, got {len(matrix)}")
    return pack_q88_row_major_words(matrix)


def zero_matrix(rows: int, cols: int) -> List[List[float]]:
    return [[0.0 for _ in range(cols)] for _ in range(rows)]


def random_q88_matrix(rows: int, cols: int, seed: int, amplitude: int = 96) -> List[List[float]]:
    rng = random.Random(seed)
    result: List[List[float]] = []
    for _ in range(rows):
        row: List[float] = []
        for _ in range(cols):
            raw = rng.randint(-amplitude, amplitude)
            row.append(raw / 256.0)
        result.append(row)
    return result


def attention_golden(
    q_matrix: Sequence[Sequence[float]],
    k_matrix: Sequence[Sequence[float]],
    v_matrix: Sequence[Sequence[float]],
    *,
    scale: float,
    causal: bool,
) -> List[List[float]]:
    out = zero_matrix(SEQ_LEN, HEAD_DIM)
    for qi in range(SEQ_LEN):
        scores: List[float] = []
        for kj in range(SEQ_LEN):
            if causal and kj > qi:
                scores.append(-1.0e30)
                continue
            dot = 0.0
            for dim in range(HEAD_DIM):
                dot += q_matrix[qi][dim] * k_matrix[kj][dim]
            scores.append(dot * scale)
        row_max = max(scores)
        exp_scores: List[float] = []
        exp_sum = 0.0
        for score in scores:
            if score <= -1.0e20:
                exp_scores.append(0.0)
            else:
                val = math.exp(score - row_max)
                exp_scores.append(val)
                exp_sum += val
        if exp_sum == 0.0:
            continue
        for kj in range(SEQ_LEN):
            prob = exp_scores[kj] / exp_sum
            if prob == 0.0:
                continue
            for dim in range(HEAD_DIM):
                out[qi][dim] += prob * v_matrix[kj][dim]
    return out


def matrix_error(actual: Sequence[Sequence[float]], expected: Sequence[Sequence[float]]) -> tuple[float, float]:
    total = 0.0
    count = 0
    worst = 0.0
    for row_idx in range(len(actual)):
        for col_idx in range(len(actual[row_idx])):
            err = abs(actual[row_idx][col_idx] - expected[row_idx][col_idx])
            total += err
            count += 1
            if err > worst:
                worst = err
    return (total / max(count, 1), worst)


@dataclass
class ReadDescLog:
    addr: int
    words: int
    tag: int


@dataclass
class WriteDescLog:
    addr: int
    words: int


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


class FABaselineEnv:
    def __init__(self, dut):
        self.dut = dut
        self.case_name = discover_case_name()
        self.ctrl_shadow = CTRL_IRQ_EN
        self.rd_desc_log: List[ReadDescLog] = []
        self.wr_desc_log: List[WriteDescLog] = []
        self.q_base = 0x0000_1000
        self.k_base = 0x0000_3000
        self.v_base = 0x0000_5000
        self.o_base = 0x0000_7000
        self.stride_bytes = HEAD_DIM * 2
        self.scale_word = q16_16_from_float(1.0 / math.sqrt(HEAD_DIM))
        self.neg_large_word = q16_16_from_float(-64.0)
        self.q_words = [0 for _ in range(SEQ_LEN * WORDS_PER_ROW)]
        self.k_words = [0 for _ in range(SEQ_LEN * WORDS_PER_ROW)]
        self.v_words = [0 for _ in range(SEQ_LEN * WORDS_PER_ROW)]
        self.o_words = [0 for _ in range(SEQ_LEN * WORDS_PER_ROW)]
        self._started = False
        self._tasks = []
        self._rd_desc_ready_pattern = ConstantPattern(1)
        self._rd_data_valid_pattern = ConstantPattern(1)
        self._wr_desc_ready_pattern = ConstantPattern(1)
        self._wr_data_ready_pattern = ConstantPattern(1)
        self._rd_active = None
        self._wr_active = None
        self._rd_fault_early_last_word: int | None = None
        self._rd_fault_suppress_final_last = False

    async def start(self) -> None:
        if self._started:
            return
        self._started = True
        self._drive_defaults()
        self._tasks = [
            cocotb.start_soon(Clock(self.dut.clk, 10, unit="ns").start()),
            cocotb.start_soon(self._rd_dma_agent()),
            cocotb.start_soon(self._wr_dma_agent()),
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
        self.dut.rd_desc_ready.value = 1
        self.dut.rd_data_valid.value = 0
        self.dut.rd_data.value = 0
        self.dut.rd_data_last.value = 0
        self.dut.wr_desc_ready.value = 1
        self.dut.wr_data_ready.value = 1

    async def reset(self, cycles: int = 5) -> None:
        self._drive_defaults()
        self._abort_dma_agents()
        await ClockCycles(self.dut.clk, cycles)
        self.dut.rstn.value = 1
        await ClockCycles(self.dut.clk, cycles)

    def _abort_dma_agents(self) -> None:
        self._rd_active = None
        self._wr_active = None
        self.dut.rd_data_valid.value = 0
        self.dut.rd_data_last.value = 0
        self.dut.wr_data_ready.value = 1

    def set_read_patterns(
        self,
        *,
        desc_ready: ConstantPattern | SequencePattern | None = None,
        data_valid: ConstantPattern | SequencePattern | None = None,
    ) -> None:
        if desc_ready is not None:
            self._rd_desc_ready_pattern = desc_ready
        if data_valid is not None:
            self._rd_data_valid_pattern = data_valid

    def set_write_patterns(
        self,
        *,
        desc_ready: ConstantPattern | SequencePattern | None = None,
        data_ready: ConstantPattern | SequencePattern | None = None,
    ) -> None:
        if desc_ready is not None:
            self._wr_desc_ready_pattern = desc_ready
        if data_ready is not None:
            self._wr_data_ready_pattern = data_ready

    def set_read_faults(
        self,
        *,
        early_last_word: int | None = None,
        suppress_final_last: bool = False,
    ) -> None:
        self._rd_fault_early_last_word = early_last_word
        self._rd_fault_suppress_final_last = suppress_final_last

    def clear_read_faults(self) -> None:
        self._rd_fault_early_last_word = None
        self._rd_fault_suppress_final_last = False

    def load_qkv(
        self,
        q_matrix: Sequence[Sequence[float]],
        k_matrix: Sequence[Sequence[float]],
        v_matrix: Sequence[Sequence[float]],
    ) -> None:
        self.q_words = make_full_memory_words(q_matrix)
        self.k_words = make_full_memory_words(k_matrix)
        self.v_words = make_full_memory_words(v_matrix)
        self.o_words = [0 for _ in range(SEQ_LEN * WORDS_PER_ROW)]

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
        else:
            raise AssertionError(f"AXI-Lite write handshake timeout at 0x{addr:02x}")
        for _ in range(400):
            await RisingEdge(self.dut.clk)
            if value_to_int(self.dut.s_axil_bvalid.value):
                resp = value_to_int(self.dut.s_axil_bresp.value)
                await RisingEdge(self.dut.clk)
                self.dut.s_axil_bready.value = 0
                return resp
        raise AssertionError(f"AXI-Lite write response timeout at 0x{addr:02x}")

    async def axil_read(self, addr: int) -> int:
        self.dut.s_axil_araddr.value = addr & 0x7F
        self.dut.s_axil_arvalid.value = 1
        self.dut.s_axil_rready.value = 1
        for _ in range(400):
            await RisingEdge(self.dut.clk)
            if value_to_int(self.dut.s_axil_arready.value):
                self.dut.s_axil_arvalid.value = 0
                break
        else:
            raise AssertionError(f"AXI-Lite read address timeout at 0x{addr:02x}")
        for _ in range(400):
            await RisingEdge(self.dut.clk)
            if value_to_int(self.dut.s_axil_rvalid.value):
                data = value_to_int(self.dut.s_axil_rdata.value)
                await RisingEdge(self.dut.clk)
                self.dut.s_axil_rready.value = 0
                return data
        raise AssertionError(f"AXI-Lite read data timeout at 0x{addr:02x}")

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
        self.ctrl_shadow = CTRL_IRQ_EN
        await self.axil_write(ADDR_CTRL, self.ctrl_shadow)
        await self.axil_write(ADDR_CTRL, self.ctrl_shadow | CTRL_START)
        await self.axil_write(ADDR_CTRL, self.ctrl_shadow)

    async def soft_reset(self) -> None:
        self.ctrl_shadow = CTRL_IRQ_EN
        await self.axil_write(ADDR_CTRL, self.ctrl_shadow | CTRL_SOFT_RESET)
        await self.axil_write(ADDR_CTRL, self.ctrl_shadow)
        self._abort_dma_agents()

    async def wait_busy(self, expected: bool, timeout_cycles: int = 4000) -> None:
        for _ in range(timeout_cycles):
            status = await self.axil_read(ADDR_STATUS)
            if bool(status & STATUS_BUSY) == expected:
                return
            await RisingEdge(self.dut.clk)
        raise AssertionError(f"busy did not become {expected}")

    async def wait_done(self, timeout_cycles: int = 600000) -> int:
        for _ in range(timeout_cycles):
            status = await self.axil_read(ADDR_STATUS)
            if status & STATUS_DONE:
                return status
            if status & STATUS_ERROR:
                raise AssertionError(f"run hit error status=0x{status:08x}")
            await RisingEdge(self.dut.clk)
        raise AssertionError("run did not finish before timeout")

    def read_output_matrix(self) -> List[List[float]]:
        return unpack_q88_row_major_words(self.o_words, SEQ_LEN, HEAD_DIM)

    async def _rd_dma_agent(self) -> None:
        active_kind = 0
        active_addr = 0
        active_words = 0
        word_offset = 0
        valid_held = False
        last_held = False
        self.dut.rd_desc_ready.value = 1
        self.dut.rd_data_valid.value = 0
        self.dut.rd_data_last.value = 0
        while True:
            await RisingEdge(self.dut.clk)
            if active_words == 0:
                if value_to_int(self.dut.rd_desc_valid.value) and value_to_int(self.dut.rd_desc_ready.value):
                    active_addr = value_to_int(self.dut.rd_desc_addr.value)
                    active_words = value_to_int(self.dut.rd_desc_words.value)
                    active_kind = value_to_int(self.dut.rd_desc_tag.value)
                    word_offset = 0
                    valid_held = False
                    last_held = False
                    self.rd_desc_log.append(ReadDescLog(addr=active_addr, words=active_words, tag=active_kind))
            else:
                if value_to_int(self.dut.rd_data_valid.value) and value_to_int(self.dut.rd_data_ready.value):
                    sent_last = last_held
                    word_offset += 1
                    valid_held = False
                    last_held = False
                    if sent_last or word_offset >= active_words:
                        active_words = 0

            self.dut.rd_desc_ready.value = self._rd_desc_ready_pattern.next()
            if active_words == 0:
                self.dut.rd_data_valid.value = 0
                self.dut.rd_data_last.value = 0
            else:
                source_words = self.q_words if active_kind == RD_TAG_Q else self.k_words if active_kind == RD_TAG_K else self.v_words
                base_addr = self.q_base if active_kind == RD_TAG_Q else self.k_base if active_kind == RD_TAG_K else self.v_base
                start_word = (active_addr - base_addr) // 4
                if not valid_held:
                    valid_held = bool(self._rd_data_valid_pattern.next())
                self.dut.rd_data_valid.value = 1 if valid_held else 0
                if valid_held:
                    is_final_word = word_offset == (active_words - 1)
                    emit_last = is_final_word
                    if self._rd_fault_early_last_word is not None and word_offset == self._rd_fault_early_last_word:
                        emit_last = True
                    if is_final_word and self._rd_fault_suppress_final_last:
                        emit_last = False
                    last_held = emit_last
                    self.dut.rd_data.value = source_words[start_word + word_offset]
                    self.dut.rd_data_last.value = int(emit_last)
                else:
                    self.dut.rd_data_last.value = 0

    async def _wr_dma_agent(self) -> None:
        active_addr = 0
        active_words = 0
        word_offset = 0
        self.dut.wr_desc_ready.value = 1
        self.dut.wr_data_ready.value = 1
        while True:
            await RisingEdge(self.dut.clk)
            if active_words == 0:
                if value_to_int(self.dut.wr_desc_valid.value) and value_to_int(self.dut.wr_desc_ready.value):
                    active_addr = value_to_int(self.dut.wr_desc_addr.value)
                    active_words = value_to_int(self.dut.wr_desc_words.value)
                    word_offset = 0
                    self.wr_desc_log.append(WriteDescLog(addr=active_addr, words=active_words))
            else:
                if value_to_int(self.dut.wr_data_valid.value) and value_to_int(self.dut.wr_data_ready.value):
                    start_word = (active_addr - self.o_base) // 4
                    self.o_words[start_word + word_offset] = value_to_int(self.dut.wr_data.value)
                    if value_to_int(self.dut.wr_data_last.value):
                        active_words = 0
                    else:
                        word_offset += 1

            self.dut.wr_desc_ready.value = self._wr_desc_ready_pattern.next()
            self.dut.wr_data_ready.value = self._wr_data_ready_pattern.next()


async def create_env(dut) -> FABaselineEnv:
    env = FABaselineEnv(dut)
    await env.start()
    return env
