from __future__ import annotations

import os
import random
from collections import deque
from dataclasses import dataclass
from typing import Deque, Dict, List, Optional, Sequence, Tuple

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge, Timer

from tests.pt_model_v2 import (
	DMA_KIND_A,
	DMA_KIND_B,
	DMA_KIND_C,
	DmaLoadExpectation,
	ExportExpectation,
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
	def __init__(self, dut, seed: int):
		self.dut = dut
		self.seed = seed
		self.rng = random.Random(seed)
		self.x_dim = env_int("PT_X_DIM", 4)
		self.y_dim = env_int("PT_Y_DIM", 4)
		self.data_width = env_int("PT_DATA_WIDTH", 32)
		self.a_base = env_int("PT_A_BASE", DEFAULT_A_BASE)
		self.b_base = env_int("PT_B_BASE", DEFAULT_B_BASE)
		self.a_bank_depth = env_int("PT_A_BANK_DEPTH", 8)
		self.b_bank_depth = env_int("PT_B_BANK_DEPTH", 8)
		self.model = PTBlackBoxModel(self.x_dim, self.y_dim, self.a_bank_depth, self.b_bank_depth, self.data_width)
		self.external_a_tiles: Dict[int, List[int]] = {}
		self.external_b_tiles: Dict[int, List[int]] = {}
		self.external_c_tiles: Dict[int, List[int]] = {}
		self.ctrl_resp_queue: Deque[int] = deque()
		self.expected_dma_loads: Deque[DmaLoadExpectation] = deque()
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
		self._started = False
		self._tasks = []

	def snapshot(self) -> CounterSnapshot:
		return CounterSnapshot(self.dma_req_count, self.export_req_count, self.export_done_count, self.export_error_count, self.irq_count)

	def register_external_matrix(self, kind: str, ctrl_id: int, matrix: Sequence[int] | Sequence[Sequence[int]]) -> None:
		if len(matrix) == self.x_dim and all(isinstance(row, (list, tuple)) for row in matrix):  # type: ignore[arg-type]
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

	async def start(self) -> None:
		if self._started:
			return
		self._started = True
		self.dut.ctrl_valid.value = 0
		self.dut.ctrl_inst.value = 0
		self.dut.ctrl_id.value = 0
		self.dut.s_axis_tvalid.value = 0
		self.dut.s_axis_tdata.value = 0
		self.dut.s_axis_tstrb.value = (1 << (self.data_width // 8)) - 1
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
		self.dut.rstn.value = 0
		self._tasks = [
			cocotb.start_soon(self._clock_driver()),
			cocotb.start_soon(self._ready_driver()),
			cocotb.start_soon(self._ctrl_resp_monitor()),
			cocotb.start_soon(self._irq_monitor()),
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

	async def reset(self, cycles: int = 5) -> None:
		self.dut.rstn.value = 0
		self.dut.clear.value = 0
		await ClockCycles(self.dut.clk, cycles)
		self.dut.rstn.value = 1
		await RisingEdge(self.dut.clk)
		self.ctrl_resp_queue.clear()
		self.expected_dma_loads.clear()
		self.dma_req_count = 0
		self.export_req_count = 0
		self.export_done_count = 0
		self.export_error_count = 0
		self.irq_count = 0
		self.dma_stream_busy = False
		self.export_busy = False
		self.model = PTBlackBoxModel(self.x_dim, self.y_dim, self.a_bank_depth, self.b_bank_depth, self.data_width)
		self.external_a_tiles.clear()
		self.external_b_tiles.clear()
		self.external_c_tiles.clear()
		self.ab_injections.clear()
		self.export_injections.clear()
		self.model.set_base("A", self.a_base)
		self.model.set_base("B", self.b_base)

	def _apply_soft_clear_to_env(self) -> None:
		self.ctrl_resp_queue.clear()
		self.expected_dma_loads.clear()
		self.ab_injections.clear()
		self.export_injections.clear()
		self.dma_stream_busy = False
		self.export_busy = False
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

	async def pulse_clear(self, cycles: int = 1) -> None:
		self.dut.clear.value = 1
		self.dut.ctrl_valid.value = 0
		self.dut.s_axis_tvalid.value = 0
		self.dut.s_axis_tlast.value = 0
		self.dut.dma_done.value = 0
		self.dut.dma_error.value = 0
		self.dut.m_dma_done.value = 0
		self.dut.m_dma_error.value = 0
		await ClockCycles(self.dut.clk, cycles)
		self.dut.clear.value = 0
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
					self.dut._log.info("dma_stream kind=%s beats=%d", kind_label, len(matrix))
					self.dma_stream_busy = True
					await self._serve_dma_stream(expected_tuser, matrix, injection)
					self.dma_stream_busy = False
		except Exception:
			self.dut._log.exception("dma_load_agent crashed")
			raise

	async def _serve_dma_stream(self, req_tuser: int, matrix: Sequence[int], injection: AbInjection) -> None:
		self.dut.s_axis_tvalid.value = 0
		self.dut.s_axis_tlast.value = 0
		if value_to_int(self.dut.clear.value):
			return
		if injection.error_mode == "before_stream":
			await self._pulse("dma_error", injection.done_delay)
			return
		await RisingEdge(self.dut.clk)

		bad_tuser = MATRIX_B_TUSER if req_tuser == MATRIX_A_TUSER else MATRIX_A_TUSER
		for beat_idx, word in enumerate(matrix):
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
				self.dut.s_axis_tuser.value = bad_tuser if injection.wrong_tuser else req_tuser
				self.dut.s_axis_tlast.value = 1 if beat_idx == len(matrix) - 1 else 0
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
					expected = self.model.expected_export()
					injection = self.export_injections.popleft() if self.export_injections else ExportInjection()
					self.dut._log.info("m_dma_req buf=%d id=0x%08x beats=%d", expected.buffer, expected.ctrl_id, len(expected.matrix))
					assert value_to_int(self.dut.m_dma_req_buf.value) == expected.buffer
					assert value_to_int(self.dut.m_dma_req_id.value) == expected.ctrl_id
					assert value_to_int(self.dut.m_dma_req_beats.value) == len(expected.matrix)
					self.export_busy = True
					await self._consume_export(expected, injection)
					self.export_busy = False
		except Exception:
			self.dut._log.exception("export_agent crashed")
			raise

	async def _consume_export(self, expected: ExportExpectation, injection: ExportInjection) -> None:
		beat_idx = 0
		while beat_idx < len(expected.matrix):
			await RisingEdge(self.dut.clk)
			if value_to_int(self.dut.clear.value):
				return
			if value_to_int(self.dut.m_axis_tvalid.value) and value_to_int(self.dut.m_axis_tready.value):
				actual_word = value_to_int(self.dut.m_axis_tdata.value)
				assert actual_word == expected.matrix[beat_idx], (
					f"m_axis_tdata mismatch beat={beat_idx} exp=0x{expected.matrix[beat_idx]:08x} got=0x{actual_word:08x}"
				)
				assert value_to_int(self.dut.m_axis_tstrb.value) == (1 << (self.data_width // 8)) - 1
				assert value_to_int(self.dut.m_axis_tkeep.value) == 1
				assert value_to_int(self.dut.m_axis_tid.value) == 0
				assert value_to_int(self.dut.m_axis_tdest.value) == 0
				assert value_to_int(self.dut.m_axis_tuser.value) == expected.buffer
				assert value_to_int(self.dut.m_axis_tlast.value) == int(beat_idx == (len(expected.matrix) - 1))
				beat_idx += 1
		if injection.error:
			await self._pulse("m_dma_error", injection.done_delay)
			self.export_error_count += 1
		else:
			await self._pulse("m_dma_done", injection.done_delay)
			self.export_done_count += 1
		self.model.complete_export(expected.buffer)

	async def send_ctrl(self, inst: int, ctrl_id: int) -> None:
		self.dut.ctrl_inst.value = inst & 0xFFFF_FFFF
		self.dut.ctrl_id.value = ctrl_id & 0xFFFF_FFFF
		self.dut.ctrl_valid.value = 1
		self.dut._log.info("send_ctrl inst=0x%08x id=0x%08x", inst & 0xFFFF_FFFF, ctrl_id & 0xFFFF_FFFF)
		while True:
			await RisingEdge(self.dut.clk)
			if value_to_int(self.dut.ctrl_ready.value):
				self.dut._log.info("ctrl accepted id=0x%08x", ctrl_id & 0xFFFF_FFFF)
				break
		self.dut.ctrl_valid.value = 0

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

	async def cfg_base(self, kind: str, value: int, ctrl_id: int) -> None:
		selector = PT_CFG_A_BASE_LO if kind == "A" else PT_CFG_B_BASE_LO
		await self.send_ctrl(build_cfg_inst(selector, value & 0xFFFF), ctrl_id)
		await self.wait_ctrl_resp(pack_resp(False, 0, ctrl_id))
		self.model.set_base(kind, value)

	async def cfg_base32(self, kind: str, value: int, ctrl_id_base: int) -> None:
		if kind == "A":
			selector_lo = PT_CFG_A_BASE_LO
			selector_hi = PT_CFG_A_BASE_HI
		else:
			selector_lo = PT_CFG_B_BASE_LO
			selector_hi = PT_CFG_B_BASE_HI
		await self.send_ctrl(build_cfg_inst(selector_lo, value & 0xFFFF), ctrl_id_base)
		await self.wait_ctrl_resp(pack_resp(False, 0, ctrl_id_base))
		await self.send_ctrl(build_cfg_inst(selector_hi, (value >> 16) & 0xFFFF), ctrl_id_base + 1)
		await self.wait_ctrl_resp(pack_resp(False, 0, ctrl_id_base + 1))
		self.model.set_base(kind, value)

	async def qcfg_success(self, granularity: int, inv_scales: Sequence[int], ctrl_id: int) -> None:
		payload_count = qcfg_payload_count(granularity, self.x_dim, self.y_dim)
		assert payload_count is not None
		assert payload_count == len(inv_scales)
		await self.send_ctrl(build_qcfg_header(granularity, qtype=PT_QTYPE_SYMMETRIC), ctrl_id)
		await self.expect_no_ctrl_resp(2)
		for idx, word in enumerate(inv_scales):
			await self.send_ctrl(to_unsigned(word, 32), ctrl_id)
			if idx == (len(inv_scales) - 1):
				await self.wait_ctrl_resp(pack_resp(False, 0, ctrl_id))
			else:
				await self.expect_no_ctrl_resp(2)
		self.model.set_qcfg(granularity, inv_scales)

	def plan_matmul(self, ctrl_id: int, *, m_scale: int, n_scale: int, k_scale: int, a_field: int = 0, b_field: int = 0):
		plan = self.model.issue_matmul(ctrl_id, self.external_a_tiles, self.external_b_tiles, m_scale, n_scale, k_scale, a_field, b_field)
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
		for expected_req in plan.expected_dma_loads:
			self.expected_dma_loads.append(expected_req)
		return plan


async def create_env(dut) -> PTBlackBoxEnv:
	seed = env_int("PT_TEST_SEED", 10)
	env = PTBlackBoxEnv(dut, seed=seed)
	dut._log.info("PT blackbox seed=%d x_dim=%d y_dim=%d", seed, env.x_dim, env.y_dim)
	await env.start()
	await env.reset()
	return env


async def setup_bases_and_passthrough_qcfg(env: PTBlackBoxEnv) -> None:
	await env.cfg_base("A", env.a_base, 0x10)
	await env.cfg_base("B", env.b_base, 0x11)
	await env.qcfg_success(PT_QGRAN_PER_TENSOR, [0x0001_0000], 0x20)
