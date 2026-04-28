from __future__ import annotations

import re
from dataclasses import dataclass
from functools import lru_cache

from . import RTL_DIR


_DEFINE_RE = re.compile(r"^\s*`define\s+([A-Za-z0-9_]+)\s+(.+?)\s*$")
_VERILOG_INT_RE = re.compile(r"^(?:(\d+))?'([bBdDhHoO])([0-9a-fA-F_xXzZ]+)$")


def _parse_verilog_int(token: str) -> int:
	value = token.strip()
	match = _VERILOG_INT_RE.fullmatch(value)
	if match is not None:
		_width_text, base_ch, digits = match.groups()
		if any(ch in "xXzZ" for ch in digits):
			raise ValueError(f"unsupported unknown digits in verilog integer {token!r}")
		base = {
			"b": 2,
			"d": 10,
			"h": 16,
			"o": 8,
		}[base_ch.lower()]
		return int(digits.replace("_", ""), base)
	return int(value, 0)


@dataclass(frozen=True)
class PtParamSnapshot:
	pt_size_w: int
	pt_tiles_1: int
	pt_tiles_2: int
	pt_tiles_4: int

	@property
	def valid_tile_counts(self) -> tuple[int, int, int]:
		return (self.pt_tiles_1, self.pt_tiles_2, self.pt_tiles_4)

	@property
	def max_encoded_elems(self) -> int:
		return (1 << self.pt_size_w) - 1


@lru_cache(maxsize=1)
def load_pt_param_snapshot() -> PtParamSnapshot:
	required = {
		"PT_SIZE_W": None,
		"PT_TILES_1": None,
		"PT_TILES_2": None,
		"PT_TILES_4": None,
	}
	for line in (RTL_DIR / "param.vh").read_text(encoding="utf-8").splitlines():
		match = _DEFINE_RE.match(line)
		if match is None:
			continue
		name, value = match.groups()
		if name in required:
			required[name] = _parse_verilog_int(value)
	missing = [name for name, value in required.items() if value is None]
	if missing:
		raise ValueError(f"missing required param.vh defines: {', '.join(missing)}")
	return PtParamSnapshot(
		pt_size_w=int(required["PT_SIZE_W"]),
		pt_tiles_1=int(required["PT_TILES_1"]),
		pt_tiles_2=int(required["PT_TILES_2"]),
		pt_tiles_4=int(required["PT_TILES_4"]),
	)
