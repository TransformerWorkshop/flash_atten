from __future__ import annotations

import os
import random
from collections import deque
from dataclasses import dataclass
from typing import Deque, Dict, List, Optional, Sequence

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from tests.pt_model import (
	MATRIX_A_TUSER,
	MATRIX_B_TUSER,
	PTBlackBoxModel,
	PT_CFG_A_BASE_LO,
	PT_CFG_B_BASE_LO,
	PT_QGRAN_PER_TENSOR,
	PT_QGRAN_X_WISE,
	PT_QGRAN_X_WISE_DIV2,
	PT_QGRAN_Y_WISE,
	PT_QGRAN_Y_WISE_DIV2,
	PT_QTYPE_SYMMETRIC,
	PT_SCALE_FULL,
	PT_SCALE_FULL_DIV2,
	build_cfg_inst,
	build_matmul_inst,
	build_mwin_off,
	build_qcfg_header,
	constant_matrix,
	ensure_row_major,
	identity_matrix,
	pack_resp,
	qcfg_payload_count,
	to_unsigned,
	zero_matrix,
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


def expand_scales(pattern: Sequence[int], count: int) -> List[int]:
	return [pattern[idx % len(pattern)] for idx in range(count)]


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
	error_mode: Optional[str] = None  # None, before_stream, mid_stream, after_stream
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
		self.model = PTBlackBoxModel(self.x_dim, self.y_dim, self.data_width)
		self.external_a_tiles: Dict[int, List[int]] = {}
		self.external_b_tiles: Dict[int, List[int]] = {}
		self.ctrl_resp_queue: Deque[int] = deque()
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

	def matrix_offset(self, tile_index: int = 0) -> int:
		return tile_index * self.x_dim

	def snapshot(self) -> CounterSnapshot:
		return CounterSnapshot(
			dma_req_count=self.dma_req_count,
			export_req_count=self.export_req_count,
			export_done_count=self.export_done_count,
			export_error_count=self.export_error_count,
			irq_count=self.irq_count,
		)

	def register_external_matrix(self, kind: str, elem_off: int, matrix: Sequence[int] | Sequence[Sequence[int]]) -> int:
		flat = ensure_row_major(matrix, self.x_dim, self.y_dim, self.data_width)
		base_kind = "A" if kind == "A" else "B"
		addr = self.model.ext_addr(base_kind, elem_off)
		if kind == "A":
			self.external_a_tiles[addr] = flat
		elif kind == "B":
			self.external_b_tiles[addr] = flat
		else:
			raise ValueError(f"unknown matrix kind {kind!r}")
		return addr

	def configure_patterns(
		self,
		*,
		dma_req_ready=None,
		m_dma_req_ready=None,
		m_axis_ready=None,
		s_axis_valid=None,
	) -> None:
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
		self.dut.clear.value = 0
		self.dut.rstn.value = 0
		cocotb.start_soon(Clock(self.dut.clk, 10, unit="ns").start())
		cocotb.start_soon(self._ready_driver())
		cocotb.start_soon(self._ctrl_resp_monitor())
		cocotb.start_soon(self._irq_monitor())
		cocotb.start_soon(self._dma_load_agent())
		cocotb.start_soon(self._export_agent())

	async def reset(self, cycles: int = 5) -> None:
		self.dut.rstn.value = 0
		self.dut.clear.value = 0
		await ClockCycles(self.dut.clk, cycles)
		self.dut.rstn.value = 1
		await RisingEdge(self.dut.clk)
		self.ctrl_resp_queue.clear()
		self.dma_req_count = 0
		self.export_req_count = 0
		self.export_done_count = 0
		self.export_error_count = 0
		self.irq_count = 0
		self.dma_stream_busy = False
		self.export_busy = False
		self.model = PTBlackBoxModel(self.x_dim, self.y_dim, self.data_width)
		self.external_a_tiles.clear()
		self.external_b_tiles.clear()
		self.ab_injections.clear()
		self.export_injections.clear()
		self.model.set_base("A", self.a_base)
		self.model.set_base("B", self.b_base)

	async def _ready_driver(self) -> None:
		while True:
			self.dut.dma_req_ready.value = 0 if self.dma_stream_busy else self.dma_req_ready_pattern.next()
			self.dut.m_dma_req_ready.value = 0 if self.export_busy else self.m_dma_req_ready_pattern.next()
			self.dut.m_axis_tready.value = self.m_axis_ready_pattern.next()
			await RisingEdge(self.dut.clk)

	async def _ctrl_resp_monitor(self) -> None:
		while True:
			await RisingEdge(self.dut.clk)
			await ReadOnly()
			if value_to_int(self.dut.ctrl_resp_valid.value):
				resp = value_to_int(self.dut.ctrl_resp.value)
				self.dut._log.info("ctrl_resp=0x%08x", resp)
				self.ctrl_resp_queue.append(resp)

	async def _irq_monitor(self) -> None:
		while True:
			await RisingEdge(self.dut.clk)
			await ReadOnly()
			if value_to_int(self.dut.irq.value):
				self.irq_count += 1

	async def _pulse(self, signal_name: str, delay_cycles: int = 0) -> None:
		signal = getattr(self.dut, signal_name)
		for _ in range(delay_cycles):
			await RisingEdge(self.dut.clk)
		signal.value = 1
		await RisingEdge(self.dut.clk)
		signal.value = 0

	async def _dma_load_agent(self) -> None:
		while True:
			await RisingEdge(self.dut.clk)
			if value_to_int(self.dut.dma_req_valid.value) and value_to_int(self.dut.dma_req_ready.value):
				self.dma_req_count += 1
				req_tuser = value_to_int(self.dut.dma_req_tuser.value)
				req_ext_addr = value_to_int(self.dut.dma_req_ext_addr.value)
				req_beats = value_to_int(self.dut.dma_req_beats.value)
				self.dut._log.info(
					"dma_req tuser=%d ext=0x%08x beats=%d",
					req_tuser,
					req_ext_addr,
					req_beats,
				)
				injection = self.ab_injections.popleft() if self.ab_injections else AbInjection()
				if req_tuser == MATRIX_A_TUSER:
					matrix = self.external_a_tiles[req_ext_addr]
				elif req_tuser == MATRIX_B_TUSER:
					matrix = self.external_b_tiles[req_ext_addr]
				else:
					raise AssertionError(f"unexpected dma_req_tuser={req_tuser}")
				assert req_beats == len(matrix), f"dma_req_beats mismatch exp={len(matrix)} got={req_beats}"
				self.dma_stream_busy = True
				await self._serve_dma_stream(req_tuser, matrix, injection)
				self.dma_stream_busy = False

	async def _serve_dma_stream(self, req_tuser: int, matrix: Sequence[int], injection: AbInjection) -> None:
		self.dut.s_axis_tvalid.value = 0
		self.dut.s_axis_tlast.value = 0
		self.dut._log.info("dma_stream_start tuser=%d beats=%d", req_tuser, len(matrix))
		if injection.error_mode == "before_stream":
			await self._pulse("dma_error", injection.done_delay)
			return
		await RisingEdge(self.dut.clk)

		bad_tuser = MATRIX_B_TUSER if req_tuser == MATRIX_A_TUSER else MATRIX_A_TUSER
		for beat_idx, word in enumerate(matrix):
			while True:
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
		self.dut._log.info("dma_stream_complete tuser=%d", req_tuser)
		if injection.error_mode == "after_stream":
			await self._pulse("dma_error", injection.done_delay)
		else:
			await self._pulse("dma_done", injection.done_delay)

	async def _export_agent(self) -> None:
		while True:
			await RisingEdge(self.dut.clk)
			if value_to_int(self.dut.m_dma_req_valid.value) and value_to_int(self.dut.m_dma_req_ready.value):
				self.export_req_count += 1
				expected = self.model.expected_export()
				injection = self.export_injections.popleft() if self.export_injections else ExportInjection()
				self.dut._log.info(
					"m_dma_req buf=%d id=0x%08x beats=%d",
					value_to_int(self.dut.m_dma_req_buf.value),
					value_to_int(self.dut.m_dma_req_id.value),
					value_to_int(self.dut.m_dma_req_beats.value),
				)
				assert value_to_int(self.dut.m_dma_req_buf.value) == expected.buffer
				assert value_to_int(self.dut.m_dma_req_id.value) == expected.ctrl_id
				assert value_to_int(self.dut.m_dma_req_beats.value) == len(expected.matrix)
				self.export_busy = True
				await self._consume_export(expected, injection)
				self.export_busy = False

	async def _consume_export(self, expected, injection: ExportInjection) -> None:
		beat_idx = 0
		while beat_idx < len(expected.matrix):
			await RisingEdge(self.dut.clk)
			if value_to_int(self.dut.m_axis_tvalid.value) and value_to_int(self.dut.m_axis_tready.value):
				actual_word = value_to_int(self.dut.m_axis_tdata.value)
				assert actual_word == expected.matrix[beat_idx], (
					f"m_axis_tdata mismatch beat={beat_idx} exp=0x{expected.matrix[beat_idx]:08x} "
					f"got=0x{actual_word:08x}"
				)
				assert (value_to_int(self.dut.m_axis_tuser.value) & 0x1) == expected.buffer
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
		while True:
			await RisingEdge(self.dut.clk)
			if value_to_int(self.dut.ctrl_ready.value):
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
		raise AssertionError(
			f"export_done timeout exp>={target_done_count} got={self.export_done_count}"
		)

	async def wait_export_error(self, target_error_count: int, timeout_cycles: int = 4000) -> None:
		for _ in range(timeout_cycles):
			if self.export_error_count >= target_error_count:
				return
			await RisingEdge(self.dut.clk)
		raise AssertionError(
			f"export_error timeout exp>={target_error_count} got={self.export_error_count}"
		)

	async def cfg_base(self, kind: str, value: int, ctrl_id: int) -> None:
		selector = PT_CFG_A_BASE_LO if kind == "A" else PT_CFG_B_BASE_LO
		await self.send_ctrl(build_cfg_inst(selector, value & 0xFFFF), ctrl_id)
		await self.wait_ctrl_resp(pack_resp(False, 0, ctrl_id))
		self.model.set_base(kind, value)

	async def qcfg_success(self, granularity: int, inv_scales: Sequence[int], ctrl_id: int) -> None:
		payload_count = qcfg_payload_count(granularity, self.x_dim, self.y_dim)
		assert payload_count is not None
		assert payload_count == len(inv_scales)
		await self.send_ctrl(build_qcfg_header(granularity), ctrl_id)
		await self.expect_no_ctrl_resp(4)
		for idx, word in enumerate(inv_scales):
			await self.send_ctrl(to_unsigned(word, 32), ctrl_id)
			if idx == (len(inv_scales) - 1):
				await self.wait_ctrl_resp(pack_resp(False, 0, ctrl_id))
			else:
				await self.expect_no_ctrl_resp(4)
		self.model.set_qcfg(granularity, inv_scales)

	def plan_matmul(self, ctrl_id: int, a_off: int, b_off: int, *, m_scale: int = PT_SCALE_FULL, n_scale: int = PT_SCALE_FULL, k_scale: int = PT_SCALE_FULL):
		return self.model.issue_matmul(
			ctrl_id=ctrl_id,
			a_off=a_off,
			b_off=b_off,
			external_a_tiles=self.external_a_tiles,
			external_b_tiles=self.external_b_tiles,
			m_scale=m_scale,
			n_scale=n_scale,
			k_scale=k_scale,
		)


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


@cocotb.test()
async def test_pt_smoke(dut) -> None:
	env = await create_env(dut)
	await setup_bases_and_passthrough_qcfg(env)

	a_matrix = flatten_pattern_matrix(env.x_dim, row_gain=3, col_gain=1, bias=0)
	b_matrix = flatten_pattern_matrix(env.y_dim, row_gain=2, col_gain=4, bias=1)
	env.register_external_matrix("A", 0, a_matrix)
	env.register_external_matrix("B", 0, b_matrix)

	start = env.snapshot()
	plan = env.plan_matmul(0x01, 0x000, 0x000)
	assert not plan.err
	assert len(plan.expected_dma_loads) == 2
	await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x01)
	resp = await env.wait_ctrl_resp(plan.response_word)
	assert ((resp >> 30) & 0x1) == plan.success_buffer
	env.model.commit_success(plan)
	await env.wait_export_done(start.export_done_count + 1)
	assert env.dma_req_count - start.dma_req_count == 2
	assert env.export_req_count - start.export_req_count == 1
	assert env.irq_count - start.irq_count == 1

	start = env.snapshot()
	hit_plan = env.plan_matmul(0x01, 0x000, 0x000)
	assert not hit_plan.err
	assert len(hit_plan.expected_dma_loads) == 0
	await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x01)
	resp = await env.wait_ctrl_resp(hit_plan.response_word)
	hit_buf = (resp >> 30) & 0x1
	env.model.commit_success(hit_plan)
	await env.wait_export_done(start.export_done_count + 1)
	assert env.dma_req_count - start.dma_req_count == 0
	assert env.export_req_count - start.export_req_count == 1
	assert env.irq_count - start.irq_count == 1

	start = env.snapshot()
	mwin_off = build_mwin_off(hit_buf, 0)
	mwin_plan = env.plan_matmul(0x03, mwin_off, mwin_off)
	assert not mwin_plan.err
	assert len(mwin_plan.expected_dma_loads) == 0
	await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, mwin_off, mwin_off), 0x03)
	await env.wait_ctrl_resp(mwin_plan.response_word)
	env.model.commit_success(mwin_plan)
	await env.wait_export_done(start.export_done_count + 1)
	assert env.dma_req_count - start.dma_req_count == 0
	assert env.export_req_count - start.export_req_count == 1
	assert env.irq_count - start.irq_count == 1


@cocotb.test()
async def test_pt_numeric_boundaries(dut) -> None:
	env = await create_env(dut)
	await setup_bases_and_passthrough_qcfg(env)

	identity = identity_matrix(env.x_dim, env.data_width)
	env.register_external_matrix("A", 0, identity)

	cases = [
		("zero", PT_QGRAN_PER_TENSOR, [0x0001_0000], zero_matrix(env.x_dim, env.y_dim)),
		("ones", PT_QGRAN_PER_TENSOR, [0x0001_0000], constant_matrix(env.x_dim, env.y_dim, 1, env.data_width)),
		(
			"upper_sat",
			PT_QGRAN_PER_TENSOR,
			[0x0001_0000],
			repeating_matrix(env.x_dim, [0x7FFF_FFFE, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF], env.data_width),
		),
		(
			"lower_sat",
			PT_QGRAN_PER_TENSOR,
			[0xFFFF_0000],
			repeating_matrix(env.x_dim, [0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF, 0x4000_0000], env.data_width),
		),
		(
			"round_tie",
			PT_QGRAN_PER_TENSOR,
			[0x0000_8000],
			repeating_matrix(env.x_dim, [1, 3, 5, 7, 9, 11, 13, 15], env.data_width),
		),
	]

	for idx, (_, granularity, scales, b_matrix) in enumerate(cases, start=1):
		await env.qcfg_success(granularity, scales, 0x40 + idx)
		env.register_external_matrix("B", 0, b_matrix)
		plan = env.plan_matmul(0x80 + idx, 0x000, 0x000)
		assert not plan.err
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x80 + idx)
		await env.wait_ctrl_resp(plan.response_word)
		env.model.commit_success(plan)
		await env.wait_export_done(idx)


@cocotb.test()
async def test_pt_qcfg_modes(dut) -> None:
	env = await create_env(dut)
	await env.cfg_base("A", env.a_base, 0x10)
	await env.cfg_base("B", env.b_base, 0x11)

	identity = identity_matrix(env.x_dim, env.data_width)
	env.register_external_matrix("A", 0, identity)
	env.register_external_matrix(
		"B",
		0,
		repeating_matrix(
			env.x_dim,
			[2, 5, 8, 11, 14, 17, 20, 23][: env.y_dim],
			env.data_width,
		),
	)

	mode_vectors = [
		(PT_QGRAN_PER_TENSOR, [0x0001_0000]),
		(PT_QGRAN_X_WISE, expand_scales([0x0001_0000, 0x0000_8000, 0x0002_0000, 0xFFFF_0000], env.x_dim)),
		(PT_QGRAN_Y_WISE, expand_scales([0x0001_0000, 0x0002_0000, 0x0000_8000, 0xFFFF_0000], env.y_dim)),
	]
	if (env.x_dim % 2) == 0:
		mode_vectors.append(
			(
				PT_QGRAN_X_WISE_DIV2,
				expand_scales([0x0001_0000, 0x0000_8000, 0xFFFF_0000, 0x0002_0000], env.x_dim // 2),
			)
		)
	if (env.y_dim % 2) == 0:
		mode_vectors.append(
			(
				PT_QGRAN_Y_WISE_DIV2,
				expand_scales([0x0001_0000, 0xFFFF_0000, 0x0000_8000, 0x0002_0000], env.y_dim // 2),
			)
		)

	export_target = 0
	for idx, (granularity, scales) in enumerate(mode_vectors, start=1):
		await env.qcfg_success(granularity, scales, 0x100 + idx)
		plan = env.plan_matmul(0x140 + idx, 0x000, 0x000)
		assert not plan.err
		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x140 + idx)
		await env.wait_ctrl_resp(plan.response_word)
		env.model.commit_success(plan)
		export_target += 1
		await env.wait_export_done(export_target)


@cocotb.test()
async def test_pt_protocol_errors(dut) -> None:
	env = await create_env(dut)
	await setup_bases_and_passthrough_qcfg(env)
	env.register_external_matrix("A", 0, flatten_pattern_matrix(env.x_dim, 1, 1, 0))
	env.register_external_matrix("B", 0, flatten_pattern_matrix(env.y_dim, 2, 1, 0))

	start = env.snapshot()
	bad_mnk_plan = env.plan_matmul(0x200, 0x000, 0x000, n_scale=PT_SCALE_FULL_DIV2)
	assert bad_mnk_plan.err
	await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL_DIV2, PT_SCALE_FULL, 0x000, 0x000), 0x200)
	await env.wait_ctrl_resp(bad_mnk_plan.response_word, 500)
	await ClockCycles(dut.clk, 8)
	assert env.dma_req_count == start.dma_req_count
	assert env.irq_count == start.irq_count + 1

	start = env.snapshot()
	bad_align_plan = env.plan_matmul(0x201, 0x001, 0x000)
	assert bad_align_plan.err
	await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x001, 0x000), 0x201)
	await env.wait_ctrl_resp(bad_align_plan.response_word, 500)
	await ClockCycles(dut.clk, 8)
	assert env.dma_req_count == start.dma_req_count
	assert env.irq_count == start.irq_count + 1

	start = env.snapshot()
	await env.send_ctrl(build_qcfg_header(PT_QGRAN_PER_TENSOR, qtype=0b01), 0x202)
	await env.wait_ctrl_resp(pack_resp(True, 0, 0x202), 500)
	await ClockCycles(dut.clk, 8)
	assert env.irq_count == start.irq_count + 1

	start = env.snapshot()
	await env.send_ctrl(build_qcfg_header(PT_QGRAN_X_WISE), 0x203)
	await env.expect_no_ctrl_resp(4)
	await env.send_ctrl(0x0001_0000, 0x203)
	await env.expect_no_ctrl_resp(4)
	await env.send_ctrl(0x0001_0000, 0x204)
	await env.wait_ctrl_resp(pack_resp(True, 0, 0x203), 500)
	await ClockCycles(dut.clk, 8)
	assert env.irq_count == start.irq_count + 1

	if (env.x_dim % 2) != 0:
		start = env.snapshot()
		await env.send_ctrl(build_qcfg_header(PT_QGRAN_X_WISE_DIV2, qtype=PT_QTYPE_SYMMETRIC), 0x205)
		await env.wait_ctrl_resp(pack_resp(True, 0, 0x205), 500)
		await ClockCycles(dut.clk, 8)
		assert env.irq_count == start.irq_count + 1

	start = env.snapshot()
	env.queue_ab_injection(AbInjection(wrong_tuser=True))
	plan = env.plan_matmul(0x206, 0x000, 0x000)
	await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x206)
	await env.wait_ctrl_resp(pack_resp(True, 0, 0x206), 2000)
	await ClockCycles(dut.clk, 8)
	assert env.dma_req_count >= start.dma_req_count + 1
	assert env.irq_count == start.irq_count + 1

	start = env.snapshot()
	env.queue_ab_injection(AbInjection(error_mode="before_stream", done_delay=2))
	await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x207)
	await env.wait_ctrl_resp(pack_resp(True, 0, 0x207), 2000)
	await ClockCycles(dut.clk, 8)
	assert env.irq_count == start.irq_count + 1

	start = env.snapshot()
	env.queue_export_injection(ExportInjection(error=True, done_delay=2))
	plan = env.plan_matmul(0x208, 0x000, 0x000)
	await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x208)
	await env.wait_ctrl_resp(plan.response_word, 4000)
	env.model.commit_success(plan)
	await env.wait_export_error(start.export_error_count + 1)
	await env.wait_ctrl_resp(pack_resp(True, plan.success_buffer, 0x208), 4000)
	assert env.export_req_count == start.export_req_count + 1
	assert env.irq_count == start.irq_count + 2


@cocotb.test()
async def test_pt_qcfg_odd_granularity(dut) -> None:
	env = await create_env(dut)
	if (env.x_dim % 2) != 0:
		await env.send_ctrl(build_qcfg_header(PT_QGRAN_X_WISE_DIV2), 0x250)
		await env.wait_ctrl_resp(pack_resp(True, 0, 0x250), 500)
	if (env.y_dim % 2) != 0:
		await env.send_ctrl(build_qcfg_header(PT_QGRAN_Y_WISE_DIV2), 0x251)
		await env.wait_ctrl_resp(pack_resp(True, 0, 0x251), 500)


@cocotb.test()
async def test_pt_backpressure(dut) -> None:
	env = await create_env(dut)
	env.configure_patterns(
		dma_req_ready=SequencePattern([0, 0, 1, 1, 0, 1, 1, 1]),
		m_dma_req_ready=SequencePattern([0, 1, 0, 1, 1, 0, 1, 1]),
		m_axis_ready=SequencePattern([1, 1, 0, 0, 0, 1, 0, 1, 1, 1]),
		s_axis_valid=SequencePattern([0, 1, 1, 0, 1, 0, 1, 1, 1]),
	)
	await setup_bases_and_passthrough_qcfg(env)

	env.register_external_matrix("A", 0, flatten_pattern_matrix(env.x_dim, 5, 1, 0))
	env.register_external_matrix("B", 0, flatten_pattern_matrix(env.y_dim, 1, 3, 1))

	first = env.plan_matmul(0x301, 0x000, 0x000)
	await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x301)
	await env.wait_ctrl_resp(first.response_word)
	env.model.commit_success(first)

	second_a = repeating_matrix(env.x_dim, [1, 0, 2, 0, 3, 0, 4, 0][: env.x_dim], env.data_width)
	second_b = flatten_pattern_matrix(env.y_dim, 2, 2, 3)
	env.register_external_matrix("A", 0, second_a)
	env.register_external_matrix("B", 0, second_b)
	second = env.plan_matmul(0x302, 0x000, 0x000)
	await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x000, 0x000), 0x302)
	await env.wait_ctrl_resp(second.response_word)
	env.model.commit_success(second)

	await env.wait_export_done(2, 12000)
	assert env.export_req_count == 2
	assert env.irq_count == 2


@cocotb.test()
async def test_pt_randomized(dut) -> None:
	env = await create_env(dut)
	random_cases = env_int("PT_RANDOM_CASES", 12)
	env.configure_patterns(
		dma_req_ready=RandomPattern(env.rng, 0.75),
		m_dma_req_ready=RandomPattern(env.rng, 0.80),
		m_axis_ready=RandomPattern(env.rng, 0.70),
		s_axis_valid=RandomPattern(env.rng, 0.80),
	)
	await setup_bases_and_passthrough_qcfg(env)

	identity = identity_matrix(env.x_dim, env.data_width)
	patterns = [
		flatten_pattern_matrix(env.x_dim, 2, 1, 0),
		flatten_pattern_matrix(env.x_dim, 3, 2, 1),
		repeating_matrix(env.x_dim, [1, 2, 3, 4, 5, 6, 7, 8][: env.x_dim], env.data_width),
		constant_matrix(env.x_dim, env.y_dim, 1, env.data_width),
	]
	last_hit_id = None
	last_matrix_idx = 0
	next_ctrl_id = 0x400
	export_target = 0

	for case_idx in range(random_cases):
		choice = env.rng.choice(["legal", "hit", "mwindow", "qcfg", "invalid", "wrong_tuser", "export_error"])

		if choice == "qcfg":
			if env.rng.random() < 0.5:
				await env.qcfg_success(PT_QGRAN_PER_TENSOR, [env.rng.choice([0x0001_0000, 0x0000_8000, 0xFFFF_0000])], next_ctrl_id)
			else:
				mode = env.rng.choice([PT_QGRAN_X_WISE, PT_QGRAN_Y_WISE])
				payload_count = qcfg_payload_count(mode, env.x_dim, env.y_dim)
				scales = [env.rng.choice([0x0001_0000, 0x0000_8000, 0x0002_0000, 0xFFFF_0000]) for _ in range(payload_count or 0)]
				await env.qcfg_success(mode, scales, next_ctrl_id)
			next_ctrl_id += 1
			continue

		if choice == "invalid":
			plan = env.plan_matmul(next_ctrl_id, 0x001, 0x000)
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, 0x001, 0x000), next_ctrl_id)
			await env.wait_ctrl_resp(plan.response_word, 1000)
			next_ctrl_id += 1
			continue

		matrix_idx = env.rng.randrange(len(patterns))
		env.register_external_matrix("A", 0, identity)
		env.register_external_matrix("B", 0, patterns[matrix_idx])

		if choice == "hit" and last_hit_id is not None:
			ctrl_id = last_hit_id
		else:
			ctrl_id = next_ctrl_id
			next_ctrl_id += 1
			last_hit_id = ctrl_id
			last_matrix_idx = matrix_idx

		if choice == "mwindow" and env.model.m_buffers[0] is not None:
			mwin_buf = env.rng.choice([buf for buf, matrix in env.model.m_buffers.items() if matrix is not None])
			a_off = build_mwin_off(mwin_buf, 0)
			b_off = build_mwin_off(mwin_buf, 0)
		else:
			a_off = 0x000
			b_off = 0x000

		plan = env.plan_matmul(ctrl_id, a_off, b_off)
		if choice == "wrong_tuser":
			env.queue_ab_injection(AbInjection(wrong_tuser=True))
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, a_off, b_off), ctrl_id)
			await env.wait_ctrl_resp(pack_resp(True, 0, ctrl_id), 4000)
			continue

		if choice == "export_error":
			env.queue_export_injection(ExportInjection(error=True, done_delay=1))
			await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, a_off, b_off), ctrl_id)
			await env.wait_ctrl_resp(plan.response_word, 4000)
			env.model.commit_success(plan)
			await env.wait_export_error(env.export_error_count + 1)
			await env.wait_ctrl_resp(pack_resp(True, plan.success_buffer, ctrl_id), 4000)
			continue

		await env.send_ctrl(build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL, a_off, b_off), ctrl_id)
		await env.wait_ctrl_resp(plan.response_word, 4000)
		env.model.commit_success(plan)
		export_target += 1
		await env.wait_export_done(export_target, 12000)
