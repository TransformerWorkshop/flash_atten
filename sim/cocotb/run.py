from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Any, List, Mapping, Optional

try:
    from cocotb_tools.runner import get_runner
except ModuleNotFoundError as exc:
    get_runner = None
    IMPORT_ERROR = exc
else:
    IMPORT_ERROR = None


REPO_ROOT = Path(__file__).resolve().parents[2]
RTL_DIR = REPO_ROOT / "rtl"
TEST_DIR = REPO_ROOT / "sim" / "cocotb" / "tests"
COCOTB_ROOT = REPO_ROOT / "sim" / "cocotb"
BUILD_ROOT = COCOTB_ROOT / "build"
RESULTS_ROOT = COCOTB_ROOT / "results"
LOG_ROOT = COCOTB_ROOT / "logs"
COVERAGE_ROOT = COCOTB_ROOT / "coverage"
BUILD_METADATA_NAME = ".runner_build_metadata.json"
DEFAULT_TIMESCALE = ("1ns", "1ps")
DEFAULT_SIMULATOR = "verilator"
DEFAULT_SEED = 10
APP_TARGET_FA = "fa"

FA_SUITES = (
    "fa_baseline",
    "fa_full",
    "fa_baseline_axi",
    "fa_full_axi",
    "fa_p_bypass",
    "fa_shared_gemm",
    "fa_oacc_update",
)


@dataclass(frozen=True)
class RunConfig:
    name: str
    x_dim: int
    y_dim: int
    test_modules: List[str]
    hdl_toplevel: str = "FA_TOP_BASELINE_SIM"
    build_name: Optional[str] = None
    seeds: Optional[List[int]] = None
    extra_env: Optional[Mapping[str, str]] = None
    rtl_params: Optional[Mapping[str, int]] = None
    build_args: Optional[List[str]] = None


@dataclass(frozen=True)
class RunOptions:
    keep_build: bool = False
    force_rebuild: bool = False
    test_filter: Optional[str] = None
    testcase_names: Optional[List[str]] = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run FA cocotb regressions")
    parser.add_argument("suite", choices=FA_SUITES)
    parser.add_argument("--sim", default=os.getenv("SIM"))
    parser.add_argument("--target", default=os.getenv("TARGET", APP_TARGET_FA), help=argparse.SUPPRESS)
    parser.add_argument("--seed", type=int, default=None, help="Override random seed for the selected suite")
    parser.add_argument("--waves", action="store_true", default=bool(int(os.getenv("WAVES", "0"))))
    parser.add_argument("--verbose", action="store_true", default=False)
    parser.add_argument("--test-filter", default=os.getenv("TEST_FILTER"), help="Regex filter for cocotb testcase selection")
    parser.add_argument("--testcase", default=os.getenv("TESTCASE"), help="Exact testcase name or comma-separated list of names")
    parser.add_argument("--keep-build", action="store_true", default=bool(int(os.getenv("KEEP_BUILD", "0"))), help="Reuse a compatible simulator build instead of rebuilding every run")
    parser.add_argument("--rebuild", action="store_true", default=bool(int(os.getenv("REBUILD", "0"))), help="Force a rebuild even when --keep-build is enabled")
    return parser.parse_args()


def normalize_sim_name(sim_name: str) -> str:
    name = sim_name.strip().lower()
    if name in {"icarus", "iverilog", "vvp"}:
        return "verilator"
    if name in {"questa", "questasim", "modelsim"}:
        return "questa"
    if name == "verilator":
        return "verilator"
    return name


def resolve_sim_name(sim_name: Optional[str]) -> str:
    if sim_name:
        return normalize_sim_name(sim_name)
    return DEFAULT_SIMULATOR


def resolve_test_selection(test_filter: Optional[str], testcase: Optional[str]) -> tuple[Optional[str], Optional[List[str]]]:
    if test_filter and testcase:
        raise SystemExit("use either --test-filter or --testcase, not both")
    if testcase is None:
        return test_filter, None
    names = [name.strip() for name in testcase.split(",") if name.strip()]
    if not names:
        return None, None
    return "|".join(f"(?:^|.*\\.){re.escape(name)}$" for name in names), names


def hdl_toplevel_supports_stream_params(hdl_toplevel: str) -> bool:
    return hdl_toplevel in {
        "FA_TOP_BASELINE",
        "FA_TOP_BASELINE_SIM",
    }


def rtl_sources() -> List[Path]:
    return sorted(RTL_DIR.glob("*.v"))


def test_module_path(module_name: str) -> Path:
    if not module_name.startswith("tests."):
        raise ValueError(f"unsupported test module namespace: {module_name}")
    relative_module = module_name[len("tests.") :].replace(".", "/")
    return TEST_DIR / f"{relative_module}.py"


def safe_read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="ignore")
    except FileNotFoundError:
        return ""


def narrow_test_modules(test_modules: List[str], testcase_names: Optional[List[str]]) -> List[str]:
    if not testcase_names:
        return test_modules
    selected: List[str] = []
    for module_name in test_modules:
        module_text = safe_read_text(test_module_path(module_name))
        if any(re.search(rf"\bdef\s+{re.escape(name)}\s*\(", module_text) for name in testcase_names):
            selected.append(module_name)
    return selected or test_modules


def build_metadata_path(build_dir: Path) -> Path:
    return build_dir / BUILD_METADATA_NAME


def build_output_path(sim_name: str, build_dir: Path, hdl_toplevel: str) -> Optional[Path]:
    if normalize_sim_name(sim_name) == "verilator":
        return build_dir / hdl_toplevel
    return None


def source_stamp(path: Path) -> Mapping[str, Any]:
    return {"path": str(path), "mtime_ns": path.stat().st_mtime_ns}


def build_metadata(
    sim_name: str,
    config: RunConfig,
    params: Mapping[str, int],
    build_args: List[str],
    waves: bool,
) -> Mapping[str, Any]:
    return {
        "sim": normalize_sim_name(sim_name),
        "hdl_toplevel": config.hdl_toplevel,
        "parameters": dict(sorted(params.items())),
        "build_args": list(build_args),
        "waves": bool(waves),
        "timescale": list(DEFAULT_TIMESCALE),
        "sources": [source_stamp(path) for path in rtl_sources()],
        "includes": [str(RTL_DIR.resolve())],
    }


def load_build_metadata(build_dir: Path) -> Optional[Mapping[str, Any]]:
    try:
        return json.loads(build_metadata_path(build_dir).read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return None


def write_build_metadata(build_dir: Path, metadata: Mapping[str, Any]) -> None:
    build_metadata_path(build_dir).write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def can_reuse_build(build_dir: Path, sim_name: str, hdl_toplevel: str, metadata: Mapping[str, Any]) -> bool:
    output_path = build_output_path(sim_name, build_dir, hdl_toplevel)
    if output_path is None or not output_path.exists():
        return False
    return load_build_metadata(build_dir) == metadata


def prime_runner_for_reused_build(runner, sources: List[Path], params: Mapping[str, int]) -> None:
    runner._set_sources(sources)
    runner._set_verilog_sources([])
    runner._set_vhdl_sources([])
    runner.parameters = dict(params)


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


def suite_configs(suite: str, seed_override: Optional[int], _target: str = APP_TARGET_FA) -> List[RunConfig]:
    default_seed = seed_override if seed_override is not None else DEFAULT_SEED
    if suite == "fa_baseline":
        return [
            RunConfig(
                name="fa_baseline_sim",
                build_name="fa_baseline_sim",
                x_dim=16,
                y_dim=16,
                test_modules=[
                    "tests.test_fa_baseline_smoke_cases",
                    "tests.test_fa_baseline_numeric_cases",
                    "tests.test_fa_baseline_csr_cases",
                    "tests.test_fa_baseline_protocol_cases",
                    "tests.test_fa_baseline_protocol_edge_cases",
                    "tests.test_fa_baseline_state_cases",
                    "tests.test_fa_baseline_backpressure_cases",
                    "tests.test_fa_baseline",
                ],
                hdl_toplevel="FA_TOP_BASELINE_SIM",
                seeds=[default_seed],
            )
        ]
    if suite == "fa_full":
        return [
            RunConfig(
                name="fa_full_sim",
                build_name="fa_baseline_sim",
                x_dim=16,
                y_dim=16,
                test_modules=[
                    "tests.test_fa_baseline_smoke_cases",
                    "tests.test_fa_baseline_numeric_cases",
                    "tests.test_fa_baseline_full_numeric_cases",
                    "tests.test_fa_baseline_csr_cases",
                    "tests.test_fa_baseline_protocol_cases",
                    "tests.test_fa_baseline_protocol_edge_cases",
                    "tests.test_fa_baseline_state_cases",
                    "tests.test_fa_baseline_backpressure_cases",
                    "tests.test_fa_baseline",
                    "tests.test_fa_baseline_full_cases",
                ],
                hdl_toplevel="FA_TOP_BASELINE_SIM",
                seeds=[default_seed],
            )
        ]
    if suite == "fa_baseline_axi":
        return [
            RunConfig(
                name="fa_baseline_axi",
                build_name="fa_baseline_axi",
                x_dim=16,
                y_dim=16,
                test_modules=["tests.test_fa_baseline_axi"],
                hdl_toplevel="FA_TOP_BASELINE",
                seeds=[default_seed],
            )
        ]
    if suite == "fa_full_axi":
        return [
            RunConfig(
                name="fa_full_axi",
                build_name="fa_baseline_axi",
                x_dim=16,
                y_dim=16,
                test_modules=["tests.test_fa_baseline_axi", "tests.test_fa_baseline_axi_full_cases"],
                hdl_toplevel="FA_TOP_BASELINE",
                seeds=[default_seed],
            )
        ]
    if suite == "fa_p_bypass":
        return [
            RunConfig(
                name="fa_p_bypass",
                build_name="fa_p_bypass",
                x_dim=16,
                y_dim=16,
                test_modules=["tests.test_fa_p_bypass"],
                hdl_toplevel="FA_P_BYPASS_REAL",
                seeds=[default_seed],
            )
        ]
    if suite == "fa_shared_gemm":
        return [
            RunConfig(
                name="fa_shared_gemm",
                build_name="fa_shared_gemm",
                x_dim=16,
                y_dim=16,
                test_modules=["tests.test_fa_shared_gemm"],
                hdl_toplevel="FA_QK_PV_SHARED_CORE_SIM",
                seeds=[default_seed],
            )
        ]
    if suite == "fa_oacc_update":
        return [
            RunConfig(
                name="fa_oacc_update",
                build_name="fa_oacc_update",
                x_dim=16,
                y_dim=16,
                test_modules=["tests.test_fa_oacc_update"],
                hdl_toplevel="FA_OACC_UPDATE_SIM",
                seeds=[default_seed],
            )
        ]
    raise SystemExit(f"unsupported suite {suite!r}")


def junit_failure_counts(results_xml: Path) -> tuple[int, int]:
    try:
        tree = ET.parse(results_xml)
    except (FileNotFoundError, ET.ParseError):
        return 1, 1
    root = tree.getroot()
    failures = 0
    errors = 0
    for suite in root.iter("testsuite"):
        if "failures" in suite.attrib:
            failures += int(suite.attrib.get("failures", "0"))
        else:
            failures += len(suite.findall("./testcase/failure"))
        if "errors" in suite.attrib:
            errors += int(suite.attrib.get("errors", "0"))
        else:
            errors += len(suite.findall("./testcase/error"))
    return failures, errors


def run_case(
    sim_name: str,
    suite_name: str,
    waves: bool,
    verbose: bool,
    config: RunConfig,
    target: str = APP_TARGET_FA,
    options: Optional[RunOptions] = None,
) -> tuple[List[Path], List[Path]]:
    del target
    if options is None:
        options = RunOptions()
    if get_runner is None:
        raise SystemExit(
            "cocotb_tools is not installed for the selected Python interpreter. "
            f"Import error: {IMPORT_ERROR}."
        )

    params = {
        "DATA_WIDTH": 32,
        "GEMM_X_DIM": config.x_dim,
        "GEMM_Y_DIM": config.y_dim,
        "EXT_ADDR_W": 32,
        "DMA_BEATS_W": 16,
        "LUT_DEPTH": 8,
        "A_BANK_DEPTH": 16,
        "B_BANK_DEPTH": 16,
        "M_BANK_DEPTH": 16,
        "A_LOAD_LANES": 1,
        "B_LOAD_LANES": 1,
        "M_WRITE_LANES": 1,
        "M_EXPORT_LANES": 1,
        "M_PHYSICAL_COPIES": 3,
    }
    if config.rtl_params:
        params.update(config.rtl_params)
    if hdl_toplevel_supports_stream_params(config.hdl_toplevel):
        params.setdefault("STREAM_CHANNELS", 1)
        params.setdefault("S_AXIS_CHANNEL_WIDTH", max(int(params["A_LOAD_LANES"]), int(params["B_LOAD_LANES"])) * int(params["DATA_WIDTH"]))
        params.setdefault("M_AXIS_CHANNEL_WIDTH", int(params["M_EXPORT_LANES"]) * int(params["DATA_WIDTH"]))

    runner = get_runner(normalize_sim_name(sim_name))
    build_dir = BUILD_ROOT / (config.build_name or config.name)
    if build_dir.exists() and not options.keep_build:
        shutil.rmtree(build_dir)
    build_dir.mkdir(parents=True, exist_ok=True)
    sync_tests_into_build(build_dir)

    build_args = ["-Wall", *(config.build_args or [])]
    if normalize_sim_name(sim_name) == "verilator":
        build_args.append("-Wno-fatal")
    build_meta = build_metadata(sim_name, config, params, build_args, waves)
    reuse_build = options.keep_build and not options.force_rebuild and can_reuse_build(build_dir, sim_name, config.hdl_toplevel, build_meta)
    if reuse_build:
        prime_runner_for_reused_build(runner, rtl_sources(), params)
        print(f"[build-reuse] {config.name}: reusing {build_dir}")
    else:
        runner.build(
            sources=rtl_sources(),
            includes=[RTL_DIR],
            hdl_toplevel=config.hdl_toplevel,
            parameters=params,
            build_args=build_args,
            build_dir=build_dir,
            always=options.force_rebuild,
            timescale=DEFAULT_TIMESCALE,
            waves=waves,
            verbose=verbose,
            log_file=LOG_ROOT / f"{config.name}.build.log",
        )
        write_build_metadata(build_dir, build_meta)

    seeds = config.seeds if config.seeds is not None else [DEFAULT_SEED]
    for seed in seeds:
        selected_test_modules = narrow_test_modules(config.test_modules, options.testcase_names)
        test_suffix = f"{config.name}_seed{seed}"
        results_xml = RESULTS_ROOT / f"{test_suffix}.xml"
        log_file = LOG_ROOT / f"{test_suffix}.test.log"
        test_dir = build_dir / f"seed_{seed}"
        if test_dir.exists():
            shutil.rmtree(test_dir)
        test_dir.mkdir(parents=True, exist_ok=True)
        sync_tests_into_dir(test_dir)

        existing_pythonpath = os.getenv("PYTHONPATH", "")
        pythonpath_entries = [str(REPO_ROOT), str(COCOTB_ROOT)]
        if existing_pythonpath:
            pythonpath_entries.append(existing_pythonpath)
        extra_env = {
            "PYTHONPATH": os.pathsep.join(pythonpath_entries),
            "FA_TEST_SEED": str(seed),
            "FA_SUITE_NAME": suite_name,
            "FA_RUN_NAME": config.name,
            "FA_TOPLEVEL": config.hdl_toplevel,
        }
        if config.extra_env:
            extra_env.update(config.extra_env)

        runner.test(
            test_module=selected_test_modules,
            hdl_toplevel=config.hdl_toplevel,
            seed=seed,
            extra_env=extra_env,
            build_dir=build_dir,
            test_dir=test_dir,
            results_xml=str(results_xml),
            waves=waves,
            verbose=verbose,
            timescale=DEFAULT_TIMESCALE,
            log_file=log_file,
            test_filter=options.test_filter,
        )

        failures, errors = junit_failure_counts(results_xml)
        if failures or errors:
            raise SystemExit(
                f"{config.name}: cocotb reported {failures} failure(s) and {errors} error(s); "
                f"see {log_file}"
            )

    return [], []


def ensure_dirs() -> None:
    for path in (BUILD_ROOT, RESULTS_ROOT, LOG_ROOT, COVERAGE_ROOT):
        path.mkdir(parents=True, exist_ok=True)


def main() -> None:
    args = parse_args()
    sim_name = resolve_sim_name(args.sim)
    test_filter, testcase_names = resolve_test_selection(args.test_filter, args.testcase)
    options = RunOptions(
        keep_build=args.keep_build,
        force_rebuild=args.rebuild,
        test_filter=test_filter,
        testcase_names=testcase_names,
    )
    ensure_dirs()
    for config in suite_configs(args.suite, args.seed, args.target):
        run_case(sim_name, args.suite, args.waves, args.verbose, config, args.target, options)


if __name__ == "__main__":
    main()
