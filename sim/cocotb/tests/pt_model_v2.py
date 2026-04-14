from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Tuple


PT_OP_MATMUL = 0x1
PT_OP_QCFG = 0x2
PT_OP_MATADD = 0x3
PT_OP_LOAD = 0x4
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

DMA_KIND_A = 0b001
DMA_KIND_B = 0b010
DMA_KIND_C = 0b100

MATRIX_A_TUSER = 0b01
MATRIX_B_TUSER = 0b10
MATRIX_C_TUSER = 0b11


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


def build_matmul_inst(m_scale: int, n_scale: int, k_scale: int, a_field: int = 0, b_field: int = 0) -> int:
	return (
		((PT_OP_MATMUL & 0xF) << 28)
		| ((m_scale & 0x3) << 26)
		| ((n_scale & 0x3) << 24)
		| ((k_scale & 0x3) << 22)
		| ((a_field & 0x3FF) << 12)
		| ((b_field & 0x3FF) << 2)
	)


def build_matadd_inst(m_off: int, c_field: int = 0, reserved_hi: int = 0, reserved_lo: int = 0) -> int:
	return (
		((PT_OP_MATADD & 0xF) << 28)
		| ((reserved_hi & 0x3F) << 22)
		| ((m_off & 0x3FF) << 12)
		| ((c_field & 0x3FF) << 2)
		| (reserved_lo & 0x3)
	)


def build_load_inst(
	a_size: int,
	b_size: int,
	*,
	need_a: bool,
	need_b: bool,
	reserved_lo: int = 0,
) -> int:
	return (
		((PT_OP_LOAD & 0xF) << 28)
		| ((1 if need_a else 0) << 27)
		| ((1 if need_b else 0) << 26)
		| ((a_size & 0x3FF) << 16)
		| ((b_size & 0x3FF) << 6)
		| (reserved_lo & 0x3F)
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
		saturating_add_value(int(lhs_word), int(rhs_word), data_width)
		for lhs_word, rhs_word in zip(lhs_matrix, rhs_matrix)
	]


@dataclass
class QuantConfig:
	granularity: int
	inv_scales: List[int]


@dataclass
class ResidencyEntry:
	a_valid: bool = False
	a_base: int = 0
	a_len: int = 0
	a_matrix: Optional[List[int]] = None
	b_valid: bool = False
	b_is_c: bool = False
	b_base: int = 0
	b_len: int = 0
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


@dataclass
class ExecPlan:
	ctrl_id: int
	response_word: int
	err: bool
	success_buffer: Optional[int]
	result_matrix: Optional[List[int]]
	expected_dma_loads: List[DmaLoadExpectation]
	a_matrix: Optional[List[int]]
	b_matrix: Optional[List[int]]
	b_is_c: bool
	a_base: int
	b_base: int
	a_len: int
	b_len: int


@dataclass
class LoadPlan:
	ctrl_id: int
	response_word: int
	err: bool
	expected_dma_loads: List[DmaLoadExpectation]
	need_a: bool
	need_b: bool
	a_size: int
	b_size: int
	a_matrix: Optional[List[int]]
	b_matrix: Optional[List[int]]
	a_base: int
	b_base: int


class PTBlackBoxModel:
	def __init__(self, x_dim: int, y_dim: int, a_bank_depth: int = 8, b_bank_depth: int = 8, data_width: int = 32):
		self.x_dim = x_dim
		self.y_dim = y_dim
		self.a_bank_depth = a_bank_depth
		self.b_bank_depth = b_bank_depth
		self.data_width = data_width
		self.max_dim = max(x_dim, y_dim)
		self.a_capacity = a_bank_depth * x_dim
		self.b_capacity = b_bank_depth * y_dim
		self.a_tile_len = x_dim * x_dim
		self.b_tile_len = y_dim * y_dim
		self.a_base = 0
		self.b_base = 0
		self.quant_cfg = QuantConfig(PT_QGRAN_PER_TENSOR, [0x0001_0000] * self.max_dim)
		self.cache_by_id: Dict[int, ResidencyEntry] = {}
		self.m_buffers: Dict[int, Optional[List[int]]] = {0: None, 1: None}
		self.m_buffer_ctrl_id: Dict[int, Optional[int]] = {0: None, 1: None}
		self.m_buffer_state: Dict[int, str] = {0: "free", 1: "free"}
		self.next_write_buf = 0
		self.a_alloc_next = 0
		self.b_alloc_next = 0

	def reset_runtime_state(self) -> None:
		self.quant_cfg = QuantConfig(PT_QGRAN_PER_TENSOR, [0x0001_0000] * self.max_dim)
		self.cache_by_id.clear()
		self.m_buffers = {0: None, 1: None}
		self.m_buffer_ctrl_id = {0: None, 1: None}
		self.m_buffer_state = {0: "free", 1: "free"}
		self.next_write_buf = 0
		self.a_alloc_next = 0
		self.b_alloc_next = 0

	def set_base(self, kind: str, value: int) -> None:
		if kind == "A":
			self.a_base = value & 0xFFFF_FFFF
		elif kind == "B":
			self.b_base = value & 0xFFFF_FFFF
		else:
			raise ValueError(f"unknown base kind {kind!r}")

	def set_qcfg(self, granularity: int, inv_scales: Sequence[int]) -> None:
		payload_count = qcfg_payload_count(granularity, self.x_dim, self.y_dim)
		if payload_count is None or len(inv_scales) != payload_count:
			raise ValueError("invalid qcfg payload count")
		full_scale = [0x0001_0000] * self.max_dim
		for idx, word in enumerate(inv_scales):
			full_scale[idx] = to_unsigned(int(word), 32)
		self.quant_cfg = QuantConfig(granularity, full_scale)

	def _alloc_base(self, current: int, capacity: int, align: int, length: int) -> Tuple[Optional[int], int]:
		if length <= 0:
			return None, current
		base = ((current + align - 1) // align) * align
		buf_start = capacity if base >= capacity else 0
		if ((base - buf_start) + length) > capacity:
			base = (((buf_start + capacity) + align - 1) // align) * align
		if (base + length) > (2 * capacity):
			return None, current
		return ((base // capacity) << 8) | (base % capacity), base + length

	def _get_external(self, store: Dict[int, List[int]], ctrl_id: int, kind: str) -> List[int]:
		try:
			return list(store[ctrl_id])
		except KeyError as exc:
			raise KeyError(f"missing external {kind} matrix for ctrl_id=0x{ctrl_id:08x}") from exc

	def _quantize_matrix(self, acc_matrix: Sequence[int]) -> List[int]:
		quantized: List[int] = []
		for row in range(self.x_dim):
			for col in range(self.y_dim):
				scale_idx = select_scale_index(self.quant_cfg.granularity, row, col)
				scale_idx = max(0, min(scale_idx, self.max_dim - 1))
				quantized.append(quantize_value(int(acc_matrix[row * self.y_dim + col]), self.quant_cfg.inv_scales[scale_idx], self.data_width))
		return quantized

	def issue_matmul(
		self,
		ctrl_id: int,
		external_a_tiles: Dict[int, List[int]],
		external_b_tiles: Dict[int, List[int]],
		m_scale: int = PT_SCALE_FULL,
		n_scale: int = PT_SCALE_FULL,
		k_scale: int = PT_SCALE_FULL,
		a_field: int = 0,
		b_field: int = 0,
	) -> ExecPlan:
		if (m_scale, n_scale, k_scale) != (PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL) or a_field != 0 or b_field != 0:
			return ExecPlan(ctrl_id, pack_resp(True, 0, ctrl_id), True, None, None, [], None, None, False, 0, 0, 0, 0)

		entry = self.cache_by_id.get(ctrl_id, ResidencyEntry())
		expected_dma: List[DmaLoadExpectation] = []
		a_base = entry.a_base
		b_base = entry.b_base
		a_matrix = entry.a_matrix
		b_matrix = entry.b_matrix if (entry.b_valid and not entry.b_is_c) else None

		if not entry.a_valid:
			a_base, next_ptr = self._alloc_base(self.a_alloc_next, self.a_capacity, self.x_dim, self.a_tile_len)
			if a_base is None:
				return ExecPlan(ctrl_id, pack_resp(True, 0, ctrl_id), True, None, None, [], None, None, False, 0, 0, 0, 0)
			self.a_alloc_next = next_ptr
			a_matrix = self._get_external(external_a_tiles, ctrl_id, "A")
			expected_dma.append(DmaLoadExpectation(ctrl_id, "A"))
		elif entry.a_len != self.a_tile_len:
			return ExecPlan(ctrl_id, pack_resp(True, 0, ctrl_id), True, None, None, [], None, None, False, 0, 0, 0, 0)

		if not entry.b_valid:
			b_base, next_ptr = self._alloc_base(self.b_alloc_next, self.b_capacity, self.y_dim, self.b_tile_len)
			if b_base is None:
				return ExecPlan(ctrl_id, pack_resp(True, 0, ctrl_id), True, None, None, [], None, None, False, 0, 0, 0, 0)
			self.b_alloc_next = next_ptr
			b_matrix = self._get_external(external_b_tiles, ctrl_id, "B")
			expected_dma.append(DmaLoadExpectation(ctrl_id, "B"))
		elif entry.b_len != self.b_tile_len:
			return ExecPlan(ctrl_id, pack_resp(True, 0, ctrl_id), True, None, None, [], None, None, False, 0, 0, 0, 0)
		elif entry.b_is_c:
			b_matrix = self._get_external(external_b_tiles, ctrl_id, "B")
			expected_dma.append(DmaLoadExpectation(ctrl_id, "B"))

		assert a_matrix is not None
		assert b_matrix is not None
		result_matrix = self._quantize_matrix(matmul_row_major(a_matrix, b_matrix, self.x_dim, self.y_dim, self.x_dim))
		success_buffer = self.next_write_buf
		return ExecPlan(
			ctrl_id=ctrl_id,
			response_word=pack_resp(False, success_buffer, ctrl_id),
			err=False,
			success_buffer=success_buffer,
			result_matrix=result_matrix,
			expected_dma_loads=expected_dma,
			a_matrix=list(a_matrix),
			b_matrix=list(b_matrix),
			b_is_c=False,
			a_base=a_base,
			b_base=b_base,
			a_len=self.a_tile_len,
			b_len=self.b_tile_len,
		)

	def issue_matadd(
		self,
		ctrl_id: int,
		m_off: int,
		external_c_tiles: Dict[int, List[int]],
		*,
		c_field: int = 0,
		reserved_hi: int = 0,
		reserved_lo: int = 0,
	) -> ExecPlan:
		if ((reserved_hi & 0x3F) != 0) or ((reserved_lo & 0x3) != 0) or c_field != 0:
			return ExecPlan(ctrl_id, pack_resp(True, 0, ctrl_id), True, None, None, [], None, None, True, 0, 0, 0, 0)
		if not ((m_off >> 9) & 0x1) or (m_off & 0xFF) != 0:
			return ExecPlan(ctrl_id, pack_resp(True, 0, ctrl_id), True, None, None, [], None, None, True, 0, 0, 0, 0)

		m_buffer = (m_off >> 8) & 0x1
		m_matrix = self.m_buffers.get(m_buffer)
		if m_matrix is None:
			raise ValueError(f"M-window buffer {m_buffer} has no retained contents for MATADD")

		entry = self.cache_by_id.get(ctrl_id, ResidencyEntry())
		expected_dma: List[DmaLoadExpectation] = []
		c_matrix = entry.b_matrix if (entry.b_valid and entry.b_is_c) else None
		b_base = entry.b_base
		if not entry.b_valid:
			b_base, next_ptr = self._alloc_base(self.b_alloc_next, self.b_capacity, self.y_dim, self.b_tile_len)
			if b_base is None:
				return ExecPlan(ctrl_id, pack_resp(True, 0, ctrl_id), True, None, None, [], None, None, True, 0, 0, 0, 0)
			self.b_alloc_next = next_ptr
			c_matrix = self._get_external(external_c_tiles, ctrl_id, "C")
			expected_dma.append(DmaLoadExpectation(ctrl_id, "C"))
		elif entry.b_len != self.b_tile_len:
			return ExecPlan(ctrl_id, pack_resp(True, 0, ctrl_id), True, None, None, [], None, None, True, 0, 0, 0, 0)
		elif not entry.b_is_c:
			c_matrix = self._get_external(external_c_tiles, ctrl_id, "C")
			expected_dma.append(DmaLoadExpectation(ctrl_id, "C"))

		assert c_matrix is not None
		result_matrix = saturating_add_matrix(m_matrix, c_matrix, self.data_width)
		success_buffer = self.next_write_buf
		return ExecPlan(
			ctrl_id=ctrl_id,
			response_word=pack_resp(False, success_buffer, ctrl_id),
			err=False,
			success_buffer=success_buffer,
			result_matrix=result_matrix,
			expected_dma_loads=expected_dma,
			a_matrix=None,
			b_matrix=list(c_matrix),
			b_is_c=True,
			a_base=0,
			b_base=b_base,
			a_len=0,
			b_len=self.b_tile_len,
		)

	def issue_load(
		self,
		ctrl_id: int,
		a_size: int,
		b_size: int,
		*,
		need_a: bool,
		need_b: bool,
		external_a_tiles: Dict[int, List[int]],
		external_b_tiles: Dict[int, List[int]],
		reserved_lo: int = 0,
	) -> LoadPlan:
		if (not (need_a or need_b)) or ((reserved_lo & 0x3F) != 0) or (need_a and a_size == 0) or (need_b and b_size == 0):
			return LoadPlan(ctrl_id, pack_resp(True, 0, ctrl_id), True, [], need_a, need_b, a_size, b_size, None, None, 0, 0)

		entry = self.cache_by_id.get(ctrl_id, ResidencyEntry())
		expected_dma: List[DmaLoadExpectation] = []
		a_base = entry.a_base
		b_base = entry.b_base
		a_matrix = None
		b_matrix = None

		if need_a:
			a_matrix = self._get_external(external_a_tiles, ctrl_id, "A")
			if len(a_matrix) != a_size:
				return LoadPlan(ctrl_id, pack_resp(True, 0, ctrl_id), True, [], need_a, need_b, a_size, b_size, None, None, 0, 0)
			if entry.a_valid:
				if entry.a_len != a_size:
					return LoadPlan(ctrl_id, pack_resp(True, 0, ctrl_id), True, [], need_a, need_b, a_size, b_size, None, None, 0, 0)
				a_base = entry.a_base
			else:
				a_base, next_ptr = self._alloc_base(self.a_alloc_next, self.a_capacity, self.x_dim, a_size)
				if a_base is None:
					return LoadPlan(ctrl_id, pack_resp(True, 0, ctrl_id), True, [], need_a, need_b, a_size, b_size, None, None, 0, 0)
				self.a_alloc_next = next_ptr
				expected_dma.append(DmaLoadExpectation(ctrl_id, "A"))

		if need_b:
			b_matrix = self._get_external(external_b_tiles, ctrl_id, "B")
			if len(b_matrix) != b_size:
				return LoadPlan(ctrl_id, pack_resp(True, 0, ctrl_id), True, [], need_a, need_b, a_size, b_size, None, None, 0, 0)
			if entry.b_valid:
				if entry.b_len != b_size or entry.b_is_c:
					return LoadPlan(ctrl_id, pack_resp(True, 0, ctrl_id), True, [], need_a, need_b, a_size, b_size, None, None, 0, 0)
				b_base = entry.b_base
			else:
				b_base, next_ptr = self._alloc_base(self.b_alloc_next, self.b_capacity, self.y_dim, b_size)
				if b_base is None:
					return LoadPlan(ctrl_id, pack_resp(True, 0, ctrl_id), True, [], need_a, need_b, a_size, b_size, None, None, 0, 0)
				self.b_alloc_next = next_ptr
				expected_dma.append(DmaLoadExpectation(ctrl_id, "B"))

		return LoadPlan(
			ctrl_id=ctrl_id,
			response_word=pack_resp(False, 0, ctrl_id),
			err=False,
			expected_dma_loads=expected_dma,
			need_a=need_a,
			need_b=need_b,
			a_size=a_size,
			b_size=b_size,
			a_matrix=None if a_matrix is None else list(a_matrix),
			b_matrix=None if b_matrix is None else list(b_matrix),
			a_base=a_base,
			b_base=b_base,
		)

	def commit_success(self, plan: ExecPlan) -> None:
		if plan.err or plan.success_buffer is None or plan.result_matrix is None:
			raise ValueError("cannot commit an error execution plan")
		entry = self.cache_by_id.get(plan.ctrl_id, ResidencyEntry())
		if plan.a_matrix is not None:
			entry.a_valid = True
			entry.a_base = plan.a_base
			entry.a_len = plan.a_len
			entry.a_matrix = list(plan.a_matrix)
		if plan.b_matrix is not None:
			entry.b_valid = True
			entry.b_is_c = plan.b_is_c
			entry.b_base = plan.b_base
			entry.b_len = plan.b_len
			entry.b_matrix = list(plan.b_matrix)
		self.cache_by_id[plan.ctrl_id] = entry

		buffer = plan.success_buffer
		self.m_buffers[buffer] = list(plan.result_matrix)
		self.m_buffer_ctrl_id[buffer] = plan.ctrl_id
		self.m_buffer_state[buffer] = "ready"
		self.next_write_buf = 1 - buffer

	def commit_load_success(self, plan: LoadPlan) -> None:
		if plan.err:
			raise ValueError("cannot commit an error load plan")
		entry = self.cache_by_id.get(plan.ctrl_id, ResidencyEntry())
		if plan.need_a and plan.a_matrix is not None:
			entry.a_valid = True
			entry.a_base = plan.a_base
			entry.a_len = plan.a_size
			entry.a_matrix = list(plan.a_matrix)
		if plan.need_b and plan.b_matrix is not None:
			entry.b_valid = True
			entry.b_is_c = False
			entry.b_base = plan.b_base
			entry.b_len = plan.b_size
			entry.b_matrix = list(plan.b_matrix)
		self.cache_by_id[plan.ctrl_id] = entry

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
