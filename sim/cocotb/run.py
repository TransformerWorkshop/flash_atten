from __future__ import annotations

import argparse
import os
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional

from cocotb_tools.runner import get_runner


REPO_ROOT = Path(__file__).resolve().parents[2]
RTL_DIR = REPO_ROOT / "rtl"
TEST_DIR = REPO_ROOT / "sim" / "cocotb" / "tests"
COCOTB_ROOT = REPO_ROOT / "sim" / "cocotb"
BUILD_ROOT = REPO_ROOT / "sim" / "cocotb" / "build"
RESULTS_ROOT = REPO_ROOT / "sim" / "cocotb" / "results"
LOG_ROOT = REPO_ROOT / "sim" / "cocotb" / "logs"


@dataclass(frozen=True)
class RunConfig:
	name: str
	x_dim: int
	y_dim: int
	testcases: List[str]
	seeds: Optional[List[int]] = None
	random_cases: int = 12


def parse_args() -> argparse.Namespace:
	parser = argparse.ArgumentParser(description="Run PT cocotb blackbox regressions")
	parser.add_argument("suite", choices=["smoke", "full", "randomized"])
	parser.add_argument("--sim", default=os.getenv("SIM", "icarus"))
	parser.add_argument("--seed", type=int, default=None, help="Override random seed for the selected suite")
	parser.add_argument("--waves", action="store_true", default=bool(int(os.getenv("WAVES", "0"))))
	parser.add_argument("--verbose", action="store_true", default=False)
	return parser.parse_args()


def rtl_sources() -> List[Path]:
	return sorted(RTL_DIR.glob("*.v"))


def suite_configs(suite: str, seed_override: Optional[int]) -> List[RunConfig]:
	if suite == "smoke":
		return [
			RunConfig(name="smoke_4x4", x_dim=4, y_dim=4, testcases=["test_pt_smoke"]),
			RunConfig(name="smoke_8x8", x_dim=8, y_dim=8, testcases=["test_pt_smoke"]),
		]

	if suite == "full":
		return [
			RunConfig(name="full_2x2_numeric", x_dim=2, y_dim=2, testcases=["test_pt_numeric_boundaries"]),
			RunConfig(
				name="full_4x4_core",
				x_dim=4,
				y_dim=4,
				testcases=[
					"test_pt_smoke",
					"test_pt_numeric_boundaries",
					"test_pt_qcfg_modes",
					"test_pt_protocol_errors",
					"test_pt_backpressure",
					"test_pt_randomized",
				],
				seeds=[10 if seed_override is None else seed_override],
				random_cases=8,
			),
			RunConfig(
				name="full_8x8_core",
				x_dim=8,
				y_dim=8,
				testcases=[
					"test_pt_smoke",
					"test_pt_numeric_boundaries",
					"test_pt_qcfg_modes",
					"test_pt_backpressure",
				],
			),
			RunConfig(name="full_3x2_protocol", x_dim=3, y_dim=2, testcases=["test_pt_qcfg_odd_granularity"]),
		]

	default_seeds = [seed_override] if seed_override is not None else list(range(10, 20))
	return [
		RunConfig(
			name="randomized_4x4",
			x_dim=4,
			y_dim=4,
			testcases=["test_pt_randomized"],
			seeds=default_seeds,
			random_cases=16,
		),
		RunConfig(
			name="randomized_8x8",
			x_dim=8,
			y_dim=8,
			testcases=["test_pt_randomized"],
			seeds=default_seeds,
			random_cases=12,
		),
	]


def run_case(sim_name: str, waves: bool, verbose: bool, config: RunConfig) -> None:
	runner = get_runner(sim_name)
	build_dir = BUILD_ROOT / config.name
	params = {
		"DATA_WIDTH": 32,
		"GEMM_X_DIM": config.x_dim,
		"GEMM_Y_DIM": config.y_dim,
		"EXT_ADDR_W": 32,
		"DMA_BEATS_W": 16,
		"LUT_DEPTH": 8,
		"A_BANK_DEPTH": 8,
		"B_BANK_DEPTH": 8,
	}

	build_dir.mkdir(parents=True, exist_ok=True)
	runner.build(
		sources=rtl_sources(),
		includes=[RTL_DIR],
		hdl_toplevel="PT",
		parameters=params,
		build_args=["-g2001", "-Wall"],
		build_dir=build_dir,
		always=True,
		timescale=("1ns", "1ps"),
		waves=waves,
		verbose=verbose,
		log_file=LOG_ROOT / f"{config.name}.build.log",
	)

	seeds = config.seeds if config.seeds is not None else [seed_override_or_default(None)]
	for seed in seeds:
		test_suffix = f"{config.name}_seed{seed}"
		results_xml = RESULTS_ROOT / f"{test_suffix}.xml"
		log_file = LOG_ROOT / f"{test_suffix}.test.log"
		test_dir = build_dir / f"seed_{seed}"
		test_dir.mkdir(parents=True, exist_ok=True)
		existing_pythonpath = os.getenv("PYTHONPATH", "")
		extra_env = {
			"PYTHONPATH": str(COCOTB_ROOT) if not existing_pythonpath else f"{COCOTB_ROOT}{os.pathsep}{existing_pythonpath}",
			"PT_X_DIM": str(config.x_dim),
			"PT_Y_DIM": str(config.y_dim),
			"PT_DATA_WIDTH": "32",
			"PT_A_BASE": str(0x0000_1000),
			"PT_B_BASE": str(0x0000_2000),
			"PT_TEST_SEED": str(seed),
			"PT_RANDOM_CASES": str(config.random_cases),
		}
		runner.test(
			test_module="tests.test_pt_blackbox",
			hdl_toplevel="PT",
			seed=seed,
			testcase=config.testcases,
			extra_env=extra_env,
			build_dir=build_dir,
			test_dir=test_dir,
			results_xml=str(results_xml),
			waves=waves,
			verbose=verbose,
			timescale=("1ns", "1ps"),
			log_file=log_file,
		)


def seed_override_or_default(seed_override: Optional[int]) -> int:
	return 10 if seed_override is None else seed_override


def ensure_dirs() -> None:
	for path in (BUILD_ROOT, RESULTS_ROOT, LOG_ROOT):
		path.mkdir(parents=True, exist_ok=True)


def main() -> None:
	args = parse_args()
	ensure_dirs()
	for config in suite_configs(args.suite, args.seed):
		run_case(args.sim, args.waves, args.verbose, config)


if __name__ == "__main__":
	main()
