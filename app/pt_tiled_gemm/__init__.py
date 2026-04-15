from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


APP_ROOT = Path(__file__).resolve().parent
REPO_ROOT = APP_ROOT.parents[1]
RTL_DIR = REPO_ROOT / "rtl"
COCOTB_ROOT = REPO_ROOT / "sim" / "cocotb"

DEFAULT_OUT_DIR = APP_ROOT / "out"

TILE_DIM = 16
DATA_WIDTH = 32
INV_SCALE_WORD = 0x0001_0000

PT_PARAMS = {
	"DATA_WIDTH": DATA_WIDTH,
	"GEMM_X_DIM": TILE_DIM,
	"GEMM_Y_DIM": TILE_DIM,
	"EXT_ADDR_W": 32,
	"DMA_BEATS_W": 16,
	"LUT_DEPTH": 8,
	"A_BANK_DEPTH": 8,
	"B_BANK_DEPTH": 16,
	"M_BANK_DEPTH": 16,
	"A_LOAD_LANES": TILE_DIM,
	"B_LOAD_LANES": TILE_DIM,
	"M_WRITE_LANES": TILE_DIM,
	"M_EXPORT_LANES": TILE_DIM,
	"M_PHYSICAL_COPIES": 2,
}


@dataclass(frozen=True)
class ProblemSpec:
	m_dim: int
	k_dim: int
	n_dim: int

	def validate(self) -> None:
		for name, value in (("M", self.m_dim), ("K", self.k_dim), ("N", self.n_dim)):
			if value <= 0:
				raise ValueError(f"{name} must be > 0, got {value}")
			if value % TILE_DIM != 0:
				raise ValueError(f"{name} must be a multiple of {TILE_DIM}, got {value}")

	@property
	def tag(self) -> str:
		return f"m{self.m_dim}_k{self.k_dim}_n{self.n_dim}"

	@property
	def notation(self) -> str:
		return f"M={self.m_dim}, K={self.k_dim}, N={self.n_dim}"

	@property
	def shape(self) -> dict[str, list[int]]:
		return {
			"A": [self.m_dim, self.k_dim],
			"B": [self.k_dim, self.n_dim],
			"C": [self.m_dim, self.n_dim],
		}

	@property
	def m_tiles(self) -> int:
		return self.m_dim // TILE_DIM

	@property
	def k_tiles(self) -> int:
		return self.k_dim // TILE_DIM

	@property
	def n_tiles(self) -> int:
		return self.n_dim // TILE_DIM

	@property
	def output_tiles(self) -> int:
		return self.m_tiles * self.n_tiles

	@property
	def partial_matmuls(self) -> int:
		return self.m_tiles * self.k_tiles * self.n_tiles

	@property
	def host_add_ops(self) -> int:
		return max(self.k_tiles - 1, 0) * self.m_dim * self.n_dim

	@property
	def supports_same_id_swap(self) -> bool:
		return self.k_tiles >= 2


DEFAULT_PROBLEM = ProblemSpec(m_dim=16, k_dim=64, n_dim=16)


def default_metrics_path(problem: ProblemSpec) -> Path:
	return DEFAULT_OUT_DIR / f"verify_metrics_{problem.tag}.json"


def default_report_path(problem: ProblemSpec) -> Path:
	return DEFAULT_OUT_DIR / f"report_{problem.tag}.md"


def cocotb_output_root(problem: ProblemSpec) -> Path:
	return DEFAULT_OUT_DIR / "cocotb" / problem.tag

