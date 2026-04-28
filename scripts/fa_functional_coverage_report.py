#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
COCOTB_ROOT = REPO_ROOT / "sim" / "cocotb"
if str(COCOTB_ROOT) not in sys.path:
    sys.path.insert(0, str(COCOTB_ROOT))

from tests.fa_functional_coverage import validate_model, write_reports  # noqa: E402


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Merge FA functional coverage raw reports")
    parser.add_argument("--raw-dir", default=COCOTB_ROOT / "coverage" / "functional" / "raw", type=Path)
    parser.add_argument("--out-dir", default=COCOTB_ROOT / "coverage" / "functional", type=Path)
    parser.add_argument("--min-functional-pct", default=None, type=float, help="Optional report-only threshold gate")
    parser.add_argument("--check-model-only", action="store_true", help="Validate coverage model and exit")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    validate_model()
    if args.check_model_only:
        print("functional coverage model OK")
        return
    json_path, md_path, report = write_reports(args.raw_dir, args.out_dir)
    totals = report["totals"]
    print(
        f"functional coverage: {totals['hit']}/{totals['bins']} bins "
        f"({totals['percent']:.2f}%), reports: {totals['raw_reports']}"
    )
    print(f"wrote {json_path}")
    print(f"wrote {md_path}")
    if args.min_functional_pct is not None and totals["percent"] < args.min_functional_pct:
        raise SystemExit(
            f"functional coverage {totals['percent']:.2f}% is below "
            f"{args.min_functional_pct:.2f}%"
        )


if __name__ == "__main__":
    main()
