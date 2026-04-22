from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import xml.etree.ElementTree as ET
from dataclasses import dataclass, replace
from pathlib import Path
from typing import List, Mapping, Optional

try:
	from cocotb_tools.runner import get_runner
except ModuleNotFoundError as exc:
	get_runner = None
	IMPORT_ERROR = exc
else:
	IMPORT_ERROR = None

from coverage_report import generate_coverage_reports
from functional_coverage import sanitize_name, write_aggregate_reports
from tests.pt_case_catalog import GUARD_PROFILES, RANDOMIZED_PROFILE_BY_NAME, RANDOMIZED_PROFILES


REPO_ROOT = Path(__file__).resolve().parents[2]
RTL_DIR = REPO_ROOT / "rtl"
TEST_DIR = REPO_ROOT / "sim" / "cocotb" / "tests"
COCOTB_ROOT = REPO_ROOT / "sim" / "cocotb"
BUILD_ROOT = REPO_ROOT / "sim" / "cocotb" / "build"
RESULTS_ROOT = REPO_ROOT / "sim" / "cocotb" / "results"
LOG_ROOT = REPO_ROOT / "sim" / "cocotb" / "logs"
COVERAGE_ROOT = REPO_ROOT / "sim" / "cocotb" / "coverage"

DEFAULT_SEED = 10
DEFAULT_A_BANK_DEPTH = 16
DEFAULT_B_BANK_DEPTH = 16
DEFAULT_M_BANK_DEPTH = 16
APP_TARGET_PT = "pt"
APP_TARGET_PT_DMA_TOP = "pt_dma_top"
APP_TARGET_PT_V3 = "pt_v3"
APP_TARGET_PT_DMA_TOP_V3 = "pt_dma_top_v3"
DEFAULT_RUN_TARGET = APP_TARGET_PT_DMA_TOP
EXTENDED_SEEDS = [10, 110, 210]
SOAK_RANDOM_CASES = 100
DEFAULT_RANDOMIZED_PROFILE_NAMES = [
	"balanced_mix_4x4",
	"legal_heavy_4x4",
	"hit_heavy_4x4",
	"mwindow_heavy_4x4",
	"qcfg_heavy_4x4",
	"invalid_heavy_4x4",
	"wrong_tuser_heavy_4x4",
	"export_error_heavy_4x4",
	"backpressure_heavy_4x4",
	"cache_reuse_heavy_4x4",
	"balanced_mix_8x8",
	"legal_heavy_8x8",
	"hit_heavy_8x8",
	"mwindow_heavy_8x8",
	"qcfg_heavy_8x8",
	"invalid_heavy_8x8",
	"wrong_tuser_heavy_8x8",
	"export_error_heavy_8x8",
	"backpressure_heavy_8x8",
	"cache_reuse_heavy_8x8",
]
EXTENDED_PROFILE_NAMES = [
	"balanced_mix_4x4",
	"qcfg_heavy_4x4",
	"invalid_heavy_4x4",
	"cache_reuse_heavy_4x4",
	"balanced_mix_8x8",
	"qcfg_heavy_8x8",
	"invalid_heavy_8x8",
	"cache_reuse_heavy_8x8",
	"balanced_mix_16x16",
	"backpressure_heavy_16x16",
	"cache_reuse_heavy_16x16",
]

FULL_4X4_MODULES = [
	"tests.test_pt_smoke_cases",
	"tests.test_pt_load_cases",
	"tests.test_pt_multik_cases",
	"tests.test_pt_numeric_cases",
	"tests.test_pt_qcfg_cases",
	"tests.test_pt_protocol_cases",
	"tests.test_pt_protocol_edge_cases",
	"tests.test_pt_state_cases",
	"tests.test_pt_backpressure_cases",
]
FULL_8X8_MODULES = [
	"tests.test_pt_smoke_cases",
	"tests.test_pt_load_cases",
	"tests.test_pt_multik_cases",
	"tests.test_pt_numeric_cases",
	"tests.test_pt_qcfg_cases",
	"tests.test_pt_protocol_edge_cases",
	"tests.test_pt_state_cases",
	"tests.test_pt_backpressure_cases",
]
DIRECTED_STRESS_MODULES = [
	"tests.test_pt_stress_cases",
	"tests.test_pt_overlap_cases",
	"tests.test_pt_csr_cases",
]
STRESS_MODULES = [
	"tests.test_pt_backpressure_cases",
	*DIRECTED_STRESS_MODULES,
]
COVERAGE_EXTRA_MODULES = [
	"tests.test_pt_coverage_cases",
]
LEGACY_COVERAGE_MODULES = [
	"tests.test_pt_legacy_core_cases",
]
WRAPPER_ONLY_SUITES = {"axil", "axil_perf"}


@dataclass(frozen=True)
class RunConfig:
	name: str
	x_dim: int
	y_dim: int
	test_modules: List[str]
	hdl_toplevel: str = "PT"
	build_name: Optional[str] = None
	seeds: Optional[List[int]] = None
	random_cases: int = 20
	expect_startup_fail: bool = False
	expected_log_tokens: Optional[List[str]] = None
	extra_env: Optional[Mapping[str, str]] = None
	rtl_params: Optional[Mapping[str, int]] = None
	build_args: Optional[List[str]] = None
	enable_coverage: bool = False


def parse_args() -> argparse.Namespace:
	parser = argparse.ArgumentParser(description="Run PT cocotb blackbox regressions")
	parser.add_argument("suite", choices=["smoke", "full", "randomized", "extended", "ci", "stress", "soak", "coverage", "perf", "axil", "axil_perf"])
	parser.add_argument("--sim", default=os.getenv("SIM", "icarus"))
	parser.add_argument("--target", default=os.getenv("TARGET", DEFAULT_RUN_TARGET), help="Regression target: pt or pt_dma_top")
	parser.add_argument("--seed", type=int, default=None, help="Override random seed for the selected suite")
	parser.add_argument("--waves", action="store_true", default=bool(int(os.getenv("WAVES", "0"))))
	parser.add_argument("--verbose", action="store_true", default=False)
	return parser.parse_args()


def normalize_sim_name(sim_name: str) -> str:
	name = sim_name.strip().lower()
	if name in {"icarus", "iverilog"}:
		return "icarus"
	if name in {"questa", "questasim", "modelsim"}:
		return "questa"
	if name == "verilator":
		return "verilator"
	return name


def normalize_target(target: str) -> str:
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
		"pt_dma_top_v3": APP_TARGET_PT_DMA_TOP_V3,
		"pt-dma-top-v3": APP_TARGET_PT_DMA_TOP_V3,
		"dma_top_v3": APP_TARGET_PT_DMA_TOP_V3,
		"wrapper_v3": APP_TARGET_PT_DMA_TOP_V3,
	}
	try:
		return alias_map[name]
	except KeyError as exc:
		raise SystemExit(f"unsupported target {target!r}; expected one of: pt, pt_dma_top, pt_v3, pt_dma_top_v3") from exc


def hdl_toplevel_for_target(target: str) -> str:
	normalized_target = normalize_target(target)
	if normalized_target == APP_TARGET_PT:
		return "PT"
	if normalized_target == APP_TARGET_PT_V3:
		return "PT_V3"
	if normalized_target == APP_TARGET_PT_DMA_TOP_V3:
		return "PT_DMA_TOP_V3"
	return "PT_DMA_TOP"


def config_suffix_for_target(target: str) -> str:
	normalized_target = normalize_target(target)
	return "" if normalized_target == DEFAULT_RUN_TARGET else f"_{normalized_target}"


def apply_target_to_config(config: RunConfig, target: str) -> RunConfig:
	normalized_target = normalize_target(target)
	default_toplevel = hdl_toplevel_for_target(normalized_target)
	if config.hdl_toplevel in {"PT_DMA_TOP", "PT_DMA_TOP_V3"}:
		if normalized_target not in {APP_TARGET_PT_DMA_TOP, APP_TARGET_PT_DMA_TOP_V3}:
			raise SystemExit(f"suite {config.name!r} is wrapper-only and does not support --target {normalized_target}")
		return config
	if default_toplevel == config.hdl_toplevel:
		return config
	suffix = config_suffix_for_target(normalized_target)
	return replace(
		config,
		name=f"{config.name}{suffix}",
		build_name=None if config.build_name is None else f"{config.build_name}{suffix}",
		hdl_toplevel=default_toplevel,
	)


def rtl_sources() -> List[Path]:
	return sorted(RTL_DIR.glob("*.v"))


def sync_tests_into_build(build_dir: Path) -> None:
	dst = build_dir / "tests"
	if dst.exists():
		shutil.rmtree(dst)
	shutil.copytree(TEST_DIR, dst)


def sync_tests_into_dir(target_dir: Path) -> None:
	dst = target_dir / "tests"
	if dst.exists():
		shutil.rmtree(dst)
	shutil.copytree(TEST_DIR, dst)


def validate_bank_config(m_bank_depth: int, x_dim: int, y_dim: int) -> Optional[str]:
	if (m_bank_depth * x_dim) < max(x_dim, y_dim):
		return (
			f"illegal PT config: M_BANK_DEPTH({m_bank_depth}) * GEMM_X_DIM({x_dim}) "
			f"< max({x_dim}, {y_dim})"
		)
	return None


def seed_override_or_default(seed_override: Optional[int]) -> int:
	return DEFAULT_SEED if seed_override is None else seed_override


def _guard_configs(prefix: str, seed_override: Optional[int]) -> List[RunConfig]:
	default_seed = seed_override_or_default(seed_override)
	return [
		RunConfig(
			name=f"{prefix}_pow2_guard_{profile.profile}",
			x_dim=profile.data["x_dim"],
			y_dim=profile.data["y_dim"],
			test_modules=["tests.test_pt_guard_boot"],
			seeds=[default_seed],
			expect_startup_fail=True,
			expected_log_tokens=profile.data.get(
				"expected_log_tokens",
				[
					"PT_MD_V2 requires power-of-two GEMM_X_DIM/GEMM_Y_DIM",
					"PT_CE_V2 requires power-of-two GEMM_X_DIM/GEMM_Y_DIM",
				],
			),
			extra_env={"PT_GUARD_PROFILE": profile.profile},
			rtl_params=profile.data.get("rtl_params"),
		)
		for profile in GUARD_PROFILES
	]


def _full_like_configs(prefix: str, seed_override: Optional[int], include_stress: bool) -> List[RunConfig]:
	default_seed = seed_override_or_default(seed_override)
	core_4x4 = list(FULL_4X4_MODULES)
	core_8x8 = list(FULL_8X8_MODULES)
	if include_stress:
		core_4x4.extend(DIRECTED_STRESS_MODULES)
		core_8x8.extend(DIRECTED_STRESS_MODULES)
	return [
		RunConfig(
			name=f"{prefix}_2x2_numeric",
			x_dim=2,
			y_dim=2,
			test_modules=["tests.test_pt_numeric_cases"],
			seeds=[default_seed],
		),
		RunConfig(
			name=f"{prefix}_4x4_core",
			x_dim=4,
			y_dim=4,
			test_modules=core_4x4,
			seeds=[default_seed],
		),
		RunConfig(
			name=f"{prefix}_8x8_core",
			x_dim=8,
			y_dim=8,
			test_modules=core_8x8,
			seeds=[default_seed],
		),
		*_guard_configs(prefix, seed_override),
	]


def suite_configs(suite: str, seed_override: Optional[int], target: str) -> List[RunConfig]:
	normalized_target = normalize_target(target)
	default_seed = seed_override_or_default(seed_override)
	configs: List[RunConfig]

	if suite == "smoke":
		configs = [
			RunConfig(name="smoke_4x4", x_dim=4, y_dim=4, test_modules=["tests.test_pt_smoke_cases", "tests.test_pt_load_cases", "tests.test_pt_multik_cases"], seeds=[default_seed]),
			RunConfig(name="smoke_8x8", x_dim=8, y_dim=8, test_modules=["tests.test_pt_smoke_cases", "tests.test_pt_load_cases", "tests.test_pt_multik_cases"], seeds=[default_seed]),
		]
		return [apply_target_to_config(config, normalized_target) for config in configs]

	if suite == "full":
		return [apply_target_to_config(config, normalized_target) for config in _full_like_configs("full", seed_override, include_stress=False)]

	if suite == "ci":
		return [apply_target_to_config(config, normalized_target) for config in _full_like_configs("ci", seed_override, include_stress=True)]

	if suite == "randomized":
		configs = []
		for profile_name in DEFAULT_RANDOMIZED_PROFILE_NAMES:
			profile = RANDOMIZED_PROFILE_BY_NAME[profile_name]
			dim = profile.dims[0]
			profile_seed = seed_override if seed_override is not None else profile.data["seed"]
			configs.append(
				RunConfig(
					name=f"randomized_{profile.profile}",
					build_name=f"randomized_dim{dim}",
					x_dim=dim,
					y_dim=dim,
					test_modules=["tests.test_pt_randomized_cases"],
					seeds=[profile_seed],
					random_cases=profile.data["random_cases"],
					extra_env={"PT_RANDOM_PROFILE": profile.profile},
				)
			)
		return [apply_target_to_config(config, normalized_target) for config in configs]

	if suite == "extended":
		configs = []
		extended_seeds = [seed_override] if seed_override is not None else EXTENDED_SEEDS
		for profile_name in EXTENDED_PROFILE_NAMES:
			profile = RANDOMIZED_PROFILE_BY_NAME[profile_name]
			dim = profile.dims[0]
			configs.append(
				RunConfig(
					name=f"extended_{profile.profile}",
					build_name=f"extended_dim{dim}_{profile.profile}",
					x_dim=dim,
					y_dim=dim,
					test_modules=["tests.test_pt_randomized_cases"],
					seeds=extended_seeds,
					random_cases=profile.data["random_cases"],
					extra_env={"PT_RANDOM_PROFILE": profile.profile},
				)
			)
		return [apply_target_to_config(config, normalized_target) for config in configs]

	if suite == "soak":
		configs = []
		soak_seeds = [seed_override] if seed_override is not None else EXTENDED_SEEDS
		for profile_name in EXTENDED_PROFILE_NAMES:
			profile = RANDOMIZED_PROFILE_BY_NAME[profile_name]
			dim = profile.dims[0]
			configs.append(
				RunConfig(
					name=f"soak_{profile.profile}",
					build_name=f"soak_dim{dim}_{profile.profile}",
					x_dim=dim,
					y_dim=dim,
					test_modules=["tests.test_pt_randomized_cases"],
					seeds=soak_seeds,
					random_cases=SOAK_RANDOM_CASES,
					extra_env={
						"PT_RANDOM_PROFILE": profile.profile,
						"PT_SOAK_MODE": "1",
						"PT_RANDOM_CLEAR_INTERVAL": "25",
						"PT_RANDOM_CLEAR_CYCLES": "2",
					},
				)
			)
		return [apply_target_to_config(config, normalized_target) for config in configs]

	if suite == "stress":
		configs = [
			RunConfig(name="stress_4x4", x_dim=4, y_dim=4, test_modules=STRESS_MODULES, seeds=[default_seed]),
			RunConfig(name="stress_8x8", x_dim=8, y_dim=8, test_modules=STRESS_MODULES, seeds=[default_seed]),
			RunConfig(
				name="stress_current_16x16",
				build_name="stress_current_16x16",
				x_dim=16,
				y_dim=16,
				test_modules=STRESS_MODULES,
				seeds=[default_seed],
				rtl_params={"A_LOAD_LANES": 16, "B_LOAD_LANES": 16, "M_WRITE_LANES": 16, "M_EXPORT_LANES": 16, "M_PHYSICAL_COPIES": 2},
			),
		]
		return [apply_target_to_config(config, normalized_target) for config in configs]

	if suite == "perf":
		configs = [
			RunConfig(
				name="perf_legacy_4x4",
				x_dim=4,
				y_dim=4,
				test_modules=["tests.test_pt_perf_cases"],
				seeds=[default_seed],
				rtl_params={"A_LOAD_LANES": 1, "B_LOAD_LANES": 1, "M_WRITE_LANES": 1, "M_EXPORT_LANES": 1, "M_PHYSICAL_COPIES": 3},
			),
			RunConfig(
				name="perf_upgrade_4x4",
				x_dim=4,
				y_dim=4,
				test_modules=["tests.test_pt_perf_cases"],
				seeds=[default_seed],
				rtl_params={"A_LOAD_LANES": 4, "B_LOAD_LANES": 4, "M_WRITE_LANES": 4, "M_EXPORT_LANES": 4, "M_PHYSICAL_COPIES": 2},
			),
			RunConfig(
				name="perf_legacy_8x8",
				x_dim=8,
				y_dim=8,
				test_modules=["tests.test_pt_perf_cases"],
				seeds=[default_seed],
				rtl_params={"A_LOAD_LANES": 1, "B_LOAD_LANES": 1, "M_WRITE_LANES": 1, "M_EXPORT_LANES": 1, "M_PHYSICAL_COPIES": 3},
			),
			RunConfig(
				name="perf_upgrade_8x8",
				x_dim=8,
				y_dim=8,
				test_modules=["tests.test_pt_perf_cases"],
				seeds=[default_seed],
				rtl_params={"A_LOAD_LANES": 8, "B_LOAD_LANES": 8, "M_WRITE_LANES": 8, "M_EXPORT_LANES": 8, "M_PHYSICAL_COPIES": 2},
			),
			RunConfig(
				name="perf_current_16x16",
				build_name="perf_current_16x16",
				x_dim=16,
				y_dim=16,
				test_modules=["tests.test_pt_perf_cases"],
				seeds=[default_seed],
				rtl_params={"A_LOAD_LANES": 16, "B_LOAD_LANES": 16, "M_WRITE_LANES": 16, "M_EXPORT_LANES": 16, "M_PHYSICAL_COPIES": 2},
			),
		]
		return [apply_target_to_config(config, normalized_target) for config in configs]

	if suite == "axil":
		if normalized_target not in {APP_TARGET_PT_DMA_TOP, APP_TARGET_PT_DMA_TOP_V3}:
			raise SystemExit("suite 'axil' is wrapper-only; use --target pt_dma_top or pt_dma_top_v3")
		return [
			RunConfig(
				name="axil_pt_dma_top_4x4",
				build_name="axil_pt_dma_top_4x4",
				x_dim=4,
				y_dim=4,
				test_modules=["tests.test_pt_dma_top_cases"],
				hdl_toplevel="PT_DMA_TOP",
				seeds=[default_seed],
			),
			RunConfig(
				name="axil_pt_dma_top_8x8",
				build_name="axil_pt_dma_top_8x8",
				x_dim=8,
				y_dim=8,
				test_modules=["tests.test_pt_dma_top_cases"],
				hdl_toplevel="PT_DMA_TOP",
				seeds=[default_seed],
			),
		]

	if suite == "axil_perf":
		if normalized_target not in {APP_TARGET_PT_DMA_TOP, APP_TARGET_PT_DMA_TOP_V3}:
			raise SystemExit("suite 'axil_perf' is wrapper-only; use --target pt_dma_top or pt_dma_top_v3")
		return [
			RunConfig(
				name="axil_perf_legacy_4x4",
				build_name="axil_perf_legacy_4x4",
				x_dim=4,
				y_dim=4,
				test_modules=["tests.test_pt_dma_top_perf_cases"],
				hdl_toplevel="PT_DMA_TOP",
				seeds=[default_seed],
			),
			RunConfig(
				name="axil_perf_legacy_8x8",
				build_name="axil_perf_legacy_8x8",
				x_dim=8,
				y_dim=8,
				test_modules=["tests.test_pt_dma_top_perf_cases"],
				hdl_toplevel="PT_DMA_TOP",
				seeds=[default_seed],
			),
			RunConfig(
				name="axil_perf_wide_8x8",
				build_name="axil_perf_wide_8x8",
				x_dim=8,
				y_dim=8,
				test_modules=["tests.test_pt_dma_top_perf_cases"],
				hdl_toplevel="PT_DMA_TOP",
				seeds=[default_seed],
				rtl_params={"A_LOAD_LANES": 8, "B_LOAD_LANES": 8, "M_WRITE_LANES": 8, "M_EXPORT_LANES": 8, "M_PHYSICAL_COPIES": 2},
			),
			RunConfig(
				name="axil_perf_current_16x16",
				build_name="axil_perf_current_16x16",
				x_dim=16,
				y_dim=16,
				test_modules=["tests.test_pt_dma_top_perf_cases"],
				hdl_toplevel="PT_DMA_TOP",
				seeds=[default_seed],
				rtl_params={"A_LOAD_LANES": 16, "B_LOAD_LANES": 16, "M_WRITE_LANES": 16, "M_EXPORT_LANES": 16, "M_PHYSICAL_COPIES": 2},
			),
		]

	configs = [
		RunConfig(
			name="coverage_core_4x4",
			build_name="coverage_dim4_core",
			x_dim=4,
			y_dim=4,
			test_modules=FULL_4X4_MODULES + DIRECTED_STRESS_MODULES + LEGACY_COVERAGE_MODULES + COVERAGE_EXTRA_MODULES,
			seeds=[default_seed],
			build_args=["--coverage", "--assert"],
			enable_coverage=True,
		),
		RunConfig(
			name="coverage_wide_4x4",
			build_name="coverage_dim4_wide",
			x_dim=4,
			y_dim=4,
			test_modules=["tests.test_pt_coverage_cases"],
			seeds=[default_seed],
			rtl_params={"A_LOAD_LANES": 2, "B_LOAD_LANES": 2, "M_WRITE_LANES": 2, "M_EXPORT_LANES": 2, "M_PHYSICAL_COPIES": 2},
			build_args=["--coverage", "--assert"],
			enable_coverage=True,
		),
		RunConfig(
			name="coverage_core_8x8",
			build_name="coverage_dim8_core",
			x_dim=8,
			y_dim=8,
			test_modules=FULL_8X8_MODULES + DIRECTED_STRESS_MODULES + LEGACY_COVERAGE_MODULES + COVERAGE_EXTRA_MODULES,
			seeds=[default_seed],
			build_args=["--coverage", "--assert"],
			enable_coverage=True,
		),
		RunConfig(
			name="coverage_wide_8x8",
			build_name="coverage_dim8_wide",
			x_dim=8,
			y_dim=8,
			test_modules=["tests.test_pt_coverage_cases"],
			seeds=[default_seed],
			rtl_params={"A_LOAD_LANES": 4, "B_LOAD_LANES": 4, "M_WRITE_LANES": 4, "M_EXPORT_LANES": 4, "M_PHYSICAL_COPIES": 2},
			build_args=["--coverage", "--assert"],
			enable_coverage=True,
		),
	]
	return [apply_target_to_config(config, normalized_target) for config in configs]


def safe_read_text(path: Path) -> str:
	try:
		return path.read_text(encoding="utf-8", errors="ignore")
	except FileNotFoundError:
		return ""


def write_synthetic_results(results_xml: Path, config: RunConfig, passed: bool, message: str) -> None:
	results_xml.parent.mkdir(parents=True, exist_ok=True)
	testsuites = ET.Element("testsuites")
	suite = ET.SubElement(
		testsuites,
		"testsuite",
		name=config.name,
		tests="1",
		failures="0" if passed else "1",
		errors="0",
		skipped="0",
	)
	testcase = ET.SubElement(suite, "testcase", classname="runner.expected_fail", name=config.name)
	if passed:
		system_out = ET.SubElement(testcase, "system-out")
		system_out.text = message
	else:
		failure = ET.SubElement(testcase, "failure", message=message)
		failure.text = message
	ET.ElementTree(testsuites).write(results_xml, encoding="utf-8", xml_declaration=True)


def expected_fail_status(config: RunConfig, exit_code: int, log_text: str) -> Optional[str]:
	if exit_code == 0:
		return f"{config.name}: simulation unexpectedly succeeded; expected startup guard failure"
	missing_tokens = [token for token in (config.expected_log_tokens or []) if token not in log_text]
	if missing_tokens:
		return (
			f"{config.name}: simulation exited with code {exit_code}, but log did not contain expected guard text. "
			f"Missing tokens: {missing_tokens}"
		)
	return None


def discover_coverage_files(*roots: Path) -> List[Path]:
	discovered: List[Path] = []
	for root in roots:
		if not root.exists():
			continue
		for path in sorted(root.rglob("coverage.dat")):
			if path not in discovered:
				discovered.append(path)
	return discovered


def discover_functional_coverage_files(*roots: Path) -> List[Path]:
	discovered: List[Path] = []
	for root in roots:
		if not root.exists():
			continue
		for path in sorted(root.rglob("*.functional.json")):
			if path not in discovered:
				discovered.append(path)
	return discovered


def snapshot_functional_coverage_files(
	suite_name: str,
	config_name: str,
	seed: int,
	fragment_paths: List[Path],
) -> List[Path]:
	if not fragment_paths:
		return []
	stage_root = COVERAGE_ROOT / ".fragments" / sanitize_name(suite_name) / sanitize_name(config_name) / f"seed_{seed}"
	if stage_root.exists():
		shutil.rmtree(stage_root)
	stage_root.mkdir(parents=True, exist_ok=True)
	snapshots: List[Path] = []
	for src in fragment_paths:
		if not src.exists():
			continue
		dst = stage_root / src.name
		shutil.copy2(src, dst)
		snapshots.append(dst)
	return snapshots


def write_functional_coverage_suite(suite: str, fragment_paths: List[Path]) -> Optional[Mapping[str, str]]:
	if not fragment_paths:
		return None
	suite_root = COVERAGE_ROOT / suite
	suite_root.mkdir(parents=True, exist_ok=True)
	report_paths = write_aggregate_reports(fragment_paths, suite_root, suite)
	report = json.loads(Path(report_paths["json_path"]).read_text(encoding="utf-8"))
	missing_bins = list(report.get("missing_required_bins", []))
	if missing_bins:
		raise SystemExit(f"{suite}: missing required functional coverage bins: {missing_bins}")
	return report_paths


def merge_coverage_files(suite: str, coverage_files: List[Path]) -> None:
	if not coverage_files:
		raise SystemExit(f"{suite}: coverage suite completed but no coverage.dat files were found")
	COVERAGE_ROOT.mkdir(parents=True, exist_ok=True)
	suite_root = COVERAGE_ROOT / suite
	suite_root.mkdir(parents=True, exist_ok=True)
	merged_dat = suite_root / f"{suite}.dat"
	merged_info = suite_root / f"{suite}.info"
	summary_txt = suite_root / "summary.txt"
	inputs = [str(path) for path in coverage_files]
	subprocess.run(["verilator_coverage", "--write", str(merged_dat), *inputs], check=True)
	subprocess.run(["verilator_coverage", "--write-info", str(merged_info), *inputs], check=True)
	summary_txt.write_text(
		"\n".join(
			[
				f"suite={suite}",
				f"coverage_files={len(coverage_files)}",
				f"merged_dat={merged_dat}",
				f"merged_info={merged_info}",
				*inputs,
			]
		)
		+ "\n",
		encoding="utf-8",
	)
	generate_coverage_reports(merged_dat, merged_info, summary_txt)


def run_case(sim_name: str, suite_name: str, waves: bool, verbose: bool, config: RunConfig) -> tuple[List[Path], List[Path]]:
	if get_runner is None:
		venv_hint = REPO_ROOT / ".venv" / "Scripts" / "python.exe"
		raise SystemExit(
			"cocotb_tools is not installed for the selected Python interpreter. "
			f"Import error: {IMPORT_ERROR}. "
			f"If this repo's virtualenv is populated, try running with {venv_hint}."
		)

	params = {
		"DATA_WIDTH": 32,
		"GEMM_X_DIM": config.x_dim,
		"GEMM_Y_DIM": config.y_dim,
		"EXT_ADDR_W": 32,
		"DMA_BEATS_W": 16,
		"LUT_DEPTH": 8,
		"A_BANK_DEPTH": DEFAULT_A_BANK_DEPTH,
		"B_BANK_DEPTH": DEFAULT_B_BANK_DEPTH,
		"M_BANK_DEPTH": DEFAULT_M_BANK_DEPTH,
		"A_LOAD_LANES": 1,
		"B_LOAD_LANES": 1,
		"M_WRITE_LANES": 1,
		"M_EXPORT_LANES": 1,
		"M_PHYSICAL_COPIES": 3,
	}
	if config.rtl_params:
		params.update(config.rtl_params)

	startup_error = validate_bank_config(int(params["M_BANK_DEPTH"]), config.x_dim, config.y_dim)
	if startup_error and not config.expect_startup_fail:
		raise SystemExit(startup_error)
	preflight_error_text = startup_error
	preflight_exit_code = 1

	runner = get_runner(normalize_sim_name(sim_name))
	build_dir = BUILD_ROOT / (config.build_name or config.name)

	if startup_error is None:
		if build_dir.exists():
			shutil.rmtree(build_dir)
		build_dir.mkdir(parents=True, exist_ok=True)
		sync_tests_into_build(build_dir)
		build_args = ["-Wall", *(config.build_args or [])]
		if normalize_sim_name(sim_name) == "verilator":
			build_args.append("-Wno-fatal")
		try:
			runner.build(
				sources=rtl_sources(),
				includes=[RTL_DIR],
				hdl_toplevel=config.hdl_toplevel,
				parameters=params,
				build_args=build_args,
				build_dir=build_dir,
				always=True,
				timescale=("1ns", "1ps"),
				waves=waves,
				verbose=verbose,
				log_file=LOG_ROOT / f"{config.name}.build.log",
			)
		except subprocess.CalledProcessError as exc:
			if not config.expect_startup_fail:
				raise
			preflight_error_text = safe_read_text(LOG_ROOT / f"{config.name}.build.log") or str(exc)
			preflight_exit_code = exc.returncode if isinstance(exc.returncode, int) else 1

	seeds = config.seeds if config.seeds is not None else [seed_override_or_default(None)]
	coverage_files: List[Path] = []
	functional_files: List[Path] = []
	for seed in seeds:
		test_suffix = f"{config.name}_seed{seed}"
		results_xml = RESULTS_ROOT / f"{test_suffix}.xml"
		log_file = LOG_ROOT / f"{test_suffix}.test.log"
		test_dir = build_dir / f"seed_{seed}"
		func_cov_dir = test_dir / "functional"
		if preflight_error_text is not None:
			log_file.parent.mkdir(parents=True, exist_ok=True)
			results_xml.parent.mkdir(parents=True, exist_ok=True)
			log_file.write_text(preflight_error_text + "\n", encoding="utf-8")
			status = expected_fail_status(config, preflight_exit_code, preflight_error_text)
			if status is None:
				write_synthetic_results(
					results_xml,
					config,
					True,
					f"Matched expected startup/build guard failure in {config.name}: {preflight_error_text}",
				)
				print(f"[expected-fail-pass] {config.name} seed={seed}: matched preflight guard")
				continue
			write_synthetic_results(results_xml, config, False, status)
			raise SystemExit(status)
		if test_dir.exists():
			shutil.rmtree(test_dir)
		test_dir.mkdir(parents=True, exist_ok=True)
		func_cov_dir.mkdir(parents=True, exist_ok=True)
		sync_tests_into_dir(test_dir)
		existing_pythonpath = os.getenv("PYTHONPATH", "")
		extra_env = {
			"PYTHONPATH": str(COCOTB_ROOT) if not existing_pythonpath else f"{COCOTB_ROOT}{os.pathsep}{existing_pythonpath}",
			"PT_X_DIM": str(config.x_dim),
			"PT_Y_DIM": str(config.y_dim),
			"PT_DATA_WIDTH": "32",
			"PT_EXT_ADDR_W": str(params["EXT_ADDR_W"]),
			"PT_A_BASE": str(0x0000_1000),
			"PT_B_BASE": str(0x0000_2000),
			"PT_LUT_DEPTH": str(params["LUT_DEPTH"]),
			"PT_A_BANK_DEPTH": str(params["A_BANK_DEPTH"]),
			"PT_B_BANK_DEPTH": str(params["B_BANK_DEPTH"]),
			"PT_M_BANK_DEPTH": str(params["M_BANK_DEPTH"]),
			"PT_A_LOAD_LANES": str(params["A_LOAD_LANES"]),
			"PT_B_LOAD_LANES": str(params["B_LOAD_LANES"]),
			"PT_M_WRITE_LANES": str(params["M_WRITE_LANES"]),
			"PT_M_EXPORT_LANES": str(params["M_EXPORT_LANES"]),
			"PT_M_PHYSICAL_COPIES": str(params["M_PHYSICAL_COPIES"]),
			"PT_TEST_SEED": str(seed),
			"PT_RANDOM_CASES": str(config.random_cases),
			"PT_SUITE_NAME": suite_name,
			"PT_RUN_NAME": config.name,
			"PT_FUNC_COV_DIR": str(func_cov_dir),
			"PT_TOPLEVEL": config.hdl_toplevel,
		}
		if config.extra_env:
			extra_env.update(config.extra_env)
		exit_code = 0
		try:
			runner.test(
				test_module=config.test_modules,
				hdl_toplevel=config.hdl_toplevel,
				seed=seed,
				extra_env=extra_env,
				build_dir=build_dir,
				test_dir=test_dir,
				results_xml=str(results_xml),
				waves=waves,
				verbose=verbose,
				timescale=("1ns", "1ps"),
				log_file=log_file,
			)
		except SystemExit as exc:
			exit_code = exc.code if isinstance(exc.code, int) else 1
			if not config.expect_startup_fail:
				raise

		if config.expect_startup_fail:
			status = expected_fail_status(config, exit_code, safe_read_text(log_file))
			if status is None:
				write_synthetic_results(
					results_xml,
					config,
					True,
					f"Matched expected startup guard failure in {log_file.name}",
				)
				print(f"[expected-fail-pass] {config.name} seed={seed}: matched startup guard")
			else:
				write_synthetic_results(results_xml, config, False, status)
				raise SystemExit(status)

		functional_fragments = discover_functional_coverage_files(func_cov_dir)
		functional_files.extend(snapshot_functional_coverage_files(suite_name, config.name, seed, functional_fragments))
		if config.enable_coverage:
			coverage_files.extend(discover_coverage_files(test_dir, build_dir))

	return coverage_files, functional_files


def ensure_dirs() -> None:
	for path in (BUILD_ROOT, RESULTS_ROOT, LOG_ROOT, COVERAGE_ROOT):
		path.mkdir(parents=True, exist_ok=True)


def main() -> None:
	args = parse_args()
	target = normalize_target(args.target)
	if args.suite == "coverage":
		target = APP_TARGET_PT
	ensure_dirs()
	staged_fragment_root = COVERAGE_ROOT / ".fragments" / sanitize_name(args.suite)
	if staged_fragment_root.exists():
		shutil.rmtree(staged_fragment_root)
	all_coverage_files: List[Path] = []
	all_functional_files: List[Path] = []
	for config in suite_configs(args.suite, args.seed, target):
		coverage_files, functional_files = run_case(args.sim, args.suite, args.waves, args.verbose, config)
		all_coverage_files.extend(coverage_files)
		all_functional_files.extend(functional_files)
	write_functional_coverage_suite(args.suite, all_functional_files)
	if args.suite == "coverage":
		merge_coverage_files(args.suite, all_coverage_files)


if __name__ == "__main__":
	main()
