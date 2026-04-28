from __future__ import annotations

import inspect
import os
from dataclasses import dataclass
from pathlib import Path
from typing import List, Sequence, Tuple

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

from tests.pt_model import (
	build_cfg_inst,
	build_load_inst,
	build_matadd_inst,
	build_mwin_off,
	build_qcfg_header,
	pack_export_beats,
	packed_word_count,
	pack_resp,
	qcfg_payload_count,
	to_signed,
	to_unsigned,
)


ADDR_CTRL = 0x00
ADDR_STATUS = 0x04
ADDR_CMD_INST = 0x08
ADDR_CMD_ID = 0x0C
ADDR_RESP_HEAD = 0x30
ADDR_SHELL_MODE = 0x80
ADDR_INGRESS_KIND = 0x84
ADDR_INGRESS_CTRL_ID = 0x88
ADDR_INGRESS_TILE_INFO0 = 0x8C
ADDR_INGRESS_TILE_INFO1 = 0x90
ADDR_INGRESS_WORD_COUNT = 0x94
ADDR_INGRESS_PUSH = 0x98
ADDR_SHELL_STATUS = 0x9C
ADDR_OUT_META_HEAD0 = 0xA0
ADDR_OUT_META_HEAD1 = 0xA4
ADDR_OUT_META_HEAD2 = 0xA8
ADDR_OUT_META_POP = 0xAC

CTRL_DESC_PUSH = 1 << 0
CTRL_RESP_POP = 1 << 1
CTRL_SOFT_CLEAR = 1 << 2
CTRL_CLEAR_FLAGS = 1 << 3

STATUS_CMD_SLOT_READY = 1 << 0
STATUS_RESP_NOT_EMPTY = 1 << 1

SHELL_KIND_A = 1
SHELL_KIND_B = 2
SHELL_KIND_C = 3


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


def encode_tile_info0(m_tile_off: int, n_tile_off: int, k_tile_off: int) -> int:
	return ((k_tile_off & 0xFF) << 16) | ((n_tile_off & 0xFF) << 8) | (m_tile_off & 0xFF)


def encode_tile_info1(m_tiles: int, n_tiles: int, k_tiles: int) -> int:
	return ((k_tiles & 0xFF) << 16) | ((n_tiles & 0xFF) << 8) | (m_tiles & 0xFF)


def words_to_128b_beats(words: Sequence[int]) -> List[Tuple[int, int]]:
	beats: List[Tuple[int, int]] = []
	for start in range(0, len(words), 4):
		chunk = words[start : start + 4]
		data = 0
		strb = 0
		for lane_idx, word in enumerate(chunk):
			data |= to_unsigned(int(word), 32) << (lane_idx * 32)
			strb |= 0xF << (lane_idx * 4)
		beats.append((data, strb))
	return beats


def scalar_matrix_to_a_words(matrix: Sequence[int], *, x_dim: int, m_tiles: int, k_tiles: int, pack_lanes: int, data_width: int, elem_width: int) -> List[int]:
	k_dim = x_dim * k_tiles
	m_dim = x_dim * m_tiles
	if len(matrix) != (m_dim * k_dim):
		raise ValueError("A matrix size mismatch")

	def pack_word(values: Sequence[int]) -> int:
		word = 0
		for lane_idx, value in enumerate(values):
			word |= to_unsigned(to_signed(int(value), data_width), elem_width) << (lane_idx * elem_width)
		return word & 0xFFFF_FFFF

	if pack_lanes <= 1:
		return [
			int(matrix[((m_tile * x_dim) + row) * k_dim + col])
			for m_tile in range(m_tiles)
			for col in range(k_dim)
			for row in range(x_dim)
		]

	return [
		pack_word(
			int(matrix[((m_tile * x_dim) + row) * k_dim + ((col_word * pack_lanes) + pack_idx)])
			for pack_idx in range(pack_lanes)
		)
		for m_tile in range(m_tiles)
		for col_word in range(packed_word_count(k_dim, pack_lanes))
		for row in range(x_dim)
	]


def scalar_matrix_to_b_words(matrix: Sequence[int], *, y_dim: int, k_tiles: int, n_tiles: int, pack_lanes: int, data_width: int, elem_width: int) -> List[int]:
	k_dim = y_dim * k_tiles
	n_dim = y_dim * n_tiles
	if len(matrix) != (k_dim * n_dim):
		raise ValueError("B matrix size mismatch")

	def pack_word(values: Sequence[int]) -> int:
		word = 0
		for lane_idx, value in enumerate(values):
			word |= to_unsigned(to_signed(int(value), data_width), elem_width) << (lane_idx * elem_width)
		return word & 0xFFFF_FFFF

	if pack_lanes <= 1:
		return [
			int(matrix[row * n_dim + (n_tile * y_dim) + col])
			for n_tile in range(n_tiles)
			for row in range(k_dim)
			for col in range(y_dim)
		]

	return [
		pack_word(
			int(matrix[((row_word * pack_lanes) + pack_idx) * n_dim + (n_tile * y_dim) + col])
			for pack_idx in range(pack_lanes)
		)
		for n_tile in range(n_tiles)
		for row_word in range(packed_word_count(k_dim, pack_lanes))
		for col in range(y_dim)
	]


def scalar_matrix_to_c_words(matrix: Sequence[int], *, y_dim: int, pack_lanes: int, data_width: int, elem_width: int) -> List[int]:
	beats = pack_export_beats(
		matrix,
		y_dim=y_dim,
		data_width=data_width,
		m_export_lanes=y_dim,
		pack_lanes=pack_lanes,
		elem_width=elem_width,
	)
	words: List[int] = []
	for beat_data, beat_strb in beats:
		for lane_idx in range(y_dim):
			if beat_strb & (0xF << (lane_idx * 4)):
				words.append((beat_data >> (lane_idx * 32)) & 0xFFFF_FFFF)
	return words


@dataclass
class OutputMeta:
	ctrl_id: int
	m_tile_off: int
	n_tile_off: int
	is_final: bool
	word_count: int
	m_tiles: int
	n_tiles: int


class PTShellSimEnv:
	def __init__(self, dut):
		self.dut = dut
		self.case_name = discover_case_name()
		self.x_dim = env_int("PT_X_DIM", 16)
		self.y_dim = env_int("PT_Y_DIM", 16)
		self.data_width = env_int("PT_DATA_WIDTH", 32)
		self.elem_width = env_int("PT_ELEM_WIDTH", 8)
		self.pack_lanes = env_int("PT_PACK_LANES", 4)
		self._started = False
		self._tasks = []
		self.ingress_gap_cycles = 0

	def configure_ingress_gap(self, gap_cycles: int) -> None:
		self.ingress_gap_cycles = max(0, gap_cycles)

	async def start(self) -> None:
		if self._started:
			return
		self._started = True
		self.dut.s_axil_awaddr.value = 0
		self.dut.s_axil_awvalid.value = 0
		self.dut.s_axil_wdata.value = 0
		self.dut.s_axil_wstrb.value = 0
		self.dut.s_axil_wvalid.value = 0
		self.dut.s_axil_bready.value = 0
		self.dut.s_axil_araddr.value = 0
		self.dut.s_axil_arvalid.value = 0
		self.dut.s_axil_rready.value = 0
		self.dut.s_shell_axis_tvalid.value = 0
		self.dut.s_shell_axis_tdata.value = 0
		self.dut.s_shell_axis_tstrb.value = 0
		self.dut.s_shell_axis_tlast.value = 0
		self.dut.s_shell_axis_tkeep.value = 1
		self.dut.m_shell_axis_tready.value = 0
		self._tasks = [cocotb.start_soon(Clock(self.dut.clk, 10, unit="ns").start())]

	def shutdown(self) -> None:
		for task in self._tasks:
			try:
				task.kill()
			except Exception:
				pass
		self._tasks = []
		self._started = False

	async def reset(self, cycles: int = 5) -> None:
		self.dut.rstn.value = 0
		self.dut.clear.value = 0
		await ClockCycles(self.dut.clk, cycles)
		self.dut.rstn.value = 1
		await ClockCycles(self.dut.clk, cycles)

	async def axil_write(self, addr: int, data: int, wstrb: int = 0xF) -> int:
		self.dut.s_axil_awaddr.value = addr
		self.dut.s_axil_awvalid.value = 1
		self.dut.s_axil_wdata.value = data & 0xFFFF_FFFF
		self.dut.s_axil_wstrb.value = wstrb & 0xF
		self.dut.s_axil_wvalid.value = 1
		self.dut.s_axil_bready.value = 1
		for _ in range(200):
			await RisingEdge(self.dut.clk)
			if value_to_int(self.dut.s_axil_awready.value) and value_to_int(self.dut.s_axil_wready.value):
				self.dut.s_axil_awvalid.value = 0
				self.dut.s_axil_wvalid.value = 0
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
			if value_to_int(self.dut.s_axil_arready.value):
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

	async def set_shell_mode(self, *, forward_m: bool, emit_intermediate: bool) -> None:
		value = (1 if forward_m else 0) | ((1 if emit_intermediate else 0) << 1)
		await self.axil_write(ADDR_SHELL_MODE, value)

	async def push_ingress_words(
		self,
		*,
		kind: int,
		ctrl_id: int,
		m_tile_off: int,
		n_tile_off: int,
		k_tile_off: int,
		m_tiles: int,
		n_tiles: int,
		k_tiles: int,
		words: Sequence[int],
		declared_word_count: int | None = None,
	) -> None:
		await self.axil_write(ADDR_INGRESS_KIND, kind)
		await self.axil_write(ADDR_INGRESS_CTRL_ID, ctrl_id)
		await self.axil_write(ADDR_INGRESS_TILE_INFO0, encode_tile_info0(m_tile_off, n_tile_off, k_tile_off))
		await self.axil_write(ADDR_INGRESS_TILE_INFO1, encode_tile_info1(m_tiles, n_tiles, k_tiles))
		await self.axil_write(ADDR_INGRESS_WORD_COUNT, len(words) if declared_word_count is None else declared_word_count)
		await self.axil_write(ADDR_INGRESS_PUSH, 1)

		for beat_idx, (beat_data, beat_strb) in enumerate(words_to_128b_beats(words)):
			while not value_to_int(self.dut.s_shell_axis_tready.value):
				await RisingEdge(self.dut.clk)
			self.dut.s_shell_axis_tvalid.value = 1
			self.dut.s_shell_axis_tdata.value = beat_data
			self.dut.s_shell_axis_tstrb.value = beat_strb
			self.dut.s_shell_axis_tlast.value = int(beat_idx == (ceil_div_words(len(words), 4) - 1))
			await RisingEdge(self.dut.clk)
			self.dut.s_shell_axis_tvalid.value = 0
			self.dut.s_shell_axis_tlast.value = 0
			if self.ingress_gap_cycles:
				await ClockCycles(self.dut.clk, self.ingress_gap_cycles)

	async def send_command(self, inst: int, ctrl_id: int) -> None:
		await self.axil_write(ADDR_CMD_INST, inst)
		await self.axil_write(ADDR_CMD_ID, ctrl_id)
		await self.axil_write(ADDR_CTRL, CTRL_DESC_PUSH)

	async def wait_resp(self, timeout_cycles: int = 4000) -> int:
		for _ in range(timeout_cycles):
			status = await self.axil_read(ADDR_STATUS)
			if status & STATUS_RESP_NOT_EMPTY:
				return await self.axil_read(ADDR_RESP_HEAD)
			await RisingEdge(self.dut.clk)
		raise AssertionError("response timeout")

	async def pop_resp(self) -> None:
		await self.axil_write(ADDR_CTRL, CTRL_RESP_POP)

	async def soft_clear(self) -> None:
		await self.axil_write(ADDR_CTRL, CTRL_SOFT_CLEAR)

	async def clear_flags(self) -> None:
		await self.axil_write(ADDR_CTRL, CTRL_CLEAR_FLAGS)

	async def read_shell_status(self) -> int:
		return await self.axil_read(ADDR_SHELL_STATUS)

	async def wait_output_meta(self, timeout_cycles: int = 4000) -> OutputMeta:
		for _ in range(timeout_cycles):
			status = await self.axil_read(ADDR_SHELL_STATUS)
			if status & (1 << 4):
				head0 = await self.axil_read(ADDR_OUT_META_HEAD0)
				head1 = await self.axil_read(ADDR_OUT_META_HEAD1)
				head2 = await self.axil_read(ADDR_OUT_META_HEAD2)
				return OutputMeta(
					ctrl_id=head0,
					m_tile_off=head1 & 0xFF,
					n_tile_off=(head1 >> 8) & 0xFF,
					is_final=bool((head1 >> 24) & 0x1),
					word_count=(head2 >> 16) & 0xFFFF,
					m_tiles=head2 & 0xFF,
					n_tiles=(head2 >> 8) & 0xFF,
				)
			await RisingEdge(self.dut.clk)
		raise AssertionError("output meta timeout")

	async def pop_output_meta(self) -> None:
		await self.axil_write(ADDR_OUT_META_POP, 1)

	async def read_output_packet_words(self, word_count: int, timeout_cycles: int = 4000) -> List[int]:
		words: List[int] = []
		self.dut.m_shell_axis_tready.value = 1
		for _ in range(timeout_cycles):
			await RisingEdge(self.dut.clk)
			if value_to_int(self.dut.m_shell_axis_tvalid.value) and value_to_int(self.dut.m_shell_axis_tready.value):
				beat_data = value_to_int(self.dut.m_shell_axis_tdata.value)
				beat_strb = value_to_int(self.dut.m_shell_axis_tstrb.value)
				for lane_idx in range(4):
					if beat_strb & (0xF << (lane_idx * 4)):
						words.append((beat_data >> (lane_idx * 32)) & 0xFFFF_FFFF)
						if len(words) >= word_count:
							self.dut.m_shell_axis_tready.value = 0
							return words
		self.dut.m_shell_axis_tready.value = 0
		raise AssertionError("output packet timeout")


def ceil_div_words(words: int, lanes: int) -> int:
	return (words + lanes - 1) // lanes


async def create_env(dut) -> PTShellSimEnv:
	env = PTShellSimEnv(dut)
	await env.start()
	return env


async def cfg_selector16(env: PTShellSimEnv, selector: int, value16: int, ctrl_id: int) -> None:
	await env.send_command(build_cfg_inst(selector, value16), ctrl_id)
	resp = await env.wait_resp()
	assert resp == pack_resp(False, 0, ctrl_id)
	await env.pop_resp()


async def qcfg_success(env: PTShellSimEnv, granularity: int, inv_scales: Sequence[int], ctrl_id: int) -> None:
	payload_count = qcfg_payload_count(granularity, env.x_dim, env.y_dim)
	assert payload_count is not None
	assert payload_count == len(inv_scales)
	await env.send_command(build_qcfg_header(granularity), ctrl_id)
	for _ in range(2):
		await RisingEdge(env.dut.clk)
	for idx, word in enumerate(inv_scales):
		await env.send_command(to_unsigned(word, 32), ctrl_id)
		if idx == (len(inv_scales) - 1):
			resp = await env.wait_resp()
			assert resp == pack_resp(False, 0, ctrl_id)
			await env.pop_resp()


async def setup_passthrough_qcfg(env: PTShellSimEnv, ctrl_id: int = 0x10) -> None:
	await cfg_selector16(env, 0, 0x1000, ctrl_id)
	await cfg_selector16(env, 1, 0x0000, ctrl_id + 1)
	await cfg_selector16(env, 2, 0x2000, ctrl_id + 2)
	await cfg_selector16(env, 3, 0x0000, ctrl_id + 3)
