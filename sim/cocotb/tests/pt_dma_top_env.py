from __future__ import annotations

import inspect
import os
import random
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Deque, Dict, List, Optional, Sequence, Tuple

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge, Timer
from cocotb.utils import get_sim_time
from functional_coverage import FunctionalCoverageRecorder, classify_csr_pattern

from tests.pt_model import (
	DMA_KIND_A,
	DMA_KIND_B,
	DMA_KIND_C,
	DmaLoadExpectation,
	ExecPlan,
	ExportExpectation,
	LoadPlan,
	MATRIX_A_TUSER,
	MATRIX_B_TUSER,
	MATRIX_C_TUSER,
	PTBlackBoxModel,
	PT_CFG_A_BASE_HI,
	PT_CFG_A_BASE_LO,
	PT_CFG_B_BASE_HI,
	PT_CFG_B_BASE_LO,
	PT_QGRAN_PER_TENSOR,
	PT_QTYPE_SYMMETRIC,
	build_cfg_inst,
	build_qcfg_header,
	pack_resp,
	qcfg_payload_count,
	to_unsigned,
)


CTRL_DESC_PUSH = 1 << 0
CTRL_RESP_POP = 1 << 1
CTRL_SOFT_CLEAR = 1 << 2
CTRL_CLEAR_FLAGS = 1 << 3

STATUS_CMD_FIFO_NOT_FULL = 1 << 0
STATUS_RESP_FIFO_NOT_EMPTY = 1 << 1
STATUS_IRQ_ACTIVE = 1 << 2
STATUS_PT_CTRL_READY = 1 << 3
STATUS_CMD_OVERFLOW = 1 << 4
STATUS_DESC_OVERFLOW = 1 << 5
STATUS_RESP_OVERFLOW = 1 << 6
STATUS_DESC_MISS = 1 << 7

ADDR_CTRL = 0x00
ADDR_STATUS = 0x04
ADDR_CMD_INST = 0x08
ADDR_CMD_ID = 0x0C
ADDR_A_ADDR_LO = 0x10
ADDR_A_ADDR_HI = 0x14
ADDR_B_ADDR_LO = 0x18
ADDR_B_ADDR_HI = 0x1C
ADDR_C_ADDR_LO = 0x20
ADDR_C_ADDR_HI = 0x24
ADDR_M_ADDR_LO = 0x28
ADDR_M_ADDR_HI = 0x2C
ADDR_RESP_HEAD = 0x30

DEFAULT_A_BASE = 0x0000_1000
DEFAULT_B_BASE = 0x0000_2000
BACKPRESSURE_LONG_THRESHOLD = 4

CSR_SELECTOR_BINS = {
	PT_CFG_A_BASE_LO: "csr:selector:a_base_lo",
	PT_CFG_A_BASE_HI: "csr:selector:a_base_hi",
	PT_CFG_B_BASE_LO: "csr:selector:b_base_lo",
	PT_CFG_B_BASE_HI: "csr:selector:b_base_hi",
}


def discover_case_name() -> str:
	for frame_info in inspect.stack():
		if frame_info.function.startswith("test_"):
			return frame_info.function
	return os.getenv("COCOTB_TESTCASE", "unknown_test")


def env_int(name: str, default: int) -> int:
	return int(os.getenv(name, str(default)))


def value_to_int(value, default: int = 0) -> int:
	is_resolvable = getattr(value, "is_resolvable", True)
	return int(value) if is_resolvable else default


@dataclass
class DescriptorAddrs:
	a_addr: int
	b_addr: int
	c_addr: int
	m_addr: int


@dataclass
class ReadDmaExpectation:
	ctrl_id: int
	kind: str
	addr: int
	elems: int
	m_tiles: int = 1
	n_tiles: int = 1
	k_tiles: int = 1


@dataclass
class ReadDmaLog:
	ctrl_id: int
	kind: int
	addr: int
	elems: int


@dataclass
class WriteDmaLog:
	ctrl_id: int
	buf: int
	addr: int
	beats: int


@dataclass
class AxilCounterSnapshot:
	write_count: int
	read_count: int


@dataclass
class DescCommandTrace:
	ctrl_id: int
	mode: str
	first_write_start_cycle: int
	ctrl_write_start_cycle: int
	return_cycle: int
	axil_writes: int
	axil_reads: int
	write_addrs: Tuple[int, ...]


@dataclass
class PtCtrlAcceptLog:
	ctrl_id: int
	inst: int
	cycle: int


@dataclass
class RespVisibleLog:
	word: int
	cycle: int


@dataclass
class RdTransferTrace:
	ctrl_id: int
	kind: int
	addr: int
	elems: int
	beats: int
	desc_cycle: int
	last_beat_cycle: int


@dataclass
class WrTransferTrace:
	ctrl_id: int
	buf: int
	addr: int
	beats: int
	desc_cycle: int
	last_beat_cycle: int
	done_cycle: int


@dataclass
class CounterSnapshot:
	dma_req_count: int
	export_req_count: int
	export_done_count: int
	export_error_count: int
	irq_count: int


@dataclass
class AbInjection:
	wrong_tuser: bool = False
	error_mode: Optional[str] = None
	error_at_beat: int = 0
	done_delay: int = 0


@dataclass
class ExportInjection:
	error: bool = False
	done_delay: int = 0


@dataclass
class CtrlSendTrace:
	wait_cycles: int
	ready_low_cycles: int


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


class RandomPattern:
	def __init__(self, rng: random.Random, ready_probability: float):
		self.rng = rng
		self.ready_probability = ready_probability

	def next(self) -> int:
		return 1 if self.rng.random() < self.ready_probability else 0


class PTDmaTopEnv:
	def __init__(self, dut):
		self.dut = dut
		self.seed = env_int("PT_TEST_SEED", 10)
		self.case_name = discover_case_name()
		self.rng = random.Random(self.seed)
		self.x_dim = env_int("PT_X_DIM", 4)
		self.y_dim = env_int("PT_Y_DIM", 4)
		self.data_width = env_int("PT_DATA_WIDTH", 32)
		self.a_base = env_int("PT_A_BASE", DEFAULT_A_BASE)
		self.b_base = env_int("PT_B_BASE", DEFAULT_B_BASE)
		self.a_bank_depth = env_int("PT_A_BANK_DEPTH", 16)
		self.b_bank_depth = env_int("PT_B_BANK_DEPTH", 16)
		self.m_bank_depth = env_int("PT_M_BANK_DEPTH", 16)
		self.lut_depth = env_int("PT_LUT_DEPTH", 8)
		self.suite_name = os.getenv("PT_SUITE_NAME", "")
		self.run_name = os.getenv("PT_RUN_NAME", "")
		self.profile_name = os.getenv("PT_RANDOM_PROFILE", "")
		self.func_cov_dir = Path(os.getenv("PT_FUNC_COV_DIR", "."))
		self.a_load_lanes = env_int("PT_A_LOAD_LANES", 1)
		self.b_load_lanes = env_int("PT_B_LOAD_LANES", 1)
		self.m_write_lanes = env_int("PT_M_WRITE_LANES", 1)
		self.m_export_lanes = env_int("PT_M_EXPORT_LANES", 1)
		self.m_physical_copies = env_int("PT_M_PHYSICAL_COPIES", 3)
		self.model = PTBlackBoxModel(self.x_dim, self.y_dim, self.a_bank_depth, self.b_bank_depth, self.data_width, self.lut_depth)
		self.a_base_shadow = 0
		self.b_base_shadow = 0
		self.a_capacity_elems = self.a_bank_depth * self.x_dim * self.x_dim
		self.b_capacity_elems = self.b_bank_depth * self.y_dim * self.y_dim
		self.m_capacity_rows = self.m_bank_depth * self.x_dim
		self.coverage = FunctionalCoverageRecorder(
			case_name=self.case_name,
			suite_name=self.suite_name,
			run_name=self.run_name,
			seed=self.seed,
			x_dim=self.x_dim,
			y_dim=self.y_dim,
			profile=self.profile_name,
			metadata={
				"a_bank_depth": self.a_bank_depth,
				"b_bank_depth": self.b_bank_depth,
				"m_bank_depth": self.m_bank_depth,
				"a_load_lanes": self.a_load_lanes,
				"b_load_lanes": self.b_load_lanes,
				"m_write_lanes": self.m_write_lanes,
				"m_export_lanes": self.m_export_lanes,
				"m_physical_copies": self.m_physical_copies,
				"lut_depth": self.lut_depth,
			},
		)
		self.external_a_tiles: Dict[int, List[int]] = {}
		self.external_b_tiles: Dict[int, List[int]] = {}
		self.external_c_tiles: Dict[int, List[int]] = {}
		self.descriptors: Dict[int, DescriptorAddrs] = {}
		self.expected_rd_dma: Deque[ReadDmaExpectation] = deque()
		self.pending_resp_plans: Dict[int, Deque[Tuple[str, object]]] = {}
		self.rd_desc_log: List[ReadDmaLog] = []
		self.wr_desc_log: List[WriteDmaLog] = []
		self.ctrl_resp_queue: Deque[int] = deque()
		self.ab_injections: Deque[AbInjection] = deque()
		self.export_injections: Deque[ExportInjection] = deque()
		self.rd_desc_count = 0
		self.wr_desc_count = 0
		self.dma_req_count = 0
		self.export_req_count = 0
		self.export_done_count = 0
		self.export_error_count = 0
		self.irq_count = 0
		self.dma_stream_busy = False
		self.export_busy = False
		self.dma_req_ready_pattern = ConstantPattern(1)
		self.m_dma_req_ready_pattern = ConstantPattern(1)
		self.m_axis_ready_pattern = ConstantPattern(1)
		self.s_axis_valid_pattern = ConstantPattern(1)
		self._seen_long_backpressure = False
		self._resp_visible = False
		self._resp_word = 0
		self.axil_write_count = 0
		self.axil_read_count = 0
		self.axil_reg_shadow: Dict[int, int] = {}
		self.pt_accept_log: Deque[PtCtrlAcceptLog] = deque()
		self.resp_visible_log: Deque[RespVisibleLog] = deque()
		self.rd_transfer_log: Deque[RdTransferTrace] = deque()
		self.wr_transfer_log: Deque[WrTransferTrace] = deque()
		self._started = False
		self._tasks = []
		self._reset_axil_shadow()

	def register_external_matrix(self, kind: str, ctrl_id: int, matrix: Sequence[int] | Sequence[Sequence[int]]) -> None:
		if matrix and all(isinstance(row, (list, tuple)) for row in matrix):  # type: ignore[arg-type]
			flat = [to_unsigned(int(value), self.data_width) for row in matrix for value in row]  # type: ignore[union-attr]
		else:
			flat = [to_unsigned(int(value), self.data_width) for value in matrix]  # type: ignore[arg-type]
		if kind == "A":
			self.external_a_tiles[ctrl_id] = flat
		elif kind == "B":
			self.external_b_tiles[ctrl_id] = flat
		elif kind == "C":
			self.external_c_tiles[ctrl_id] = flat
		else:
			raise ValueError(f"unknown matrix kind {kind!r}")

	async def start(self) -> None:
		if self._started:
			return
		self._started = True
		self._drive_defaults()
		self._tasks = [
			cocotb.start_soon(Clock(self.dut.clk, 10, unit="ns").start()),
			cocotb.start_soon(self._ready_driver()),
			cocotb.start_soon(self._resp_fifo_monitor()),
			cocotb.start_soon(self._pt_ctrl_accept_monitor()),
			cocotb.start_soon(self._irq_monitor()),
			cocotb.start_soon(self._backpressure_monitor()),
			cocotb.start_soon(self._rd_dma_agent()),
			cocotb.start_soon(self._wr_dma_agent()),
		]

	async def reset(self, cycles: int = 5) -> None:
		self._drive_defaults()
		self.dut.rstn.value = 0
		self.dut.clear.value = 0
		await ClockCycles(self.dut.clk, cycles)
		self.dut.rstn.value = 1
		await ClockCycles(self.dut.clk, cycles)
		self._apply_soft_clear_model()

	def shutdown(self) -> None:
		if not self._started:
			return
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
		self.dut.rd_dma_desc_ready.value = 1
		self.dut.rd_dma_error.value = 0
		self.dut.s_axis_tvalid.value = 0
		self.dut.s_axis_tdata.value = 0
		self.dut.s_axis_tstrb.value = 0
		self.dut.s_axis_tlast.value = 0
		self.dut.s_axis_tkeep.value = 1
		self.dut.s_axis_tid.value = 0
		self.dut.s_axis_tdest.value = 0
		self.dut.s_axis_tuser.value = 0
		self.dut.wr_dma_desc_ready.value = 1
		self.dut.wr_dma_done.value = 0
		self.dut.wr_dma_error.value = 0
		self.dut.m_axis_tready.value = 1

	def _apply_soft_clear_model(self) -> None:
		self.model.reset_runtime_state()
		self.expected_rd_dma.clear()
		self.pending_resp_plans.clear()
		self.descriptors.clear()
		self.rd_desc_log.clear()
		self.wr_desc_log.clear()
		self.ctrl_resp_queue.clear()
		self.ab_injections.clear()
		self.export_injections.clear()
		self.rd_desc_count = 0
		self.wr_desc_count = 0
		self.dma_req_count = 0
		self.export_req_count = 0
		self.export_done_count = 0
		self.export_error_count = 0
		self.irq_count = 0
		self.dma_stream_busy = False
		self.export_busy = False
		self._resp_visible = False
		self._resp_word = 0
		self.axil_write_count = 0
		self.axil_read_count = 0
		self.pt_accept_log.clear()
		self.resp_visible_log.clear()
		self.rd_transfer_log.clear()
		self.wr_transfer_log.clear()
		self._seen_long_backpressure = False
		self.a_base_shadow = 0
		self.b_base_shadow = 0
		self.model.set_base("A", 0)
		self.model.set_base("B", 0)
		self._reset_axil_shadow()

	def _reset_axil_shadow(self) -> None:
		self.axil_reg_shadow = {
			ADDR_CTRL: 0,
			ADDR_CMD_INST: 0,
			ADDR_CMD_ID: 0,
			ADDR_A_ADDR_LO: 0,
			ADDR_A_ADDR_HI: 0,
			ADDR_B_ADDR_LO: 0,
			ADDR_B_ADDR_HI: 0,
			ADDR_C_ADDR_LO: 0,
			ADDR_C_ADDR_HI: 0,
			ADDR_M_ADDR_LO: 0,
			ADDR_M_ADDR_HI: 0,
		}

	def current_cycle(self) -> int:
		return int(get_sim_time(unit="ns")) // 10

	def snapshot_axil_counters(self) -> AxilCounterSnapshot:
		return AxilCounterSnapshot(write_count=self.axil_write_count, read_count=self.axil_read_count)

	def snapshot(self) -> CounterSnapshot:
		return CounterSnapshot(self.dma_req_count, self.export_req_count, self.export_done_count, self.export_error_count, self.irq_count)

	def configure_patterns(self, *, dma_req_ready=None, m_dma_req_ready=None, m_axis_ready=None, s_axis_valid=None) -> None:
		if dma_req_ready is not None:
			self.dma_req_ready_pattern = dma_req_ready
		if m_dma_req_ready is not None:
			self.m_dma_req_ready_pattern = m_dma_req_ready
		if m_axis_ready is not None:
			self.m_axis_ready_pattern = m_axis_ready
		if s_axis_valid is not None:
			self.s_axis_valid_pattern = s_axis_valid

	def queue_ab_injection(self, injection: AbInjection) -> None:
		self.ab_injections.append(injection)

	def queue_export_injection(self, injection: ExportInjection) -> None:
		self.export_injections.append(injection)

	def _apply_wstrb32(self, curr: int, data: int, wstrb: int) -> int:
		value = curr & 0xFFFF_FFFF
		for byte_idx in range(4):
			if wstrb & (1 << byte_idx):
				mask = 0xFF << (byte_idx * 8)
				value = (value & ~mask) | (data & mask)
		return value & 0xFFFF_FFFF

	def _shadow_word(self, addr: int) -> int:
		return self.axil_reg_shadow.get(addr & 0xFF, 0)

	def _resolve_path(self, path: str):
		handle = self.dut
		for part in path.split("."):
			handle = getattr(handle, part)
		return handle

	def _signal_value(self, path: str) -> int:
		return value_to_int(self._resolve_path(path).value)

	async def _wait_for_logged_event(
		self,
		queue: Deque[object],
		label: str,
		predicate: Callable[[object], bool],
		timeout_cycles: int = 4000,
	):
		for _ in range(timeout_cycles):
			for item in list(queue):
				if predicate(item):
					queue.remove(item)
					return item
			await RisingEdge(self.dut.clk)
		raise AssertionError(f"{label} timeout")

	def _pt_root_prefix(self) -> str:
		return "u_pt.u_pt_v2"

	def _auto_descriptor_addrs(self, ctrl_id: int) -> DescriptorAddrs:
		base_id = ctrl_id & 0xFFFF_FFFF
		return DescriptorAddrs(
			a_addr=(0x1000_0000 + ((base_id & 0xFFFF) << 8)) & 0xFFFF_FFFF,
			b_addr=(0x2000_0000 + ((base_id & 0xFFFF) << 8)) & 0xFFFF_FFFF,
			c_addr=(0x3000_0000 + ((base_id & 0xFFFF) << 8)) & 0xFFFF_FFFF,
			m_addr=(0x4000_0000 + ((base_id & 0xFFFF) << 8)) & 0xFFFF_FFFF,
		)

	def _pack_ab_beats(self, kind: str, matrix: Sequence[int], expectation: Optional[ReadDmaExpectation] = None) -> List[Tuple[int, int]]:
		beats: List[Tuple[int, int]] = []
		byte_mask = (1 << (self.data_width // 8)) - 1
		if kind == "A":
			if expectation is not None:
				k_dim = self.x_dim * expectation.k_tiles
				m_dim = self.x_dim * expectation.m_tiles
				assert len(matrix) == m_dim * k_dim
				stream_words = [
					int(matrix[((m_tile * self.x_dim) + row) * k_dim + col])
					for m_tile in range(expectation.m_tiles)
					for col in range(k_dim)
					for row in range(self.x_dim)
				]
			elif len(matrix) % self.x_dim == 0:
				k_dim = len(matrix) // self.x_dim
				stream_words = [int(matrix[row * k_dim + col]) for col in range(k_dim) for row in range(self.x_dim)]
			else:
				stream_words = [int(word) for word in matrix]
			for start in range(0, len(stream_words), self.a_load_lanes):
				chunk = stream_words[start : start + self.a_load_lanes]
				beat_data = 0
				beat_strb = 0
				for lane_idx, word in enumerate(chunk):
					beat_data |= to_unsigned(word, self.data_width) << (lane_idx * self.data_width)
					beat_strb |= byte_mask << (lane_idx * (self.data_width // 8))
				beats.append((beat_data, beat_strb))
		else:
			if expectation is not None and kind == "B":
				k_dim = self.y_dim * expectation.k_tiles
				n_dim = self.y_dim * expectation.n_tiles
				assert len(matrix) == k_dim * n_dim
				stream_words = [
					int(matrix[row * n_dim + (n_tile * self.y_dim) + col])
					for n_tile in range(expectation.n_tiles)
					for row in range(k_dim)
					for col in range(self.y_dim)
				]
			else:
				stream_words = [int(word) for word in matrix]
			for start in range(0, len(stream_words), self.b_load_lanes):
				chunk = stream_words[start : start + self.b_load_lanes]
				beat_data = 0
				beat_strb = 0
				for lane_idx, word in enumerate(chunk):
					beat_data |= to_unsigned(word, self.data_width) << (lane_idx * self.data_width)
					beat_strb |= byte_mask << (lane_idx * (self.data_width // 8))
				beats.append((beat_data, beat_strb))
		return beats

	def _pack_export_beats(self, matrix: Sequence[int]) -> List[Tuple[int, int]]:
		beats: List[Tuple[int, int]] = []
		byte_mask = (1 << (self.data_width // 8)) - 1
		for start in range(0, len(matrix), self.m_export_lanes):
			chunk = list(matrix[start : start + self.m_export_lanes])
			beat_data = 0
			beat_strb = 0
			for lane_idx, word in enumerate(chunk):
				beat_data |= to_unsigned(int(word), self.data_width) << (lane_idx * self.data_width)
				beat_strb |= byte_mask << (lane_idx * (self.data_width // 8))
			beats.append((beat_data, beat_strb))
		return beats

	async def axil_write(self, addr: int, data: int, wstrb: int = 0xF, write_delay_cycles: int = 0) -> int:
		self.axil_write_count += 1
		self.dut.s_axil_awaddr.value = addr
		self.dut.s_axil_awvalid.value = 1
		self.dut.s_axil_wdata.value = data & 0xFFFF_FFFF
		self.dut.s_axil_wstrb.value = wstrb & 0xF
		self.dut.s_axil_wvalid.value = 0 if write_delay_cycles > 0 else 1
		self.dut.s_axil_bready.value = 1

		aw_done = False
		w_done = False
		delay_count = write_delay_cycles
		for _ in range(200):
			await RisingEdge(self.dut.clk)
			if delay_count > 0:
				delay_count -= 1
				if delay_count == 0:
					self.dut.s_axil_wvalid.value = 1
			if not aw_done and value_to_int(self.dut.s_axil_awvalid.value) and value_to_int(self.dut.s_axil_awready.value):
				aw_done = True
				self.dut.s_axil_awvalid.value = 0
			if not w_done and value_to_int(self.dut.s_axil_wvalid.value) and value_to_int(self.dut.s_axil_wready.value):
				w_done = True
				self.dut.s_axil_wvalid.value = 0
			if aw_done and w_done:
				break
		else:
			raise AssertionError(f"AXI-Lite write handshake timeout at 0x{addr:02x}")

		for _ in range(200):
			await RisingEdge(self.dut.clk)
			if value_to_int(self.dut.s_axil_bvalid.value):
				resp = value_to_int(self.dut.s_axil_bresp.value)
				await RisingEdge(self.dut.clk)
				self.dut.s_axil_bready.value = 0
				addr8 = addr & 0xFF
				if addr8 != ADDR_CTRL:
					self.axil_reg_shadow[addr8] = self._apply_wstrb32(self._shadow_word(addr8), data, wstrb)
				return resp
		raise AssertionError(f"AXI-Lite write response timeout at 0x{addr:02x}")

	async def axil_read(self, addr: int) -> int:
		self.axil_read_count += 1
		self.dut.s_axil_araddr.value = addr
		self.dut.s_axil_arvalid.value = 1
		self.dut.s_axil_rready.value = 1
		for _ in range(200):
			await RisingEdge(self.dut.clk)
			if value_to_int(self.dut.s_axil_arvalid.value) and value_to_int(self.dut.s_axil_arready.value):
				self.dut.s_axil_arvalid.value = 0
				break
		else:
			raise AssertionError(f"AXI-Lite read address timeout at 0x{addr:02x}")

		for _ in range(200):
			await RisingEdge(self.dut.clk)
			if value_to_int(self.dut.s_axil_rvalid.value):
				data = value_to_int(self.dut.s_axil_rdata.value)
				await RisingEdge(self.dut.clk)
				self.dut.s_axil_rready.value = 0
				return data
		raise AssertionError(f"AXI-Lite read data timeout at 0x{addr:02x}")

	async def _write_addr64(self, addr_lo: int, addr_hi: int, value: int) -> None:
		await self.axil_write(addr_lo, value & 0xFFFF_FFFF)
		await self.axil_write(addr_hi, (value >> 32) & 0xFFFF_FFFF)

	async def _write_addr64_delta(self, addr_lo: int, addr_hi: int, value: int, write_addrs: List[int]) -> None:
		word_lo = value & 0xFFFF_FFFF
		word_hi = (value >> 32) & 0xFFFF_FFFF
		if self._shadow_word(addr_lo) != word_lo:
			await self.axil_write(addr_lo, word_lo)
			write_addrs.append(addr_lo)
		if self._shadow_word(addr_hi) != word_hi:
			await self.axil_write(addr_hi, word_hi)
			write_addrs.append(addr_hi)

	async def send_desc_command_timed(
		self,
		inst: int,
		ctrl_id: int,
		*,
		a_addr: int = 0,
		b_addr: int = 0,
		c_addr: int = 0,
		m_addr: int = 0,
		ctrl_write_delay_cycles: int = 0,
		mode: str = "full",
	) -> DescCommandTrace:
		self.descriptors[ctrl_id & 0xFFFF_FFFF] = DescriptorAddrs(
			a_addr=a_addr & 0xFFFF_FFFF_FFFF_FFFF,
			b_addr=b_addr & 0xFFFF_FFFF_FFFF_FFFF,
			c_addr=c_addr & 0xFFFF_FFFF_FFFF_FFFF,
			m_addr=m_addr & 0xFFFF_FFFF_FFFF_FFFF,
		)
		before = self.snapshot_axil_counters()
		write_addrs: List[int] = []
		first_write_start_cycle: Optional[int] = None
		ctrl_write_start_cycle: Optional[int] = None

		async def traced_write(addr: int, data: int, wstrb: int = 0xF, write_delay_cycles_local: int = 0) -> None:
			nonlocal first_write_start_cycle, ctrl_write_start_cycle
			start_cycle = self.current_cycle()
			if first_write_start_cycle is None:
				first_write_start_cycle = start_cycle
			if (addr & 0xFF) == ADDR_CTRL:
				ctrl_write_start_cycle = start_cycle
			await self.axil_write(addr, data, wstrb=wstrb, write_delay_cycles=write_delay_cycles_local)
			write_addrs.append(addr & 0xFF)

		if mode == "full":
			await traced_write(ADDR_CMD_INST, inst & 0xFFFF_FFFF)
			await traced_write(ADDR_CMD_ID, ctrl_id & 0xFFFF_FFFF)
			await traced_write(ADDR_A_ADDR_LO, a_addr & 0xFFFF_FFFF)
			await traced_write(ADDR_A_ADDR_HI, (a_addr >> 32) & 0xFFFF_FFFF)
			await traced_write(ADDR_B_ADDR_LO, b_addr & 0xFFFF_FFFF)
			await traced_write(ADDR_B_ADDR_HI, (b_addr >> 32) & 0xFFFF_FFFF)
			await traced_write(ADDR_C_ADDR_LO, c_addr & 0xFFFF_FFFF)
			await traced_write(ADDR_C_ADDR_HI, (c_addr >> 32) & 0xFFFF_FFFF)
			await traced_write(ADDR_M_ADDR_LO, m_addr & 0xFFFF_FFFF)
			await traced_write(ADDR_M_ADDR_HI, (m_addr >> 32) & 0xFFFF_FFFF)
			await traced_write(ADDR_CTRL, CTRL_DESC_PUSH, write_delay_cycles_local=ctrl_write_delay_cycles)
		elif mode == "delta":
			if self._shadow_word(ADDR_CMD_INST) != (inst & 0xFFFF_FFFF):
				await traced_write(ADDR_CMD_INST, inst & 0xFFFF_FFFF)
			if self._shadow_word(ADDR_CMD_ID) != (ctrl_id & 0xFFFF_FFFF):
				await traced_write(ADDR_CMD_ID, ctrl_id & 0xFFFF_FFFF)
			if first_write_start_cycle is None and (
				self._shadow_word(ADDR_A_ADDR_LO) != (a_addr & 0xFFFF_FFFF)
				or self._shadow_word(ADDR_A_ADDR_HI) != ((a_addr >> 32) & 0xFFFF_FFFF)
				or self._shadow_word(ADDR_B_ADDR_LO) != (b_addr & 0xFFFF_FFFF)
				or self._shadow_word(ADDR_B_ADDR_HI) != ((b_addr >> 32) & 0xFFFF_FFFF)
				or self._shadow_word(ADDR_C_ADDR_LO) != (c_addr & 0xFFFF_FFFF)
				or self._shadow_word(ADDR_C_ADDR_HI) != ((c_addr >> 32) & 0xFFFF_FFFF)
				or self._shadow_word(ADDR_M_ADDR_LO) != (m_addr & 0xFFFF_FFFF)
				or self._shadow_word(ADDR_M_ADDR_HI) != ((m_addr >> 32) & 0xFFFF_FFFF)
			):
				first_write_start_cycle = self.current_cycle()
			await self._write_addr64_delta(ADDR_A_ADDR_LO, ADDR_A_ADDR_HI, a_addr, write_addrs)
			await self._write_addr64_delta(ADDR_B_ADDR_LO, ADDR_B_ADDR_HI, b_addr, write_addrs)
			await self._write_addr64_delta(ADDR_C_ADDR_LO, ADDR_C_ADDR_HI, c_addr, write_addrs)
			await self._write_addr64_delta(ADDR_M_ADDR_LO, ADDR_M_ADDR_HI, m_addr, write_addrs)
			if first_write_start_cycle is None:
				first_write_start_cycle = self.current_cycle()
			ctrl_write_start_cycle = self.current_cycle()
			await self.axil_write(ADDR_CTRL, CTRL_DESC_PUSH, write_delay_cycles=ctrl_write_delay_cycles)
			write_addrs.append(ADDR_CTRL)
		else:
			raise ValueError(f"unknown desc command mode {mode!r}")

		assert first_write_start_cycle is not None
		assert ctrl_write_start_cycle is not None
		after = self.snapshot_axil_counters()
		return DescCommandTrace(
			ctrl_id=ctrl_id & 0xFFFF_FFFF,
			mode=mode,
			first_write_start_cycle=first_write_start_cycle,
			ctrl_write_start_cycle=ctrl_write_start_cycle,
			return_cycle=self.current_cycle(),
			axil_writes=after.write_count - before.write_count,
			axil_reads=after.read_count - before.read_count,
			write_addrs=tuple(write_addrs),
		)

	async def send_desc_command(
		self,
		inst: int,
		ctrl_id: int,
		*,
		a_addr: int = 0,
		b_addr: int = 0,
		c_addr: int = 0,
		m_addr: int = 0,
		ctrl_write_delay_cycles: int = 0,
	) -> None:
		await self.send_desc_command_timed(
			inst,
			ctrl_id,
			a_addr=a_addr,
			b_addr=b_addr,
			c_addr=c_addr,
			m_addr=m_addr,
			ctrl_write_delay_cycles=ctrl_write_delay_cycles,
			mode="full",
		)

	async def wait_status(self, mask: int, expected: bool = True, timeout_cycles: int = 4000) -> int:
		for _ in range(timeout_cycles):
			status = await self.axil_read(ADDR_STATUS)
			if bool(status & mask) == expected:
				return status
			await RisingEdge(self.dut.clk)
		raise AssertionError(f"status wait timeout mask=0x{mask:02x} expected={expected}")

	async def wait_irq(self, expected: bool, timeout_cycles: int = 4000) -> None:
		for _ in range(timeout_cycles):
			if bool(value_to_int(self.dut.irq.value)) == expected:
				return
			await RisingEdge(self.dut.clk)
		raise AssertionError(f"irq wait timeout expected={expected}")

	async def wait_rd_desc_count(self, target: int, timeout_cycles: int = 4000) -> None:
		for _ in range(timeout_cycles):
			if self.rd_desc_count >= target:
				return
			await RisingEdge(self.dut.clk)
		raise AssertionError(f"rd_desc timeout exp>={target} got={self.rd_desc_count}")

	async def wait_wr_desc_count(self, target: int, timeout_cycles: int = 4000) -> None:
		for _ in range(timeout_cycles):
			if self.wr_desc_count >= target:
				return
			await RisingEdge(self.dut.clk)
		raise AssertionError(f"wr_desc timeout exp>={target} got={self.wr_desc_count}")

	async def wait_export_done(self, target: int, timeout_cycles: int = 4000) -> None:
		for _ in range(timeout_cycles):
			if self.export_done_count >= target:
				return
			await RisingEdge(self.dut.clk)
		raise AssertionError(f"export_done timeout exp>={target} got={self.export_done_count}")

	async def pop_resp(self) -> None:
		await self.axil_write(ADDR_CTRL, CTRL_RESP_POP)
		await ClockCycles(self.dut.clk, 2)

	async def soft_clear(self) -> None:
		await self.axil_write(ADDR_CTRL, CTRL_SOFT_CLEAR)
		await ClockCycles(self.dut.clk, 3)
		self._apply_soft_clear_model()

	async def clear_flags(self) -> None:
		await self.axil_write(ADDR_CTRL, CTRL_CLEAR_FLAGS)
		await ClockCycles(self.dut.clk, 2)

	async def pulse_clear(self, cycles: int = 1, phase: str = "generic") -> None:
		if phase:
			self.coverage.hit(f"clear:{phase}")
		self.dut.clear.value = 1
		self.dut.s_axil_awvalid.value = 0
		self.dut.s_axil_wvalid.value = 0
		self.dut.s_axil_arvalid.value = 0
		self.dut.s_axis_tvalid.value = 0
		self.dut.s_axis_tlast.value = 0
		self.dut.rd_dma_error.value = 0
		self.dut.wr_dma_done.value = 0
		self.dut.wr_dma_error.value = 0
		await ClockCycles(self.dut.clk, cycles)
		self.dut.clear.value = 0
		await RisingEdge(self.dut.clk)
		self._apply_soft_clear_model()

	async def wait_and_pop_resp(self, expected_word: int, timeout_cycles: int = 4000) -> int:
		for _ in range(timeout_cycles):
			status = await self.axil_read(ADDR_STATUS)
			if status & STATUS_RESP_FIFO_NOT_EMPTY:
				head = await self.axil_read(ADDR_RESP_HEAD)
				assert head == expected_word, f"resp mismatch exp=0x{expected_word:08x} got=0x{head:08x}"
				await self.pop_resp()
				if self.ctrl_resp_queue and self.ctrl_resp_queue[0] == head:
					self.ctrl_resp_queue.popleft()
				self._finalize_pending_plan(head)
				return head
			await RisingEdge(self.dut.clk)
		raise AssertionError(f"resp timeout waiting for 0x{expected_word:08x}")

	async def wait_pt_ctrl_accept(self, ctrl_id: int, after_cycle: int = 0, timeout_cycles: int = 4000) -> PtCtrlAcceptLog:
		return await self._wait_for_logged_event(
			self.pt_accept_log,
			f"pt ctrl accept id=0x{ctrl_id & 0xFFFF_FFFF:08x}",
			lambda item: isinstance(item, PtCtrlAcceptLog)
			and item.ctrl_id == (ctrl_id & 0xFFFF_FFFF)
			and item.cycle >= after_cycle,
			timeout_cycles,
		)

	async def wait_resp_visible(self, expected_word: int, after_cycle: int = 0, timeout_cycles: int = 4000) -> RespVisibleLog:
		return await self._wait_for_logged_event(
			self.resp_visible_log,
			f"resp visible 0x{expected_word:08x}",
			lambda item: isinstance(item, RespVisibleLog)
			and item.word == (expected_word & 0xFFFF_FFFF)
			and item.cycle >= after_cycle,
			timeout_cycles,
		)

	async def wait_rd_transfer(self, ctrl_id: int, kind: int, after_cycle: int = 0, timeout_cycles: int = 4000) -> RdTransferTrace:
		return await self._wait_for_logged_event(
			self.rd_transfer_log,
			f"rd transfer id=0x{ctrl_id & 0xFFFF_FFFF:08x} kind={kind}",
			lambda item: isinstance(item, RdTransferTrace)
			and item.ctrl_id == (ctrl_id & 0xFFFF_FFFF)
			and item.kind == kind
			and item.desc_cycle >= after_cycle,
			timeout_cycles,
		)

	async def wait_wr_transfer(self, ctrl_id: int, after_cycle: int = 0, timeout_cycles: int = 4000) -> WrTransferTrace:
		return await self._wait_for_logged_event(
			self.wr_transfer_log,
			f"wr transfer id=0x{ctrl_id & 0xFFFF_FFFF:08x}",
			lambda item: isinstance(item, WrTransferTrace)
			and item.ctrl_id == (ctrl_id & 0xFFFF_FFFF)
			and item.desc_cycle >= after_cycle,
			timeout_cycles,
		)

	async def wait_ctrl_resp(self, expected_word: int, timeout_cycles: int = 4000) -> int:
		for _ in range(timeout_cycles):
			if self.ctrl_resp_queue:
				actual = self.ctrl_resp_queue.popleft()
				assert actual == expected_word, f"ctrl_resp mismatch exp=0x{expected_word:08x} got=0x{actual:08x}"
				await self.pop_resp()
				return actual
			await RisingEdge(self.dut.clk)
		raise AssertionError(f"ctrl_resp timeout waiting for 0x{expected_word:08x}")

	async def expect_no_ctrl_resp(self, wait_cycles: int) -> None:
		for _ in range(wait_cycles):
			assert not self.ctrl_resp_queue, f"unexpected queued ctrl_resp 0x{self.ctrl_resp_queue[0]:08x}"
			await RisingEdge(self.dut.clk)
			assert not self.ctrl_resp_queue, f"unexpected ctrl_resp 0x{self.ctrl_resp_queue[0]:08x}"

	async def wait_export_error(self, target_error_count: int, timeout_cycles: int = 4000) -> None:
		for _ in range(timeout_cycles):
			if self.export_error_count >= target_error_count:
				return
			await RisingEdge(self.dut.clk)
		raise AssertionError(f"export_error timeout exp>={target_error_count} got={self.export_error_count}")

	async def wait_dma_req(self, target_req_count: int, timeout_cycles: int = 4000) -> None:
		for _ in range(timeout_cycles):
			if self.dma_req_count >= target_req_count:
				return
			await RisingEdge(self.dut.clk)
		raise AssertionError(f"dma_req timeout exp>={target_req_count} got={self.dma_req_count}")

	async def wait_export_req(self, target_req_count: int, timeout_cycles: int = 4000) -> None:
		for _ in range(timeout_cycles):
			if self.export_req_count >= target_req_count:
				return
			await RisingEdge(self.dut.clk)
		raise AssertionError(f"export_req timeout exp>={target_req_count} got={self.export_req_count}")

	async def wait_signal_value(self, signal_name: str, expected_value: int, timeout_cycles: int = 4000) -> None:
		alias_map = {
			"dma_req_valid": "rd_dma_desc_valid",
			"dma_req_ready": "rd_dma_desc_ready",
			"m_dma_req_valid": "wr_dma_desc_valid",
			"m_dma_req_ready": "wr_dma_desc_ready",
		}
		signal = getattr(self.dut, alias_map.get(signal_name, signal_name))
		for _ in range(timeout_cycles):
			if value_to_int(signal.value) == expected_value:
				return
			await RisingEdge(self.dut.clk)
		raise AssertionError(f"{signal_name} timeout exp={expected_value} got={value_to_int(signal.value)}")

	async def wait_malloc_slot_scan(self, ctrl_id: int, timeout_cycles: int = 4000) -> Dict[str, int]:
		root = self._pt_root_prefix()
		for cycle in range(timeout_cycles):
			await ReadOnly()
			if self._signal_value(f"{root}.malloc_cmd_valid") and self._signal_value(f"{root}.malloc_cmd_id") == (ctrl_id & 0xFFFF_FFFF):
				return {
					"slot_found": self._signal_value(f"{root}.u_malloc.slot_found"),
					"slot_idx": self._signal_value(f"{root}.u_malloc.slot_idx"),
					"free_found": self._signal_value(f"{root}.u_malloc.free_found"),
					"free_idx": self._signal_value(f"{root}.u_malloc.free_idx"),
					"cmd_slot_idx": self._signal_value(f"{root}.u_malloc.cmd_slot_idx"),
				}
			if cycle != (timeout_cycles - 1):
				await RisingEdge(self.dut.clk)
		raise AssertionError(f"malloc_cmd timeout for ctrl_id=0x{ctrl_id:08x}")

	def _queue_pending_plan(self, response_word: int, plan_kind: str, plan: ExecPlan | LoadPlan) -> None:
		self.pending_resp_plans.setdefault(response_word, deque()).append((plan_kind, plan))

	def _finalize_pending_plan(self, response_word: int) -> None:
		plan_queue = self.pending_resp_plans.get(response_word)
		if not plan_queue:
			return None, False
		plan_kind, plan = plan_queue.popleft()
		if not plan_queue:
			del self.pending_resp_plans[response_word]
		if plan_kind == "exec":
			exec_plan = plan
			if not exec_plan.err:
				self.model.commit_success(exec_plan)
			return plan_kind, exec_plan.err
		elif plan_kind == "load":
			load_plan = plan
			if not load_plan.err:
				self.model.commit_load_success(load_plan)
			return plan_kind, load_plan.err
		return None, False

	async def _ready_driver(self) -> None:
		try:
			while True:
				self.dut.rd_dma_desc_ready.value = 0 if self.dma_stream_busy else self.dma_req_ready_pattern.next()
				self.dut.wr_dma_desc_ready.value = 0 if self.export_busy else self.m_dma_req_ready_pattern.next()
				self.dut.m_axis_tready.value = self.m_axis_ready_pattern.next()
				await RisingEdge(self.dut.clk)
		except Exception:
			self.dut._log.exception("ready_driver crashed")
			raise

	async def _resp_fifo_monitor(self) -> None:
		try:
			while True:
				await RisingEdge(self.dut.clk)
				await ReadOnly()
				resp_valid = value_to_int(self.dut.u_resp_fifo.valid_out.value)
				resp_word = value_to_int(self.dut.u_resp_fifo.data_out.value)
				if resp_valid:
					if (not self._resp_visible) or (resp_word != self._resp_word):
						plan_kind, plan_err = self._finalize_pending_plan(resp_word)
						self._resp_visible = True
						self._resp_word = resp_word
						self.resp_visible_log.append(RespVisibleLog(word=resp_word, cycle=self.current_cycle()))
						self.ctrl_resp_queue.append(resp_word)
						if ((resp_word >> 31) & 0x1) or (plan_kind == "exec" and not plan_err):
							self.irq_count += 1
				else:
					self._resp_visible = False
		except Exception:
			self.dut._log.exception("resp_fifo_monitor crashed")
			raise

	async def _pt_ctrl_accept_monitor(self) -> None:
		try:
			while True:
				await RisingEdge(self.dut.clk)
				await ReadOnly()
				if self._signal_value("pt_ctrl_valid") and self._signal_value("pt_ctrl_ready"):
					self.pt_accept_log.append(
						PtCtrlAcceptLog(
							ctrl_id=self._signal_value("pt_ctrl_id"),
							inst=self._signal_value("pt_ctrl_inst"),
							cycle=self.current_cycle(),
						)
					)
		except Exception:
			self.dut._log.exception("pt_ctrl_accept_monitor crashed")
			raise

	async def send_ctrl_timed(self, inst: int, ctrl_id: int, timeout_cycles: int = 4000) -> CtrlSendTrace:
		del timeout_cycles
		desc = self.descriptors.get(ctrl_id & 0xFFFF_FFFF, self._auto_descriptor_addrs(ctrl_id))
		trace = await self.send_desc_command_timed(
			inst,
			ctrl_id,
			a_addr=desc.a_addr,
			b_addr=desc.b_addr,
			c_addr=desc.c_addr,
			m_addr=desc.m_addr,
			mode="delta" if (ctrl_id & 0xFFFF_FFFF) in self.descriptors else "full",
		)
		accept = await self.wait_pt_ctrl_accept(ctrl_id, after_cycle=trace.ctrl_write_start_cycle)
		wait_cycles = max(1, accept.cycle - trace.ctrl_write_start_cycle)
		ready_low_cycles = max(0, wait_cycles - 1)
		return CtrlSendTrace(wait_cycles=wait_cycles, ready_low_cycles=ready_low_cycles)

	async def send_ctrl(self, inst: int, ctrl_id: int) -> CtrlSendTrace:
		return await self.send_ctrl_timed(inst, ctrl_id)

	async def _irq_monitor(self) -> None:
		try:
			while True:
				await RisingEdge(self.dut.clk)
				await ReadOnly()
				_ = value_to_int(self.dut.irq.value)
		except Exception:
			self.dut._log.exception("irq_monitor crashed")
			raise

	async def _backpressure_monitor(self) -> None:
		dma_block = 0
		export_req_block = 0
		axis_block = 0
		try:
			while True:
				await RisingEdge(self.dut.clk)
				await ReadOnly()
				dma_block = dma_block + 1 if value_to_int(self.dut.rd_dma_desc_valid.value) and not value_to_int(self.dut.rd_dma_desc_ready.value) else 0
				export_req_block = export_req_block + 1 if value_to_int(self.dut.wr_dma_desc_valid.value) and not value_to_int(self.dut.wr_dma_desc_ready.value) else 0
				axis_block = axis_block + 1 if value_to_int(self.dut.m_axis_tvalid.value) and not value_to_int(self.dut.m_axis_tready.value) else 0
				if not self._seen_long_backpressure and max(dma_block, export_req_block, axis_block) >= BACKPRESSURE_LONG_THRESHOLD:
					self.coverage.hit("backpressure:long_phase")
					self._seen_long_backpressure = True
		except Exception:
			self.dut._log.exception("backpressure_monitor crashed")
			raise

	def plan_load(self, ctrl_id: int, a_size: int, b_size: int, *, need_a: bool, need_b: bool, reserved_lo: int = 0) -> LoadPlan:
		plan = self.model.issue_load(
			ctrl_id,
			a_size,
			b_size,
			need_a=need_a,
			need_b=need_b,
			external_a_tiles=self.external_a_tiles,
			external_b_tiles=self.external_b_tiles,
			reserved_lo=reserved_lo,
		)
		self.coverage.hit_many(plan.coverage_tags)
		if plan.reject_reason:
			self.coverage.hit(plan.reject_reason)
		self._queue_pending_plan(plan.response_word, "load", plan)
		desc = self.descriptors.get(ctrl_id & 0xFFFF_FFFF, self._auto_descriptor_addrs(ctrl_id))
		for expected_req in plan.expected_dma_loads:
			if expected_req.kind == "A":
				self.expected_rd_dma.append(ReadDmaExpectation(ctrl_id, "A", desc.a_addr, plan.a_size, expected_req.m_tiles, expected_req.n_tiles, expected_req.k_tiles))
			elif expected_req.kind == "B":
				self.expected_rd_dma.append(ReadDmaExpectation(ctrl_id, "B", desc.b_addr, plan.b_size, expected_req.m_tiles, expected_req.n_tiles, expected_req.k_tiles))
		return plan

	def plan_matmul(self, ctrl_id: int, *, m_scale: int, n_scale: int, k_scale: int, reserved_a: int = 0, reserved_b: int = 0) -> ExecPlan:
		plan = self.model.issue_matmul(
			ctrl_id,
			self.external_a_tiles,
			self.external_b_tiles,
			m_scale,
			n_scale,
			k_scale,
			reserved_a,
			reserved_b,
		)
		self.coverage.hit_many(plan.coverage_tags)
		if plan.reject_reason:
			self.coverage.hit(plan.reject_reason)
		self._queue_pending_plan(plan.response_word, "exec", plan)
		desc = self.descriptors.get(ctrl_id & 0xFFFF_FFFF, self._auto_descriptor_addrs(ctrl_id))
		for expected_req in plan.expected_dma_loads:
			if expected_req.kind == "A":
				self.expected_rd_dma.append(ReadDmaExpectation(ctrl_id, "A", desc.a_addr, plan.a_len, expected_req.m_tiles, expected_req.n_tiles, expected_req.k_tiles))
			elif expected_req.kind == "B":
				self.expected_rd_dma.append(ReadDmaExpectation(ctrl_id, "B", desc.b_addr, plan.b_len, expected_req.m_tiles, expected_req.n_tiles, expected_req.k_tiles))
		return plan

	def plan_matadd(self, ctrl_id: int, m_off: int, *, c_field: int = 0, reserved_hi: int = 0, reserved_lo: int = 0) -> ExecPlan:
		plan = self.model.issue_matadd(
			ctrl_id,
			m_off,
			self.external_c_tiles,
			c_field=c_field,
			reserved_hi=reserved_hi,
			reserved_lo=reserved_lo,
		)
		self.coverage.hit_many(plan.coverage_tags)
		if plan.reject_reason:
			self.coverage.hit(plan.reject_reason)
		self._queue_pending_plan(plan.response_word, "exec", plan)
		desc = self.descriptors.get(ctrl_id & 0xFFFF_FFFF, self._auto_descriptor_addrs(ctrl_id))
		for expected_req in plan.expected_dma_loads:
			if expected_req.kind == "C":
				self.expected_rd_dma.append(ReadDmaExpectation(ctrl_id, "C", desc.c_addr, plan.b_len))
		return plan

	async def cfg_selector16(self, selector: int, value16: int, ctrl_id: int) -> None:
		self.coverage.hit("cmd:cfg")
		if selector in CSR_SELECTOR_BINS:
			self.coverage.hit(CSR_SELECTOR_BINS[selector])
		self.coverage.hit(classify_csr_pattern(value16))
		await self.send_desc_command(build_cfg_inst(selector, value16 & 0xFFFF), ctrl_id)
		await self.wait_and_pop_resp(pack_resp(False, 0, ctrl_id))
		word = value16 & 0xFFFF
		if selector == PT_CFG_A_BASE_LO:
			self.a_base_shadow = (self.a_base_shadow & 0xFFFF_0000) | word
			self.model.set_base("A", self.a_base_shadow)
		elif selector == PT_CFG_A_BASE_HI:
			self.a_base_shadow = ((word << 16) & 0xFFFF_0000) | (self.a_base_shadow & 0x0000_FFFF)
			self.model.set_base("A", self.a_base_shadow)
		elif selector == PT_CFG_B_BASE_LO:
			self.b_base_shadow = (self.b_base_shadow & 0xFFFF_0000) | word
			self.model.set_base("B", self.b_base_shadow)
		elif selector == PT_CFG_B_BASE_HI:
			self.b_base_shadow = ((word << 16) & 0xFFFF_0000) | (self.b_base_shadow & 0x0000_FFFF)
			self.model.set_base("B", self.b_base_shadow)

	def read_csr_bases(self) -> Tuple[int, int]:
		root = self._pt_root_prefix()
		return (
			self._signal_value(f"{root}.pcsr_a_base"),
			self._signal_value(f"{root}.pcsr_b_base"),
		)

	async def cfg_base(self, kind: str, value: int, ctrl_id: int) -> None:
		selector = PT_CFG_A_BASE_LO if kind == "A" else PT_CFG_B_BASE_LO
		await self.cfg_selector16(selector, value & 0xFFFF, ctrl_id)

	async def cfg_base32(self, kind: str, value: int, ctrl_id_base: int) -> None:
		if kind == "A":
			selector_lo = PT_CFG_A_BASE_LO
			selector_hi = PT_CFG_A_BASE_HI
		else:
			selector_lo = PT_CFG_B_BASE_LO
			selector_hi = PT_CFG_B_BASE_HI
		await self.cfg_selector16(selector_lo, value & 0xFFFF, ctrl_id_base)
		await self.cfg_selector16(selector_hi, (value >> 16) & 0xFFFF, ctrl_id_base + 1)

	async def qcfg_success(self, granularity: int, inv_scales: Sequence[int], ctrl_id: int) -> None:
		payload_count = qcfg_payload_count(granularity, self.x_dim, self.y_dim)
		assert payload_count is not None
		assert payload_count == len(inv_scales)
		self.coverage.hit("cmd:qcfg")
		mode_bin = {
			0: "qcfg:per_tensor",
			1: "qcfg:x_wise",
			2: "qcfg:y_wise",
			3: "qcfg:x_wise_div2",
			4: "qcfg:y_wise_div2",
		}.get(granularity)
		if mode_bin:
			self.coverage.hit(mode_bin)
		await self.send_desc_command(build_qcfg_header(granularity, qtype=PT_QTYPE_SYMMETRIC), ctrl_id)
		for _ in range(2):
			await RisingEdge(self.dut.clk)
		for idx, word in enumerate(inv_scales):
			await self.send_desc_command(to_unsigned(word, 32), ctrl_id)
			if idx == (len(inv_scales) - 1):
				await self.wait_ctrl_resp(pack_resp(False, 0, ctrl_id))
			else:
				await self.expect_no_ctrl_resp(2)
		self.model.set_qcfg(granularity, inv_scales)

	async def _rd_dma_agent(self) -> None:
		try:
			while True:
				await RisingEdge(self.dut.clk)
				await ReadOnly()
				if value_to_int(self.dut.rd_dma_desc_valid.value) and value_to_int(self.dut.rd_dma_desc_ready.value):
					desc_cycle = self.current_cycle()
					self.rd_desc_count += 1
					self.dma_req_count += 1
					assert self.expected_rd_dma, "unexpected rd_dma_desc handshake"
					expected = self.expected_rd_dma.popleft()
					actual_id = value_to_int(self.dut.rd_dma_desc_id.value)
					actual_kind = value_to_int(self.dut.rd_dma_desc_kind.value)
					actual_addr = value_to_int(self.dut.rd_dma_desc_addr.value)
					actual_elems = value_to_int(self.dut.rd_dma_desc_elems.value)
					assert actual_id == (expected.ctrl_id & 0xFFFF_FFFF)
					exp_kind = {"A": DMA_KIND_A, "B": DMA_KIND_B, "C": DMA_KIND_C}[expected.kind]
					assert actual_kind == exp_kind
					assert actual_addr == expected.addr
					assert actual_elems == expected.elems
					self.rd_desc_log.append(ReadDmaLog(ctrl_id=actual_id, kind=actual_kind, addr=actual_addr, elems=actual_elems))
					injection = self.ab_injections.popleft() if self.ab_injections else AbInjection()
					beats = self._pack_ab_beats(expected.kind, self.external_a_tiles[actual_id] if expected.kind == "A" else (self.external_b_tiles[actual_id] if expected.kind == "B" else self.external_c_tiles[actual_id]), expected)
					self.dma_stream_busy = True
					last_beat_cycle = await self._serve_rd_stream(expected, beats, injection)
					self.dma_stream_busy = False
					self.rd_transfer_log.append(
						RdTransferTrace(
							ctrl_id=actual_id,
							kind=actual_kind,
							addr=actual_addr,
							elems=actual_elems,
							beats=len(beats),
							desc_cycle=desc_cycle,
							last_beat_cycle=last_beat_cycle,
						)
					)
		except Exception:
			self.dut._log.exception("rd_dma_agent crashed")
			raise

	async def _serve_rd_stream(self, expectation: ReadDmaExpectation, beats: Sequence[Tuple[int, int]], injection: AbInjection) -> int:
		ctrl_id = expectation.ctrl_id
		kind = expectation.kind
		if kind == "A":
			matrix = self.external_a_tiles[ctrl_id]
			req_tuser = MATRIX_A_TUSER
		elif kind == "B":
			matrix = self.external_b_tiles[ctrl_id]
			req_tuser = MATRIX_B_TUSER
		else:
			matrix = self.external_c_tiles[ctrl_id]
			req_tuser = MATRIX_C_TUSER
		if injection.error_mode == "before_stream":
			await RisingEdge(self.dut.clk)
			self.dut.rd_dma_error.value = 1
			await RisingEdge(self.dut.clk)
			self.dut.rd_dma_error.value = 0
			return self.current_cycle()
		await RisingEdge(self.dut.clk)
		last_beat_cycle = self.current_cycle()
		bad_tuser = MATRIX_B_TUSER if req_tuser == MATRIX_A_TUSER else MATRIX_A_TUSER
		for beat_idx, (word, strb) in enumerate(beats):
			while True:
				offer = self.s_axis_valid_pattern.next()
				if not offer:
					self.dut.s_axis_tvalid.value = 0
					self.dut.s_axis_tlast.value = 0
					await RisingEdge(self.dut.clk)
					continue
				self.dut.s_axis_tvalid.value = 1
				self.dut.s_axis_tdata.value = word
				self.dut.s_axis_tstrb.value = strb
				self.dut.s_axis_tuser.value = bad_tuser if injection.wrong_tuser else req_tuser
				self.dut.s_axis_tlast.value = 1 if beat_idx == (len(beats) - 1) else 0
				await RisingEdge(self.dut.clk)
				if value_to_int(self.dut.s_axis_tready.value):
					last_beat_cycle = self.current_cycle()
					break
			if injection.error_mode == "mid_stream" and beat_idx == injection.error_at_beat:
				self.dut.s_axis_tvalid.value = 0
				self.dut.s_axis_tlast.value = 0
				self.dut.rd_dma_error.value = 1
				for _ in range(injection.done_delay):
					await RisingEdge(self.dut.clk)
				await RisingEdge(self.dut.clk)
				self.dut.rd_dma_error.value = 0
				return self.current_cycle()
			if injection.wrong_tuser:
				self.dut.s_axis_tvalid.value = 0
				self.dut.s_axis_tlast.value = 0
				return last_beat_cycle
		self.dut.s_axis_tvalid.value = 0
		self.dut.s_axis_tlast.value = 0
		if injection.error_mode == "after_stream":
			self.dut.rd_dma_error.value = 1
			for _ in range(injection.done_delay):
				await RisingEdge(self.dut.clk)
			await RisingEdge(self.dut.clk)
			self.dut.rd_dma_error.value = 0
		return last_beat_cycle

	async def _wr_dma_agent(self) -> None:
		try:
			while True:
				await RisingEdge(self.dut.clk)
				await ReadOnly()
				if value_to_int(self.dut.wr_dma_desc_valid.value) and value_to_int(self.dut.wr_dma_desc_ready.value):
					desc_cycle = self.current_cycle()
					self.wr_desc_count += 1
					self.export_req_count += 1
					expected = await self._await_expected_export()
					desc = self.descriptors[expected.ctrl_id]
					expected_beats = self._pack_export_beats(expected.matrix)
					injection = self.export_injections.popleft() if self.export_injections else ExportInjection()
					actual_addr = value_to_int(self.dut.wr_dma_desc_addr.value)
					actual_id = value_to_int(self.dut.wr_dma_desc_id.value)
					actual_buf = value_to_int(self.dut.wr_dma_desc_buf.value)
					actual_beats = value_to_int(self.dut.wr_dma_desc_beats.value)
					assert actual_addr == desc.m_addr
					assert actual_id == (expected.ctrl_id & 0xFFFF_FFFF)
					assert actual_buf == expected.buffer
					assert actual_beats == len(expected_beats)
					self.wr_desc_log.append(
						WriteDmaLog(
							ctrl_id=actual_id,
							buf=actual_buf,
							addr=actual_addr,
							beats=actual_beats,
						)
					)
					self.export_busy = True
					last_beat_cycle, done_cycle = await self._consume_export(expected, expected_beats, injection)
					self.export_busy = False
					self.wr_transfer_log.append(
						WrTransferTrace(
							ctrl_id=actual_id,
							buf=actual_buf,
							addr=actual_addr,
							beats=actual_beats,
							desc_cycle=desc_cycle,
							last_beat_cycle=last_beat_cycle,
							done_cycle=done_cycle,
						)
					)
		except Exception:
			self.dut._log.exception("wr_dma_agent crashed")
			raise

	async def _await_expected_export(self, timeout_cycles: int = 2) -> ExportExpectation:
		last_error: Optional[Exception] = None
		for attempt in range(timeout_cycles + 1):
			try:
				return self.model.expected_export()
			except ValueError as exc:
				last_error = exc
				if "no ready M buffer available" not in str(exc) or attempt == timeout_cycles:
					raise
				await RisingEdge(self.dut.clk)
		assert last_error is not None
		raise last_error

	async def _consume_export(self, expected: ExportExpectation, expected_beats: Sequence[Tuple[int, int]], injection: ExportInjection) -> Tuple[int, int]:
		beat_idx = 0
		last_beat_cycle = self.current_cycle()
		while beat_idx < len(expected_beats):
			await RisingEdge(self.dut.clk)
			await ReadOnly()
			if value_to_int(self.dut.m_axis_tvalid.value) and value_to_int(self.dut.m_axis_tready.value):
				actual_word = value_to_int(self.dut.m_axis_tdata.value)
				expected_word, expected_strb = expected_beats[beat_idx]
				assert actual_word == expected_word
				assert value_to_int(self.dut.m_axis_tstrb.value) == expected_strb
				assert value_to_int(self.dut.m_axis_tkeep.value) == 1
				assert value_to_int(self.dut.m_axis_tid.value) == 0
				assert value_to_int(self.dut.m_axis_tdest.value) == 0
				assert value_to_int(self.dut.m_axis_tuser.value) == expected.buffer
				assert value_to_int(self.dut.m_axis_tlast.value) == int(beat_idx == (len(expected_beats) - 1))
				last_beat_cycle = self.current_cycle()
				beat_idx += 1
		await RisingEdge(self.dut.clk)
		if injection.error:
			self.dut.wr_dma_error.value = 1
			for _ in range(injection.done_delay):
				await RisingEdge(self.dut.clk)
			done_cycle = self.current_cycle()
			await RisingEdge(self.dut.clk)
			self.dut.wr_dma_error.value = 0
			self.export_error_count += 1
			self.coverage.hit("export:error")
		else:
			self.dut.wr_dma_done.value = 1
			for _ in range(injection.done_delay):
				await RisingEdge(self.dut.clk)
			done_cycle = self.current_cycle()
			await RisingEdge(self.dut.clk)
			self.dut.wr_dma_done.value = 0
			self.export_done_count += 1
			self.coverage.hit("export:success")
		self.model.complete_export(expected.buffer)
		return last_beat_cycle, done_cycle


async def create_env(dut) -> PTDmaTopEnv:
	env = PTDmaTopEnv(dut)
	dut._log.info("PT DMA top env seed=%d case=%s x_dim=%d y_dim=%d", env.seed, env.case_name, env.x_dim, env.y_dim)
	await env.start()
	await env.reset()
	return env


async def setup_bases_and_passthrough_qcfg(env: PTDmaTopEnv) -> None:
	await env.cfg_base32("A", 0x0000_1000, 0x10)
	await env.cfg_base32("B", 0x0000_2000, 0x20)
	await env.qcfg_success(PT_QGRAN_PER_TENSOR, [0x0001_0000], 0x30)
