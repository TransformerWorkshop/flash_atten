from __future__ import annotations

import atexit
import json
import os
from collections import Counter, defaultdict
from pathlib import Path
from typing import Iterable


_declared_bins: set[str] = set()
_bin_hits: Counter[str] = Counter()
_metrics: dict[str, list[int]] = defaultdict(list)
_cases: list[dict[str, object]] = []
_written = False


def declare_bins(names: Iterable[str]) -> None:
    _declared_bins.update(names)


def hit(name: str, amount: int = 1) -> None:
    _declared_bins.add(name)
    _bin_hits[name] += amount


def sample_metric(name: str, value: int) -> None:
    _metrics[name].append(int(value))


def record_case(name: str, **details: object) -> None:
    entry = {"name": name}
    entry.update(details)
    _cases.append(entry)


def _coverage_dir() -> Path:
    env_dir = os.getenv("TPU_FUNC_COV_DIR")
    if env_dir:
        return Path(env_dir)
    return Path(__file__).resolve().parents[1] / "coverage" / "latest"


def _metric_summary(values: list[int]) -> dict[str, float | int]:
    if not values:
        return {"count": 0}
    return {
        "count": len(values),
        "min": min(values),
        "max": max(values),
        "avg": sum(values) / len(values),
    }


def write_reports() -> None:
    global _written
    if _written:
        return
    _written = True

    out_dir = _coverage_dir()
    out_dir.mkdir(parents=True, exist_ok=True)

    hit_bins = sum(1 for name in _declared_bins if _bin_hits.get(name, 0) > 0)
    total_bins = len(_declared_bins)
    summary = {
        "declared_bins": sorted(_declared_bins),
        "bin_hits": {name: _bin_hits.get(name, 0) for name in sorted(_declared_bins)},
        "hit_bins": hit_bins,
        "total_bins": total_bins,
        "coverage_ratio": (hit_bins / total_bins) if total_bins else 1.0,
        "metrics": {name: _metric_summary(values) for name, values in sorted(_metrics.items())},
        "cases": _cases,
    }

    (out_dir / "functional_coverage.json").write_text(
        json.dumps(summary, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    lines = [
        "# Functional Coverage",
        "",
        f"- Hit bins: {hit_bins}/{total_bins}",
        f"- Coverage ratio: {summary['coverage_ratio']:.2%}",
        f"- Recorded cases: {len(_cases)}",
        "",
        "## Bins",
        "",
        "| Bin | Hits |",
        "| --- | ---: |",
    ]
    for name in sorted(_declared_bins):
        lines.append(f"| `{name}` | {_bin_hits.get(name, 0)} |")

    lines.extend(["", "## Metrics", "", "| Metric | Count | Min | Max | Avg |", "| --- | ---: | ---: | ---: | ---: |"])
    for name, values in sorted(_metrics.items()):
        info = _metric_summary(values)
        lines.append(
            f"| `{name}` | {info['count']} | {info.get('min', '-')} | {info.get('max', '-')} | "
            f"{info.get('avg', '-')} |"
        )

    if _cases:
        lines.extend(["", "## Cases", "", "| Name | Details |", "| --- | --- |"])
        for case in _cases:
            name = case["name"]
            details = ", ".join(f"{key}={value}" for key, value in case.items() if key != "name")
            lines.append(f"| `{name}` | {details} |")

    (out_dir / "functional_coverage.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


atexit.register(write_reports)
