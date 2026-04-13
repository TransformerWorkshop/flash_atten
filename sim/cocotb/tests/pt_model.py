from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Tuple


PT_OP_MATMUL = 0x1
PT_OP_QCFG = 0x2
PT_OP_MATADD = 0x3
PT_OP_CFG = 0xF

PT_SCALE_SCALAR = 0b00
PT_SCALE_FULL_DIV4 = 0b01
PT_SCALE_FULL_DIV2 = 0b10
PT_SCALE_FULL = 0b11

PT_CFG_A_BASE_LO = 0x0
PT_CFG_A_BASE_HI = 0x1
PT_CFG_B_BASE_LO = 0x2
PT_CFG_B_BASE_HI = 0x3

PT_QCFG_CMD_HDR = 0x0
PT_QTYPE_SYMMETRIC = 0b00

PT_QGRAN_PER_TENSOR = 0
PT_QGRAN_X_WISE = 1
PT_QGRAN_Y_WISE = 2
PT_QGRAN_X_WISE_DIV2 = 3
PT_QGRAN_Y_WISE_DIV2 = 4

MATRIX_A_TUSER = 0b01
MATRIX_B_TUSER = 0b10


def to_signed(value: int, bits: int) -> int:
	mask = (1 << bits) - 1
	value &= mask
	sign_bit = 1 << (bits - 1)
	return value - (1 << bits) if (value & sign_bit) else value


def to_unsigned(value: int, bits: int) -> int:
	return value & ((1 << bits) - 1)


def pack_resp(err: bool, m_buf: int, ctrl_id: int) -> int:
	return ((1 if err else 0) << 31) | ((m_buf & 0x1) << 30) | (ctrl_id & 0x3FFF_FFFF)


def build_cfg_inst(selector: int, value16: int) -> int:
	return ((PT_OP_CFG & 0xF) << 28) | ((selector & 0xF) << 24) | (value16 & 0xFFFF)


def build_qcfg_header(granularity: int, qtype: int = PT_QTYPE_SYMMETRIC, cmd: int = PT_QCFG_CMD_HDR) -> int:
	return (
		((PT_OP_QCFG & 0xF) << 28)
		| ((cmd & 0xF) << 24)
		| ((qtype & 0x3) << 22)
		| ((granularity & 0x7) << 19)
	)


def build_matmul_inst(m_scale: int, n_scale: int, k_scale: int, a_off: int, b_off: int) -> int:
	return (
		((PT_OP_MATMUL & 0xF) << 28)
		| ((m_scale & 0x3) << 26)
		| ((n_scale & 0x3) << 24)
		| ((k_scale & 0x3) << 22)
		| ((a_off & 0x3FF) << 12)
		| ((b_off & 0x3FF) << 2)
	)


def build_matadd_inst(m_off: int, c_off: int, reserved_hi: int = 0, reserved_lo: int = 0) -> int:
	return (
		((PT_OP_MATADD & 0xF) << 28)
		| ((reserved_hi & 0x3F) << 22)
		| ((m_off & 0x3FF) << 12)
		| ((c_off & 0x3FF) << 2)
		| (reserved_lo & 0x3)
	)


def build_mwin_off(buf_sel: int, elem_off: int) -> int:
	return (1 << 9) | ((buf_sel & 0x1) << 8) | (elem_off & 0xFF)


def ensure_row_major(matrix: Sequence[Sequence[int]] | Sequence[int], rows: int, cols: int, bits: int) -> List[int]:
	if len(matrix) == rows and all(isinstance(row, (list, tuple)) for row in matrix):  # type: ignore[arg-type]
		flat = [to_unsigned(int(value), bits) for row in matrix for value in row]  # type: ignore[union-attr]
	else:
		flat = [to_unsigned(int(value), bits) for value in matrix]  # type: ignore[arg-type]
	if len(flat) != rows * cols:
		raise ValueError(f"matrix size mismatch: expected {rows * cols} values, got {len(flat)}")
	return flat


def identity_matrix(dim: int, bits: int) -> List[int]:
	return [1 if row == col else 0 for row in range(dim) for col in range(dim)]


def zero_matrix(rows: int, cols: int) -> List[int]:
	return [0] * (rows * cols)


def constant_matrix(rows: int, cols: int, value: int, bits: int) -> List[int]:
	word = to_unsigned(value, bits)
	return [word] * (rows * cols)


def matmul_row_major(a_matrix: Sequence[int], b_matrix: Sequence[int], x_dim: int, y_dim: int, k_dim: Optional[int] = None) -> List[int]:
	if k_dim is None:
		k_dim = x_dim
	result: List[int] = []
	for row in range(x_dim):
		for col in range(y_dim):
			acc = 0
			for acc_idx in range(k_dim):
				acc += int(a_matrix[row * k_dim + acc_idx]) * int(b_matrix[acc_idx * y_dim + col])
			result.append(acc)
	return result


def qcfg_payload_count(granularity: int, x_dim: int, y_dim: int) -> Optional[int]:
	if granularity == PT_QGRAN_PER_TENSOR:
		return 1
	if granularity == PT_QGRAN_X_WISE:
		return x_dim
	if granularity == PT_QGRAN_Y_WISE:
		return y_dim
	if granularity == PT_QGRAN_X_WISE_DIV2:
		return None if (x_dim % 2) else (x_dim // 2)
	if granularity == PT_QGRAN_Y_WISE_DIV2:
		return None if (y_dim % 2) else (y_dim // 2)
	return None


def select_scale_index(granularity: int, row_idx: int, col_idx: int) -> int:
	if granularity == PT_QGRAN_X_WISE:
		return row_idx
	if granularity == PT_QGRAN_Y_WISE:
		return col_idx
	if granularity == PT_QGRAN_X_WISE_DIV2:
		return row_idx >> 1
	if granularity == PT_QGRAN_Y_WISE_DIV2:
		return col_idx >> 1
	return 0


def quantize_value(acc_value: int, inv_scale_word: int, data_width: int) -> int:
	inv_scale = to_signed(inv_scale_word, 32)
	prod = acc_value * inv_scale
	prod_mag = -prod if prod < 0 else prod
	q_mag = (prod_mag + 0x8000) >> 16
	q_signed = -q_mag if prod < 0 else q_mag
	sat_max = (1 << (data_width - 1)) - 1
	sat_min = -(1 << (data_width - 1))
	if q_signed > sat_max:
		q_signed = sat_max
	elif q_signed < sat_min:
		q_signed = sat_min
	return to_unsigned(q_signed, data_width)


def saturating_add_value(lhs_word: int, rhs_word: int, data_width: int) -> int:
	lhs = to_signed(lhs_word, data_width)
	rhs = to_signed(rhs_word, data_width)
	sum_value = lhs + rhs
	sat_max = (1 << (data_width - 1)) - 1
	sat_min = -(1 << (data_width - 1))
	if sum_value > sat_max:
		sum_value = sat_max
	elif sum_value < sat_min:
		sum_value = sat_min
	return to_unsigned(sum_value, data_width)


def saturating_add_matrix(lhs_matrix: Sequence[int], rhs_matrix: Sequence[int], data_width: int) -> List[int]:
	if len(lhs_matrix) != len(rhs_matrix):
		raise ValueError(f"matrix size mismatch: lhs={len(lhs_matrix)} rhs={len(rhs_matrix)}")
	return [
		saturating_add_value(lhs_word=int(lhs_word), rhs_word=int(rhs_word), data_width=data_width)
		for lhs_word, rhs_word in zip(lhs_matrix, rhs_matrix)
	]


@dataclass
class QuantConfig:
	granularity: int
	inv_scales: List[int]


@dataclass
class CacheEntry:
	a_off: Optional[int]
	b_off: Optional[int]
	a_matrix: Optional[List[int]] = None
	b_matrix: Optional[List[int]] = None


@dataclass
class ExportExpectation:
	ctrl_id: int
	buffer: int
	matrix: List[int]


@dataclass
class DmaLoadExpectation:
	ctrl_id: int
	kind: str
	ext_addr: int
	local_addr: int
	beats: int


@dataclass
class ExecPlan:
	ctrl_id: int
	response_word: int
	err: bool
	success_buffer: Optional[int]
	result_matrix: Optional[List[int]]
	expected_dma_loads: List[DmaLoadExpectation]
	a_off: int
	b_off: int
	a_matrix: Optional[List[int]]
	b_matrix: Optional[List[int]]
	cache_update: Optional[CacheEntry]


MatmulPlan = ExecPlan
MataddPlan = ExecPlan


class PTBlackBoxModel:
	def __init__(self, x_dim: int, y_dim: int, data_width: int = 32):
		self.x_dim = x_dim
		self.y_dim = y_dim
		self.data_width = data_width
		self.word_bytes = max(1, data_width // 8)
		self.k_dim = x_dim
		self.max_dim = max(x_dim, y_dim)
		self.a_base = 0
		self.b_base = 0
		self.quant_cfg = QuantConfig(
			granularity=PT_QGRAN_PER_TENSOR,
			inv_scales=[0x0001_0000] * self.max_dim,
		)
		self.cache_by_id: Dict[int, CacheEntry] = {}
		self.m_buffers: Dict[int, Optional[List[int]]] = {0: None, 1: None}
		self.m_buffer_ctrl_id: Dict[int, Optional[int]] = {0: None, 1: None}
		self.m_buffer_state: Dict[int, str] = {0: "free", 1: "free"}
		self.next_write_buf = 0
		self.a_dma_buf_sel = 0
		self.b_dma_buf_sel = 0

	def reset_runtime_state(self) -> None:
		self.quant_cfg = QuantConfig(
			granularity=PT_QGRAN_PER_TENSOR,
			inv_scales=[0x0001_0000] * self.max_dim,
		)
		self.cache_by_id.clear()
		self.m_buffers = {0: None, 1: None}
		self.m_buffer_ctrl_id = {0: None, 1: None}
		self.m_buffer_state = {0: "free", 1: "free"}
		self.next_write_buf = 0
		self.a_dma_buf_sel = 0
		self.b_dma_buf_sel = 0

	def set_base(self, kind: str, value: int) -> None:
		if kind == "A":
			self.a_base = value & 0xFFFF_FFFF
		elif kind == "B":
			self.b_base = value & 0xFFFF_FFFF
		else:
			raise ValueError(f"unknown base kind {kind!r}")

	def ext_addr(self, kind: str, elem_off: int) -> int:
		base = self.a_base if kind == "A" else self.b_base
		return (base + (elem_off * self.word_bytes)) & 0xFFFF_FFFF

	def local_addr(self, kind: str, elem_off: int, buf_sel: int) -> int:
		align = self.x_dim if kind == "A" else self.y_dim
		local_elem_off = elem_off & ~(align - 1)
		return ((buf_sel & 0x1) << 8) | (local_elem_off & 0xFF)

	def set_qcfg(self, granularity: int, inv_scales: Sequence[int]) -> None:
		payload_count = qcfg_payload_count(granularity, self.x_dim, self.y_dim)
		if payload_count is None:
			raise ValueError("invalid qcfg granularity for current dimensions")
		if len(inv_scales) != payload_count:
			raise ValueError(f"expected {payload_count} qcfg payloads, got {len(inv_scales)}")
		full_scale = [0x0001_0000] * self.max_dim
		for idx, word in enumerate(inv_scales):
			full_scale[idx] = to_unsigned(int(word), 32)
		self.quant_cfg = QuantConfig(granularity=granularity, inv_scales=full_scale)

	def _quantize_matrix(self, acc_matrix: Sequence[int]) -> List[int]:
		quantized: List[int] = []
		for row in range(self.x_dim):
			for col in range(self.y_dim):
				scale_idx = select_scale_index(self.quant_cfg.granularity, row, col)
				scale_idx = max(0, min(scale_idx, self.max_dim - 1))
				quantized.append(
					quantize_value(
						acc_value=int(acc_matrix[row * self.y_dim + col]),
						inv_scale_word=self.quant_cfg.inv_scales[scale_idx],
						data_width=self.data_width,
					)
				)
		return quantized

	def _resolve_matrix(
		self,
		kind: str,
		offset: int,
		external_tiles: Dict[int, List[int]],
	) -> Tuple[List[int], bool]:
		is_mwindow = bool((offset >> 9) & 0x1)
		if is_mwindow:
			buffer = (offset >> 8) & 0x1
			matrix = self.m_buffers.get(buffer)
			if matrix is None:
				raise ValueError(f"M-window buffer {buffer} has no retained contents for {kind}")
			return list(matrix), True

		ext_addr = self.ext_addr(kind, offset)
		try:
			return list(external_tiles[ext_addr]), False
		except KeyError as exc:
			raise KeyError(f"missing external tile for {kind} at ext_addr=0x{ext_addr:08x}") from exc

	def issue_matmul(
		self,
		ctrl_id: int,
		a_off: int,
		b_off: int,
		external_a_tiles: Dict[int, List[int]],
		external_b_tiles: Dict[int, List[int]],
		m_scale: int = PT_SCALE_FULL,
		n_scale: int = PT_SCALE_FULL,
		k_scale: int = PT_SCALE_FULL,
	) -> ExecPlan:
		if (m_scale, n_scale, k_scale) != (PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL):
			return ExecPlan(
				ctrl_id=ctrl_id,
				response_word=pack_resp(True, 0, ctrl_id),
				err=True,
				success_buffer=None,
				result_matrix=None,
				expected_dma_loads=[],
				a_off=a_off,
				b_off=b_off,
				a_matrix=None,
				b_matrix=None,
				cache_update=None,
			)

		if ((a_off & 0xFF) % self.x_dim) != 0 or ((b_off & 0xFF) % self.y_dim) != 0:
			return ExecPlan(
				ctrl_id=ctrl_id,
				response_word=pack_resp(True, 0, ctrl_id),
				err=True,
				success_buffer=None,
				result_matrix=None,
				expected_dma_loads=[],
				a_off=a_off,
				b_off=b_off,
				a_matrix=None,
				b_matrix=None,
				cache_update=None,
			)

		cache_entry = self.cache_by_id.get(ctrl_id)
		expected_dma_loads: List[DmaLoadExpectation] = []

		a_matrix, a_is_m = self._resolve_matrix("A", a_off, external_a_tiles)
		if not a_is_m and cache_entry is not None and cache_entry.a_off == a_off and cache_entry.a_matrix is not None:
			a_matrix = list(cache_entry.a_matrix)
		elif not a_is_m:
			expected_dma_loads.append(
				DmaLoadExpectation(
					ctrl_id=ctrl_id,
					kind="A",
					ext_addr=self.ext_addr("A", a_off),
					local_addr=self.local_addr("A", a_off, self.a_dma_buf_sel),
					beats=self.x_dim * self.x_dim,
				)
			)

		b_matrix, b_is_m = self._resolve_matrix("B", b_off, external_b_tiles)
		if not b_is_m and cache_entry is not None and cache_entry.b_off == b_off and cache_entry.b_matrix is not None:
			b_matrix = list(cache_entry.b_matrix)
		elif not b_is_m:
			expected_dma_loads.append(
				DmaLoadExpectation(
					ctrl_id=ctrl_id,
					kind="B",
					ext_addr=self.ext_addr("B", b_off),
					local_addr=self.local_addr("B", b_off, self.b_dma_buf_sel),
					beats=self.y_dim * self.y_dim,
				)
			)

		result_matrix = self._quantize_matrix(matmul_row_major(a_matrix, b_matrix, self.x_dim, self.y_dim, self.k_dim))
		success_buffer = self.next_write_buf
		cache_update = CacheEntry(
			a_off=None if a_is_m else a_off,
			b_off=None if b_is_m else b_off,
		)
		return ExecPlan(
			ctrl_id=ctrl_id,
			response_word=pack_resp(False, success_buffer, ctrl_id),
			err=False,
			success_buffer=success_buffer,
			result_matrix=result_matrix,
			expected_dma_loads=expected_dma_loads,
			a_off=a_off,
			b_off=b_off,
			a_matrix=None if a_is_m else list(a_matrix),
			b_matrix=None if b_is_m else list(b_matrix),
			cache_update=cache_update,
		)

	def issue_matadd(
		self,
		ctrl_id: int,
		m_off: int,
		c_off: int,
		external_b_tiles: Dict[int, List[int]],
		*,
		reserved_hi: int = 0,
		reserved_lo: int = 0,
	) -> ExecPlan:
		if ((reserved_hi & 0x3F) != 0) or ((reserved_lo & 0x3) != 0):
			return ExecPlan(
				ctrl_id=ctrl_id,
				response_word=pack_resp(True, 0, ctrl_id),
				err=True,
				success_buffer=None,
				result_matrix=None,
				expected_dma_loads=[],
				a_off=m_off,
				b_off=c_off,
				a_matrix=None,
				b_matrix=None,
				cache_update=None,
			)

		if not ((m_off >> 9) & 0x1) or ((c_off >> 9) & 0x1) or ((c_off & 0xFF) % self.y_dim) != 0:
			return ExecPlan(
				ctrl_id=ctrl_id,
				response_word=pack_resp(True, 0, ctrl_id),
				err=True,
				success_buffer=None,
				result_matrix=None,
				expected_dma_loads=[],
				a_off=m_off,
				b_off=c_off,
				a_matrix=None,
				b_matrix=None,
				cache_update=None,
			)

		m_buffer = (m_off >> 8) & 0x1
		m_matrix = self.m_buffers.get(m_buffer)
		if m_matrix is None:
			raise ValueError(f"M-window buffer {m_buffer} has no retained contents for MATADD")

		cache_entry = self.cache_by_id.get(ctrl_id)
		expected_dma_loads: List[DmaLoadExpectation] = []
		c_matrix, _ = self._resolve_matrix("B", c_off, external_b_tiles)
		if cache_entry is not None and cache_entry.b_off == c_off and cache_entry.b_matrix is not None:
			c_matrix = list(cache_entry.b_matrix)
		else:
			expected_dma_loads.append(
				DmaLoadExpectation(
					ctrl_id=ctrl_id,
					kind="B",
					ext_addr=self.ext_addr("B", c_off),
					local_addr=self.local_addr("B", c_off, self.b_dma_buf_sel),
					beats=self.y_dim * self.y_dim,
				)
			)

		result_matrix = saturating_add_matrix(m_matrix, c_matrix, self.data_width)
		success_buffer = self.next_write_buf
		cache_update = CacheEntry(a_off=None, b_off=c_off)
		return ExecPlan(
			ctrl_id=ctrl_id,
			response_word=pack_resp(False, success_buffer, ctrl_id),
			err=False,
			success_buffer=success_buffer,
			result_matrix=result_matrix,
			expected_dma_loads=expected_dma_loads,
			a_off=m_off,
			b_off=c_off,
			a_matrix=None,
			b_matrix=list(c_matrix),
			cache_update=cache_update,
		)

	def commit_success(self, plan: ExecPlan) -> None:
		if plan.err or plan.success_buffer is None or plan.result_matrix is None:
			raise ValueError("cannot commit an error plan")
		buffer = plan.success_buffer
		self.m_buffers[buffer] = list(plan.result_matrix)
		self.m_buffer_ctrl_id[buffer] = plan.ctrl_id
		self.m_buffer_state[buffer] = "ready"
		self.next_write_buf = 1 - buffer

		prev = self.cache_by_id.get(plan.ctrl_id, CacheEntry(a_off=None, b_off=None))
		self.cache_by_id[plan.ctrl_id] = CacheEntry(
			a_off=plan.cache_update.a_off if plan.cache_update and plan.cache_update.a_off is not None else prev.a_off,
			b_off=plan.cache_update.b_off if plan.cache_update and plan.cache_update.b_off is not None else prev.b_off,
			a_matrix=plan.a_matrix if plan.a_matrix is not None else prev.a_matrix,
			b_matrix=plan.b_matrix if plan.b_matrix is not None else prev.b_matrix,
		)

	def expected_export(self) -> ExportExpectation:
		ready0 = self.m_buffer_state[0] == "ready"
		ready1 = self.m_buffer_state[1] == "ready"
		if ready0 and ready1:
			buffer = self.next_write_buf
		elif ready1:
			buffer = 1
		elif ready0:
			buffer = 0
		else:
			raise ValueError("no ready M buffer available for export")

		matrix = self.m_buffers[buffer]
		ctrl_id = self.m_buffer_ctrl_id[buffer]
		if matrix is None or ctrl_id is None:
			raise ValueError(f"buffer {buffer} has no matrix data")
		self.m_buffer_state[buffer] = "exporting"
		return ExportExpectation(ctrl_id=(ctrl_id & 0x3FFF_FFFF), buffer=buffer, matrix=list(matrix))

	def complete_export(self, buffer: int) -> None:
		self.m_buffer_state[buffer] = "free"

	def commit_dma_success(self, kind: str) -> None:
		if kind == "A":
			self.a_dma_buf_sel = 1 - self.a_dma_buf_sel
		elif kind == "B":
			self.b_dma_buf_sel = 1 - self.b_dma_buf_sel
		else:
			raise ValueError(f"unknown DMA kind {kind!r}")
