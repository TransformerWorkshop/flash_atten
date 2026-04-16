from __future__ import annotations

from dataclasses import dataclass
from math import log2

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from tests.functional_coverage import declare_bins, hit, record_case, sample_metric
from tests.numeric_case_catalog import NUMERIC_CASES, NumericCase, PM_INT8_ALL, PM_INT8_INT32


CSR_CTRL = 0x00
CSR_STATUS = 0x04
CSR_CONFIG = 0x08
CSR_DBG_DONE = 0x0C
CSR_SOFT_RESET_CFG = 0x84

CTRL_ENABLE = 1 << 0
CTRL_SOFT_RESET = 1 << 2

STATUS_READY = 1 << 0
STATUS_LOAD_BUSY = 1 << 1
STATUS_COMPUTE_BUSY = 1 << 2
STATUS_STORE_BUSY = 1 << 3
STATUS_DONE = 1 << 4
STATUS_SOFT_RESET_ACTIVE = 1 << 5

MATRIX_A_BASE = 0x0000_0000
MATRIX_B_BASE = 0x0000_4000
MATRIX_C_BASE = 0x0000_8000
MATRIX_D_BASE = 0x0000_C000

OBS_MAX_WRITE_WORDS = 256


declare_bins(
    [
        "reset_defaults",
        "status_ready",
        "axil_readback",
        "axil_staggered_write",
        "soft_reset_seen",
        "load_done_seen",
        "compute_done_seen",
        "transfer_done_seen",
        "ram_a_done_seen",
        "ram_b_done_seen",
        "ram_c_done_seen",
        "writeback_seen",
        "writeback_strb_full",
        "done_bit_clear_on_read",
        "cat_edge",
        "cat_boundary",
        "cat_typical",
        "cat_random",
        "pm_int8",
        "pm_int8_int32",
        "dim_8x8",
        "dim_16x16",
        "dim_8x32",
        "dim_32x8",
        "zero_a_case",
        "zero_b_case",
        "zero_c_case",
        "single_hot_case",
        "boundary_value_case",
        "signed_inputs_case",
        "saturation_pos_case",
        "saturation_neg_case",
        "random_case",
    ]
)


def signal_value(signal) -> int:
    return int(signal.value)


def signal_width(signal) -> int:
    return len(signal)


def build_config_word(matrix_m: int, matrix_n: int, matrix_k: int, precision_mode: int = PM_INT8_ALL) -> int:
    return ((precision_mode & 0xF) << 24) | ((matrix_m & 0xFF) << 16) | ((matrix_n & 0xFF) << 8) | (matrix_k & 0xFF)


def build_int8_matrix(seed: int, rows: int = 8, cols: int = 8) -> list[list[int]]:
    matrix: list[list[int]] = []
    for row in range(rows):
        row_data: list[int] = []
        for col in range(cols):
            row_data.append((seed + row * cols + col) & 0xFF)
        matrix.append(row_data)
    return matrix


def pack_matrix_int8_row_major(matrix: list[list[int]], bytes_per_word: int) -> list[tuple[int, int]]:
    rows = len(matrix)
    cols = len(matrix[0])
    if bytes_per_word <= 0:
        raise ValueError("bytes_per_word must be positive")

    words: list[tuple[int, int]] = []
    for row in range(rows):
        for col_base in range(0, cols, bytes_per_word):
            word = 0
            wstrb = 0
            chunk = matrix[row][col_base:col_base + bytes_per_word]
            for offset, value in enumerate(chunk):
                word |= (value & 0xFF) << (offset * 8)
                wstrb |= 1 << offset
            words.append((word, wstrb))
    return words


def pack_matrix_int32_row_major(matrix: list[list[int]], bytes_per_word: int) -> list[tuple[int, int]]:
    rows = len(matrix)
    cols = len(matrix[0])
    elems_per_word = bytes_per_word // 4
    if elems_per_word <= 0:
        raise ValueError("int32 pack expects at least one 32-bit lane")

    words: list[tuple[int, int]] = []
    for row in range(rows):
        for col_base in range(0, cols, elems_per_word):
            word = 0
            wstrb = 0
            chunk = matrix[row][col_base:col_base + elems_per_word]
            for offset, value in enumerate(chunk):
                word |= (value & 0xFFFF_FFFF) << (offset * 32)
                wstrb |= 0xF << (offset * 4)
            words.append((word, wstrb))
    return words


def decode_writeback_words(dut, word_count: int) -> tuple[list[int], list[int]]:
    packed_words = signal_value(dut.obs_writeback_words)
    packed_strbs = signal_value(dut.obs_writeback_strbs)
    axi_data_width = signal_width(dut.obs_last_m_axi_wdata)
    axi_strb_width = signal_width(dut.obs_last_m_axi_wstrb)
    words: list[int] = []
    strbs: list[int] = []
    for index in range(word_count):
        words.append((packed_words >> (index * axi_data_width)) & ((1 << axi_data_width) - 1))
        strbs.append((packed_strbs >> (index * axi_strb_width)) & ((1 << axi_strb_width) - 1))
    return words, strbs


@dataclass
class AxilReadResult:
    data: int
    resp: int


class TpuTopBench:
    def __init__(self, dut):
        self.dut = dut
        self.axi_data_width = signal_width(dut.s_axi_wdata)
        self.axi_strb_width = signal_width(dut.s_axi_wstrb)
        self.axi_bytes = self.axi_data_width // 8
        self.int32_lanes_per_word = self.axi_bytes // 4
        self.full_axi_wstrb = (1 << self.axi_strb_width) - 1
        self.awsize = int(log2(self.axi_bytes))
        self.max_axi_burst_beats = 256

    async def start(self) -> None:
        self._drive_defaults()
        cocotb.start_soon(Clock(self.dut.clk, 10, unit="ns").start())
        await self.reset()

    async def reset(self, cycles: int = 5) -> None:
        self._drive_defaults()
        self.dut.rst_n.value = 0
        await ClockCycles(self.dut.clk, cycles)
        self.dut.rst_n.value = 1
        await ClockCycles(self.dut.clk, cycles)

    def _drive_defaults(self) -> None:
        self.dut.rst_n.value = 0

        self.dut.s_axi_awid.value = 0
        self.dut.s_axi_awaddr.value = 0
        self.dut.s_axi_awlen.value = 0
        self.dut.s_axi_awsize.value = 0
        self.dut.s_axi_awburst.value = 0
        self.dut.s_axi_awlock.value = 0
        self.dut.s_axi_awcache.value = 0
        self.dut.s_axi_awprot.value = 0
        self.dut.s_axi_awqos.value = 0
        self.dut.s_axi_awregion.value = 0
        self.dut.s_axi_awuser.value = 0
        self.dut.s_axi_awvalid.value = 0
        self.dut.s_axi_wdata.value = 0
        self.dut.s_axi_wstrb.value = 0
        self.dut.s_axi_wlast.value = 0
        self.dut.s_axi_wuser.value = 0
        self.dut.s_axi_wvalid.value = 0
        self.dut.s_axi_bready.value = 0

        self.dut.s_axil_awaddr.value = 0
        self.dut.s_axil_awvalid.value = 0
        self.dut.s_axil_wdata.value = 0
        self.dut.s_axil_wstrb.value = 0
        self.dut.s_axil_wvalid.value = 0
        self.dut.s_axil_bready.value = 0
        self.dut.s_axil_araddr.value = 0
        self.dut.s_axil_arvalid.value = 0
        self.dut.s_axil_rready.value = 0

    async def wait_for(self, predicate, timeout_cycles: int, message: str) -> None:
        for _ in range(timeout_cycles):
            if predicate():
                return
            await RisingEdge(self.dut.clk)
        raise AssertionError(message)

    async def axil_write(self, addr: int, data: int, wstrb: int = 0xF, write_delay_cycles: int = 0) -> int:
        self.dut.s_axil_awaddr.value = addr
        self.dut.s_axil_awvalid.value = 1
        self.dut.s_axil_wdata.value = data
        self.dut.s_axil_wstrb.value = wstrb
        self.dut.s_axil_wvalid.value = 0 if write_delay_cycles > 0 else 1
        self.dut.s_axil_bready.value = 1

        aw_done = False
        w_done = False
        delay_count = write_delay_cycles

        while not (aw_done and w_done):
            await RisingEdge(self.dut.clk)
            if delay_count > 0:
                delay_count -= 1
                if delay_count == 0:
                    self.dut.s_axil_wvalid.value = 1

            if not aw_done and signal_value(self.dut.s_axil_awvalid) and signal_value(self.dut.s_axil_awready):
                aw_done = True
                self.dut.s_axil_awvalid.value = 0

            if not w_done and signal_value(self.dut.s_axil_wvalid) and signal_value(self.dut.s_axil_wready):
                w_done = True
                self.dut.s_axil_wvalid.value = 0

        await self.wait_for(
            lambda: signal_value(self.dut.s_axil_bvalid) == 1,
            timeout_cycles=50,
            message=f"AXI-Lite write response timeout at 0x{addr:02x}",
        )
        resp = signal_value(self.dut.s_axil_bresp)
        await RisingEdge(self.dut.clk)
        self.dut.s_axil_bready.value = 0
        return resp

    async def axil_read(self, addr: int) -> AxilReadResult:
        self.dut.s_axil_araddr.value = addr
        self.dut.s_axil_arvalid.value = 1
        self.dut.s_axil_rready.value = 1

        await self.wait_for(
            lambda: signal_value(self.dut.s_axil_arvalid) and signal_value(self.dut.s_axil_arready),
            timeout_cycles=50,
            message=f"AXI-Lite read address timeout at 0x{addr:02x}",
        )
        self.dut.s_axil_arvalid.value = 0

        await self.wait_for(
            lambda: signal_value(self.dut.s_axil_rvalid) == 1,
            timeout_cycles=50,
            message=f"AXI-Lite read data timeout at 0x{addr:02x}",
        )
        result = AxilReadResult(
            data=signal_value(self.dut.s_axil_rdata),
            resp=signal_value(self.dut.s_axil_rresp),
        )
        await RisingEdge(self.dut.clk)
        self.dut.s_axil_rready.value = 0
        return result

    async def _axi_write_burst_chunk(self, addr: int, beats: list[tuple[int, int]], awid: int = 0) -> int:
        self.dut.s_axi_awid.value = awid
        self.dut.s_axi_awaddr.value = addr
        self.dut.s_axi_awlen.value = len(beats) - 1
        self.dut.s_axi_awsize.value = self.awsize
        self.dut.s_axi_awburst.value = 1
        self.dut.s_axi_awlock.value = 0
        self.dut.s_axi_awcache.value = 0
        self.dut.s_axi_awprot.value = 0
        self.dut.s_axi_awqos.value = 0
        self.dut.s_axi_awregion.value = 0
        self.dut.s_axi_awuser.value = 0
        self.dut.s_axi_awvalid.value = 1
        self.dut.s_axi_bready.value = 1

        await self.wait_for(
            lambda: signal_value(self.dut.s_axi_awvalid) and signal_value(self.dut.s_axi_awready),
            timeout_cycles=1000,
            message=f"AXI write address timeout at 0x{addr:08x}",
        )
        self.dut.s_axi_awvalid.value = 0

        for index, (word, wstrb) in enumerate(beats):
            self.dut.s_axi_wdata.value = word
            self.dut.s_axi_wstrb.value = wstrb
            self.dut.s_axi_wlast.value = 1 if index == len(beats) - 1 else 0
            self.dut.s_axi_wuser.value = 0
            self.dut.s_axi_wvalid.value = 1
            await self.wait_for(
                lambda: signal_value(self.dut.s_axi_wvalid) and signal_value(self.dut.s_axi_wready),
                timeout_cycles=1000,
                message=f"AXI write data timeout at 0x{addr:08x}, beat {index}",
            )
            self.dut.s_axi_wvalid.value = 0
            await RisingEdge(self.dut.clk)

        await self.wait_for(
            lambda: signal_value(self.dut.s_axi_bvalid) == 1,
            timeout_cycles=1000,
            message=f"AXI write response timeout at 0x{addr:08x}",
        )
        resp = signal_value(self.dut.s_axi_bresp)
        await RisingEdge(self.dut.clk)
        self.dut.s_axi_bready.value = 0
        return resp

    async def axi_write_burst(self, addr: int, beats: list[tuple[int, int]], awid: int = 0) -> int:
        if not beats:
            raise ValueError("AXI burst must contain at least one beat")

        for chunk_index, start in enumerate(range(0, len(beats), self.max_axi_burst_beats)):
            chunk = beats[start:start + self.max_axi_burst_beats]
            chunk_addr = addr + start * self.axi_bytes
            resp = await self._axi_write_burst_chunk(chunk_addr, chunk, awid=awid + chunk_index)
            if resp != 0:
                return resp
        return 0

    async def axi_write_int8_matrix(self, base_addr: int, matrix: list[list[int]], awid: int = 0) -> int:
        return await self.axi_write_burst(
            base_addr,
            pack_matrix_int8_row_major(matrix, self.axi_bytes),
            awid=awid,
        )

    async def axi_write_int32_matrix(self, base_addr: int, matrix: list[list[int]], awid: int = 0) -> int:
        return await self.axi_write_burst(
            base_addr,
            pack_matrix_int32_row_major(matrix, self.axi_bytes),
            awid=awid,
        )


@cocotb.test()
async def test_default_status_and_reset_defaults(dut) -> None:
    tb = TpuTopBench(dut)
    await tb.start()

    await tb.wait_for(
        lambda: signal_value(dut.obs_axi_wr_ready) == 0 and signal_value(dut.obs_soft_reset_active) == 0,
        timeout_cycles=20,
        message="wrapper failed to leave reset cleanly",
    )

    status = await tb.axil_read(CSR_STATUS)
    assert status.resp == 0
    assert status.data & STATUS_READY
    assert (status.data & (STATUS_LOAD_BUSY | STATUS_COMPUTE_BUSY | STATUS_STORE_BUSY | STATUS_DONE)) == 0
    hit("reset_defaults")
    hit("status_ready")

    config = await tb.axil_read(CSR_CONFIG)
    assert config.resp == 0
    assert config.data == build_config_word(16, 16, 16)

    soft_reset_cfg = await tb.axil_read(CSR_SOFT_RESET_CFG)
    assert soft_reset_cfg.resp == 0
    assert soft_reset_cfg.data == 500000
    hit("axil_readback")


@cocotb.test()
async def test_axil_staggered_write_and_soft_reset(dut) -> None:
    tb = TpuTopBench(dut)
    await tb.start()

    resp = await tb.axil_write(CSR_SOFT_RESET_CFG, 3, write_delay_cycles=3)
    assert resp == 0
    hit("axil_staggered_write")

    soft_reset_cfg = await tb.axil_read(CSR_SOFT_RESET_CFG)
    assert soft_reset_cfg.data == 3

    config_word = build_config_word(8, 8, 8)
    resp = await tb.axil_write(CSR_CONFIG, config_word, write_delay_cycles=2)
    assert resp == 0

    config = await tb.axil_read(CSR_CONFIG)
    assert config.data == config_word

    resp = await tb.axil_write(CSR_CTRL, CTRL_SOFT_RESET)
    assert resp == 0

    await tb.wait_for(
        lambda: signal_value(dut.obs_soft_reset_active) == 1,
        timeout_cycles=20,
        message="soft reset never became active",
    )
    hit("soft_reset_seen")
    await tb.wait_for(
        lambda: signal_value(dut.obs_soft_reset_active) == 0,
        timeout_cycles=20,
        message="soft reset did not clear",
    )

    status = await tb.axil_read(CSR_STATUS)
    assert (status.data & STATUS_SOFT_RESET_ACTIVE) == 0
    assert status.data & STATUS_READY
    hit("status_ready")

    config_after_reset = await tb.axil_read(CSR_CONFIG)
    assert config_after_reset.data == config_word
    hit("axil_readback")


async def run_numeric_case(dut, case: NumericCase) -> None:
    tb = TpuTopBench(dut)
    await tb.start()

    matrix_m = len(case.a_matrix)
    matrix_k = len(case.a_matrix[0])
    matrix_n = len(case.b_matrix[0])
    expected_word_count = matrix_m * ((matrix_n + tb.int32_lanes_per_word - 1) // tb.int32_lanes_per_word)

    hit(f"cat_{case.category}")
    if case.precision_mode == PM_INT8_ALL:
        hit("pm_int8")
    if case.precision_mode == PM_INT8_INT32:
        hit("pm_int8_int32")
    if matrix_m == 8 and matrix_n == 8 and matrix_k == 8:
        hit("dim_8x8")
    if matrix_m == 16 and matrix_n == 16 and matrix_k == 16:
        hit("dim_16x16")
    if matrix_m == 8 and matrix_n == 32 and matrix_k == 16:
        hit("dim_8x32")
    if matrix_m == 32 and matrix_n == 8 and matrix_k == 16:
        hit("dim_32x8")
    for tag in case.tags:
        hit(tag)

    sample_metric("matrix_m", matrix_m)
    sample_metric("matrix_n", matrix_n)
    sample_metric("matrix_k", matrix_k)

    config_word = build_config_word(matrix_m, matrix_n, matrix_k, precision_mode=case.precision_mode)
    assert await tb.axil_write(CSR_CONFIG, config_word) == 0
    assert await tb.axil_write(CSR_CTRL, CTRL_ENABLE) == 0

    await ClockCycles(dut.clk, 4)

    assert await tb.axi_write_int8_matrix(MATRIX_A_BASE, case.a_matrix, awid=1) == 0
    assert await tb.axi_write_int8_matrix(MATRIX_B_BASE, case.b_matrix, awid=2) == 0
    if case.precision_mode == PM_INT8_INT32:
        assert await tb.axi_write_int32_matrix(MATRIX_C_BASE, case.c_matrix, awid=3) == 0
    else:
        assert await tb.axi_write_int8_matrix(MATRIX_C_BASE, case.c_matrix, awid=3) == 0

    await tb.wait_for(
        lambda: signal_value(dut.obs_ram_a_wr_done_count) >= 1
        and signal_value(dut.obs_ram_b_wr_done_count) >= 1
        and signal_value(dut.obs_ram_c_wr_done_count) >= 1,
        timeout_cycles=400,
        message=f"{case.name}: matrix write-done pulses were not all observed",
    )
    hit("ram_a_done_seen")
    hit("ram_b_done_seen")
    hit("ram_c_done_seen")

    dbg_done = await tb.axil_read(CSR_DBG_DONE)
    assert dbg_done.data & 0x7 == 0x7

    await tb.wait_for(
        lambda: signal_value(dut.obs_compute_done_count) >= 1
        and signal_value(dut.obs_transfer_done_count) >= 1
        and signal_value(dut.obs_m_axi_w_count) >= expected_word_count
        and signal_value(dut.obs_m_axi_b_count) >= 1,
        timeout_cycles=30000,
        message=f"{case.name}: end-to-end compute/store activity did not complete",
    )
    hit("compute_done_seen")
    hit("transfer_done_seen")
    hit("writeback_seen")

    actual_words, actual_strbs = decode_writeback_words(dut, expected_word_count)
    expected_words = [word for word, _ in pack_matrix_int32_row_major(case.expected_matrix, tb.axi_bytes)]
    sample_metric("writeback_words", expected_word_count)
    sample_metric("aw_count", signal_value(dut.obs_m_axi_aw_count))
    sample_metric("w_count", signal_value(dut.obs_m_axi_w_count))
    words_match = actual_words == expected_words
    strbs_match = all(strb == tb.full_axi_wstrb for strb in actual_strbs)
    record_case(
        case.name,
        category=case.category,
        precision_mode=case.precision_mode,
        matrix_m=matrix_m,
        matrix_n=matrix_n,
        matrix_k=matrix_k,
        writeback_words=expected_word_count,
        aw_count=signal_value(dut.obs_m_axi_aw_count),
        w_count=signal_value(dut.obs_m_axi_w_count),
        status="pass" if words_match and strbs_match else "fail",
    )
    assert actual_words == expected_words, (
        f"{case.name}: writeback mismatch\n"
        f"expected={expected_words}\n"
        f"actual={actual_words}"
    )
    assert strbs_match, f"{case.name}: unexpected write strobes {actual_strbs}"
    hit("writeback_strb_full")

    status_first = await tb.axil_read(CSR_STATUS)
    assert status_first.data & STATUS_DONE
    status_second = await tb.axil_read(CSR_STATUS)
    assert (status_second.data & STATUS_DONE) == 0
    hit("done_bit_clear_on_read")


@cocotb.test()
async def test_load_abc_and_observe_writeback_activity(dut) -> None:
    tb = TpuTopBench(dut)
    await tb.start()

    config_word = build_config_word(8, 8, 8)
    assert await tb.axil_write(CSR_CONFIG, config_word) == 0
    assert await tb.axil_write(CSR_CTRL, CTRL_ENABLE) == 0

    await ClockCycles(dut.clk, 4)

    a_matrix = build_int8_matrix(0x01)
    b_matrix = build_int8_matrix(0x21)
    c_matrix = build_int8_matrix(0x41)
    a_beats = pack_matrix_int8_row_major(a_matrix, tb.axi_bytes)
    b_beats = pack_matrix_int8_row_major(b_matrix, tb.axi_bytes)
    c_beats = pack_matrix_int8_row_major(c_matrix, tb.axi_bytes)

    if tb.axi_bytes == 16:
        assert a_beats[0][1] == 0x00FF
        assert b_beats[0][1] == 0x00FF
        assert c_beats[0][1] == 0x00FF

    assert await tb.axi_write_burst(MATRIX_A_BASE, a_beats, awid=1) == 0
    assert await tb.axi_write_burst(MATRIX_B_BASE, b_beats, awid=2) == 0
    assert await tb.axi_write_burst(MATRIX_C_BASE, c_beats, awid=3) == 0

    await tb.wait_for(
        lambda: signal_value(dut.obs_ram_a_wr_done_count) >= 1
        and signal_value(dut.obs_ram_b_wr_done_count) >= 1
        and signal_value(dut.obs_ram_c_wr_done_count) >= 1,
        timeout_cycles=100,
        message="matrix write-done pulses were not all observed",
    )
    hit("ram_a_done_seen")
    hit("ram_b_done_seen")
    hit("ram_c_done_seen")

    dbg_done = await tb.axil_read(CSR_DBG_DONE)
    assert dbg_done.data & 0x7 == 0x7

    await tb.wait_for(
        lambda: signal_value(dut.obs_compute_done_count) >= 1
        and signal_value(dut.obs_transfer_done_count) >= 1
        and signal_value(dut.obs_m_axi_aw_count) >= 1
        and signal_value(dut.obs_m_axi_w_count) >= 1
        and signal_value(dut.obs_m_axi_b_count) >= 1,
        timeout_cycles=4000,
        message="end-to-end compute/store activity did not complete",
    )
    hit("compute_done_seen")
    hit("transfer_done_seen")
    hit("writeback_seen")

    status_first = await tb.axil_read(CSR_STATUS)
    assert status_first.data & STATUS_DONE

    status_second = await tb.axil_read(CSR_STATUS)
    assert (status_second.data & STATUS_DONE) == 0
    hit("done_bit_clear_on_read")

    assert signal_value(dut.obs_last_m_axi_awaddr) >= MATRIX_D_BASE
    assert signal_value(dut.obs_m_axi_w_count) > 0
    sample_metric("writeback_words", signal_value(dut.obs_m_axi_w_count))
    hit("dim_8x8")


def _register_numeric_tests() -> None:
    for case in NUMERIC_CASES:
        async def _numeric_case_test(dut, case: NumericCase = case) -> None:
            await run_numeric_case(dut, case)

        globals()[case.name] = cocotb.test(name=case.name)(_numeric_case_test)


_register_numeric_tests()
