#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_WIDE_SWEEP_PATH = REPO_ROOT / "app" / "pt_tiled_gemm" / "out" / "multitile_sweep_pt_dma_top_v3_icarus_compact.json"
DEFAULT_STRICT_SWEEP_PATH = REPO_ROOT / "app" / "pt_tiled_gemm" / "out" / "multitile_sweep_pt_dma_top_v3_128b_strict_icarus_compact.json"

VALID_CHANNELS = (1, 2, 4)
VALID_FREQ_RATIOS = (1.0, 2.0)


def ceil_div(numer: int, denom: int) -> int:
	if denom <= 0:
		raise ValueError("denom must be > 0")
	return (numer + denom - 1) // denom


def ceil_div_float(numer: int, denom: float) -> int:
	if denom <= 0.0:
		raise ValueError("denom must be > 0")
	return int(math.ceil(numer / denom))


def pct(value: float) -> float:
	return value * 100.0


def format_bytes(value: int) -> str:
	if value >= 1024 * 1024:
		return f"{value / (1024 * 1024):.2f} MiB"
	if value >= 1024:
		return f"{value / 1024:.2f} KiB"
	return f"{value} B"


def format_ratio(value: float) -> str:
	return f"{pct(value):.1f}%"


def format_float(value: float) -> str:
	return f"{value:.3f}"


def speedup_ratio(baseline_cycles: int, candidate_cycles: int) -> float:
	if baseline_cycles <= 0 or candidate_cycles <= 0:
		raise ValueError("cycles must be > 0")
	return (baseline_cycles / candidate_cycles) - 1.0


def slowdown_ratio(candidate_cycles: int, baseline_cycles: int) -> float:
	if baseline_cycles <= 0 or candidate_cycles <= 0:
		raise ValueError("cycles must be > 0")
	return (candidate_cycles / baseline_cycles) - 1.0


@dataclass(frozen=True)
class TileGeometry:
	x_dim: int
	y_dim: int
	data_width: int
	a_load_lanes: int
	b_load_lanes: int
	m_write_lanes: int
	m_export_lanes: int
	word_bytes: int
	a_tile_bytes: int
	b_tile_bytes: int
	m_tile_bytes: int
	internal_bits: int


@dataclass(frozen=True)
class ProblemShape:
	m: int
	k: int
	n: int
	m_tiles: int
	k_tiles: int
	n_tiles: int
	output_tiles: int
	partial_products: int


@dataclass(frozen=True)
class ReuseConfig:
	reuse_a: int
	reuse_b: int
	forward_m: bool


@dataclass(frozen=True)
class TransportConfig:
	ps_pl_bits: int
	ps_pl_channels: int
	ps_pl_freq_ratio: float


@dataclass(frozen=True)
class MeasuredAnchor:
	target: str
	target_label: str
	done_cycles: int
	ops_per_cycle: float
	accept_to_resp_cycles: int
	resp_to_done_cycles: int
	export_beats: int
	command_count: int
	issued_command_count: int


@dataclass(frozen=True)
class ExternalTraffic:
	a_bytes: int
	b_bytes: int
	intermediate_m_bytes: int
	final_output_bytes: int
	total_bytes: int
	a_beats: int
	b_beats: int
	intermediate_m_beats: int
	final_output_beats: int
	total_beats: int
	ingress_bytes: int
	egress_bytes: int
	ingress_beats: int
	egress_beats: int
	ingress_cycles: int
	egress_cycles: int
	transport_cycles: int


@dataclass(frozen=True)
class Projection:
	supply_ratio: float
	lower_bound_cycles: int
	upper_bound_cycles: int
	non_hidden_transport_residue: int
	speedup_vs_strict_best_case: float
	speedup_vs_strict_worst_case: float
	slowdown_vs_wide_best_case: float
	slowdown_vs_wide_worst_case: float


@dataclass(frozen=True)
class EvaluationResult:
	input_config: dict[str, Any]
	geometry: TileGeometry
	shape: ProblemShape
	reuse: ReuseConfig
	transport: TransportConfig
	measured_anchors: dict[str, MeasuredAnchor]
	external_traffic: ExternalTraffic
	projection: Projection
	assumptions: list[str]

	def to_dict(self) -> dict[str, Any]:
		return asdict(self)


def build_geometry(args: argparse.Namespace) -> TileGeometry:
	if args.data_width <= 0 or (args.data_width % 8) != 0:
		raise ValueError("data width must be a positive multiple of 8")
	for name, lanes in (
		("a_load_lanes", args.a_load_lanes),
		("b_load_lanes", args.b_load_lanes),
		("m_write_lanes", args.m_write_lanes),
		("m_export_lanes", args.m_export_lanes),
	):
		if lanes <= 0:
			raise ValueError(f"{name} must be > 0")
	if args.x_dim <= 0 or args.y_dim <= 0:
		raise ValueError("x_dim and y_dim must be > 0")
	if (args.x_dim % args.a_load_lanes) != 0:
		raise ValueError(f"x_dim={args.x_dim} must be divisible by a_load_lanes={args.a_load_lanes}")
	if (args.y_dim % args.b_load_lanes) != 0:
		raise ValueError(f"y_dim={args.y_dim} must be divisible by b_load_lanes={args.b_load_lanes}")
	if (args.y_dim % args.m_write_lanes) != 0:
		raise ValueError(f"y_dim={args.y_dim} must be divisible by m_write_lanes={args.m_write_lanes}")
	if (args.y_dim % args.m_export_lanes) != 0:
		raise ValueError(f"y_dim={args.y_dim} must be divisible by m_export_lanes={args.m_export_lanes}")

	word_bytes = args.data_width // 8
	return TileGeometry(
		x_dim=args.x_dim,
		y_dim=args.y_dim,
		data_width=args.data_width,
		a_load_lanes=args.a_load_lanes,
		b_load_lanes=args.b_load_lanes,
		m_write_lanes=args.m_write_lanes,
		m_export_lanes=args.m_export_lanes,
		word_bytes=word_bytes,
		a_tile_bytes=args.x_dim * args.x_dim * word_bytes,
		b_tile_bytes=args.x_dim * args.y_dim * word_bytes,
		m_tile_bytes=args.x_dim * args.y_dim * word_bytes,
		internal_bits=max(args.a_load_lanes, args.b_load_lanes, args.m_write_lanes, args.m_export_lanes) * args.data_width,
	)


def build_shape(args: argparse.Namespace, geometry: TileGeometry) -> ProblemShape:
	for name, total, tile in (
		("m", args.m, geometry.x_dim),
		("k", args.k, geometry.x_dim),
		("n", args.n, geometry.y_dim),
	):
		if total <= 0:
			raise ValueError(f"{name} must be > 0")
		if (total % tile) != 0:
			raise ValueError(f"{name}={total} must be divisible by tile size {tile}")
	return ProblemShape(
		m=args.m,
		k=args.k,
		n=args.n,
		m_tiles=args.m // geometry.x_dim,
		k_tiles=args.k // geometry.x_dim,
		n_tiles=args.n // geometry.y_dim,
		output_tiles=(args.m // geometry.x_dim) * (args.n // geometry.y_dim),
		partial_products=(args.m // geometry.x_dim) * (args.k // geometry.x_dim) * (args.n // geometry.y_dim),
	)


def build_reuse(args: argparse.Namespace, shape: ProblemShape) -> ReuseConfig:
	if args.reuse_a <= 0:
		raise ValueError("reuse_a must be > 0")
	if args.reuse_b <= 0:
		raise ValueError("reuse_b must be > 0")
	if args.reuse_a > shape.n_tiles:
		raise ValueError(f"reuse_a={args.reuse_a} exceeds n_tiles={shape.n_tiles}")
	if args.reuse_b > shape.m_tiles:
		raise ValueError(f"reuse_b={args.reuse_b} exceeds m_tiles={shape.m_tiles}")
	return ReuseConfig(reuse_a=args.reuse_a, reuse_b=args.reuse_b, forward_m=args.forward_m)


def build_transport(args: argparse.Namespace) -> TransportConfig:
	if args.ps_pl_bits <= 0 or (args.ps_pl_bits % 8) != 0:
		raise ValueError("ps_pl_bits must be a positive multiple of 8")
	if args.ps_pl_channels not in VALID_CHANNELS:
		raise ValueError(f"ps_pl_channels must be one of {VALID_CHANNELS}")
	if args.ps_pl_freq_ratio not in VALID_FREQ_RATIOS:
		raise ValueError(f"ps_pl_freq_ratio must be one of {VALID_FREQ_RATIOS}")
	return TransportConfig(
		ps_pl_bits=args.ps_pl_bits,
		ps_pl_channels=args.ps_pl_channels,
		ps_pl_freq_ratio=args.ps_pl_freq_ratio,
	)


def load_case(path: Path, m: int, n: int, k: int) -> dict[str, Any]:
	if not path.exists():
		raise FileNotFoundError(f"missing measured sweep artifact: {path}")
	data = json.loads(path.read_text(encoding="utf-8"))
	for case in data.get("cases", []):
		if (
			case.get("status") == "passed"
			and case.get("m_dim") == m
			and case.get("n_dim") == n
			and case.get("k_dim") == k
		):
			return case
	raise ValueError(f"no passed case for shape m={m}, n={n}, k={k} in {path}")


def build_anchor(case: dict[str, Any], *, target: str, target_label: str) -> MeasuredAnchor:
	return MeasuredAnchor(
		target=target,
		target_label=target_label,
		done_cycles=int(case["accept_to_done_cycles"]),
		ops_per_cycle=float(case["ops_per_cycle"]),
		accept_to_resp_cycles=int(case["accept_to_resp_cycles"]),
		resp_to_done_cycles=int(case["perf_resp_to_done_cycles"]),
		export_beats=int(case["export_beats"]),
		command_count=int(case["command_count"]),
		issued_command_count=int(case.get("issued_command_count", case["command_count"])),
	)


def measure_anchors(args: argparse.Namespace, shape: ProblemShape) -> dict[str, MeasuredAnchor]:
	wide_case = load_case(args.wide_sweep_path, shape.m, shape.n, shape.k)
	strict_case = load_case(args.strict_sweep_path, shape.m, shape.n, shape.k)
	return {
		"wide_internal_512b": build_anchor(wide_case, target="pt_dma_top_v3", target_label="PT_DMA_TOP_V3"),
		"strict_all_128b": build_anchor(strict_case, target="pt_dma_top_v3_128b_strict", target_label="PT_DMA_TOP_V3_128B_STRICT"),
	}


def project_external_traffic(
	shape: ProblemShape,
	geometry: TileGeometry,
	reuse: ReuseConfig,
	transport: TransportConfig,
) -> ExternalTraffic:
	a_tile_fetches = shape.m_tiles * shape.k_tiles * ceil_div(shape.n_tiles, reuse.reuse_a)
	b_tile_fetches = shape.k_tiles * shape.n_tiles * ceil_div(shape.m_tiles, reuse.reuse_b)
	final_output_tiles = shape.output_tiles
	intermediate_output_tiles = 0 if reuse.forward_m else (shape.output_tiles * max(shape.k_tiles - 1, 0))

	a_bytes = a_tile_fetches * geometry.a_tile_bytes
	b_bytes = b_tile_fetches * geometry.b_tile_bytes
	intermediate_m_bytes = intermediate_output_tiles * geometry.m_tile_bytes
	final_output_bytes = final_output_tiles * geometry.m_tile_bytes
	total_bytes = a_bytes + b_bytes + intermediate_m_bytes + final_output_bytes

	bits_per_pt_cycle = transport.ps_pl_bits * transport.ps_pl_channels
	a_beats = ceil_div(a_bytes * 8, bits_per_pt_cycle)
	b_beats = ceil_div(b_bytes * 8, bits_per_pt_cycle)
	intermediate_m_beats = ceil_div(intermediate_m_bytes * 8, bits_per_pt_cycle)
	final_output_beats = ceil_div(final_output_bytes * 8, bits_per_pt_cycle)
	total_beats = a_beats + b_beats + intermediate_m_beats + final_output_beats

	ingress_bytes = a_bytes + b_bytes
	egress_bytes = intermediate_m_bytes + final_output_bytes
	ingress_beats = a_beats + b_beats
	egress_beats = intermediate_m_beats + final_output_beats
	ingress_cycles = ceil_div_float(ingress_beats, transport.ps_pl_freq_ratio)
	egress_cycles = ceil_div_float(egress_beats, transport.ps_pl_freq_ratio)
	transport_cycles = ingress_cycles + egress_cycles

	return ExternalTraffic(
		a_bytes=a_bytes,
		b_bytes=b_bytes,
		intermediate_m_bytes=intermediate_m_bytes,
		final_output_bytes=final_output_bytes,
		total_bytes=total_bytes,
		a_beats=a_beats,
		b_beats=b_beats,
		intermediate_m_beats=intermediate_m_beats,
		final_output_beats=final_output_beats,
		total_beats=total_beats,
		ingress_bytes=ingress_bytes,
		egress_bytes=egress_bytes,
		ingress_beats=ingress_beats,
		egress_beats=egress_beats,
		ingress_cycles=ingress_cycles,
		egress_cycles=egress_cycles,
		transport_cycles=transport_cycles,
	)


def build_projection(
	anchors: dict[str, MeasuredAnchor],
	traffic: ExternalTraffic,
	geometry: TileGeometry,
	transport: TransportConfig,
) -> Projection:
	wide_cycles = anchors["wide_internal_512b"].done_cycles
	strict_cycles = anchors["strict_all_128b"].done_cycles
	lower_bound = max(wide_cycles, traffic.transport_cycles)
	residue = traffic.egress_cycles + max(0, traffic.ingress_cycles - wide_cycles)
	upper_bound = wide_cycles + residue
	if upper_bound < lower_bound:
		upper_bound = lower_bound
	return Projection(
		supply_ratio=(transport.ps_pl_bits * transport.ps_pl_channels * transport.ps_pl_freq_ratio) / geometry.internal_bits,
		lower_bound_cycles=lower_bound,
		upper_bound_cycles=upper_bound,
		non_hidden_transport_residue=residue,
		speedup_vs_strict_best_case=speedup_ratio(strict_cycles, lower_bound),
		speedup_vs_strict_worst_case=speedup_ratio(strict_cycles, upper_bound),
		slowdown_vs_wide_best_case=slowdown_ratio(lower_bound, wide_cycles),
		slowdown_vs_wide_worst_case=slowdown_ratio(upper_bound, wide_cycles),
	)


def evaluate(args: argparse.Namespace) -> EvaluationResult:
	geometry = build_geometry(args)
	shape = build_shape(args, geometry)
	reuse = build_reuse(args, shape)
	transport = build_transport(args)
	anchors = measure_anchors(args, shape)
	traffic = project_external_traffic(shape, geometry, reuse, transport)
	projection = build_projection(anchors, traffic, geometry, transport)
	assumptions = [
		"Internal PT demand is anchored to measured wide `pt_dma_top_v3` compact results, not a synthetic throughput constant.",
		"Strict all-128b `pt_dma_top_v3_128b_strict` is used only as a comparison baseline.",
		"PS-PL transport is modeled as 128b-class serialization with configurable channel count and frequency ratio.",
		"Local pack/unpack and BRAM line-buffer logic are treated as hidden unless external transport is slower than internal demand.",
		"Final output always exits the shell once; `forward_m=off` additionally pays intermediate partial-M traffic, while `forward_m=on` suppresses that traffic.",
		"Multi-tile retained-M reuse is not available in the current RTL; any benefit from `forward_m=on` is an architectural projection.",
	]
	return EvaluationResult(
		input_config={
			"shape": {"m": args.m, "k": args.k, "n": args.n},
			"internal_geometry": {
				"x_dim": geometry.x_dim,
				"y_dim": geometry.y_dim,
				"data_width": geometry.data_width,
				"a_load_lanes": geometry.a_load_lanes,
				"b_load_lanes": geometry.b_load_lanes,
				"m_write_lanes": geometry.m_write_lanes,
				"m_export_lanes": geometry.m_export_lanes,
			},
			"transport": {
				"ps_pl_bits": transport.ps_pl_bits,
				"ps_pl_channels": transport.ps_pl_channels,
				"ps_pl_freq_ratio": transport.ps_pl_freq_ratio,
			},
			"reuse": {
				"reuse_a": reuse.reuse_a,
				"reuse_b": reuse.reuse_b,
				"forward_m": reuse.forward_m,
			},
		},
		geometry=geometry,
		shape=shape,
		reuse=reuse,
		transport=transport,
		measured_anchors=anchors,
		external_traffic=traffic,
		projection=projection,
		assumptions=assumptions,
	)


def render_markdown(result: EvaluationResult) -> str:
	wide = result.measured_anchors["wide_internal_512b"]
	strict = result.measured_anchors["strict_all_128b"]
	traffic = result.external_traffic
	proj = result.projection
	return "\n".join(
		[
			f"# PS-PL Shell Cost Model ({result.shape.m}x{result.shape.n}x{result.shape.k})",
			"",
			"## Assumptions",
			"",
			*[f"- {item}" for item in result.assumptions],
			"",
			"## Configuration",
			"",
			f"- Internal PT geometry: `x={result.geometry.x_dim}`, `y={result.geometry.y_dim}`, `data_width={result.geometry.data_width}`, "
			f"`A={result.geometry.a_load_lanes}`, `B={result.geometry.b_load_lanes}`, `M write={result.geometry.m_write_lanes}`, `M export={result.geometry.m_export_lanes}`",
			f"- Shell transport: `{result.transport.ps_pl_bits}b x {result.transport.ps_pl_channels} channels @ {format_float(result.transport.ps_pl_freq_ratio)}x PT clock`",
			f"- Reuse knobs: `reuse_a={result.reuse.reuse_a}`, `reuse_b={result.reuse.reuse_b}`, `forward_m={'on' if result.reuse.forward_m else 'off'}`",
			f"- Supply ratio: `{format_float(proj.supply_ratio)}`",
			"",
			"## Measured Anchors",
			"",
			"| Anchor | Done Cycles | Ops/Cycle | Accept->Resp | Resp->Done | Export Beats | Cmds |",
			"| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
			f"| {wide.target_label} | {wide.done_cycles} | {format_float(wide.ops_per_cycle)} | {wide.accept_to_resp_cycles} | {wide.resp_to_done_cycles} | {wide.export_beats} | {wide.command_count} |",
			f"| {strict.target_label} | {strict.done_cycles} | {format_float(strict.ops_per_cycle)} | {strict.accept_to_resp_cycles} | {strict.resp_to_done_cycles} | {strict.export_beats} | {strict.command_count} |",
			"",
			"## External Traffic",
			"",
			"| Component | Bytes | 128b Beats |",
			"| --- | ---: | ---: |",
			f"| A ingress | {format_bytes(traffic.a_bytes)} | {traffic.a_beats} |",
			f"| B ingress | {format_bytes(traffic.b_bytes)} | {traffic.b_beats} |",
			f"| Intermediate partial M | {format_bytes(traffic.intermediate_m_bytes)} | {traffic.intermediate_m_beats} |",
			f"| Final output | {format_bytes(traffic.final_output_bytes)} | {traffic.final_output_beats} |",
			f"| Total | {format_bytes(traffic.total_bytes)} | {traffic.total_beats} |",
			"",
			f"- Ingress cycles: `{traffic.ingress_cycles}`",
			f"- Egress cycles: `{traffic.egress_cycles}`",
			f"- Transport-limited cycles: `{traffic.transport_cycles}`",
			"",
			"## Projection",
			"",
			f"- Lower bound cycles: `{proj.lower_bound_cycles}`",
			f"- Upper bound cycles: `{proj.upper_bound_cycles}`",
			f"- Non-hidden transport residue: `{proj.non_hidden_transport_residue}`",
			f"- Best-case speedup vs strict all-128b: `{format_ratio(proj.speedup_vs_strict_best_case)}`",
			f"- Worst-case speedup vs strict all-128b: `{format_ratio(proj.speedup_vs_strict_worst_case)}`",
			f"- Best-case slowdown vs wide internal baseline: `{format_ratio(proj.slowdown_vs_wide_best_case)}`",
			f"- Worst-case slowdown vs wide internal baseline: `{format_ratio(proj.slowdown_vs_wide_worst_case)}`",
		]
	)


def build_parser() -> argparse.ArgumentParser:
	parser = argparse.ArgumentParser(description="Cost model for PS-PL 128b / internal 512b PT shell exploration")
	parser.add_argument("--m", type=int, required=True, help="problem M dimension")
	parser.add_argument("--k", type=int, required=True, help="problem K dimension")
	parser.add_argument("--n", type=int, required=True, help="problem N dimension")
	parser.add_argument("--x-dim", type=int, default=16, help="internal PT tile X dimension")
	parser.add_argument("--y-dim", type=int, default=16, help="internal PT tile Y dimension")
	parser.add_argument("--data-width", type=int, default=32, help="internal PT scalar data width in bits")
	parser.add_argument("--a-load-lanes", type=int, default=16, help="internal PT A load lanes")
	parser.add_argument("--b-load-lanes", type=int, default=16, help="internal PT B load lanes")
	parser.add_argument("--m-write-lanes", type=int, default=16, help="internal PT M writeback lanes")
	parser.add_argument("--m-export-lanes", type=int, default=16, help="internal PT M export lanes")
	parser.add_argument("--ps-pl-bits", type=int, default=128, help="PS-PL shell data width in bits")
	parser.add_argument("--ps-pl-channels", type=int, default=1, choices=list(VALID_CHANNELS), help="parallel PS-PL channels")
	parser.add_argument("--ps-pl-freq-ratio", type=float, default=1.0, choices=list(VALID_FREQ_RATIOS), help="PS-PL clock / PT clock ratio")
	parser.add_argument("--reuse-a", type=int, default=1, help="A tile fanout served by one external fetch")
	parser.add_argument("--reuse-b", type=int, default=1, help="B tile fanout served by one external fetch")
	parser.add_argument("--forward-m", action="store_true", help="suppress intermediate partial-M traffic across PS-PL")
	parser.add_argument("--wide-sweep-path", type=Path, default=DEFAULT_WIDE_SWEEP_PATH, help="measured wide-PT sweep artifact")
	parser.add_argument("--strict-sweep-path", type=Path, default=DEFAULT_STRICT_SWEEP_PATH, help="measured strict-128b sweep artifact")
	parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
	return parser


def main() -> int:
	parser = build_parser()
	args = parser.parse_args()
	result = evaluate(args)
	if args.json:
		print(json.dumps(result.to_dict(), ensure_ascii=False, indent=2, sort_keys=True))
	else:
		print(render_markdown(result))
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
