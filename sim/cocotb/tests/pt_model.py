from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Tuple


PT_OP_MATMUL = 0x1
PT_OP_QCFG = 0x2
PT_OP_MATADD = 0x3
PT_OP_LOAD = 0x4
PT_OP_CFG = 0xF

PT_TILES_1 = 0x1
PT_TILES_2 = 0x2
PT_TILES_4 = 0x4
VALID_TILE_COUNTS = (PT_TILES_1, PT_TILES_2, PT_TILES_4)

# Legacy aliases kept for older tests that have not been renamed yet.
PT_SCALE_SCALAR = 0x0
PT_SCALE_FULL_DIV4 = PT_TILES_4
PT_SCALE_FULL_DIV2 = PT_TILES_2
PT_SCALE_FULL = PT_TILES_1

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


def build_matmul_inst(m_tiles: int, n_tiles: int, k_tiles: int, reserved_a: int = 0, reserved_b: int = 0) -> int:
	return (
		((PT_OP_MATMUL & 0xF) << 28)
		| ((m_tiles & 0xF) << 24)
		| ((n_tiles & 0xF) << 20)
		| ((k_tiles & 0xF) << 16)
		| ((reserved_a & 0xFF) << 8)
		| (reserved_b & 0xFF)
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
	m_tiles: int = PT_TILES_1,
	n_tiles: int = PT_TILES_1,
	k_tiles: int = PT_TILES_1,
	reserved_lo: Optional[int] = None,
) -> int:
	if reserved_lo is None:
		reserved_lo = encode_load_shape(m_tiles, n_tiles, k_tiles)
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


def encode_tile_code(tile_count: int) -> int:
	if tile_count == PT_TILES_1:
		return 0b00
	if tile_count == PT_TILES_2:
		return 0b01
	if tile_count == PT_TILES_4:
		return 0b10
	raise ValueError(f"unsupported tile count {tile_count}")


def decode_tile_code(encoded: int) -> Optional[int]:
	if encoded == 0b00:
		return PT_TILES_1
	if encoded == 0b01:
		return PT_TILES_2
	if encoded == 0b10:
		return PT_TILES_4
	return None


def encode_load_shape(m_tiles: int, n_tiles: int, k_tiles: int) -> int:
	return (encode_tile_code(m_tiles) << 4) | (encode_tile_code(n_tiles) << 2) | encode_tile_code(k_tiles)


def decode_load_shape(reserved_lo: int) -> Optional[Tuple[int, int, int]]:
	m_tiles = decode_tile_code((reserved_lo >> 4) & 0x3)
	n_tiles = decode_tile_code((reserved_lo >> 2) & 0x3)
	k_tiles = decode_tile_code(reserved_lo & 0x3)
	if m_tiles is None or n_tiles is None or k_tiles is None:
		return None
	return m_tiles, n_tiles, k_tiles


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


def matmul_row_major(
	a_matrix: Sequence[int],
	b_matrix: Sequence[int],
	x_dim: int,
	y_dim: int,
	k_dim: Optional[int] = None,
	bits: int = 32,
) -> List[int]:
	if k_dim is None:
		k_dim = x_dim
	result: List[int] = []
	for row in range(x_dim):
		for col in range(y_dim):
			acc = 0
			for acc_idx in range(k_dim):
				a_word = to_signed(int(a_matrix[row * k_dim + acc_idx]), bits)
				b_word = to_signed(int(b_matrix[acc_idx * y_dim + col]), bits)
				acc += a_word * b_word
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
	a_m_tiles: int = PT_TILES_1
	a_k_tiles: int = PT_TILES_1
	b_valid: bool = False
	b_is_c: bool = False
	b_base: int = 0
	b_len: int = 0
	b_matrix: Optional[List[int]] = None
	b_k_tiles: int = PT_TILES_1
	b_n_tiles: int = PT_TILES_1


@dataclass
class ExportExpectation:
	ctrl_id: int
	buffer: int
	matrix: List[int]


@dataclass
class DmaLoadExpectation:
	ctrl_id: int
	kind: str
	m_tiles: int = PT_TILES_1
	n_tiles: int = PT_TILES_1
	k_tiles: int = PT_TILES_1


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
	a_m_tiles: int
	a_k_tiles: int
	b_k_tiles: int
	b_n_tiles: int
	row_chunk_count: int
	single_output_tile: bool
	a_alloc_next: int
	b_alloc_next: int
	coverage_tags: List[str]
	reject_reason: Optional[str]
	committed: bool = False


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
	a_m_tiles: int
	a_k_tiles: int
	b_k_tiles: int
	b_n_tiles: int
	a_alloc_next: int
	b_alloc_next: int
	coverage_tags: List[str]
	reject_reason: Optional[str]
	committed: bool = False


class PTBlackBoxModel:
	def __init__(self, x_dim: int, y_dim: int, a_bank_depth: int = 8, b_bank_depth: int = 16, data_width: int = 32, lut_depth: int = 8):
		self.x_dim = x_dim
		self.y_dim = y_dim
		self.a_bank_depth = a_bank_depth
		self.b_bank_depth = b_bank_depth
		self.data_width = data_width
		self.lut_depth = lut_depth
		self.max_dim = max(x_dim, y_dim)
		self.a_tile_len = x_dim * x_dim
		self.b_tile_len = y_dim * y_dim
		self.a_capacity = a_bank_depth * self.a_tile_len
		self.b_capacity = b_bank_depth * self.b_tile_len
		self.a_base = 0
		self.b_base = 0
		self.quant_cfg = QuantConfig(PT_QGRAN_PER_TENSOR, [0x0001_0000] * self.max_dim)
		self.cache_by_id: Dict[int, ResidencyEntry] = {}
		self.m_buffers: Dict[int, Optional[List[int]]] = {0: None, 1: None}
		self.m_buffer_ctrl_id: Dict[int, Optional[int]] = {0: None, 1: None}
		self.m_buffer_state: Dict[int, str] = {0: "free", 1: "free"}
		self.m_buffer_single_output: Dict[int, bool] = {0: True, 1: True}
		self.m_buffer_row_chunk_count: Dict[int, int] = {0: self.x_dim, 1: self.x_dim}
		self.next_write_buf = 0
		self.a_alloc_next = 0
		self.b_alloc_next = 0

	def reset_runtime_state(self, preserve_cfg: bool = False) -> None:
		if not preserve_cfg:
			self.quant_cfg = QuantConfig(PT_QGRAN_PER_TENSOR, [0x0001_0000] * self.max_dim)
		self.cache_by_id.clear()
		self.m_buffers = {0: None, 1: None}
		self.m_buffer_ctrl_id = {0: None, 1: None}
		self.m_buffer_state = {0: "free", 1: "free"}
		self.m_buffer_single_output = {0: True, 1: True}
		self.m_buffer_row_chunk_count = {0: self.x_dim, 1: self.x_dim}
		self.next_write_buf = 0
		self.a_alloc_next = 0
		self.b_alloc_next = 0

	def _evict_oldest_if_needed(self, incoming_ctrl_id: int) -> None:
		if incoming_ctrl_id in self.cache_by_id:
			return
		if len(self.cache_by_id) < self.lut_depth:
			return
		oldest_ctrl_id = next(iter(self.cache_by_id))
		del self.cache_by_id[oldest_ctrl_id]

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

	def _reserve_m_buffer(self) -> Optional[int]:
		if self.m_buffer_state[0] == "free":
			self.m_buffer_state[0] = "reserved"
			return 0
		if self.m_buffer_state[1] == "free":
			self.m_buffer_state[1] = "reserved"
			return 1
		return None

	def _alloc_base(self, current: int, capacity: int, align: int, length: int) -> Tuple[Optional[int], int]:
		if length <= 0:
			return None, current
		base = ((current + align - 1) // align) * align
		buf_start = capacity if base >= capacity else 0
		if ((base - buf_start) + length) > capacity:
			base = (((buf_start + capacity) + align - 1) // align) * align
		if (base + length) > (2 * capacity):
			return None, current
		return ((base // capacity) << 11) | (base % capacity), base + length

	def _get_external(self, store: Dict[int, List[int]], ctrl_id: int, kind: str) -> List[int]:
		try:
			return list(store[ctrl_id])
		except KeyError as exc:
			raise KeyError(f"missing external {kind} matrix for ctrl_id=0x{ctrl_id:08x}") from exc

	def _quantize_matrix(self, acc_matrix: Sequence[int], rows: int, cols: int) -> List[int]:
		quantized: List[int] = []
		for row in range(rows):
			for col in range(cols):
				scale_idx = select_scale_index(self.quant_cfg.granularity, row % self.x_dim, col % self.y_dim)
				scale_idx = max(0, min(scale_idx, self.max_dim - 1))
				quantized.append(quantize_value(int(acc_matrix[row * cols + col]), self.quant_cfg.inv_scales[scale_idx], self.data_width))
		return quantized

	def _make_exec_error(self, ctrl_id: int, coverage_tags: List[str], reject_reason: str, *, b_is_c: bool = False) -> ExecPlan:
		return ExecPlan(
			ctrl_id=ctrl_id,
			response_word=pack_resp(True, 0, ctrl_id),
			err=True,
			success_buffer=None,
			result_matrix=None,
			expected_dma_loads=[],
			a_matrix=None,
			b_matrix=None,
			b_is_c=b_is_c,
			a_base=0,
			b_base=0,
			a_len=0,
			b_len=0,
			a_m_tiles=PT_TILES_1,
			a_k_tiles=PT_TILES_1,
			b_k_tiles=PT_TILES_1,
			b_n_tiles=PT_TILES_1,
			row_chunk_count=self.x_dim,
			single_output_tile=True,
			a_alloc_next=self.a_alloc_next,
			b_alloc_next=self.b_alloc_next,
			coverage_tags=list(coverage_tags),
			reject_reason=reject_reason,
		)

	def _make_load_error(
		self,
		ctrl_id: int,
		a_size: int,
		b_size: int,
		need_a: bool,
		need_b: bool,
		coverage_tags: List[str],
		reject_reason: str,
	) -> LoadPlan:
		return LoadPlan(
			ctrl_id=ctrl_id,
			response_word=pack_resp(True, 0, ctrl_id),
			err=True,
			expected_dma_loads=[],
			need_a=need_a,
			need_b=need_b,
			a_size=a_size,
			b_size=b_size,
			a_matrix=None,
			b_matrix=None,
			a_base=0,
			b_base=0,
			a_m_tiles=PT_TILES_1,
			a_k_tiles=PT_TILES_1,
			b_k_tiles=PT_TILES_1,
			b_n_tiles=PT_TILES_1,
			a_alloc_next=self.a_alloc_next,
			b_alloc_next=self.b_alloc_next,
			coverage_tags=list(coverage_tags),
			reject_reason=reject_reason,
		)

	def issue_matmul(
		self,
		ctrl_id: int,
		external_a_tiles: Dict[int, List[int]],
		external_b_tiles: Dict[int, List[int]],
		m_tiles: int = PT_TILES_1,
		n_tiles: int = PT_TILES_1,
		k_tiles: int = PT_TILES_1,
		reserved_a: int = 0,
		reserved_b: int = 0,
	) -> ExecPlan:
		coverage_tags = ["cmd:matmul", "operand:matmul_ab"]
		if (
			m_tiles not in VALID_TILE_COUNTS
			or n_tiles not in VALID_TILE_COUNTS
			or k_tiles not in VALID_TILE_COUNTS
			or reserved_a != 0
			or reserved_b != 0
		):
			return self._make_exec_error(ctrl_id, coverage_tags, "reject:illegal_matmul")

		expected_a_len = self.a_tile_len * m_tiles * k_tiles
		expected_b_len = self.b_tile_len * k_tiles * n_tiles
		if self.x_dim != self.y_dim and ((m_tiles != PT_TILES_1) or (n_tiles != PT_TILES_1)):
			return self._make_exec_error(ctrl_id, coverage_tags, "reject:multitile_requires_square")
		k_dim = self.x_dim * k_tiles
		m_dim = self.x_dim * m_tiles
		n_dim = self.y_dim * n_tiles
		entry = self.cache_by_id.get(ctrl_id, ResidencyEntry())
		expected_dma: List[DmaLoadExpectation] = []
		a_base = entry.a_base
		b_base = entry.b_base
		a_alloc_next = self.a_alloc_next
		b_alloc_next = self.b_alloc_next
		a_matrix = entry.a_matrix
		b_matrix = entry.b_matrix if (entry.b_valid and not entry.b_is_c) else None

		if not entry.a_valid:
			coverage_tags.append("cache:a_miss")
			a_base, next_ptr = self._alloc_base(self.a_alloc_next, self.a_capacity, self.x_dim, expected_a_len)
			if a_base is None:
				return self._make_exec_error(ctrl_id, coverage_tags, "reject:a_capacity")
			a_alloc_next = next_ptr
			a_matrix = self._get_external(external_a_tiles, ctrl_id, "A")
			if len(a_matrix) != expected_a_len:
				return self._make_exec_error(ctrl_id, coverage_tags, "reject:a_size_mismatch")
			expected_dma.append(DmaLoadExpectation(ctrl_id, "A", m_tiles=m_tiles, n_tiles=n_tiles, k_tiles=k_tiles))
		else:
			coverage_tags.append("cache:a_hit")
			if (entry.a_len != expected_a_len) or (entry.a_m_tiles != m_tiles) or (entry.a_k_tiles != k_tiles):
				return self._make_exec_error(ctrl_id, coverage_tags, "reject:a_size_mismatch")

		if not entry.b_valid:
			coverage_tags.append("cache:b_miss")
			b_base, next_ptr = self._alloc_base(self.b_alloc_next, self.b_capacity, self.y_dim, expected_b_len)
			if b_base is None:
				return self._make_exec_error(ctrl_id, coverage_tags, "reject:b_capacity")
			b_alloc_next = next_ptr
			b_matrix = self._get_external(external_b_tiles, ctrl_id, "B")
			if len(b_matrix) != expected_b_len:
				return self._make_exec_error(ctrl_id, coverage_tags, "reject:b_size_mismatch")
			expected_dma.append(DmaLoadExpectation(ctrl_id, "B", m_tiles=m_tiles, n_tiles=n_tiles, k_tiles=k_tiles))
		elif entry.b_is_c:
			coverage_tags.extend(["cache:b_miss", "reuse:b_reload_after_c"])
			b_matrix = self._get_external(external_b_tiles, ctrl_id, "B")
			if len(b_matrix) != expected_b_len:
				return self._make_exec_error(ctrl_id, coverage_tags, "reject:b_size_mismatch")
			expected_dma.append(DmaLoadExpectation(ctrl_id, "B", m_tiles=m_tiles, n_tiles=n_tiles, k_tiles=k_tiles))
		else:
			coverage_tags.append("cache:b_hit")
			if (entry.b_len != expected_b_len) or (entry.b_k_tiles != k_tiles) or (entry.b_n_tiles != n_tiles):
				return self._make_exec_error(ctrl_id, coverage_tags, "reject:b_size_mismatch")

		assert a_matrix is not None
		assert b_matrix is not None
		result_matrix = self._quantize_matrix(
			matmul_row_major(a_matrix, b_matrix, m_dim, n_dim, k_dim, bits=self.data_width),
			m_dim,
			n_dim,
		)
		success_buffer = self._reserve_m_buffer()
		if success_buffer is None:
			return self._make_exec_error(ctrl_id, coverage_tags, "reject:m_buffer_busy")
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
			a_len=expected_a_len,
			b_len=expected_b_len,
			a_m_tiles=m_tiles,
			a_k_tiles=k_tiles,
			b_k_tiles=k_tiles,
			b_n_tiles=n_tiles,
			row_chunk_count=m_dim * n_tiles,
			single_output_tile=(m_tiles == PT_TILES_1) and (n_tiles == PT_TILES_1),
			a_alloc_next=a_alloc_next,
			b_alloc_next=b_alloc_next,
			coverage_tags=coverage_tags,
			reject_reason=None,
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
		m_buffer = (m_off >> 8) & 0x1
		coverage_tags = ["cmd:matadd", "operand:matadd_m_c", f"mwindow:buf{m_buffer}"]
		if ((reserved_hi & 0x3F) != 0) or ((reserved_lo & 0x3) != 0) or c_field != 0:
			return self._make_exec_error(ctrl_id, coverage_tags, "reject:illegal_matadd", b_is_c=True)
		if not ((m_off >> 9) & 0x1) or (m_off & 0xFF) != 0:
			return self._make_exec_error(ctrl_id, coverage_tags, "reject:illegal_matadd", b_is_c=True)
		m_matrix = self.m_buffers.get(m_buffer)
		if m_matrix is None:
			return self._make_exec_error(ctrl_id, coverage_tags, "reject:mwindow_empty", b_is_c=True)
		if not self.m_buffer_single_output.get(m_buffer, True):
			return self._make_exec_error(ctrl_id, coverage_tags, "reject:mwindow_multitile", b_is_c=True)

		entry = self.cache_by_id.get(ctrl_id, ResidencyEntry())
		expected_dma: List[DmaLoadExpectation] = []
		c_matrix = entry.b_matrix if (entry.b_valid and entry.b_is_c) else None
		b_base = entry.b_base
		b_alloc_next = self.b_alloc_next
		if entry.b_valid and entry.b_is_c:
			coverage_tags.append("cache:c_hit")
			if entry.b_len != self.b_tile_len:
				return self._make_exec_error(ctrl_id, coverage_tags, "reject:b_size_mismatch", b_is_c=True)
		else:
			coverage_tags.append("cache:c_miss")
			b_base, next_ptr = self._alloc_base(self.b_alloc_next, self.b_capacity, self.y_dim, self.b_tile_len)
			if b_base is None:
				return self._make_exec_error(ctrl_id, coverage_tags, "reject:b_capacity", b_is_c=True)
			b_alloc_next = next_ptr
			c_matrix = self._get_external(external_c_tiles, ctrl_id, "C")
			expected_dma.append(DmaLoadExpectation(ctrl_id, "C"))

		assert c_matrix is not None
		result_matrix = saturating_add_matrix(m_matrix, c_matrix, self.data_width)
		success_buffer = self._reserve_m_buffer()
		if success_buffer is None:
			return self._make_exec_error(ctrl_id, coverage_tags, "reject:m_buffer_busy", b_is_c=True)
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
			a_m_tiles=PT_TILES_1,
			a_k_tiles=PT_TILES_1,
			b_k_tiles=PT_TILES_1,
			b_n_tiles=PT_TILES_1,
			row_chunk_count=self.x_dim,
			single_output_tile=True,
			a_alloc_next=self.a_alloc_next,
			b_alloc_next=b_alloc_next,
			coverage_tags=coverage_tags,
			reject_reason=None,
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
		coverage_tags = ["cmd:load"]
		if need_a and need_b:
			coverage_tags.append("load:need_a_and_b")
		elif need_a:
			coverage_tags.append("load:need_a_only")
		elif need_b:
			coverage_tags.append("load:need_b_only")
		load_shape = decode_load_shape(reserved_lo & 0x3F)
		if load_shape is None:
			return self._make_load_error(ctrl_id, a_size, b_size, need_a, need_b, coverage_tags, "reject:illegal_load")
		load_m_tiles, load_n_tiles, load_k_tiles = load_shape
		expected_a_size = self.a_tile_len * load_m_tiles * load_k_tiles
		expected_b_size = self.b_tile_len * load_k_tiles * load_n_tiles
		if (not (need_a or need_b)) or (need_a and a_size == 0) or (need_b and b_size == 0):
			return self._make_load_error(ctrl_id, a_size, b_size, need_a, need_b, coverage_tags, "reject:illegal_load")
		if need_a and a_size != expected_a_size:
			return self._make_load_error(ctrl_id, a_size, b_size, need_a, need_b, coverage_tags, "reject:a_size_mismatch")
		if need_b and b_size != expected_b_size:
			return self._make_load_error(ctrl_id, a_size, b_size, need_a, need_b, coverage_tags, "reject:b_size_mismatch")
		entry = self.cache_by_id.get(ctrl_id, ResidencyEntry())
		expected_dma: List[DmaLoadExpectation] = []
		a_base = entry.a_base
		b_base = entry.b_base
		a_alloc_next = self.a_alloc_next
		b_alloc_next = self.b_alloc_next
		a_matrix = None
		b_matrix = None

		if need_a:
			a_matrix = self._get_external(external_a_tiles, ctrl_id, "A")
			if len(a_matrix) != a_size:
				return self._make_load_error(ctrl_id, a_size, b_size, need_a, need_b, coverage_tags, "reject:a_size_mismatch")
			if entry.a_valid:
				coverage_tags.append("cache:a_hit")
				if (entry.a_len != a_size) or (entry.a_m_tiles != load_m_tiles) or (entry.a_k_tiles != load_k_tiles):
					return self._make_load_error(ctrl_id, a_size, b_size, need_a, need_b, coverage_tags, "reject:a_size_mismatch")
				a_base = entry.a_base
			else:
				coverage_tags.append("cache:a_miss")
				a_base, next_ptr = self._alloc_base(self.a_alloc_next, self.a_capacity, self.x_dim, a_size)
				if a_base is None:
					return self._make_load_error(ctrl_id, a_size, b_size, need_a, need_b, coverage_tags, "reject:a_capacity")
				a_alloc_next = next_ptr
				expected_dma.append(DmaLoadExpectation(ctrl_id, "A", m_tiles=load_m_tiles, n_tiles=load_n_tiles, k_tiles=load_k_tiles))

		if need_b:
			b_matrix = self._get_external(external_b_tiles, ctrl_id, "B")
			if len(b_matrix) != b_size:
				return self._make_load_error(ctrl_id, a_size, b_size, need_a, need_b, coverage_tags, "reject:b_size_mismatch")
			if entry.b_valid:
				if entry.b_is_c:
					return self._make_load_error(ctrl_id, a_size, b_size, need_a, need_b, coverage_tags, "reject:b_conflicts_with_c")
				coverage_tags.append("cache:b_hit")
				if (entry.b_len != b_size) or (entry.b_k_tiles != load_k_tiles) or (entry.b_n_tiles != load_n_tiles):
					return self._make_load_error(ctrl_id, a_size, b_size, need_a, need_b, coverage_tags, "reject:b_size_mismatch")
				b_base = entry.b_base
			else:
				coverage_tags.append("cache:b_miss")
				b_base, next_ptr = self._alloc_base(self.b_alloc_next, self.b_capacity, self.y_dim, b_size)
				if b_base is None:
					return self._make_load_error(ctrl_id, a_size, b_size, need_a, need_b, coverage_tags, "reject:b_capacity")
				b_alloc_next = next_ptr
				expected_dma.append(DmaLoadExpectation(ctrl_id, "B", m_tiles=load_m_tiles, n_tiles=load_n_tiles, k_tiles=load_k_tiles))

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
			a_m_tiles=load_m_tiles,
			a_k_tiles=load_k_tiles,
			b_k_tiles=load_k_tiles,
			b_n_tiles=load_n_tiles,
			a_alloc_next=a_alloc_next,
			b_alloc_next=b_alloc_next,
			coverage_tags=coverage_tags,
			reject_reason=None,
		)

	def commit_success(self, plan: ExecPlan) -> None:
		if plan.err or plan.success_buffer is None or plan.result_matrix is None:
			raise ValueError("cannot commit an error execution plan")
		if plan.committed:
			return
		entry = self.cache_by_id.get(plan.ctrl_id, ResidencyEntry())
		if plan.a_matrix is not None:
			entry.a_valid = True
			entry.a_base = plan.a_base
			entry.a_len = plan.a_len
			entry.a_matrix = list(plan.a_matrix)
			entry.a_m_tiles = plan.a_m_tiles
			entry.a_k_tiles = plan.a_k_tiles
		if plan.b_matrix is not None:
			entry.b_valid = True
			entry.b_is_c = plan.b_is_c
			entry.b_base = plan.b_base
			entry.b_len = plan.b_len
			entry.b_matrix = list(plan.b_matrix)
			entry.b_k_tiles = plan.b_k_tiles
			entry.b_n_tiles = plan.b_n_tiles
		self.cache_by_id[plan.ctrl_id] = entry
		self.a_alloc_next = plan.a_alloc_next
		self.b_alloc_next = plan.b_alloc_next

		buffer = plan.success_buffer
		self.m_buffers[buffer] = list(plan.result_matrix)
		self.m_buffer_ctrl_id[buffer] = plan.ctrl_id
		self.m_buffer_state[buffer] = "ready"
		self.m_buffer_single_output[buffer] = plan.single_output_tile
		self.m_buffer_row_chunk_count[buffer] = plan.row_chunk_count
		self.next_write_buf = 1 - buffer
		plan.committed = True

	def commit_load_success(self, plan: LoadPlan) -> None:
		if plan.err:
			raise ValueError("cannot commit an error load plan")
		if plan.committed:
			return
		entry = self.cache_by_id.get(plan.ctrl_id, ResidencyEntry())
		if plan.need_a and plan.a_matrix is not None:
			entry.a_valid = True
			entry.a_base = plan.a_base
			entry.a_len = plan.a_size
			entry.a_matrix = list(plan.a_matrix)
			entry.a_m_tiles = plan.a_m_tiles
			entry.a_k_tiles = plan.a_k_tiles
		if plan.need_b and plan.b_matrix is not None:
			entry.b_valid = True
			entry.b_is_c = False
			entry.b_base = plan.b_base
			entry.b_len = plan.b_size
			entry.b_matrix = list(plan.b_matrix)
			entry.b_k_tiles = plan.b_k_tiles
			entry.b_n_tiles = plan.b_n_tiles
		self.cache_by_id[plan.ctrl_id] = entry
		self.a_alloc_next = plan.a_alloc_next
		self.b_alloc_next = plan.b_alloc_next
		plan.committed = True

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
