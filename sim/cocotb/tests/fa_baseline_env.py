from __future__ import annotations

import inspect
import math
import os
import random
from dataclasses import dataclass
from typing import List, Optional, Sequence

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from tests.fa_functional_coverage import FunctionalCoverageRecorder


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


def env_flag(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() not in {"0", "false", "no", "off"}


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


def attention_golden_rows(
    q_matrix: Sequence[Sequence[float]],
    k_matrix: Sequence[Sequence[float]],
    v_matrix: Sequence[Sequence[float]],
    *,
    scale: float,
    causal: bool,
    q_start: int = 0,
    q_rows: int | None = None,
) -> List[List[float]]:
    if q_start < 0 or q_start >= SEQ_LEN:
        raise ValueError(f"expected 0 <= q_start < {SEQ_LEN}, got {q_start}")
    if q_rows is None:
        q_end = SEQ_LEN
    else:
        if q_rows < 0:
            raise ValueError(f"expected q_rows >= 0, got {q_rows}")
        q_end = min(q_start + q_rows, SEQ_LEN)

    out = zero_matrix(q_end - q_start, HEAD_DIM)
    for out_row, qi in enumerate(range(q_start, q_end)):
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
                out[out_row][dim] += prob * v_matrix[kj][dim]
    return out


def attention_golden(
    q_matrix: Sequence[Sequence[float]],
    k_matrix: Sequence[Sequence[float]],
    v_matrix: Sequence[Sequence[float]],
    *,
    scale: float,
    causal: bool,
) -> List[List[float]]:
    return attention_golden_rows(
        q_matrix,
        k_matrix,
        v_matrix,
        scale=scale,
        causal=causal,
        q_start=0,
        q_rows=SEQ_LEN,
    )


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


def pattern_values(pattern: ConstantPattern | SequencePattern) -> List[int]:
    if isinstance(pattern, ConstantPattern):
        return [pattern.value]
    return list(pattern.values)


def pattern_has_stall(pattern: ConstantPattern | SequencePattern) -> bool:
    return any(value == 0 for value in pattern_values(pattern))


def patterns_are_constant_ready(*patterns: ConstantPattern | SequencePattern) -> bool:
    return all(isinstance(pattern, ConstantPattern) and pattern.value == 1 for pattern in patterns)


def nonzero_row_indices(matrix: Sequence[Sequence[float]]) -> List[int]:
    rows: List[int] = []
    for row_idx, row in enumerate(matrix):
        if any(abs(float(value)) > 0.0 for value in row):
            rows.append(row_idx)
    return rows


def record_shape_coverage(
    coverage: FunctionalCoverageRecorder,
    q_matrix: Sequence[Sequence[float]],
    k_matrix: Sequence[Sequence[float]],
    v_matrix: Sequence[Sequence[float]],
) -> None:
    q_rows = nonzero_row_indices(q_matrix)
    k_rows = nonzero_row_indices(k_matrix)
    v_rows = nonzero_row_indices(v_matrix)
    evidence = {
        "q_nonzero_rows": len(q_rows),
        "k_nonzero_rows": len(k_rows),
        "v_nonzero_rows": len(v_rows),
    }
    if q_rows and k_rows and v_rows and max(len(q_rows), len(k_rows), len(v_rows)) <= TILE_ROWS:
        coverage.hit("shape.single_tile", evidence=evidence)
    if len(q_rows) >= SEQ_LEN and len(k_rows) >= SEQ_LEN and len(v_rows) >= SEQ_LEN:
        coverage.hit("shape.full_sequence", evidence=evidence)
    if q_rows:
        if min(q_rows) == 0:
            coverage.hit("shape.q_row.first", q_row_min=min(q_rows), q_row_max=max(q_rows))
        if any(TILE_ROWS <= row < SEQ_LEN - TILE_ROWS for row in q_rows):
            coverage.hit("shape.q_row.middle", q_row_min=min(q_rows), q_row_max=max(q_rows))
        if max(q_rows) >= SEQ_LEN - TILE_ROWS:
            coverage.hit("shape.q_row.last", q_row_min=min(q_rows), q_row_max=max(q_rows))


class FABaselineEnv:
    def __init__(self, dut):
        self.dut = dut
        self.case_name = discover_case_name()
        self.coverage = FunctionalCoverageRecorder(case_name=self.case_name)
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
        self._dma_abort_epoch = 0
        self._rd_fault_early_last_beat: int | None = None
        self._rd_fault_suppress_final_last = False
        self._fast_wait_enabled = env_flag("FA_FAST_WAIT", True)
        self._status_handles_resolved = False
        self._status_busy_handle = None
        self._status_done_handle = None
        self._status_error_handle = None

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
        self.dut.rd_desc_ready.value = 1
        self.dut.rd_beat_valid.value = 0
        self.dut.rd_beat_data.value = 0
        self.dut.rd_beat_word_count.value = 0
        self.dut.rd_beat_last.value = 0
        self.dut.wr_desc_ready.value = 1
        self.dut.wr_data_ready.value = 1

    async def reset(self, cycles: int = 5) -> None:
        self._drive_defaults()
        self._abort_dma_agents()
        await ClockCycles(self.dut.clk, cycles)
        self.dut.rstn.value = 1
        await ClockCycles(self.dut.clk, cycles)

    def _abort_dma_agents(self) -> None:
        self._dma_abort_epoch += 1
        self._rd_active = None
        self._wr_active = None
        self.dut.rd_beat_valid.value = 0
        self.dut.rd_beat_word_count.value = 0
        self.dut.rd_beat_last.value = 0
        self.dut.wr_data_ready.value = 1

    def set_read_patterns(
        self,
        *,
        desc_ready: ConstantPattern | SequencePattern | None = None,
        data_valid: ConstantPattern | SequencePattern | None = None,
    ) -> None:
        if desc_ready is not None:
            self._rd_desc_ready_pattern = desc_ready
            if pattern_has_stall(desc_ready):
                self.coverage.hit("stream.read_desc_backpressure", pattern=pattern_values(desc_ready))
                self.coverage.hit("stream.valid_hold", source="read_desc_ready")
        if data_valid is not None:
            self._rd_data_valid_pattern = data_valid
            if pattern_has_stall(data_valid):
                self.coverage.hit("stream.read_data_backpressure", pattern=pattern_values(data_valid))
                self.coverage.hit("stream.valid_hold", source="read_data_valid")

    def set_write_patterns(
        self,
        *,
        desc_ready: ConstantPattern | SequencePattern | None = None,
        data_ready: ConstantPattern | SequencePattern | None = None,
    ) -> None:
        if desc_ready is not None:
            self._wr_desc_ready_pattern = desc_ready
            if pattern_has_stall(desc_ready):
                self.coverage.hit("stream.write_desc_backpressure", pattern=pattern_values(desc_ready))
                self.coverage.hit("stream.valid_hold", source="write_desc_ready")
        if data_ready is not None:
            self._wr_data_ready_pattern = data_ready
            if pattern_has_stall(data_ready):
                self.coverage.hit("stream.write_data_backpressure", pattern=pattern_values(data_ready))
                self.coverage.hit("stream.valid_hold", source="write_data_ready")

    def set_read_faults(
        self,
        *,
        early_last_beat: int | None = None,
        suppress_final_last: bool = False,
    ) -> None:
        self._rd_fault_early_last_beat = early_last_beat
        self._rd_fault_suppress_final_last = suppress_final_last
        if early_last_beat is not None:
            self.coverage.hit("protocol.read_fault_early_last", early_last_beat=early_last_beat)
        if suppress_final_last:
            self.coverage.hit("protocol.read_fault_missing_final_last")

    def clear_read_faults(self) -> None:
        self._rd_fault_early_last_beat = None
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
        record_shape_coverage(self.coverage, q_matrix, k_matrix, v_matrix)

    async def axil_write(self, addr: int, data: int, wstrb: int = 0xF) -> int:
        if addr == ADDR_STRIDE_BYTES and data % 16:
            self.coverage.hit("csr.alignment_error", stride_bytes=data)
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
        if patterns_are_constant_ready(
            self._rd_desc_ready_pattern,
            self._rd_data_valid_pattern,
            self._wr_desc_ready_pattern,
            self._wr_data_ready_pattern,
        ):
            self.coverage.hit("stream.constant_ready")
        self.ctrl_shadow = CTRL_IRQ_EN
        await self.axil_write(ADDR_CTRL, self.ctrl_shadow)
        await self.axil_write(ADDR_CTRL, self.ctrl_shadow | CTRL_START)
        await self.axil_write(ADDR_CTRL, self.ctrl_shadow)

    async def soft_reset(self) -> None:
        self.coverage.hit("csr.soft_reset")
        self.ctrl_shadow = CTRL_IRQ_EN
        await self.axil_write(ADDR_CTRL, self.ctrl_shadow | CTRL_SOFT_RESET)
        await self.axil_write(ADDR_CTRL, self.ctrl_shadow)
        self._abort_dma_agents()

    def _resolve_handle_chain(self, *names: str):
        handle = self.dut
        for name in names:
            try:
                handle = getattr(handle, name)
            except AttributeError:
                return None
        return handle

    def _resolve_status_handles(self) -> None:
        if self._status_handles_resolved:
            return
        self._status_busy_handle = self._resolve_handle_chain("status_busy")
        if self._status_busy_handle is None:
            self._status_busy_handle = self._resolve_handle_chain("u_fa_csr", "status_busy")
        self._status_done_handle = self._resolve_handle_chain("status_done")
        if self._status_done_handle is None:
            self._status_done_handle = self._resolve_handle_chain("u_fa_csr", "status_done")
        self._status_error_handle = self._resolve_handle_chain("status_error")
        self._status_handles_resolved = True

    def _fast_wait_ready(self) -> bool:
        if not self._fast_wait_enabled:
            return False
        self._resolve_status_handles()
        return (
            self._status_busy_handle is not None
            and self._status_done_handle is not None
            and self._status_error_handle is not None
        )

    def _internal_status_word(self) -> int:
        status = 0
        if self._status_busy_handle is not None and value_to_int(self._status_busy_handle.value):
            status |= STATUS_BUSY
        if self._status_done_handle is not None and value_to_int(self._status_done_handle.value):
            status |= STATUS_DONE
        if self._status_error_handle is not None and value_to_int(self._status_error_handle.value):
            status |= STATUS_ERROR
        return status

    async def wait_busy(self, expected: bool, timeout_cycles: int = 4000) -> None:
        if self._fast_wait_ready():
            for _ in range(timeout_cycles):
                if bool(self._internal_status_word() & STATUS_BUSY) == expected:
                    return
                await RisingEdge(self.dut.clk)
            raise AssertionError(f"busy did not become {expected}")
        for _ in range(timeout_cycles):
            status = await self.axil_read(ADDR_STATUS)
            if bool(status & STATUS_BUSY) == expected:
                return
            await RisingEdge(self.dut.clk)
        raise AssertionError(f"busy did not become {expected}")

    async def wait_done(self, timeout_cycles: int = 600000) -> int:
        if self._fast_wait_ready():
            for _ in range(timeout_cycles):
                status = self._internal_status_word()
                if status & STATUS_DONE:
                    self.coverage.hit("csr.start_done", status=status)
                    return status
                if status & STATUS_ERROR:
                    raise AssertionError(f"run hit error status=0x{status:08x}")
                await RisingEdge(self.dut.clk)
            raise AssertionError("run did not finish before timeout")
        for _ in range(timeout_cycles):
            status = await self.axil_read(ADDR_STATUS)
            if status & STATUS_DONE:
                self.coverage.hit("csr.start_done", status=status)
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
        beat_words_held = 0
        seen_abort_epoch = self._dma_abort_epoch
        self.dut.rd_desc_ready.value = 1
        self.dut.rd_beat_valid.value = 0
        self.dut.rd_beat_word_count.value = 0
        self.dut.rd_beat_last.value = 0
        while True:
            await RisingEdge(self.dut.clk)
            if seen_abort_epoch != self._dma_abort_epoch:
                active_kind = 0
                active_addr = 0
                active_words = 0
                word_offset = 0
                valid_held = False
                last_held = False
                beat_words_held = 0
                self.dut.rd_beat_valid.value = 0
                self.dut.rd_beat_word_count.value = 0
                self.dut.rd_beat_last.value = 0
                seen_abort_epoch = self._dma_abort_epoch
            if active_words == 0:
                if value_to_int(self.dut.rd_desc_valid.value) and value_to_int(self.dut.rd_desc_ready.value):
                    active_addr = value_to_int(self.dut.rd_desc_addr.value)
                    active_words = value_to_int(self.dut.rd_desc_words.value)
                    active_kind = value_to_int(self.dut.rd_desc_tag.value)
                    word_offset = 0
                    valid_held = False
                    last_held = False
                    beat_words_held = 0
                    self.rd_desc_log.append(ReadDescLog(addr=active_addr, words=active_words, tag=active_kind))
            else:
                if value_to_int(self.dut.rd_beat_valid.value) and value_to_int(self.dut.rd_beat_ready.value):
                    sent_last = last_held
                    word_offset += beat_words_held
                    valid_held = False
                    last_held = False
                    beat_words_held = 0
                    if sent_last or word_offset >= active_words:
                        active_words = 0

            self.dut.rd_desc_ready.value = self._rd_desc_ready_pattern.next()
            if active_words == 0:
                self.dut.rd_beat_valid.value = 0
                self.dut.rd_beat_word_count.value = 0
                self.dut.rd_beat_last.value = 0
            else:
                source_words = self.q_words if active_kind == RD_TAG_Q else self.k_words if active_kind == RD_TAG_K else self.v_words
                base_addr = self.q_base if active_kind == RD_TAG_Q else self.k_base if active_kind == RD_TAG_K else self.v_base
                start_word = (active_addr - base_addr) // 4
                if not valid_held:
                    valid_held = bool(self._rd_data_valid_pattern.next())
                self.dut.rd_beat_valid.value = 1 if valid_held else 0
                if valid_held:
                    remaining_words = active_words - word_offset
                    beat_words = min(4, remaining_words)
                    beat_idx = word_offset // 4
                    is_final_beat = beat_words == remaining_words
                    emit_last = is_final_beat
                    if self._rd_fault_early_last_beat is not None and beat_idx == self._rd_fault_early_last_beat:
                        emit_last = True
                    if is_final_beat and self._rd_fault_suppress_final_last:
                        emit_last = False
                    beat_value = 0
                    for beat_lane in range(beat_words):
                        beat_value |= (int(source_words[start_word + word_offset + beat_lane]) & 0xFFFF_FFFF) << (beat_lane * 32)
                    last_held = emit_last
                    beat_words_held = beat_words
                    self.dut.rd_beat_data.value = beat_value
                    self.dut.rd_beat_word_count.value = beat_words
                    self.dut.rd_beat_last.value = int(emit_last)
                else:
                    self.dut.rd_beat_word_count.value = 0
                    self.dut.rd_beat_last.value = 0

    async def _wr_dma_agent(self) -> None:
        active_addr = 0
        active_words = 0
        word_offset = 0
        seen_abort_epoch = self._dma_abort_epoch
        self.dut.wr_desc_ready.value = 1
        self.dut.wr_data_ready.value = 1
        while True:
            await RisingEdge(self.dut.clk)
            if seen_abort_epoch != self._dma_abort_epoch:
                active_addr = 0
                active_words = 0
                word_offset = 0
                seen_abort_epoch = self._dma_abort_epoch
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
