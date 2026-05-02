from __future__ import annotations

import inspect
import json
import os
import re
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping


SCHEMA_VERSION = 2


@dataclass(frozen=True)
class CoverageBin:
    bin_id: str
    category: str
    description: str
    active: bool = True


ACTIVE_COVERAGE_BINS: tuple[CoverageBin, ...] = (
    CoverageBin("mode.causal", "Core mode", "Causal attention run completed or started."),
    CoverageBin("mode.noncausal", "Core mode", "Non-causal attention run completed or started."),
    CoverageBin("shape.single_tile", "Numeric shape", "Single Q/K/V tile scenario exercised."),
    CoverageBin("shape.full_sequence", "Numeric shape", "Full 256-row sequence scenario exercised."),
    CoverageBin("shape.q_row.first", "Numeric shape", "Q row window at the start of the sequence exercised."),
    CoverageBin("shape.q_row.middle", "Numeric shape", "Q row window in the middle of the sequence exercised."),
    CoverageBin("shape.q_row.last", "Numeric shape", "Q row window at the end of the sequence exercised."),
    CoverageBin("mask.causal_boundary", "Numeric shape", "Causal mask boundary exercised."),
    CoverageBin("csr.programming.basic", "CSR", "Common CSR programming sequence exercised."),
    CoverageBin("csr.start_done", "CSR", "Start-to-done status path exercised."),
    CoverageBin("csr.byte_counters_exact", "CSR", "Read/write byte counters checked exactly."),
    CoverageBin("csr.soft_reset", "CSR", "Soft reset path exercised."),
    CoverageBin("csr.start_while_busy", "CSR", "Start command while busy is ignored."),
    CoverageBin("axi.read_burst", "AXI", "AXI read burst path exercised."),
    CoverageBin("axi.write_burst", "AXI", "AXI write burst path exercised."),
    CoverageBin("axi.max_read_burst", "AXI", "Maximum-length AXI read burst exercised."),
    CoverageBin("axi.max_write_burst", "AXI", "Maximum-length AXI write burst exercised."),
    CoverageBin("axi.read_backpressure", "AXI", "AXI read address/data backpressure exercised."),
    CoverageBin("axi.write_backpressure", "AXI", "AXI write address/data backpressure exercised."),
    CoverageBin("axi.response_backpressure", "AXI", "AXI write response backpressure exercised."),
    CoverageBin("axi.alignment_error", "AXI", "AXI top alignment error path exercised."),
    CoverageBin("axi.soft_reset_mid_transfer", "AXI", "AXI top soft reset during transfer exercised."),
    CoverageBin("axi.full_sequence", "AXI", "AXI full-sequence numeric path exercised."),
    CoverageBin("axi.no_extra_after_done", "AXI", "No extra AXI traffic or byte-counter change after done."),
    CoverageBin("axi.read_fault_early_last", "AXI", "Early AXI RLAST fault reports error."),
    CoverageBin("axi.read_fault_missing_final_last", "AXI", "Missing final AXI RLAST fault reports error."),
    CoverageBin("row_state.init", "Row-state", "Row-state init path exercised."),
    CoverageBin("row_state.valid_row", "Row-state", "Valid row update path exercised."),
    CoverageBin("row_state.masked_row", "Row-state", "Fully masked row update path exercised."),
    CoverageBin("row_state.accumulate", "Row-state", "Row-state accumulation/update path exercised."),
    CoverageBin("module.p_bypass", "Submodule", "P-bypass read mapping exercised."),
    CoverageBin("module.shared_gemm", "Submodule", "Shared GEMM request path exercised."),
    CoverageBin("module.shared_gemm_qk_priority", "Submodule", "Shared GEMM QK priority arbitration exercised."),
    CoverageBin("module.shared_gemm_pv_path", "Submodule", "Shared GEMM PV path exercised."),
    CoverageBin("module.oacc_update", "Submodule", "OACC update path exercised."),
    CoverageBin("module.oacc_rounding", "Submodule", "OACC rounding boundaries exercised."),
    CoverageBin("module.oacc_saturation", "Submodule", "OACC saturation boundaries exercised."),
)

LEGACY_COVERAGE_BINS: tuple[CoverageBin, ...] = (
    CoverageBin("csr.alignment_error", "Legacy CSR", "Legacy duplicate of current AXI-top alignment error bin.", active=False),
    CoverageBin("dma.descriptor_counts_exact", "Legacy descriptor DMA", "Descriptor count check for removed descriptor-level harness.", active=False),
    CoverageBin("dma.descriptor_order_qkv", "Legacy descriptor DMA", "Q/K/V descriptor order check for removed descriptor-level harness.", active=False),
    CoverageBin("protocol.no_extra_dma_after_done", "Legacy descriptor DMA", "Legacy descriptor-level no-extra-DMA-after-done bin.", active=False),
    CoverageBin("protocol.read_fault_early_last", "Legacy descriptor DMA", "Legacy descriptor-level early read-last fault bin.", active=False),
    CoverageBin("protocol.read_fault_missing_final_last", "Legacy descriptor DMA", "Legacy descriptor-level missing final read-last fault bin.", active=False),
    CoverageBin("stream.constant_ready", "Legacy stream flow", "Removed stream-ready harness bin.", active=False),
    CoverageBin("stream.read_desc_backpressure", "Legacy stream flow", "Removed read descriptor ready backpressure bin.", active=False),
    CoverageBin("stream.read_data_backpressure", "Legacy stream flow", "Removed read data valid backpressure bin.", active=False),
    CoverageBin("stream.write_desc_backpressure", "Legacy stream flow", "Removed write descriptor ready backpressure bin.", active=False),
    CoverageBin("stream.write_data_backpressure", "Legacy stream flow", "Removed write data ready backpressure bin.", active=False),
    CoverageBin("stream.valid_hold", "Legacy stream flow", "Removed stream valid/data hold bin.", active=False),
)

COVERAGE_BINS: tuple[CoverageBin, ...] = ACTIVE_COVERAGE_BINS + LEGACY_COVERAGE_BINS
ACTIVE_COVERAGE_MODEL: dict[str, CoverageBin] = {coverage_bin.bin_id: coverage_bin for coverage_bin in ACTIVE_COVERAGE_BINS}
COVERAGE_MODEL: dict[str, CoverageBin] = {coverage_bin.bin_id: coverage_bin for coverage_bin in COVERAGE_BINS}
LEGACY_COVERAGE_MODEL: dict[str, CoverageBin] = {coverage_bin.bin_id: coverage_bin for coverage_bin in LEGACY_COVERAGE_BINS}


def env_flag(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() not in {"0", "false", "no", "off"}


def sanitize_token(value: str) -> str:
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", value).strip("_") or "unknown"


def discover_case_name() -> str:
    for frame_info in inspect.stack():
        if frame_info.function.startswith("test_"):
            return frame_info.function
    return os.getenv("COCOTB_TESTCASE", "unknown_test")


def jsonable(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, Mapping):
        return {str(key): jsonable(val) for key, val in sorted(value.items(), key=lambda item: str(item[0]))}
    if isinstance(value, (list, tuple, set)):
        return [jsonable(item) for item in value]
    return str(value)


class FunctionalCoverageRecorder:
    def __init__(
        self,
        *,
        case_name: str | None = None,
        suite_name: str | None = None,
        run_name: str | None = None,
        seed: str | int | None = None,
        enabled: bool | None = None,
        output_dir: str | Path | None = None,
    ) -> None:
        self.enabled = env_flag("FA_FUNC_COV", False) if enabled is None else enabled
        self.suite_name = suite_name or os.getenv("FA_SUITE_NAME", "unknown_suite")
        self.run_name = run_name or os.getenv("FA_RUN_NAME", "unknown_run")
        self.case_name = case_name or discover_case_name()
        self.seed = str(seed if seed is not None else os.getenv("FA_TEST_SEED", "unknown_seed"))
        self.toplevel = os.getenv("FA_TOPLEVEL", "unknown_toplevel")
        self.output_dir = Path(output_dir or os.getenv("FA_FUNC_COV_DIR", "coverage/functional/raw"))
        self._hits: dict[str, list[dict[str, Any]]] = {}

    def hit(self, bin_id: str, evidence: Mapping[str, Any] | None = None, **fields: Any) -> None:
        if bin_id not in COVERAGE_MODEL:
            raise KeyError(f"unknown functional coverage bin: {bin_id}")
        if not self.enabled:
            return
        payload: dict[str, Any] = {}
        if evidence:
            payload.update(evidence)
        payload.update(fields)
        self._hits.setdefault(bin_id, []).append(jsonable(payload))

    def hit_many(self, bin_ids: Iterable[str], evidence: Mapping[str, Any] | None = None, **fields: Any) -> None:
        for bin_id in bin_ids:
            self.hit(bin_id, evidence=evidence, **fields)

    def dump(self) -> Path | None:
        if not self.enabled:
            return None
        target_dir = self.output_dir / sanitize_token(self.suite_name) / sanitize_token(self.run_name)
        target_dir.mkdir(parents=True, exist_ok=True)
        target = target_dir / f"{sanitize_token(self.case_name)}_seed{sanitize_token(self.seed)}.json"
        payload = {
            "schema_version": SCHEMA_VERSION,
            "suite": self.suite_name,
            "run": self.run_name,
            "case": self.case_name,
            "seed": self.seed,
            "toplevel": self.toplevel,
            "generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "hits": [
                {"bin_id": bin_id, "evidence": evidence}
                for bin_id, evidences in sorted(self._hits.items())
                for evidence in evidences
            ],
        }
        target.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        return target


def record_module_hits(bin_ids: Iterable[str], evidence: Mapping[str, Any] | None = None, **fields: Any) -> None:
    recorder = FunctionalCoverageRecorder(case_name=discover_case_name())
    recorder.hit_many(bin_ids, evidence=evidence, **fields)
    recorder.dump()


def load_raw_reports(raw_dir: Path) -> list[dict[str, Any]]:
    reports: list[dict[str, Any]] = []
    for path in sorted(raw_dir.rglob("*.json")):
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            continue
        if payload.get("schema_version") == SCHEMA_VERSION and isinstance(payload.get("hits"), list):
            payload["_path"] = str(path)
            reports.append(payload)
    return reports


def merge_raw_reports(raw_dir: Path) -> dict[str, Any]:
    reports = load_raw_reports(raw_dir)
    bins: dict[str, dict[str, Any]] = {
        bin_id: {
            **asdict(coverage_bin),
            "hit": False,
            "hits": [],
        }
        for bin_id, coverage_bin in sorted(ACTIVE_COVERAGE_MODEL.items())
    }
    unknown_hits: list[dict[str, Any]] = []
    legacy_hits: list[dict[str, Any]] = []
    for report in reports:
        context = {
            "suite": report.get("suite"),
            "run": report.get("run"),
            "case": report.get("case"),
            "seed": report.get("seed"),
            "path": report.get("_path"),
        }
        for hit in report.get("hits", []):
            bin_id = hit.get("bin_id")
            record = {**context, "evidence": hit.get("evidence", {})}
            if bin_id in bins:
                bins[bin_id]["hit"] = True
                bins[bin_id]["hits"].append(record)
            elif bin_id in LEGACY_COVERAGE_MODEL:
                legacy_hits.append({"bin_id": bin_id, **record})
            else:
                unknown_hits.append({"bin_id": bin_id, **record})

    hit_bins = [bin_id for bin_id, data in bins.items() if data["hit"]]
    missing_bins = [bin_id for bin_id, data in bins.items() if not data["hit"]]
    total_bins = len(bins)
    hit_count = len(hit_bins)
    percent = (100.0 * hit_count / total_bins) if total_bins else 0.0
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "raw_dir": str(raw_dir),
        "totals": {
            "bins": total_bins,
            "hit": hit_count,
            "missing": len(missing_bins),
            "percent": percent,
            "raw_reports": len(reports),
            "unknown_hits": len(unknown_hits),
            "legacy_hits": len(legacy_hits),
        },
        "coverage_model": {
            "active_bins": len(ACTIVE_COVERAGE_MODEL),
            "legacy_bins": len(LEGACY_COVERAGE_MODEL),
        },
        "hit_bins": hit_bins,
        "missing_bins": missing_bins,
        "legacy_hits": legacy_hits,
        "unknown_hits": unknown_hits,
        "bins": bins,
    }


def markdown_report(report: Mapping[str, Any]) -> str:
    totals = report["totals"]
    lines = [
        "# FA Functional Coverage",
        "",
        f"- Generated: {report['generated_at_utc']}",
        f"- Raw reports: {totals['raw_reports']}",
        f"- Coverage: {totals['hit']}/{totals['bins']} bins ({totals['percent']:.2f}%)",
        f"- Missing bins: {totals['missing']}",
        f"- Legacy hits excluded from denominator: {totals['legacy_hits']}",
        "",
    ]

    categories = sorted({data["category"] for data in report["bins"].values()})
    for category in categories:
        lines.extend([f"## {category}", "", "| Bin | Status | Evidence |", "| --- | --- | --- |"])
        for bin_id, data in sorted(report["bins"].items()):
            if data["category"] != category:
                continue
            status = "hit" if data["hit"] else "missing"
            evidence = ""
            if data["hits"]:
                first_hit = data["hits"][0]
                evidence = f"{first_hit['case']} seed={first_hit['seed']}"
                if len(data["hits"]) > 1:
                    evidence += f" (+{len(data['hits']) - 1})"
            lines.append(f"| `{bin_id}` | {status} | {evidence} |")
        lines.append("")

    if report["unknown_hits"]:
        lines.extend(["## Unknown Hits", "", "| Bin | Case | Path |", "| --- | --- | --- |"])
        for hit in report["unknown_hits"]:
            lines.append(f"| `{hit.get('bin_id')}` | {hit.get('case')} | {hit.get('path')} |")
        lines.append("")
    if report["legacy_hits"]:
        lines.extend(["## Legacy Hits", "", "These bins are accepted for old raw reports but excluded from the active coverage denominator.", "", "| Bin | Case | Path |", "| --- | --- | --- |"])
        for hit in report["legacy_hits"]:
            lines.append(f"| `{hit.get('bin_id')}` | {hit.get('case')} | {hit.get('path')} |")
        lines.append("")
    return "\n".join(lines)


def write_reports(raw_dir: Path, out_dir: Path) -> tuple[Path, Path, dict[str, Any]]:
    out_dir.mkdir(parents=True, exist_ok=True)
    report = merge_raw_reports(raw_dir)
    json_path = out_dir / "functional_coverage.json"
    md_path = out_dir / "functional_coverage.md"
    json_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    md_path.write_text(markdown_report(report), encoding="utf-8")
    return json_path, md_path, report


def validate_model() -> None:
    if len(COVERAGE_MODEL) != len(COVERAGE_BINS):
        raise SystemExit("functional coverage model contains duplicate bin IDs")
    if any(not coverage_bin.active for coverage_bin in ACTIVE_COVERAGE_BINS):
        raise SystemExit("active functional coverage model contains inactive bins")
    if any(coverage_bin.active for coverage_bin in LEGACY_COVERAGE_BINS):
        raise SystemExit("legacy functional coverage model contains active bins")
