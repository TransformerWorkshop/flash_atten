from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, List, Mapping, Optional

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
    "fa_rowstate_profile",
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
    coverage: bool = False
    coverage_mode: str = "full"


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
    parser.add_argument("--coverage", action="store_true", default=bool(int(os.getenv("COVERAGE", "0"))), help="Enable simulator code coverage collection")
    parser.add_argument(
        "--coverage-mode",
        choices=("full", "line", "line-toggle"),
        default=os.getenv("COVERAGE_MODE", "full"),
        help="Verilator coverage mode used when --coverage is enabled",
    )
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


def sanitized_filename(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip("_") or "run"


def relpath(path: Path) -> str:
    try:
        return str(path.resolve().relative_to(REPO_ROOT))
    except ValueError:
        return str(path.resolve())


def coverage_build_name(base_name: str, options: RunOptions) -> str:
    if not options.coverage:
        return base_name
    return f"{base_name}_cov_{sanitized_filename(options.coverage_mode)}"


def coverage_build_args(mode: str) -> List[str]:
    if mode == "full":
        return ["--coverage"]
    if mode == "line":
        return ["--coverage-line"]
    if mode == "line-toggle":
        return ["--coverage-line", "--coverage-toggle"]
    raise ValueError(f"unsupported coverage mode: {mode}")


def coverage_selection_suffix(options: RunOptions) -> str:
    if options.testcase_names:
        return "_tc_" + sanitized_filename("_".join(options.testcase_names))
    if options.test_filter:
        return "_tf_" + sanitized_filename(options.test_filter)
    return ""


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


def code_coverage_dirs(suite_name: str) -> Mapping[str, Path]:
    return {
        "root": COVERAGE_ROOT / "code",
        "raw": COVERAGE_ROOT / "code" / "raw" / sanitized_filename(suite_name),
        "merged": COVERAGE_ROOT / "code" / "merged",
        "lcov": COVERAGE_ROOT / "code" / "lcov",
        "annotated": COVERAGE_ROOT / "code" / "annotated" / sanitized_filename(suite_name),
        "summary": COVERAGE_ROOT / "code" / "summary",
    }


def prepare_code_coverage_suite(suite_name: str) -> None:
    dirs = code_coverage_dirs(suite_name)
    for path in dirs.values():
        if path.name == sanitized_filename(suite_name) and path.exists():
            shutil.rmtree(path)
        path.mkdir(parents=True, exist_ok=True)


def code_coverage_raw_path(suite_name: str, config: RunConfig, seed: int, options: RunOptions) -> Path:
    filename = f"{sanitized_filename(config.name)}_seed{seed}{coverage_selection_suffix(options)}.dat"
    return code_coverage_dirs(suite_name)["raw"] / filename


def candidate_coverage_files(raw_path: Path, test_dir: Path, build_dir: Path) -> Iterable[Path]:
    yield raw_path
    yield test_dir / "coverage.dat"
    yield build_dir / "coverage.dat"
    yield COCOTB_ROOT / "coverage.dat"
    yield REPO_ROOT / "coverage.dat"
    yield Path.cwd() / "coverage.dat"
    yield from test_dir.rglob("coverage.dat")
    yield from build_dir.rglob("coverage.dat")


def collect_code_coverage_dat(raw_path: Path, test_dir: Path, build_dir: Path, run_started_ns: int) -> Path:
    if raw_path.exists() and raw_path.stat().st_size > 0:
        return raw_path

    candidates: List[Path] = []
    seen: set[Path] = set()
    for candidate in candidate_coverage_files(raw_path, test_dir, build_dir):
        try:
            resolved = candidate.resolve()
            stat = resolved.stat()
        except FileNotFoundError:
            continue
        if resolved in seen or stat.st_size <= 0:
            continue
        seen.add(resolved)
        if stat.st_mtime_ns >= run_started_ns - 1_000_000_000:
            candidates.append(resolved)
    if not candidates:
        raise SystemExit(f"coverage was enabled, but no coverage.dat was produced for {raw_path.name}")

    newest = max(candidates, key=lambda path: path.stat().st_mtime_ns)
    raw_path.parent.mkdir(parents=True, exist_ok=True)
    if newest != raw_path.resolve():
        shutil.copy2(newest, raw_path)
    if raw_path.stat().st_size <= 0:
        raise SystemExit(f"coverage file is empty: {raw_path}")
    return raw_path


def parse_lcov_line_coverage(info_path: Path) -> Mapping[str, Any]:
    totals = {"lines": 0, "covered": 0}
    files: dict[str, dict[str, Any]] = {}
    current_source: Optional[str] = None
    current_lines: dict[int, int] = {}

    def finish_record() -> None:
        nonlocal current_source, current_lines
        if current_source is None:
            current_lines = {}
            return
        line_total = len(current_lines)
        covered = sum(1 for count in current_lines.values() if count > 0)
        files[current_source] = {
            "lines": files.get(current_source, {}).get("lines", 0) + line_total,
            "covered": files.get(current_source, {}).get("covered", 0) + covered,
        }
        totals["lines"] += line_total
        totals["covered"] += covered
        current_source = None
        current_lines = {}

    try:
        lines = info_path.read_text(encoding="utf-8", errors="ignore").splitlines()
    except FileNotFoundError:
        return {"lines": 0, "covered": 0, "percent": 0.0, "files": {}}

    for line in lines:
        if line.startswith("SF:"):
            finish_record()
            current_source = line[3:]
        elif line.startswith("DA:"):
            fields = line[3:].split(",", 2)
            if len(fields) >= 2:
                try:
                    current_lines[int(fields[0])] = max(current_lines.get(int(fields[0]), 0), int(fields[1]))
                except ValueError:
                    continue
        elif line == "end_of_record":
            finish_record()
    finish_record()

    percent = (100.0 * totals["covered"] / totals["lines"]) if totals["lines"] else 0.0
    for file_data in files.values():
        file_data["percent"] = (100.0 * file_data["covered"] / file_data["lines"]) if file_data["lines"] else 0.0
    return {
        "lines": totals["lines"],
        "covered": totals["covered"],
        "percent": percent,
        "files": dict(sorted(files.items())),
    }


def run_verilator_coverage(args: List[str]) -> None:
    tool = shutil.which("verilator_coverage")
    if tool is None:
        raise SystemExit("verilator_coverage is required for --coverage but was not found in PATH")
    subprocess.run([tool, *args], check=True)


def finalize_code_coverage(suite_name: str, coverage_mode: str, raw_files: List[Path]) -> None:
    if not raw_files:
        return
    dirs = code_coverage_dirs(suite_name)
    for path in (dirs["merged"], dirs["lcov"], dirs["summary"]):
        path.mkdir(parents=True, exist_ok=True)
    if dirs["annotated"].exists():
        shutil.rmtree(dirs["annotated"])
    dirs["annotated"].mkdir(parents=True, exist_ok=True)

    suite_token = sanitized_filename(suite_name)
    merged_dat = dirs["merged"] / f"{suite_token}.dat"
    lcov_info = dirs["lcov"] / f"{suite_token}.info"
    raw_args = [str(path) for path in raw_files]
    run_verilator_coverage(["--write", str(merged_dat), *raw_args])
    run_verilator_coverage(["--write-info", str(lcov_info), *raw_args])
    run_verilator_coverage(["--annotate", str(dirs["annotated"]), *raw_args])

    line_coverage = parse_lcov_line_coverage(lcov_info)
    summary = {
        "schema_version": 1,
        "suite": suite_name,
        "coverage_mode": coverage_mode,
        "generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "raw_files": [relpath(path) for path in raw_files],
        "merged_dat": relpath(merged_dat),
        "lcov_info": relpath(lcov_info),
        "annotated_dir": relpath(dirs["annotated"]),
        "line_coverage": line_coverage,
    }
    summary_path = dirs["summary"] / f"{suite_token}.json"
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        f"[coverage] {suite_name}: {line_coverage['covered']}/{line_coverage['lines']} "
        f"lines covered ({line_coverage['percent']:.2f}%)"
    )


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
    if suite == "fa_rowstate_profile":
        return [
            RunConfig(
                name="fa_rowstate_profile",
                build_name="fa_rowstate_profile",
                x_dim=16,
                y_dim=16,
                test_modules=["tests.test_fa_baseline_perf_rowstate"],
                hdl_toplevel="FA_ROW_STATE_PROFILE_SIM",
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
    if options.coverage and normalize_sim_name(sim_name) != "verilator":
        raise SystemExit("--coverage is currently supported only with the Verilator simulator")
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
    build_name = coverage_build_name(config.build_name or config.name, options)
    build_dir = BUILD_ROOT / build_name
    if build_dir.exists() and not options.keep_build:
        shutil.rmtree(build_dir)
    build_dir.mkdir(parents=True, exist_ok=True)
    sync_tests_into_build(build_dir)

    build_args = ["-Wall", *(config.build_args or [])]
    if normalize_sim_name(sim_name) == "verilator":
        build_args.append("-Wno-fatal")
    if options.coverage:
        build_args.extend(coverage_build_args(options.coverage_mode))
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

    coverage_files: List[Path] = []
    seeds = config.seeds if config.seeds is not None else [DEFAULT_SEED]
    for seed in seeds:
        selected_test_modules = narrow_test_modules(config.test_modules, options.testcase_names)
        coverage_suffix = f"_cov_{sanitized_filename(options.coverage_mode)}" if options.coverage else ""
        test_suffix = f"{config.name}_seed{seed}{coverage_suffix}{coverage_selection_suffix(options)}"
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
        if os.getenv("FA_FUNC_COV"):
            extra_env["FA_FUNC_COV"] = os.getenv("FA_FUNC_COV", "1")
            extra_env["FA_FUNC_COV_DIR"] = os.getenv("FA_FUNC_COV_DIR", str(COVERAGE_ROOT / "functional" / "raw"))
        if config.extra_env:
            extra_env.update(config.extra_env)

        plusargs: List[str] = []
        raw_coverage_path: Optional[Path] = None
        if options.coverage:
            raw_coverage_path = code_coverage_raw_path(suite_name, config, seed, options).resolve()
            raw_coverage_path.parent.mkdir(parents=True, exist_ok=True)
            try:
                raw_coverage_path.unlink()
            except FileNotFoundError:
                pass
            plusargs.append(f"+verilator+coverage+file+{raw_coverage_path}")

        run_started_ns = time.time_ns()
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
            plusargs=plusargs,
        )

        failures, errors = junit_failure_counts(results_xml)
        if failures or errors:
            raise SystemExit(
                f"{config.name}: cocotb reported {failures} failure(s) and {errors} error(s); "
                f"see {log_file}"
            )
        if raw_coverage_path is not None:
            coverage_files.append(collect_code_coverage_dat(raw_coverage_path, test_dir, build_dir, run_started_ns))

    return coverage_files, []


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
        coverage=args.coverage,
        coverage_mode=args.coverage_mode,
    )
    ensure_dirs()
    if options.coverage:
        prepare_code_coverage_suite(args.suite)
    coverage_files: List[Path] = []
    for config in suite_configs(args.suite, args.seed, args.target):
        config_coverage, _ = run_case(sim_name, args.suite, args.waves, args.verbose, config, args.target, options)
        coverage_files.extend(config_coverage)
    if options.coverage:
        finalize_code_coverage(args.suite, options.coverage_mode, coverage_files)


if __name__ == "__main__":
    main()
