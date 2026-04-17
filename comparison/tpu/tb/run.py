from __future__ import annotations

import argparse
import os
from pathlib import Path
import re

try:
    from cocotb_tools.runner import get_runner
except ModuleNotFoundError as exc:
    get_runner = None
    IMPORT_ERROR = exc
else:
    IMPORT_ERROR = None


TB_DIR = Path(__file__).resolve().parent
TPU_DIR = TB_DIR.parent
DEFAULT_RTL_DIR = TPU_DIR / "rtl"
TEST_DIR = TB_DIR / "tests"
BUILD_DIR = TB_DIR / "build"
RESULTS_DIR = TB_DIR / "results"
LOG_DIR = TB_DIR / "logs"
TOPLEVEL = "tb_tpu_top_64bit"
TEST_MODULE = "tests.test_tpu_top_64bit"
SMOKE_FILTER = (
    "test_default_status_and_reset_defaults|"
    "test_axil_staggered_write_and_soft_reset|"
    "test_load_abc_and_observe_writeback_activity"
)
NUMERIC_FILTER = "test_numeric_"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run comparison/tpu cocotb verification")
    parser.add_argument("mode", choices=["build", "smoke", "coverage", "numeric"], nargs="?", default="smoke")
    parser.add_argument("--sim", default=os.getenv("SIM", "verilator"))
    parser.add_argument("--testcase", default=os.getenv("TESTCASE"))
    parser.add_argument("--rtl-root", default=str(DEFAULT_RTL_DIR))
    parser.add_argument("--variant", default="local")
    parser.add_argument("--pe-size", type=int, default=int(os.getenv("PE_SIZE", "16")))
    parser.add_argument("--axi-data-width", type=int, default=int(os.getenv("AXI_DATA_WIDTH", "128")))
    parser.add_argument("--ram-data-width", type=int, default=int(os.getenv("RAM_DATA_WIDTH", "64")))
    parser.add_argument("--waves", action="store_true", default=bool(int(os.getenv("WAVES", "0"))))
    parser.add_argument("--verbose", action="store_true", default=bool(int(os.getenv("VERBOSE", "0"))))
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


def ensure_dirs() -> None:
    for path in (BUILD_DIR, RESULTS_DIR, LOG_DIR):
        path.mkdir(parents=True, exist_ok=True)


def sanitize_name(text: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_.-]+", "_", text.strip())


def rtl_sources(rtl_dir: Path) -> list[Path]:
    sources = sorted(rtl_dir.rglob("*.v"))
    sources.append(TB_DIR / "tb_tpu_top_64bit.v")
    return sources


def detect_tpu_defines(rtl_dir: Path) -> dict[str, int]:
    top_path = rtl_dir / "tpu_top.v"
    if not top_path.is_file():
        return {}

    top_text = top_path.read_text(encoding="utf-8", errors="ignore")
    defines: dict[str, int] = {}
    if re.search(r"\bdbg_m00_awvalid\b", top_text):
        defines["TPU_HAS_DBG_BRANCH_PORTS"] = 1
    if re.search(r"\bm_axi_rd_arid\b", top_text):
        defines["TPU_HAS_RD_MASTER_PORTS"] = 1
    if re.search(r"\blegacy_load_done\b", top_text):
        defines["TPU_OBS_LOAD_DONE_USES_LEGACY_NAME"] = 1
    return defines


def main() -> None:
    args = parse_args()
    ensure_dirs()
    rtl_dir = Path(args.rtl_root).resolve()
    if not rtl_dir.is_dir():
        raise SystemExit(f"RTL root does not exist: {rtl_dir}")

    if get_runner is None:
        raise SystemExit(
            "cocotb_tools is not installed for the selected Python interpreter. "
            f"Import error: {IMPORT_ERROR}"
        )

    sim_name = normalize_sim_name(args.sim)
    runner = get_runner(sim_name)
    variant_name = sanitize_name(args.variant or rtl_dir.parent.name or "rtl")
    build_name = (
        f"{sim_name}_{variant_name}_pe{args.pe_size}_axi{args.axi_data_width}_ram{args.ram_data_width}_{args.mode}"
    )
    build_dir = BUILD_DIR / build_name
    test_dir = build_dir / "run"
    results_xml = RESULTS_DIR / f"{build_name}.xml"

    build_args = ["-Wall"]
    if sim_name == "verilator":
        build_args.extend(["-Wno-fatal"])

    runner.build(
        sources=rtl_sources(rtl_dir),
        includes=[rtl_dir, TB_DIR],
        defines=detect_tpu_defines(rtl_dir),
        hdl_toplevel=TOPLEVEL,
        parameters={
            "PE_SIZE": args.pe_size,
            "AXI_DATA_WIDTH": args.axi_data_width,
            "RAM_DATA_WIDTH": args.ram_data_width,
        },
        build_dir=build_dir,
        build_args=build_args,
        always=True,
        waves=args.waves,
        verbose=args.verbose,
        timescale=("1ns", "1ps"),
        log_file=LOG_DIR / f"{build_name}.build.log",
    )

    if args.mode == "build":
        return

    existing_pythonpath = os.getenv("PYTHONPATH", "")
    extra_env = {
        "PYTHONPATH": str(TB_DIR) if not existing_pythonpath else f"{TB_DIR}{os.pathsep}{existing_pythonpath}",
        "TPU_VARIANT": variant_name,
        "TPU_RTL_ROOT": str(rtl_dir),
        "TPU_PE_SIZE": str(args.pe_size),
        "TPU_AXI_DATA_WIDTH": str(args.axi_data_width),
        "TPU_RAM_DATA_WIDTH": str(args.ram_data_width),
    }
    if args.mode in {"smoke", "coverage", "numeric"}:
        extra_env["TPU_FUNC_COV_DIR"] = str(TB_DIR / "coverage" / build_name)

    test_filter = None
    if not args.testcase:
        if args.mode in {"smoke", "coverage"}:
            test_filter = SMOKE_FILTER
        elif args.mode == "numeric":
            test_filter = NUMERIC_FILTER

    runner.test(
        test_module=TEST_MODULE,
        testcase=args.testcase,
        test_filter=test_filter,
        hdl_toplevel=TOPLEVEL,
        build_dir=build_dir,
        test_dir=test_dir,
        results_xml=str(results_xml),
        waves=args.waves,
        verbose=args.verbose,
        extra_env=extra_env,
        timescale=("1ns", "1ps"),
        log_file=LOG_DIR / f"{build_name}.test.log",
    )


if __name__ == "__main__":
    main()
