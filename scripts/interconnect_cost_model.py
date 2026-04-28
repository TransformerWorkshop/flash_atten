#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
from dataclasses import asdict, dataclass


DEFAULT_EFFECTIVE_OPS_PER_CYCLE = 120.0
DEFAULT_THROUGHPUT_GAIN_THRESHOLD = 0.20
DEFAULT_DRAM_SAVINGS_THRESHOLD = 0.30
DEFAULT_SINGLE_NODE_DEGRADATION_THRESHOLD = 0.10


def ceil_div(numer: int, denom: int) -> int:
	if denom <= 0:
		raise ValueError("denom must be > 0")
	return (numer + denom - 1) // denom


def pct(value: float) -> float:
	return value * 100.0


def parse_topology(text: str) -> tuple[int, int]:
	normalized = text.lower().strip()
	parts = normalized.split("x")
	if len(parts) != 2:
		raise ValueError(f"topology must look like AxB, got {text!r}")
	rows = int(parts[0])
	cols = int(parts[1])
	if rows <= 0 or cols <= 0:
		raise ValueError("topology dimensions must be > 0")
	return rows, cols


def require_divisible(name: str, total: int, tile: int) -> int:
	if total <= 0:
		raise ValueError(f"{name} must be > 0")
	if tile <= 0:
		raise ValueError(f"{name} tile must be > 0")
	if total % tile != 0:
		raise ValueError(f"{name}={total} must be divisible by tile size {tile}")
	return total // tile


@dataclass
class TileGeometry:
	x_dim: int
	y_dim: int
	data_width: int
	word_bytes: int
	a_tile_bytes: int
	b_tile_bytes: int
	m_tile_bytes: int
	a_tile_bits: int
	b_tile_bits: int
	m_tile_bits: int
	a_load_beat_bits: int
	b_load_beat_bits: int
	m_export_beat_bits: int
	a_tile_beats: int
	b_tile_beats: int
	m_tile_beats: int


@dataclass
class ProblemShape:
	m: int
	k: int
	n: int
	m_tiles: int
	k_tiles: int
	n_tiles: int
	output_tiles: int
	total_partial_products: int
	total_ops: int


@dataclass
class NoCConfig:
	payload_bits: int
	head_tail_flits: int
	topology: str
	rows: int
	cols: int
	node_count: int
	active_nodes: int
	reuse_a: int
	reuse_b: int
	forward_m: bool


@dataclass
class TrafficLedger:
	external_a_bytes: int
	external_b_bytes: int
	external_m_bytes: int
	external_total_bytes: int
	pt_a_beats: int
	pt_b_beats: int
	pt_m_beats: int
	pt_total_beats: int
	noc_a_tile_packets: int
	noc_b_tile_packets: int
	noc_m_tile_packets: int
	noc_a_beat_packets: int
	noc_b_beat_packets: int
	noc_m_beat_packets: int
	noc_a_flits: int
	noc_b_flits: int
	noc_m_flits: int
	noc_total_flits: int
	noc_payload_bytes: int
	extra_serialization_cycles: int
	idealized_overlap_cycles: int
	single_node_cycles: int
	single_node_latency_degradation: float
	throughput_gain_vs_baseline: float
	dram_savings_vs_baseline: float
	go_no_go: bool
	decision_reason: str


@dataclass
class EvaluationResult:
	shape: ProblemShape
	geometry: TileGeometry
	noc: NoCConfig
	baseline_cycles: int
	long_case: bool
	baseline: TrafficLedger
	naive_noc: TrafficLedger
	recommended_noc: TrafficLedger


def build_geometry(args: argparse.Namespace) -> TileGeometry:
	if args.data_width <= 0 or args.data_width % 8 != 0:
		raise ValueError("data width must be a positive multiple of 8")
	if args.a_load_lanes <= 0 or args.b_load_lanes <= 0 or args.m_export_lanes <= 0:
		raise ValueError("lane counts must be > 0")

	word_bytes = args.data_width // 8
	a_tile_bytes = args.x_dim * args.x_dim * word_bytes
	b_tile_bytes = args.x_dim * args.y_dim * word_bytes
	m_tile_bytes = args.x_dim * args.y_dim * word_bytes
	a_tile_bits = a_tile_bytes * 8
	b_tile_bits = b_tile_bytes * 8
	m_tile_bits = m_tile_bytes * 8
	a_load_beat_bits = args.a_load_lanes * args.data_width
	b_load_beat_bits = args.b_load_lanes * args.data_width
	m_export_beat_bits = args.m_export_lanes * args.data_width
	return TileGeometry(
		x_dim=args.x_dim,
		y_dim=args.y_dim,
		data_width=args.data_width,
		word_bytes=word_bytes,
		a_tile_bytes=a_tile_bytes,
		b_tile_bytes=b_tile_bytes,
		m_tile_bytes=m_tile_bytes,
		a_tile_bits=a_tile_bits,
		b_tile_bits=b_tile_bits,
		m_tile_bits=m_tile_bits,
		a_load_beat_bits=a_load_beat_bits,
		b_load_beat_bits=b_load_beat_bits,
		m_export_beat_bits=m_export_beat_bits,
		a_tile_beats=ceil_div(a_tile_bits, a_load_beat_bits),
		b_tile_beats=ceil_div(b_tile_bits, b_load_beat_bits),
		m_tile_beats=ceil_div(m_tile_bits, m_export_beat_bits),
	)


def build_shape(args: argparse.Namespace, geometry: TileGeometry) -> ProblemShape:
	m_tiles = require_divisible("m", args.m, geometry.x_dim)
	k_tiles = require_divisible("k", args.k, geometry.x_dim)
	n_tiles = require_divisible("n", args.n, geometry.y_dim)
	output_tiles = m_tiles * n_tiles
	total_partial_products = output_tiles * k_tiles
	total_ops = 2 * args.m * args.k * args.n
	return ProblemShape(
		m=args.m,
		k=args.k,
		n=args.n,
		m_tiles=m_tiles,
		k_tiles=k_tiles,
		n_tiles=n_tiles,
		output_tiles=output_tiles,
		total_partial_products=total_partial_products,
		total_ops=total_ops,
	)


def build_noc(args: argparse.Namespace, shape: ProblemShape) -> NoCConfig:
	rows, cols = parse_topology(args.topology)
	node_count = rows * cols
	active_nodes = min(node_count, shape.output_tiles)
	reuse_a = max(1, min(args.reuse_a, shape.n_tiles, node_count))
	reuse_b = max(1, min(args.reuse_b, shape.m_tiles, node_count))
	return NoCConfig(
		payload_bits=args.noc_payload_bits,
		head_tail_flits=args.head_tail_flits,
		topology=args.topology,
		rows=rows,
		cols=cols,
		node_count=node_count,
		active_nodes=active_nodes,
		reuse_a=reuse_a,
		reuse_b=reuse_b,
		forward_m=args.forward_m,
	)


def baseline_cycles(shape: ProblemShape, args: argparse.Namespace) -> int:
	return math.ceil(shape.total_ops / args.baseline_effective_ops_per_cycle)


def per_case_go_no_go(
	baseline_total_cycles: int,
	architecture_cycles: int,
	single_node_cycles: int,
	baseline_external_bytes: int,
	architecture_external_bytes: int,
	args: argparse.Namespace,
) -> tuple[float, float, float, bool, str]:
	throughput_gain = (baseline_total_cycles / architecture_cycles) - 1.0
	dram_savings = 1.0 - (architecture_external_bytes / baseline_external_bytes)
	single_node_degradation = (single_node_cycles / baseline_total_cycles) - 1.0
	pass_gain = throughput_gain >= args.throughput_gain_threshold
	pass_dram = dram_savings >= args.dram_savings_threshold
	pass_latency = single_node_degradation <= args.single_node_degradation_threshold
	pass_overall = (pass_gain or pass_dram) and pass_latency

	reasons = []
	if pass_gain:
		reasons.append(
			f"throughput gain {pct(throughput_gain):.1f}% >= {pct(args.throughput_gain_threshold):.1f}%"
		)
	else:
		reasons.append(
			f"throughput gain {pct(throughput_gain):.1f}% < {pct(args.throughput_gain_threshold):.1f}%"
		)
	if pass_dram:
		reasons.append(
			f"DRAM savings {pct(dram_savings):.1f}% >= {pct(args.dram_savings_threshold):.1f}%"
		)
	else:
		reasons.append(
			f"DRAM savings {pct(dram_savings):.1f}% < {pct(args.dram_savings_threshold):.1f}%"
		)
	if pass_latency:
		reasons.append(
			f"single-node degradation {pct(single_node_degradation):.1f}% <= {pct(args.single_node_degradation_threshold):.1f}%"
		)
	else:
		reasons.append(
			f"single-node degradation {pct(single_node_degradation):.1f}% > {pct(args.single_node_degradation_threshold):.1f}%"
		)
	return throughput_gain, dram_savings, single_node_degradation, pass_overall, "; ".join(reasons)


def build_baseline_ledger(
	shape: ProblemShape,
	geometry: TileGeometry,
	baseline_total_cycles: int,
	args: argparse.Namespace,
) -> TrafficLedger:
	external_a_bytes = shape.total_partial_products * geometry.a_tile_bytes
	external_b_bytes = shape.total_partial_products * geometry.b_tile_bytes
	external_m_bytes = shape.output_tiles * geometry.m_tile_bytes
	external_total_bytes = external_a_bytes + external_b_bytes + external_m_bytes
	pt_a_beats = shape.total_partial_products * geometry.a_tile_beats
	pt_b_beats = shape.total_partial_products * geometry.b_tile_beats
	pt_m_beats = shape.output_tiles * geometry.m_tile_beats
	pt_total_beats = pt_a_beats + pt_b_beats + pt_m_beats
	throughput_gain, dram_savings, single_node_degradation, go_no_go, reason = per_case_go_no_go(
		baseline_total_cycles,
		baseline_total_cycles,
		baseline_total_cycles,
		external_total_bytes,
		external_total_bytes,
		args,
	)
	return TrafficLedger(
		external_a_bytes=external_a_bytes,
		external_b_bytes=external_b_bytes,
		external_m_bytes=external_m_bytes,
		external_total_bytes=external_total_bytes,
		pt_a_beats=pt_a_beats,
		pt_b_beats=pt_b_beats,
		pt_m_beats=pt_m_beats,
		pt_total_beats=pt_total_beats,
		noc_a_tile_packets=0,
		noc_b_tile_packets=0,
		noc_m_tile_packets=0,
		noc_a_beat_packets=0,
		noc_b_beat_packets=0,
		noc_m_beat_packets=0,
		noc_a_flits=0,
		noc_b_flits=0,
		noc_m_flits=0,
		noc_total_flits=0,
		noc_payload_bytes=0,
		extra_serialization_cycles=0,
		idealized_overlap_cycles=baseline_total_cycles,
		single_node_cycles=baseline_total_cycles,
		single_node_latency_degradation=single_node_degradation,
		throughput_gain_vs_baseline=throughput_gain,
		dram_savings_vs_baseline=dram_savings,
		go_no_go=go_no_go,
		decision_reason=reason,
	)


def build_naive_ledger(
	shape: ProblemShape,
	geometry: TileGeometry,
	noc: NoCConfig,
	baseline_total_cycles: int,
	baseline_traffic: TrafficLedger,
	args: argparse.Namespace,
) -> TrafficLedger:
	a_body_flits = ceil_div(geometry.a_load_beat_bits, noc.payload_bits)
	b_body_flits = ceil_div(geometry.b_load_beat_bits, noc.payload_bits)
	m_body_flits = ceil_div(geometry.m_export_beat_bits, noc.payload_bits)

	noc_a_beat_packets = baseline_traffic.pt_a_beats
	noc_b_beat_packets = baseline_traffic.pt_b_beats
	noc_m_beat_packets = baseline_traffic.pt_m_beats
	noc_a_flits = noc_a_beat_packets * (a_body_flits + noc.head_tail_flits)
	noc_b_flits = noc_b_beat_packets * (b_body_flits + noc.head_tail_flits)
	noc_m_flits = noc_m_beat_packets * (m_body_flits + noc.head_tail_flits)
	noc_total_flits = noc_a_flits + noc_b_flits + noc_m_flits
	baseline_non_transfer_cycles = baseline_total_cycles - baseline_traffic.pt_total_beats
	single_node_cycles = baseline_non_transfer_cycles + noc_total_flits
	idealized_overlap_cycles = single_node_cycles
	throughput_gain, dram_savings, single_node_degradation, go_no_go, reason = per_case_go_no_go(
		baseline_total_cycles,
		idealized_overlap_cycles,
		single_node_cycles,
		baseline_traffic.external_total_bytes,
		baseline_traffic.external_total_bytes,
		args,
	)
	return TrafficLedger(
		external_a_bytes=baseline_traffic.external_a_bytes,
		external_b_bytes=baseline_traffic.external_b_bytes,
		external_m_bytes=baseline_traffic.external_m_bytes,
		external_total_bytes=baseline_traffic.external_total_bytes,
		pt_a_beats=0,
		pt_b_beats=0,
		pt_m_beats=0,
		pt_total_beats=0,
		noc_a_tile_packets=0,
		noc_b_tile_packets=0,
		noc_m_tile_packets=0,
		noc_a_beat_packets=noc_a_beat_packets,
		noc_b_beat_packets=noc_b_beat_packets,
		noc_m_beat_packets=noc_m_beat_packets,
		noc_a_flits=noc_a_flits,
		noc_b_flits=noc_b_flits,
		noc_m_flits=noc_m_flits,
		noc_total_flits=noc_total_flits,
		noc_payload_bytes=baseline_traffic.external_total_bytes,
		extra_serialization_cycles=noc_total_flits - baseline_traffic.pt_total_beats,
		idealized_overlap_cycles=idealized_overlap_cycles,
		single_node_cycles=single_node_cycles,
		single_node_latency_degradation=single_node_degradation,
		throughput_gain_vs_baseline=throughput_gain,
		dram_savings_vs_baseline=dram_savings,
		go_no_go=go_no_go,
		decision_reason=reason,
	)


def build_recommended_ledger(
	shape: ProblemShape,
	geometry: TileGeometry,
	noc: NoCConfig,
	baseline_total_cycles: int,
	baseline_traffic: TrafficLedger,
	args: argparse.Namespace,
) -> TrafficLedger:
	a_external_tile_fetches = shape.m_tiles * shape.k_tiles * ceil_div(shape.n_tiles, noc.reuse_a)
	b_external_tile_fetches = shape.k_tiles * shape.n_tiles * ceil_div(shape.m_tiles, noc.reuse_b)
	a_tile_uses = shape.total_partial_products
	b_tile_uses = shape.total_partial_products
	m_tile_uses = shape.output_tiles

	noc_a_tile_packets = a_tile_uses - a_external_tile_fetches
	noc_b_tile_packets = b_tile_uses - b_external_tile_fetches
	noc_m_tile_packets = m_tile_uses if noc.forward_m else 0

	external_a_bytes = a_external_tile_fetches * geometry.a_tile_bytes
	external_b_bytes = b_external_tile_fetches * geometry.b_tile_bytes
	external_m_bytes = 0 if noc.forward_m else baseline_traffic.external_m_bytes
	external_total_bytes = external_a_bytes + external_b_bytes + external_m_bytes
	external_a_pt_beats = a_external_tile_fetches * geometry.a_tile_beats
	external_b_pt_beats = b_external_tile_fetches * geometry.b_tile_beats
	external_m_pt_beats = 0 if noc.forward_m else baseline_traffic.pt_m_beats
	external_pt_total_beats = external_a_pt_beats + external_b_pt_beats + external_m_pt_beats

	noc_a_flits = noc_a_tile_packets * (ceil_div(geometry.a_tile_bits, noc.payload_bits) + noc.head_tail_flits)
	noc_b_flits = noc_b_tile_packets * (ceil_div(geometry.b_tile_bits, noc.payload_bits) + noc.head_tail_flits)
	noc_m_flits = noc_m_tile_packets * (ceil_div(geometry.m_tile_bits, noc.payload_bits) + noc.head_tail_flits)
	noc_total_flits = noc_a_flits + noc_b_flits + noc_m_flits

	recommended_pt_a_beats = noc_a_tile_packets * geometry.a_tile_beats
	recommended_pt_b_beats = noc_b_tile_packets * geometry.b_tile_beats
	recommended_pt_m_beats = noc_m_tile_packets * geometry.m_tile_beats
	recommended_pt_total_beats = recommended_pt_a_beats + recommended_pt_b_beats + recommended_pt_m_beats

	single_node_cycles = baseline_total_cycles
	baseline_non_transfer_cycles = baseline_total_cycles - baseline_traffic.pt_total_beats
	idealized_overlap_cycles = baseline_non_transfer_cycles + external_pt_total_beats + noc_total_flits
	throughput_gain, dram_savings, single_node_degradation, go_no_go, reason = per_case_go_no_go(
		baseline_total_cycles,
		idealized_overlap_cycles,
		single_node_cycles,
		baseline_traffic.external_total_bytes,
		external_total_bytes,
		args,
	)
	return TrafficLedger(
		external_a_bytes=external_a_bytes,
		external_b_bytes=external_b_bytes,
		external_m_bytes=external_m_bytes,
		external_total_bytes=external_total_bytes,
		pt_a_beats=external_a_pt_beats,
		pt_b_beats=external_b_pt_beats,
		pt_m_beats=external_m_pt_beats,
		pt_total_beats=external_pt_total_beats,
		noc_a_tile_packets=noc_a_tile_packets,
		noc_b_tile_packets=noc_b_tile_packets,
		noc_m_tile_packets=noc_m_tile_packets,
		noc_a_beat_packets=0,
		noc_b_beat_packets=0,
		noc_m_beat_packets=0,
		noc_a_flits=noc_a_flits,
		noc_b_flits=noc_b_flits,
		noc_m_flits=noc_m_flits,
		noc_total_flits=noc_total_flits,
		noc_payload_bytes=(
			noc_a_tile_packets * geometry.a_tile_bytes
			+ noc_b_tile_packets * geometry.b_tile_bytes
			+ noc_m_tile_packets * geometry.m_tile_bytes
		),
		extra_serialization_cycles=noc_total_flits - recommended_pt_total_beats,
		idealized_overlap_cycles=idealized_overlap_cycles,
		single_node_cycles=single_node_cycles,
		single_node_latency_degradation=single_node_degradation,
		throughput_gain_vs_baseline=throughput_gain,
		dram_savings_vs_baseline=dram_savings,
		go_no_go=go_no_go,
		decision_reason=reason,
	)


def build_evaluation(args: argparse.Namespace) -> EvaluationResult:
	geometry = build_geometry(args)
	shape = build_shape(args, geometry)
	noc = build_noc(args, shape)
	base_cycles = baseline_cycles(shape, args)
	long_case = shape.output_tiles >= args.long_case_output_tiles
	baseline = build_baseline_ledger(shape, geometry, base_cycles, args)
	naive = build_naive_ledger(shape, geometry, noc, base_cycles, baseline, args)
	recommended = build_recommended_ledger(shape, geometry, noc, base_cycles, baseline, args)
	return EvaluationResult(
		shape=shape,
		geometry=geometry,
		noc=noc,
		baseline_cycles=base_cycles,
		long_case=long_case,
		baseline=baseline,
		naive_noc=naive,
		recommended_noc=recommended,
	)


def format_bytes(value: int) -> str:
	if value >= 1024 * 1024:
		return f"{value / (1024 * 1024):.2f} MiB"
	if value >= 1024:
		return f"{value / 1024:.2f} KiB"
	return f"{value} B"


def format_cycles(value: int) -> str:
	return f"{value:,}"


def format_ratio(value: float) -> str:
	return f"{pct(value):.1f}%"


def render_markdown(result: EvaluationResult) -> str:
	shape = result.shape
	geometry = result.geometry
	noc = result.noc
	lines = [
		f"# Interconnect Cost Model ({shape.m}x{shape.k}x{shape.n})",
		"",
		"## Assumptions",
		"",
		f"- Tile geometry: `M={geometry.x_dim}`, `K={geometry.x_dim}`, `N={geometry.y_dim}`",
		f"- PT lanes: `A={geometry.a_load_beat_bits // geometry.data_width}`, `B={geometry.b_load_beat_bits // geometry.data_width}`, `M export={geometry.m_export_beat_bits // geometry.data_width}`",
		f"- NoC: `{noc.topology}` = `{noc.node_count}` nodes, payload `{noc.payload_bits}` bits, fixed `{noc.head_tail_flits}` head/tail flits per packet",
		f"- Reuse knobs: `reuse_a={noc.reuse_a}`, `reuse_b={noc.reuse_b}`, `forward_m={'on' if noc.forward_m else 'off'}`",
		f"- Baseline is anchored to `{DEFAULT_EFFECTIVE_OPS_PER_CYCLE:.1f}` effective ops/cycle from current compact `PT_DMA_TOP` measurements",
		"",
		"## Shape Summary",
		"",
		f"- Tiles: `m_tiles={shape.m_tiles}`, `k_tiles={shape.k_tiles}`, `n_tiles={shape.n_tiles}`, `output_tiles={shape.output_tiles}`",
		f"- Total partial products: `{shape.total_partial_products}`",
		f"- Baseline end-to-end cycles: `{format_cycles(result.baseline_cycles)}`",
		f"- Long-case threshold hit: `{'yes' if result.long_case else 'no'}`",
		"",
		"## Ledgers",
		"",
		"| Architecture | External Traffic | NoC Flits | Extra Serialization | Idealized Overlap Cycles | DRAM Savings | Throughput Gain | Go/No-Go |",
		"| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
	]
	for label, ledger in (
		("Baseline", result.baseline),
		("Naive NoC", result.naive_noc),
		("Recommended NoC", result.recommended_noc),
	):
		lines.append(
			f"| {label} | {format_bytes(ledger.external_total_bytes)} | {ledger.noc_total_flits:,} | {ledger.extra_serialization_cycles:,} | {format_cycles(ledger.idealized_overlap_cycles)} | {format_ratio(ledger.dram_savings_vs_baseline)} | {format_ratio(ledger.throughput_gain_vs_baseline)} | {'PASS' if ledger.go_no_go else 'FAIL'} |"
		)
	lines.extend(
		[
			"",
			"## Detail",
			"",
			f"- Baseline external bytes: `A={format_bytes(result.baseline.external_a_bytes)}`, `B={format_bytes(result.baseline.external_b_bytes)}`, `M={format_bytes(result.baseline.external_m_bytes)}`",
			f"- Naive NoC flits: `A={result.naive_noc.noc_a_flits:,}`, `B={result.naive_noc.noc_b_flits:,}`, `M={result.naive_noc.noc_m_flits:,}`",
			f"- Recommended NoC flits: `A={result.recommended_noc.noc_a_flits:,}`, `B={result.recommended_noc.noc_b_flits:,}`, `M={result.recommended_noc.noc_m_flits:,}`",
			f"- Single-node degradation: naive `{format_ratio(result.naive_noc.single_node_latency_degradation)}`, recommended `{format_ratio(result.recommended_noc.single_node_latency_degradation)}`",
			f"- Recommended decision: {result.recommended_noc.decision_reason}",
		]
	)
	return "\n".join(lines)


def build_parser() -> argparse.ArgumentParser:
	parser = argparse.ArgumentParser(description="Cost model for PT_DMA_TOP interconnect exploration")
	parser.add_argument("--m", type=int, required=True, help="problem M dimension")
	parser.add_argument("--k", type=int, required=True, help="problem K dimension")
	parser.add_argument("--n", type=int, required=True, help="problem N dimension")
	parser.add_argument("--x-dim", type=int, default=16, help="PT tile X dimension")
	parser.add_argument("--y-dim", type=int, default=16, help="PT tile Y dimension")
	parser.add_argument("--data-width", type=int, default=32, help="scalar data width in bits")
	parser.add_argument("--a-load-lanes", type=int, default=16, help="A-side PT load lanes")
	parser.add_argument("--b-load-lanes", type=int, default=16, help="B-side PT load lanes")
	parser.add_argument("--m-export-lanes", type=int, default=16, help="M export PT lanes")
	parser.add_argument("--noc-payload-bits", type=int, default=128, help="NoC payload bits per body flit")
	parser.add_argument("--head-tail-flits", type=int, default=2, help="fixed non-payload flits per packet")
	parser.add_argument("--topology", default="2x2", help="NoC topology, for example 2x2 or 5x5")
	parser.add_argument("--reuse-a", type=int, default=1, help="average A tile fanout served by one DRAM fetch")
	parser.add_argument("--reuse-b", type=int, default=1, help="average B tile fanout served by one DRAM fetch")
	parser.add_argument("--forward-m", action="store_true", help="treat M as node-to-node forwarded instead of written off-cluster")
	parser.add_argument(
		"--baseline-effective-ops-per-cycle",
		type=float,
		default=DEFAULT_EFFECTIVE_OPS_PER_CYCLE,
		help="empirical single-node PT_DMA_TOP throughput anchor",
	)
	parser.add_argument(
		"--throughput-gain-threshold",
		type=float,
		default=DEFAULT_THROUGHPUT_GAIN_THRESHOLD,
		help="go/no-go throughput threshold as a fraction",
	)
	parser.add_argument(
		"--dram-savings-threshold",
		type=float,
		default=DEFAULT_DRAM_SAVINGS_THRESHOLD,
		help="go/no-go DRAM savings threshold as a fraction",
	)
	parser.add_argument(
		"--single-node-degradation-threshold",
		type=float,
		default=DEFAULT_SINGLE_NODE_DEGRADATION_THRESHOLD,
		help="max allowed single-node latency regression as a fraction",
	)
	parser.add_argument(
		"--long-case-output-tiles",
		type=int,
		default=4,
		help="case is considered long when output tile count reaches this value",
	)
	parser.add_argument("--json", action="store_true", help="emit machine-readable JSON")
	return parser


def main() -> int:
	parser = build_parser()
	args = parser.parse_args()
	result = build_evaluation(args)
	if args.json:
		print(json.dumps(asdict(result), indent=2, sort_keys=True))
	else:
		print(render_markdown(result))
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
