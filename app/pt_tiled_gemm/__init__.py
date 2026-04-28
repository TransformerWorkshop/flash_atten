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
WORD_WIDTH = 32
ELEM_WIDTH_V3 = 8
PACK_LANES_V3 = 4
ACC_WIDTH_V3 = 32
INV_SCALE_WORD = 0x0001_0000
APP_TARGET_PT = "pt"
APP_TARGET_PT_DMA_TOP = "pt_dma_top"
APP_TARGET_PT_V3 = "pt_v3"
APP_TARGET_PT_DMA_TOP_V3 = "pt_dma_top_v3"
APP_TARGET_PT_DMA_TOP_V3_CH1 = "pt_dma_top_v3_ch1"
APP_TARGET_PT_DMA_TOP_V3_CH2 = "pt_dma_top_v3_ch2"
APP_TARGET_PT_DMA_TOP_V3_CH4 = "pt_dma_top_v3_ch4"
APP_TARGET_PT_DMA_TOP_V3_128B = "pt_dma_top_v3_128b"
APP_TARGET_PT_DMA_TOP_V3_128B_STRICT = "pt_dma_top_v3_128b_strict"
DEFAULT_APP_TARGET = APP_TARGET_PT_DMA_TOP
SUPPORTED_APP_TARGETS = (
	APP_TARGET_PT,
	APP_TARGET_PT_DMA_TOP,
	APP_TARGET_PT_V3,
	APP_TARGET_PT_DMA_TOP_V3,
	APP_TARGET_PT_DMA_TOP_V3_CH1,
	APP_TARGET_PT_DMA_TOP_V3_CH2,
	APP_TARGET_PT_DMA_TOP_V3_CH4,
	APP_TARGET_PT_DMA_TOP_V3_128B,
	APP_TARGET_PT_DMA_TOP_V3_128B_STRICT,
)

PT_PARAMS = {
	"DATA_WIDTH": DATA_WIDTH,
	"GEMM_X_DIM": TILE_DIM,
	"GEMM_Y_DIM": TILE_DIM,
	"EXT_ADDR_W": 32,
	"DMA_BEATS_W": 16,
	"LUT_DEPTH": 8,
	"A_BANK_DEPTH": 16,
	"B_BANK_DEPTH": 16,
	"M_BANK_DEPTH": 16,
	"A_LOAD_LANES": TILE_DIM,
	"B_LOAD_LANES": TILE_DIM,
	"M_WRITE_LANES": TILE_DIM,
	"M_EXPORT_LANES": TILE_DIM,
	"M_PHYSICAL_COPIES": 2,
}

PT_V3_PARAMS = {
	"DATA_WIDTH": WORD_WIDTH,
	"WORD_WIDTH": WORD_WIDTH,
	"ELEM_WIDTH": ELEM_WIDTH_V3,
	"PACK_LANES": PACK_LANES_V3,
	"ACC_WIDTH": ACC_WIDTH_V3,
	"GEMM_X_DIM": TILE_DIM,
	"GEMM_Y_DIM": TILE_DIM,
	"EXT_ADDR_W": 32,
	"DMA_BEATS_W": 16,
	"LUT_DEPTH": 8,
	"A_BANK_DEPTH": 16,
	"B_BANK_DEPTH": 16,
	"M_BANK_DEPTH": 16,
	"A_LOAD_LANES": TILE_DIM,
	"B_LOAD_LANES": TILE_DIM,
	"M_WRITE_LANES": TILE_DIM,
	"M_EXPORT_LANES": TILE_DIM,
	"M_PHYSICAL_COPIES": 2,
}

PT_V3_128B_PARAMS = {
	**PT_V3_PARAMS,
	"A_LOAD_LANES": 4,
	"B_LOAD_LANES": 4,
	"M_EXPORT_LANES": 4,
}

PT_V3_128B_STRICT_PARAMS = {
	**PT_V3_128B_PARAMS,
	"M_WRITE_LANES": 4,
}

PT_V3_CH1_PARAMS = {
	**PT_V3_PARAMS,
	"STREAM_CHANNELS": 1,
	"S_AXIS_CHANNEL_WIDTH": 512,
	"M_AXIS_CHANNEL_WIDTH": 512,
}

PT_V3_CH2_PARAMS = {
	**PT_V3_PARAMS,
	"STREAM_CHANNELS": 2,
	"S_AXIS_CHANNEL_WIDTH": 256,
	"M_AXIS_CHANNEL_WIDTH": 256,
}

PT_V3_CH4_PARAMS = {
	**PT_V3_PARAMS,
	"STREAM_CHANNELS": 4,
	"S_AXIS_CHANNEL_WIDTH": 128,
	"M_AXIS_CHANNEL_WIDTH": 128,
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


def normalize_app_target(target: str | None) -> str:
	if target is None:
		return DEFAULT_APP_TARGET
	name = target.strip().lower()
	alias_map = {
		"pt": APP_TARGET_PT,
		"native": APP_TARGET_PT,
		"pt_dma_top": APP_TARGET_PT_DMA_TOP,
		"pt-dma-top": APP_TARGET_PT_DMA_TOP,
		"dma_top": APP_TARGET_PT_DMA_TOP,
		"wrapper": APP_TARGET_PT_DMA_TOP,
		"pt_v3": APP_TARGET_PT_V3,
		"pt-v3": APP_TARGET_PT_V3,
		"native_v3": APP_TARGET_PT_V3,
		"pt_dma_top_v3": APP_TARGET_PT_DMA_TOP_V3,
		"pt-dma-top-v3": APP_TARGET_PT_DMA_TOP_V3,
		"dma_top_v3": APP_TARGET_PT_DMA_TOP_V3,
		"wrapper_v3": APP_TARGET_PT_DMA_TOP_V3,
		"pt_dma_top_v3_ch1": APP_TARGET_PT_DMA_TOP_V3_CH1,
		"pt-dma-top-v3-ch1": APP_TARGET_PT_DMA_TOP_V3_CH1,
		"dma_top_v3_ch1": APP_TARGET_PT_DMA_TOP_V3_CH1,
		"wrapper_v3_ch1": APP_TARGET_PT_DMA_TOP_V3_CH1,
		"pt_dma_top_v3_ch2": APP_TARGET_PT_DMA_TOP_V3_CH2,
		"pt-dma-top-v3-ch2": APP_TARGET_PT_DMA_TOP_V3_CH2,
		"dma_top_v3_ch2": APP_TARGET_PT_DMA_TOP_V3_CH2,
		"wrapper_v3_ch2": APP_TARGET_PT_DMA_TOP_V3_CH2,
		"pt_dma_top_v3_ch4": APP_TARGET_PT_DMA_TOP_V3_CH4,
		"pt-dma-top-v3-ch4": APP_TARGET_PT_DMA_TOP_V3_CH4,
		"dma_top_v3_ch4": APP_TARGET_PT_DMA_TOP_V3_CH4,
		"wrapper_v3_ch4": APP_TARGET_PT_DMA_TOP_V3_CH4,
		"pt_dma_top_v3_128b": APP_TARGET_PT_DMA_TOP_V3_128B,
		"pt-dma-top-v3-128b": APP_TARGET_PT_DMA_TOP_V3_128B,
		"dma_top_v3_128b": APP_TARGET_PT_DMA_TOP_V3_128B,
		"wrapper_v3_128b": APP_TARGET_PT_DMA_TOP_V3_128B,
		"pt_dma_top_v3_128b_strict": APP_TARGET_PT_DMA_TOP_V3_128B_STRICT,
		"pt-dma-top-v3-128b-strict": APP_TARGET_PT_DMA_TOP_V3_128B_STRICT,
		"dma_top_v3_128b_strict": APP_TARGET_PT_DMA_TOP_V3_128B_STRICT,
		"wrapper_v3_128b_strict": APP_TARGET_PT_DMA_TOP_V3_128B_STRICT,
	}
	try:
		return alias_map[name]
	except KeyError as exc:
		raise ValueError(f"unsupported app target {target!r}") from exc


def app_target_label(target: str) -> str:
	normalized_target = normalize_app_target(target)
	if normalized_target == APP_TARGET_PT:
		return "PT"
	if normalized_target == APP_TARGET_PT_DMA_TOP:
		return "PT_DMA_TOP"
	if normalized_target == APP_TARGET_PT_V3:
		return "PT_V3"
	if normalized_target == APP_TARGET_PT_DMA_TOP_V3:
		return "PT_DMA_TOP_V3"
	if normalized_target == APP_TARGET_PT_DMA_TOP_V3_CH1:
		return "PT_DMA_TOP_V3_CH1"
	if normalized_target == APP_TARGET_PT_DMA_TOP_V3_CH2:
		return "PT_DMA_TOP_V3_CH2"
	if normalized_target == APP_TARGET_PT_DMA_TOP_V3_CH4:
		return "PT_DMA_TOP_V3_CH4"
	if normalized_target == APP_TARGET_PT_DMA_TOP_V3_128B:
		return "PT_DMA_TOP_V3_128B"
	if normalized_target == APP_TARGET_PT_DMA_TOP_V3_128B_STRICT:
		return "PT_DMA_TOP_V3_128B_STRICT"
	raise ValueError(f"unsupported app target {target!r}")


def is_wrapper_target(target: str | None) -> bool:
	normalized_target = normalize_app_target(target)
	return normalized_target in {
		APP_TARGET_PT_DMA_TOP,
		APP_TARGET_PT_DMA_TOP_V3,
		APP_TARGET_PT_DMA_TOP_V3_CH1,
		APP_TARGET_PT_DMA_TOP_V3_CH2,
		APP_TARGET_PT_DMA_TOP_V3_CH4,
		APP_TARGET_PT_DMA_TOP_V3_128B,
		APP_TARGET_PT_DMA_TOP_V3_128B_STRICT,
	}


def is_v3_wrapper_target(target: str | None) -> bool:
	normalized_target = normalize_app_target(target)
	return normalized_target in {
		APP_TARGET_PT_DMA_TOP_V3,
		APP_TARGET_PT_DMA_TOP_V3_CH1,
		APP_TARGET_PT_DMA_TOP_V3_CH2,
		APP_TARGET_PT_DMA_TOP_V3_CH4,
		APP_TARGET_PT_DMA_TOP_V3_128B,
		APP_TARGET_PT_DMA_TOP_V3_128B_STRICT,
	}


def default_metrics_path(problem: ProblemSpec, target: str = DEFAULT_APP_TARGET) -> Path:
	normalized_target = normalize_app_target(target)
	if normalized_target == APP_TARGET_PT:
		return DEFAULT_OUT_DIR / f"verify_metrics_{problem.tag}.json"
	return DEFAULT_OUT_DIR / f"verify_metrics_{normalized_target}_{problem.tag}.json"


def default_report_path(problem: ProblemSpec, target: str = DEFAULT_APP_TARGET) -> Path:
	normalized_target = normalize_app_target(target)
	if normalized_target == APP_TARGET_PT:
		return DEFAULT_OUT_DIR / f"report_{problem.tag}.md"
	return DEFAULT_OUT_DIR / f"report_{normalized_target}_{problem.tag}.md"


def cocotb_output_root(problem: ProblemSpec, target: str = DEFAULT_APP_TARGET) -> Path:
	normalized_target = normalize_app_target(target)
	if normalized_target == APP_TARGET_PT:
		return DEFAULT_OUT_DIR / "cocotb" / problem.tag
	return DEFAULT_OUT_DIR / "cocotb" / normalized_target / problem.tag


def hdl_toplevel_for_target(target: str) -> str:
	normalized_target = normalize_app_target(target)
	if normalized_target == APP_TARGET_PT:
		return "PT"
	if normalized_target == APP_TARGET_PT_DMA_TOP:
		return "PT_DMA_TOP"
	if normalized_target == APP_TARGET_PT_V3:
		return "PT_V3"
	if normalized_target in {
		APP_TARGET_PT_DMA_TOP_V3,
		APP_TARGET_PT_DMA_TOP_V3_CH1,
		APP_TARGET_PT_DMA_TOP_V3_CH2,
		APP_TARGET_PT_DMA_TOP_V3_CH4,
		APP_TARGET_PT_DMA_TOP_V3_128B,
		APP_TARGET_PT_DMA_TOP_V3_128B_STRICT,
	}:
		return "PT_DMA_TOP_V3"
	raise ValueError(f"unsupported app target {target!r}")


def rtl_params_for_target(target: str) -> dict[str, int]:
	normalized_target = normalize_app_target(target)
	if normalized_target in {APP_TARGET_PT, APP_TARGET_PT_DMA_TOP}:
		return dict(PT_PARAMS)
	if normalized_target in {APP_TARGET_PT_V3, APP_TARGET_PT_DMA_TOP_V3}:
		return dict(PT_V3_PARAMS)
	if normalized_target == APP_TARGET_PT_DMA_TOP_V3_CH1:
		return dict(PT_V3_CH1_PARAMS)
	if normalized_target == APP_TARGET_PT_DMA_TOP_V3_CH2:
		return dict(PT_V3_CH2_PARAMS)
	if normalized_target == APP_TARGET_PT_DMA_TOP_V3_CH4:
		return dict(PT_V3_CH4_PARAMS)
	if normalized_target == APP_TARGET_PT_DMA_TOP_V3_128B:
		return dict(PT_V3_128B_PARAMS)
	if normalized_target == APP_TARGET_PT_DMA_TOP_V3_128B_STRICT:
		return dict(PT_V3_128B_STRICT_PARAMS)
	raise ValueError(f"unsupported app target {target!r}")
