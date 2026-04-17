from __future__ import annotations

import inspect
import os
from collections import deque
from dataclasses import dataclass
from typing import Deque, Dict, List, Optional, Sequence, Tuple

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

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


class PTDmaTopEnv:
	def __init__(self, dut):
		self.dut = dut
		self.seed = env_int("PT_TEST_SEED", 10)
		self.case_name = discover_case_name()
		self.x_dim = env_int("PT_X_DIM", 4)
		self.y_dim = env_int("PT_Y_DIM", 4)
		self.data_width = env_int("PT_DATA_WIDTH", 32)
		self.a_bank_depth = env_int("PT_A_BANK_DEPTH", 16)
		self.b_bank_depth = env_int("PT_B_BANK_DEPTH", 16)
		self.m_bank_depth = env_int("PT_M_BANK_DEPTH", 16)
		self.lut_depth = env_int("PT_LUT_DEPTH", 8)
		self.a_load_lanes = env_int("PT_A_LOAD_LANES", 1)
		self.b_load_lanes = env_int("PT_B_LOAD_LANES", 1)
		self.m_export_lanes = env_int("PT_M_EXPORT_LANES", 1)
		self.model = PTBlackBoxModel(self.x_dim, self.y_dim, self.a_bank_depth, self.b_bank_depth, self.data_width, self.lut_depth)
		self.external_a_tiles: Dict[int, List[int]] = {}
		self.external_b_tiles: Dict[int, List[int]] = {}
		self.external_c_tiles: Dict[int, List[int]] = {}
		self.descriptors: Dict[int, DescriptorAddrs] = {}
		self.expected_rd_dma: Deque[ReadDmaExpectation] = deque()
		self.pending_resp_plans: Dict[int, Deque[Tuple[str, object]]] = {}
		self.rd_desc_log: List[ReadDmaLog] = []
		self.wr_desc_log: List[WriteDmaLog] = []
		self.rd_desc_count = 0
		self.wr_desc_count = 0
		self.export_done_count = 0
		self.export_error_count = 0
		self._resp_visible = False
		self._resp_word = 0
		self._started = False
		self._tasks = []

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
			cocotb.start_soon(self._resp_fifo_monitor()),
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
		self.rd_desc_count = 0
		self.wr_desc_count = 0
		self.export_done_count = 0
		self.export_error_count = 0
		self._resp_visible = False
		self._resp_word = 0

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
				return resp
		raise AssertionError(f"AXI-Lite write response timeout at 0x{addr:02x}")

	async def axil_read(self, addr: int) -> int:
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
		self.descriptors[ctrl_id & 0xFFFF_FFFF] = DescriptorAddrs(
			a_addr=a_addr & 0xFFFF_FFFF_FFFF_FFFF,
			b_addr=b_addr & 0xFFFF_FFFF_FFFF_FFFF,
			c_addr=c_addr & 0xFFFF_FFFF_FFFF_FFFF,
			m_addr=m_addr & 0xFFFF_FFFF_FFFF_FFFF,
		)
		await self.axil_write(ADDR_CMD_INST, inst & 0xFFFF_FFFF)
		await self.axil_write(ADDR_CMD_ID, ctrl_id & 0xFFFF_FFFF)
		await self._write_addr64(ADDR_A_ADDR_LO, ADDR_A_ADDR_HI, a_addr)
		await self._write_addr64(ADDR_B_ADDR_LO, ADDR_B_ADDR_HI, b_addr)
		await self._write_addr64(ADDR_C_ADDR_LO, ADDR_C_ADDR_HI, c_addr)
		await self._write_addr64(ADDR_M_ADDR_LO, ADDR_M_ADDR_HI, m_addr)
		await self.axil_write(ADDR_CTRL, CTRL_DESC_PUSH, write_delay_cycles=ctrl_write_delay_cycles)

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

	async def wait_and_pop_resp(self, expected_word: int, timeout_cycles: int = 4000) -> int:
		for _ in range(timeout_cycles):
			status = await self.axil_read(ADDR_STATUS)
			if status & STATUS_RESP_FIFO_NOT_EMPTY:
				head = await self.axil_read(ADDR_RESP_HEAD)
				assert head == expected_word, f"resp mismatch exp=0x{expected_word:08x} got=0x{head:08x}"
				await self.pop_resp()
				self._finalize_pending_plan(head)
				return head
			await RisingEdge(self.dut.clk)
		raise AssertionError(f"resp timeout waiting for 0x{expected_word:08x}")

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

	async def _resp_fifo_monitor(self) -> None:
		try:
			while True:
				await RisingEdge(self.dut.clk)
				await ReadOnly()
				resp_valid = value_to_int(self.dut.u_resp_fifo.valid_out.value)
				resp_word = value_to_int(self.dut.u_resp_fifo.data_out.value)
				if resp_valid:
					if (not self._resp_visible) or (resp_word != self._resp_word):
						self._finalize_pending_plan(resp_word)
						self._resp_visible = True
						self._resp_word = resp_word
				else:
					self._resp_visible = False
		except Exception:
			self.dut._log.exception("resp_fifo_monitor crashed")
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
		self._queue_pending_plan(plan.response_word, "load", plan)
		desc = self.descriptors.get(ctrl_id & 0xFFFF_FFFF, DescriptorAddrs(0, 0, 0, 0))
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
		self._queue_pending_plan(plan.response_word, "exec", plan)
		desc = self.descriptors.get(ctrl_id & 0xFFFF_FFFF, DescriptorAddrs(0, 0, 0, 0))
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
		self._queue_pending_plan(plan.response_word, "exec", plan)
		desc = self.descriptors.get(ctrl_id & 0xFFFF_FFFF, DescriptorAddrs(0, 0, 0, 0))
		for expected_req in plan.expected_dma_loads:
			if expected_req.kind == "C":
				self.expected_rd_dma.append(ReadDmaExpectation(ctrl_id, "C", desc.c_addr, plan.b_len))
		return plan

	async def cfg_selector16(self, selector: int, value16: int, ctrl_id: int) -> None:
		await self.send_desc_command(build_cfg_inst(selector, value16 & 0xFFFF), ctrl_id)
		await self.wait_and_pop_resp(pack_resp(False, 0, ctrl_id))
		if selector == PT_CFG_A_BASE_LO:
			self.model.set_base("A", (self.model.a_base & 0xFFFF_0000) | (value16 & 0xFFFF))
		elif selector == PT_CFG_A_BASE_HI:
			self.model.set_base("A", ((value16 & 0xFFFF) << 16) | (self.model.a_base & 0x0000_FFFF))
		elif selector == PT_CFG_B_BASE_LO:
			self.model.set_base("B", (self.model.b_base & 0xFFFF_0000) | (value16 & 0xFFFF))
		elif selector == PT_CFG_B_BASE_HI:
			self.model.set_base("B", ((value16 & 0xFFFF) << 16) | (self.model.b_base & 0x0000_FFFF))

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
		await self.send_desc_command(build_qcfg_header(granularity, qtype=PT_QTYPE_SYMMETRIC), ctrl_id)
		for _ in range(2):
			await RisingEdge(self.dut.clk)
		for idx, word in enumerate(inv_scales):
			await self.send_desc_command(to_unsigned(word, 32), ctrl_id)
			if idx == (len(inv_scales) - 1):
				await self.wait_and_pop_resp(pack_resp(False, 0, ctrl_id))
			else:
				status = await self.axil_read(ADDR_STATUS)
				assert (status & STATUS_RESP_FIFO_NOT_EMPTY) == 0
		self.model.set_qcfg(granularity, inv_scales)

	async def _rd_dma_agent(self) -> None:
		try:
			while True:
				await RisingEdge(self.dut.clk)
				await ReadOnly()
				if value_to_int(self.dut.rd_dma_desc_valid.value) and value_to_int(self.dut.rd_dma_desc_ready.value):
					self.rd_desc_count += 1
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
					await self._serve_rd_stream(expected)
		except Exception:
			self.dut._log.exception("rd_dma_agent crashed")
			raise

	async def _serve_rd_stream(self, expectation: ReadDmaExpectation) -> None:
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
		beats = self._pack_ab_beats(kind, matrix, expectation)
		await RisingEdge(self.dut.clk)
		for beat_idx, (word, strb) in enumerate(beats):
			while True:
				self.dut.s_axis_tvalid.value = 1
				self.dut.s_axis_tdata.value = word
				self.dut.s_axis_tstrb.value = strb
				self.dut.s_axis_tuser.value = req_tuser
				self.dut.s_axis_tlast.value = 1 if beat_idx == (len(beats) - 1) else 0
				await RisingEdge(self.dut.clk)
				if value_to_int(self.dut.s_axis_tready.value):
					break
		self.dut.s_axis_tvalid.value = 0
		self.dut.s_axis_tlast.value = 0

	async def _wr_dma_agent(self) -> None:
		try:
			while True:
				await RisingEdge(self.dut.clk)
				await ReadOnly()
				if value_to_int(self.dut.wr_dma_desc_valid.value) and value_to_int(self.dut.wr_dma_desc_ready.value):
					self.wr_desc_count += 1
					expected = await self._await_expected_export()
					desc = self.descriptors[expected.ctrl_id]
					expected_beats = self._pack_export_beats(expected.matrix)
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
					await self._consume_export(expected, expected_beats)
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

	async def _consume_export(self, expected: ExportExpectation, expected_beats: Sequence[Tuple[int, int]]) -> None:
		beat_idx = 0
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
				beat_idx += 1
		await RisingEdge(self.dut.clk)
		self.dut.wr_dma_done.value = 1
		await RisingEdge(self.dut.clk)
		self.dut.wr_dma_done.value = 0
		self.export_done_count += 1
		self.model.complete_export(expected.buffer)


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
