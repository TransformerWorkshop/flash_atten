from __future__ import annotations

import inspect
import os
import random
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Deque, Dict, List, Optional, Sequence, Tuple

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge, Timer
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


def flatten_pattern_matrix(dim: int, row_gain: int, col_gain: int, bias: int, bits: int = 32) -> List[int]:
	values = []
	for row in range(dim):
		for col in range(dim):
			values.append(to_unsigned(((row + 1) * row_gain) + ((col + 1) * col_gain) + bias, bits))
	return values


def repeating_matrix(dim: int, values: Sequence[int], bits: int = 32) -> List[int]:
	return [to_unsigned(values[idx % len(values)], bits) for idx in range(dim * dim)]


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


class PTBlackBoxEnv:
	def __init__(self, dut, seed: int, case_name: str):
		self.dut = dut
		self.seed = seed
		self.case_name = case_name
		self.rng = random.Random(seed)
		self.x_dim = env_int("PT_X_DIM", 4)
		self.y_dim = env_int("PT_Y_DIM", 4)
		self.data_width = env_int("PT_DATA_WIDTH", 32)
		self.a_base = env_int("PT_A_BASE", DEFAULT_A_BASE)
		self.b_base = env_int("PT_B_BASE", DEFAULT_B_BASE)
		self.a_bank_depth = env_int("PT_A_BANK_DEPTH", 16)
		self.b_bank_depth = env_int("PT_B_BANK_DEPTH", 16)
		self.m_bank_depth = env_int("PT_M_BANK_DEPTH", 16)
		self.a_load_lanes = env_int("PT_A_LOAD_LANES", 1)
		self.b_load_lanes = env_int("PT_B_LOAD_LANES", 1)
		self.m_write_lanes = env_int("PT_M_WRITE_LANES", 1)
		self.m_export_lanes = env_int("PT_M_EXPORT_LANES", 1)
		self.m_physical_copies = env_int("PT_M_PHYSICAL_COPIES", 3)
		if (self.m_bank_depth * self.x_dim) < max(self.x_dim, self.y_dim):
			raise ValueError(
				f"illegal PT M-bank configuration: M_BANK_DEPTH({self.m_bank_depth}) * GEMM_X_DIM({self.x_dim}) "
				f"< max({self.x_dim}, {self.y_dim})"
			)
		self.lut_depth = env_int("PT_LUT_DEPTH", 8)
		self.suite_name = os.getenv("PT_SUITE_NAME", "")
		self.run_name = os.getenv("PT_RUN_NAME", "")
		self.profile_name = os.getenv("PT_RANDOM_PROFILE", "")
		self.func_cov_dir = Path(os.getenv("PT_FUNC_COV_DIR", "."))
		self.a_capacity_elems = self.a_bank_depth * self.x_dim * self.x_dim
		self.b_capacity_elems = self.b_bank_depth * self.y_dim * self.y_dim
		self.m_capacity_rows = self.m_bank_depth * self.x_dim
		self.model = PTBlackBoxModel(self.x_dim, self.y_dim, self.a_bank_depth, self.b_bank_depth, self.data_width, self.lut_depth)
		self.a_base_shadow = 0
		self.b_base_shadow = 0
		self.coverage = FunctionalCoverageRecorder(
			case_name=case_name,
			suite_name=self.suite_name,
			run_name=self.run_name,
			seed=seed,
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
		self.ctrl_resp_queue: Deque[int] = deque()
		self.expected_dma_loads: Deque[DmaLoadExpectation] = deque()
		self.pending_resp_plans: Dict[int, Deque[Tuple[str, object]]] = {}
		self.ab_injections: Deque[AbInjection] = deque()
		self.export_injections: Deque[ExportInjection] = deque()
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
		self._started = False
		self._tasks = []

	def _full_lane_strb(self, lanes: int) -> int:
		return (1 << (lanes * (self.data_width // 8))) - 1

	def _pack_ab_beats(self, kind: str, matrix: Sequence[int], expectation: Optional[DmaLoadExpectation] = None) -> List[Tuple[int, int]]:
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
				if beat_strb != 0:
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
				if beat_strb != 0:
					beats.append((beat_data, beat_strb))
		return beats

	def _pack_export_beats(self, matrix: Sequence[int]) -> List[Tuple[int, int]]:
		beats: List[Tuple[int, int]] = []
		byte_mask = (1 << (self.data_width // 8)) - 1
		for row_start in range(0, len(matrix), self.y_dim):
			row = list(matrix[row_start : row_start + self.y_dim])
			for start in range(0, len(row), self.m_export_lanes):
				chunk = row[start : start + self.m_export_lanes]
				beat_data = 0
				beat_strb = 0
				for lane_idx, word in enumerate(chunk):
					beat_data |= to_unsigned(int(word), self.data_width) << (lane_idx * self.data_width)
					beat_strb |= byte_mask << (lane_idx * (self.data_width // 8))
				beats.append((beat_data, beat_strb))
		return beats

	def snapshot(self) -> CounterSnapshot:
		return CounterSnapshot(self.dma_req_count, self.export_req_count, self.export_done_count, self.export_error_count, self.irq_count)

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

	def _pt_root_prefix(self) -> str:
		return "u_pt_v2"

	def _resolve_path(self, path: str):
		handle = self.dut
		for part in path.split("."):
			handle = getattr(handle, part)
		return handle

	def _signal_value(self, path: str) -> int:
		return value_to_int(self._resolve_path(path).value)

	async def start(self) -> None:
		if self._started:
			return
		self._started = True
		self.dut.ctrl_valid.value = 0
		self.dut.ctrl_inst.value = 0
		self.dut.ctrl_id.value = 0
		self.dut.s_axis_tvalid.value = 0
		self.dut.s_axis_tdata.value = 0
		self.dut.s_axis_tstrb.value = self._full_lane_strb(max(self.a_load_lanes, self.b_load_lanes))
		self.dut.s_axis_tlast.value = 0
		self.dut.s_axis_tkeep.value = 1
		self.dut.s_axis_tid.value = 0
		self.dut.s_axis_tdest.value = 0
		self.dut.s_axis_tuser.value = 0
		self.dut.dma_done.value = 0
		self.dut.dma_error.value = 0
		self.dut.m_dma_done.value = 0
		self.dut.m_dma_error.value = 0
		self.dut.dma_req_ready.value = 1
		self.dut.m_dma_req_ready.value = 1
		self.dut.m_axis_tready.value = 1
		self.dut.clk.value = 0
		self.dut.clear.value = 0
		if hasattr(self.dut, "soft_clear"):
			self.dut.soft_clear.value = 0
		self.dut.rstn.value = 0
		self._tasks = [
			cocotb.start_soon(self._clock_driver()),
			cocotb.start_soon(self._ready_driver()),
			cocotb.start_soon(self._ctrl_resp_monitor()),
			cocotb.start_soon(self._irq_monitor()),
			cocotb.start_soon(self._backpressure_monitor()),
			cocotb.start_soon(self._dma_load_agent()),
			cocotb.start_soon(self._export_agent()),
		]

	async def _clock_driver(self) -> None:
		try:
			while True:
				self.dut.clk.value = 0
				await Timer(5, unit="ns")
				self.dut.clk.value = 1
				await Timer(5, unit="ns")
		except Exception:
			self.dut._log.exception("clock_driver crashed")
			raise

	def shutdown(self) -> None:
		if not self._started:
			return
		for task in self._tasks:
			try:
				task.kill()
			except Exception:
				pass
		self._tasks = []
		self._started = False
		self.dut.ctrl_valid.value = 0
		self.dut.s_axis_tvalid.value = 0
		self.dut.dma_done.value = 0
		self.dut.dma_error.value = 0
		self.dut.m_dma_done.value = 0
		self.dut.m_dma_error.value = 0
		self.dut.dma_req_ready.value = 0
		self.dut.m_dma_req_ready.value = 0
		self.dut.m_axis_tready.value = 0
		self.coverage.dump(self.func_cov_dir)

	async def reset(self, cycles: int = 5) -> None:
		self.dut.rstn.value = 0
		self.dut.clear.value = 0
		if hasattr(self.dut, "soft_clear"):
			self.dut.soft_clear.value = 0
		await ClockCycles(self.dut.clk, cycles)
		self.dut.rstn.value = 1
		await RisingEdge(self.dut.clk)
		self.ctrl_resp_queue.clear()
		self.expected_dma_loads.clear()
		self.pending_resp_plans.clear()
		self.dma_req_count = 0
		self.export_req_count = 0
		self.export_done_count = 0
		self.export_error_count = 0
		self.irq_count = 0
		self.dma_stream_busy = False
		self.export_busy = False
		self._seen_long_backpressure = False
		self.model = PTBlackBoxModel(self.x_dim, self.y_dim, self.a_bank_depth, self.b_bank_depth, self.data_width, self.lut_depth)
		self.external_a_tiles.clear()
		self.external_b_tiles.clear()
		self.external_c_tiles.clear()
		self.ab_injections.clear()
		self.export_injections.clear()
		self.a_base_shadow = 0
		self.b_base_shadow = 0
		self.model.set_base("A", 0)
		self.model.set_base("B", 0)

	def _apply_soft_clear_to_env(self) -> None:
		self.ctrl_resp_queue.clear()
		self.expected_dma_loads.clear()
		self.pending_resp_plans.clear()
		self.ab_injections.clear()
		self.export_injections.clear()
		self.dma_stream_busy = False
		self.export_busy = False
		self.a_base_shadow = 0
		self.b_base_shadow = 0
		self.dut.ctrl_valid.value = 0
		self.dut.s_axis_tvalid.value = 0
		self.dut.s_axis_tlast.value = 0
		self.dut.dma_done.value = 0
		self.dut.dma_error.value = 0
		self.dut.m_dma_done.value = 0
		self.dut.m_dma_error.value = 0
		self.model.reset_runtime_state()
		self.model.set_base("A", 0)
		self.model.set_base("B", 0)

	async def pulse_clear(self, cycles: int = 1, phase: str = "generic") -> None:
		if phase:
			self.coverage.hit(f"clear:{phase}")
		self.dut.clear.value = 1
		if hasattr(self.dut, "soft_clear"):
			self.dut.soft_clear.value = 0
		self.dut.ctrl_valid.value = 0
		self.dut.s_axis_tvalid.value = 0
		self.dut.s_axis_tlast.value = 0
		self.dut.dma_done.value = 0
		self.dut.dma_error.value = 0
		self.dut.m_dma_done.value = 0
		self.dut.m_dma_error.value = 0
		await ClockCycles(self.dut.clk, cycles)
		self.dut.clear.value = 0
		if hasattr(self.dut, "soft_clear"):
			self.dut.soft_clear.value = 0
		await RisingEdge(self.dut.clk)
		self._apply_soft_clear_to_env()

	async def _ready_driver(self) -> None:
		try:
			while True:
				self.dut.dma_req_ready.value = 0 if self.dma_stream_busy else self.dma_req_ready_pattern.next()
				self.dut.m_dma_req_ready.value = 0 if self.export_busy else self.m_dma_req_ready_pattern.next()
				self.dut.m_axis_tready.value = self.m_axis_ready_pattern.next()
				await RisingEdge(self.dut.clk)
		except Exception:
			self.dut._log.exception("ready_driver crashed")
			raise

	async def _ctrl_resp_monitor(self) -> None:
		try:
			while True:
				await RisingEdge(self.dut.clk)
				await ReadOnly()
				if value_to_int(self.dut.ctrl_resp_valid.value):
					resp = value_to_int(self.dut.ctrl_resp.value)
					self.dut._log.info("ctrl_resp=0x%08x", resp)
					self._finalize_pending_plan(resp)
					if (resp >> 31) & 0x1:
						resp_id = resp & 0x3FFF_FFFF
						self.expected_dma_loads = deque(
							req for req in self.expected_dma_loads if (req.ctrl_id & 0x3FFF_FFFF) != resp_id
						)
					self.ctrl_resp_queue.append(resp)
		except Exception:
			self.dut._log.exception("ctrl_resp_monitor crashed")
			raise

	async def _irq_monitor(self) -> None:
		try:
			while True:
				await RisingEdge(self.dut.clk)
				await ReadOnly()
				if value_to_int(self.dut.irq.value):
					self.irq_count += 1
					self.dut._log.info("irq pulse count=%d", self.irq_count)
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
				dma_block = dma_block + 1 if value_to_int(self.dut.dma_req_valid.value) and not value_to_int(self.dut.dma_req_ready.value) else 0
				export_req_block = export_req_block + 1 if value_to_int(self.dut.m_dma_req_valid.value) and not value_to_int(self.dut.m_dma_req_ready.value) else 0
				axis_block = axis_block + 1 if value_to_int(self.dut.m_axis_tvalid.value) and not value_to_int(self.dut.m_axis_tready.value) else 0
				if not self._seen_long_backpressure and max(dma_block, export_req_block, axis_block) >= BACKPRESSURE_LONG_THRESHOLD:
					self.coverage.hit("backpressure:long_phase")
					self._seen_long_backpressure = True
		except Exception:
			self.dut._log.exception("backpressure_monitor crashed")
			raise

	async def _pulse(self, signal_name: str, delay_cycles: int = 0) -> None:
		signal = getattr(self.dut, signal_name)
		for _ in range(delay_cycles):
			await RisingEdge(self.dut.clk)
		signal.value = 1
		await RisingEdge(self.dut.clk)
		signal.value = 0

	def _dma_kind_to_label(self, req_kind: int) -> Tuple[str, int]:
		if req_kind == DMA_KIND_A:
			return "A", MATRIX_A_TUSER
		if req_kind == DMA_KIND_B:
			return "B", MATRIX_B_TUSER
		if req_kind == DMA_KIND_C:
			return "C", MATRIX_C_TUSER
		raise AssertionError(f"unexpected dma_req_kind={req_kind}")

	async def _dma_load_agent(self) -> None:
		try:
			while True:
				await RisingEdge(self.dut.clk)
				if value_to_int(self.dut.dma_req_valid.value) and value_to_int(self.dut.dma_req_ready.value):
					self.dma_req_count += 1
					req_kind = value_to_int(self.dut.dma_req_kind.value)
					req_id = value_to_int(self.dut.dma_req_id.value)
					kind_label, expected_tuser = self._dma_kind_to_label(req_kind)
					self.dut._log.info("dma_req kind=%s id=0x%08x", kind_label, req_id)
					expected_req = None
					if self.expected_dma_loads:
						expected_req = self.expected_dma_loads.popleft()
						assert expected_req.kind == kind_label, f"dma_req kind mismatch exp={expected_req.kind} got={kind_label}"
						assert expected_req.ctrl_id == req_id, f"dma_req id mismatch exp=0x{expected_req.ctrl_id:08x} got=0x{req_id:08x}"
					injection = self.ab_injections.popleft() if self.ab_injections else AbInjection()
					if kind_label == "A":
						matrix = self.external_a_tiles[req_id]
					elif kind_label == "B":
						matrix = self.external_b_tiles[req_id]
					else:
						matrix = self.external_c_tiles[req_id]
					load_beats = self._pack_ab_beats(kind_label, matrix, expected_req)
					self.dut._log.info("dma_stream kind=%s beats=%d", kind_label, len(load_beats))
					self.dma_stream_busy = True
					await self._serve_dma_stream(expected_tuser, load_beats, injection)
					self.dma_stream_busy = False
		except Exception:
			self.dut._log.exception("dma_load_agent crashed")
			raise

	async def _serve_dma_stream(self, req_tuser: int, beats: Sequence[Tuple[int, int]], injection: AbInjection) -> None:
		self.dut.s_axis_tvalid.value = 0
		self.dut.s_axis_tlast.value = 0
		if value_to_int(self.dut.clear.value):
			return
		if injection.error_mode == "before_stream":
			await self._pulse("dma_error", injection.done_delay)
			return
		await RisingEdge(self.dut.clk)

		bad_tuser = MATRIX_B_TUSER if req_tuser == MATRIX_A_TUSER else MATRIX_A_TUSER
		for beat_idx, (word, strb) in enumerate(beats):
			if value_to_int(self.dut.clear.value):
				self.dut.s_axis_tvalid.value = 0
				self.dut.s_axis_tlast.value = 0
				return
			while True:
				if value_to_int(self.dut.clear.value):
					self.dut.s_axis_tvalid.value = 0
					self.dut.s_axis_tlast.value = 0
					return
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
				self.dut.s_axis_tlast.value = 1 if beat_idx == len(beats) - 1 else 0
				await RisingEdge(self.dut.clk)
				assert value_to_int(self.dut.s_axis_tready.value), "expected s_axis_tready high while streaming DMA beats"
				break
			if injection.error_mode == "mid_stream" and beat_idx == injection.error_at_beat:
				self.dut.s_axis_tvalid.value = 0
				self.dut.s_axis_tlast.value = 0
				await self._pulse("dma_error", injection.done_delay)
				return
			if injection.wrong_tuser:
				self.dut.s_axis_tvalid.value = 0
				self.dut.s_axis_tlast.value = 0
				return

		self.dut.s_axis_tvalid.value = 0
		self.dut.s_axis_tlast.value = 0
		if injection.error_mode == "after_stream":
			await self._pulse("dma_error", injection.done_delay)
		else:
			await self._pulse("dma_done", injection.done_delay)

	async def _export_agent(self) -> None:
		try:
			while True:
				await RisingEdge(self.dut.clk)
				if value_to_int(self.dut.m_dma_req_valid.value) and value_to_int(self.dut.m_dma_req_ready.value):
					self.export_req_count += 1
					expected = await self._await_expected_export()
					expected_beats = self._pack_export_beats(expected.matrix)
					injection = self.export_injections.popleft() if self.export_injections else ExportInjection()
					self.dut._log.info("m_dma_req buf=%d id=0x%08x beats=%d", expected.buffer, expected.ctrl_id, len(expected_beats))
					assert value_to_int(self.dut.m_dma_req_buf.value) == expected.buffer
					assert value_to_int(self.dut.m_dma_req_id.value) == expected.ctrl_id
					assert value_to_int(self.dut.m_dma_req_beats.value) == len(expected_beats)
					self.export_busy = True
					await self._consume_export(expected, expected_beats, injection)
					self.export_busy = False
		except Exception:
			self.dut._log.exception("export_agent crashed")
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

	async def _consume_export(self, expected: ExportExpectation, expected_beats: Sequence[Tuple[int, int]], injection: ExportInjection) -> None:
		beat_idx = 0
		while beat_idx < len(expected_beats):
			await RisingEdge(self.dut.clk)
			if value_to_int(self.dut.clear.value):
				return
			if value_to_int(self.dut.m_axis_tvalid.value) and value_to_int(self.dut.m_axis_tready.value):
				actual_word = value_to_int(self.dut.m_axis_tdata.value)
				expected_word, expected_strb = expected_beats[beat_idx]
				assert actual_word == expected_word, (
					f"m_axis_tdata mismatch beat={beat_idx} exp=0x{expected_word:x} got=0x{actual_word:x}"
				)
				assert value_to_int(self.dut.m_axis_tstrb.value) == expected_strb
				assert value_to_int(self.dut.m_axis_tkeep.value) == 1
				assert value_to_int(self.dut.m_axis_tid.value) == 0
				assert value_to_int(self.dut.m_axis_tdest.value) == 0
				assert value_to_int(self.dut.m_axis_tuser.value) == expected.buffer
				assert value_to_int(self.dut.m_axis_tlast.value) == int(beat_idx == (len(expected_beats) - 1))
				beat_idx += 1
		if injection.error:
			await self._pulse("m_dma_error", injection.done_delay)
			self.export_error_count += 1
			self.coverage.hit("export:error")
		else:
			await self._pulse("m_dma_done", injection.done_delay)
			self.export_done_count += 1
			self.coverage.hit("export:success")
		self.model.complete_export(expected.buffer)

	async def send_ctrl_timed(self, inst: int, ctrl_id: int, timeout_cycles: int = 4000) -> CtrlSendTrace:
		self.dut.ctrl_inst.value = inst & 0xFFFF_FFFF
		self.dut.ctrl_id.value = ctrl_id & 0xFFFF_FFFF
		self.dut.ctrl_valid.value = 1
		self.dut._log.info("send_ctrl inst=0x%08x id=0x%08x", inst & 0xFFFF_FFFF, ctrl_id & 0xFFFF_FFFF)
		wait_cycles = 0
		ready_low_cycles = 0
		while wait_cycles < timeout_cycles:
			await RisingEdge(self.dut.clk)
			wait_cycles += 1
			if value_to_int(self.dut.ctrl_ready.value):
				self.dut._log.info("ctrl accepted id=0x%08x", ctrl_id & 0xFFFF_FFFF)
				break
			ready_low_cycles += 1
		else:
			self.dut.ctrl_valid.value = 0
			raise AssertionError(f"ctrl acceptance timeout id=0x{ctrl_id & 0xFFFF_FFFF:08x}")
		self.dut.ctrl_valid.value = 0
		trace = CtrlSendTrace(wait_cycles=wait_cycles, ready_low_cycles=ready_low_cycles)
		if trace.ready_low_cycles > 0:
			self.coverage.hit("queue:ctrl_ready_low")
		if trace.wait_cycles > 1:
			self.coverage.hit("queue:ctrl_accept_slow")
		return trace

	async def send_ctrl(self, inst: int, ctrl_id: int) -> CtrlSendTrace:
		return await self.send_ctrl_timed(inst, ctrl_id)

	async def wait_ctrl_resp(self, expected_word: int, timeout_cycles: int = 4000) -> int:
		for _ in range(timeout_cycles):
			if self.ctrl_resp_queue:
				actual = self.ctrl_resp_queue.popleft()
				assert actual == expected_word, f"ctrl_resp mismatch exp=0x{expected_word:08x} got=0x{actual:08x}"
				return actual
			await RisingEdge(self.dut.clk)
		raise AssertionError(f"ctrl_resp timeout waiting for 0x{expected_word:08x}")

	async def expect_no_ctrl_resp(self, wait_cycles: int) -> None:
		for _ in range(wait_cycles):
			assert not self.ctrl_resp_queue, f"unexpected queued ctrl_resp 0x{self.ctrl_resp_queue[0]:08x}"
			await RisingEdge(self.dut.clk)
			assert not self.ctrl_resp_queue, f"unexpected ctrl_resp 0x{self.ctrl_resp_queue[0]:08x}"

	async def wait_export_done(self, target_done_count: int, timeout_cycles: int = 4000) -> None:
		for _ in range(timeout_cycles):
			if self.export_done_count >= target_done_count:
				return
			await RisingEdge(self.dut.clk)
		raise AssertionError(f"export_done timeout exp>={target_done_count} got={self.export_done_count}")

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
		signal = getattr(self.dut, signal_name)
		for _ in range(timeout_cycles):
			if value_to_int(signal.value) == expected_value:
				return
			await RisingEdge(self.dut.clk)
		raise AssertionError(f"{signal_name} timeout exp={expected_value} got={value_to_int(signal.value)}")

	async def wait_malloc_slot_scan(self, ctrl_id: int, timeout_cycles: int = 4000) -> Dict[str, int]:
		for cycle in range(timeout_cycles):
			await ReadOnly()
			if value_to_int(self.dut.u_pt_v2.malloc_cmd_valid.value) and value_to_int(self.dut.u_pt_v2.malloc_cmd_id.value) == (ctrl_id & 0xFFFF_FFFF):
				snapshot = {
					"slot_found": value_to_int(self.dut.u_pt_v2.u_malloc.slot_found.value),
					"slot_idx": value_to_int(self.dut.u_pt_v2.u_malloc.slot_idx.value),
					"free_found": value_to_int(self.dut.u_pt_v2.u_malloc.free_found.value),
					"free_idx": value_to_int(self.dut.u_pt_v2.u_malloc.free_idx.value),
					"cmd_slot_idx": value_to_int(self.dut.u_pt_v2.u_malloc.cmd_slot_idx.value),
				}
				if snapshot["slot_found"] and snapshot["slot_idx"] != 0:
					self.coverage.hit("slot_scan:hit_nonzero")
				if snapshot["free_found"] and snapshot["free_idx"] != 0:
					self.coverage.hit("slot_scan:free_nonzero")
				if (not snapshot["slot_found"]) and (not snapshot["free_found"]):
					self.coverage.hit("slot_scan:lut_full_reject")
				return snapshot
			if cycle != (timeout_cycles - 1):
				await RisingEdge(self.dut.clk)
		raise AssertionError(f"malloc_cmd timeout for ctrl_id=0x{ctrl_id:08x}")

	def _apply_cfg_selector(self, selector: int, value16: int) -> None:
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
		return (
			value_to_int(self.dut.u_pt_v2.pcsr_a_base.value),
			value_to_int(self.dut.u_pt_v2.pcsr_b_base.value),
		)

	async def cfg_selector16(self, selector: int, value16: int, ctrl_id: int) -> None:
		self.coverage.hit("cmd:cfg")
		if selector in CSR_SELECTOR_BINS:
			self.coverage.hit(CSR_SELECTOR_BINS[selector])
		self.coverage.hit(classify_csr_pattern(value16))
		await self.send_ctrl(build_cfg_inst(selector, value16 & 0xFFFF), ctrl_id)
		await self.wait_ctrl_resp(pack_resp(False, 0, ctrl_id))
		self._apply_cfg_selector(selector, value16)

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
		await self.send_ctrl(build_qcfg_header(granularity, qtype=PT_QTYPE_SYMMETRIC), ctrl_id)
		await self.expect_no_ctrl_resp(2)
		for idx, word in enumerate(inv_scales):
			await self.send_ctrl(to_unsigned(word, 32), ctrl_id)
			if idx == (len(inv_scales) - 1):
				await self.wait_ctrl_resp(pack_resp(False, 0, ctrl_id))
			else:
				await self.expect_no_ctrl_resp(2)
		self.model.set_qcfg(granularity, inv_scales)

	def plan_matmul(self, ctrl_id: int, *, m_scale: int, n_scale: int, k_scale: int, reserved_a: int = 0, reserved_b: int = 0):
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
		for expected_req in plan.expected_dma_loads:
			self.expected_dma_loads.append(expected_req)
		return plan

	def plan_matadd(self, ctrl_id: int, m_off: int, *, c_field: int = 0, reserved_hi: int = 0, reserved_lo: int = 0):
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
		for expected_req in plan.expected_dma_loads:
			self.expected_dma_loads.append(expected_req)
		return plan

	def plan_load(self, ctrl_id: int, a_size: int, b_size: int, *, need_a: bool, need_b: bool, reserved_lo: int = 0):
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
		for expected_req in plan.expected_dma_loads:
			self.expected_dma_loads.append(expected_req)
		return plan

	def _queue_pending_plan(self, response_word: int, plan_kind: str, plan: ExecPlan | LoadPlan) -> None:
		self.pending_resp_plans.setdefault(response_word, deque()).append((plan_kind, plan))

	def _finalize_pending_plan(self, response_word: int) -> None:
		plan_queue = self.pending_resp_plans.get(response_word)
		if not plan_queue:
			return

		plan_kind, plan = plan_queue.popleft()
		if not plan_queue:
			del self.pending_resp_plans[response_word]

		if plan_kind == "exec":
			exec_plan = plan
			if not exec_plan.err:
				self.model.commit_success(exec_plan)
		elif plan_kind == "load":
			load_plan = plan
			if not load_plan.err:
				self.model.commit_load_success(load_plan)


async def create_env(dut) -> PTBlackBoxEnv:
	if os.getenv("PT_TOPLEVEL", "PT") == "PT_DMA_TOP":
		from tests.pt_dma_top_env import create_env as create_dma_top_env
		return await create_dma_top_env(dut)
	seed = env_int("PT_TEST_SEED", 10)
	case_name = discover_case_name()
	env = PTBlackBoxEnv(dut, seed=seed, case_name=case_name)
	dut._log.info("PT blackbox seed=%d case=%s x_dim=%d y_dim=%d", seed, case_name, env.x_dim, env.y_dim)
	await env.start()
	await env.reset()
	return env


async def setup_bases_and_passthrough_qcfg(env: PTBlackBoxEnv) -> None:
	await env.cfg_base("A", env.a_base, 0x10)
	await env.cfg_base("B", env.b_base, 0x11)
	await env.qcfg_success(PT_QGRAN_PER_TENSOR, [0x0001_0000], 0x20)
