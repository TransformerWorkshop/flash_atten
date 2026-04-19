#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import math
from dataclasses import asdict, dataclass
from typing import Dict


SCENARIOS = (
	"cold_miss",
	"cache_hit",
	"m_window",
	"steady_stream_cold",
	"steady_stream_mixed",
)


def ceil_div_rate(units: float, units_per_cycle: float) -> float:
	if units_per_cycle <= 0:
		raise ValueError("units_per_cycle must be > 0")
	return math.ceil(units / units_per_cycle)


def pct(part: float, total: float) -> float:
	return 0.0 if total == 0 else (100.0 * part / total)


def maybe_ratio(numer: float, denom: float) -> float | None:
	return None if denom == 0 else (numer / denom)


def require_positive(name: str, value: int, upper_bound: int | None = None) -> None:
	if value <= 0:
		raise ValueError(f"{name} must be > 0")
	if upper_bound is not None and value > upper_bound:
		raise ValueError(f"{name} must be <= {upper_bound}")


def bytes_per_cycle_from_gbps(gbps: float, freq_mhz: float) -> float:
	if gbps <= 0:
		raise ValueError("bandwidth must be > 0")
	if freq_mhz <= 0:
		raise ValueError("target frequency must be > 0 when using absolute bandwidth")
	return gbps * 1000.0 / freq_mhz


@dataclass
class PTPerfResult:
	scenario: str
	x_dim: int
	y_dim: int
	data_width: int
	word_bytes: int
	cold_ratio: float
	target_freq_mhz: float | None
	ext_in_beats_per_cycle: float
	ext_out_beats_per_cycle: float
	ext_in_bytes_per_cycle: float
	ext_out_bytes_per_cycle: float
	a_load_lanes: int
	b_load_lanes: int
	m_write_lanes: int
	m_export_lanes: int
	m_physical_copies: int
	matmul_overlap_depth: int
	peak_macs_per_cycle: float
	peak_ops_per_cycle: float
	macs_per_tile: int
	ops_per_tile: int
	a_input_beats_per_tile: float
	b_input_beats_per_tile: float
	export_beats_per_tile: float
	external_input_beats: float
	external_output_beats: float
	external_total_beats: float
	external_input_bytes: float
	external_output_bytes: float
	external_total_bytes: float
	input_bytes_per_op: float | None
	output_bytes_per_op: float | None
	external_bytes_per_op: float
	external_beats_per_op: float
	logical_onchip_operand_read_bytes: int
	logical_onchip_m_writeback_bytes: int
	physical_onchip_m_writeback_bytes: int
	logical_onchip_export_read_bytes: int
	logical_onchip_total_bytes: int
	physical_onchip_total_bytes: int
	logical_onchip_bytes_per_op: float
	physical_onchip_bytes_per_op: float
	a_load_cycles: float
	b_load_cycles: float
	input_phase_cycles: float
	internal_issue_cycles: int
	internal_start_cycles: int
	internal_feed_cycles: int
	internal_collect_cycles: int
	internal_drain_cycles: int
	internal_row_capture_cycles: int
	internal_m_writeback_cycles: int
	internal_resp_merge_cycles: int
	internal_total_cycles: int
	internal_overlap_steady_cycles: float
	export_phase_cycles: float
	ctrl_resp_visible_cycles: float
	single_tile_latency_cycles: float
	sustained_cycles_per_tile: float
	sustained_ops_per_cycle: float
	sustained_macs_per_cycle: float
	effective_util_pct: float
	latency_ns: float | None
	sustained_gops: float | None
	sustained_tops: float | None
	roofline_ops_per_cycle_ext_in: float | None
	roofline_ops_per_cycle_ext_out: float | None
	external_input_min_cycles_ideal: float
	external_output_min_cycles_ideal: float
	overall_bottleneck_stage: str
	external_bottleneck_stage: str
	internal_bottleneck_stage: str
	internal_stage_shares: Dict[str, float]
	latency_stage_shares: Dict[str, float]


def derive_rates(args: argparse.Namespace, word_bytes: int) -> tuple[float, float, float | None]:
	target_freq_mhz = args.target_freq_mhz if args.target_freq_mhz is not None else args.freq_mhz
	load_stream_lanes = max(args.a_load_lanes, args.b_load_lanes)

	if args.ext_in_gbps is not None:
		if target_freq_mhz is None:
			raise ValueError("--ext-in-gbps requires --target-freq-mhz or --freq-mhz")
		ext_in_bytes_per_cycle = bytes_per_cycle_from_gbps(args.ext_in_gbps, target_freq_mhz)
		ext_in_beats_per_cycle = ext_in_bytes_per_cycle / (word_bytes * load_stream_lanes)
	else:
		ext_in_beats_per_cycle = args.ext_in_beats_per_cycle
		ext_in_bytes_per_cycle = ext_in_beats_per_cycle * word_bytes * load_stream_lanes

	export_beat_bytes = word_bytes * args.m_export_lanes
	if args.ext_out_gbps is not None:
		if target_freq_mhz is None:
			raise ValueError("--ext-out-gbps requires --target-freq-mhz or --freq-mhz")
		ext_out_bytes_per_cycle = bytes_per_cycle_from_gbps(args.ext_out_gbps, target_freq_mhz)
		ext_out_beats_per_cycle = ext_out_bytes_per_cycle / export_beat_bytes
	else:
		ext_out_beats_per_cycle = args.ext_out_beats_per_cycle
		ext_out_bytes_per_cycle = ext_out_beats_per_cycle * export_beat_bytes

	if ext_in_beats_per_cycle <= 0:
		raise ValueError("ext_in_beats_per_cycle must be > 0")
	if ext_out_beats_per_cycle <= 0:
		raise ValueError("ext_out_beats_per_cycle must be > 0")

	return ext_in_beats_per_cycle, ext_out_beats_per_cycle, target_freq_mhz


def build_result(args: argparse.Namespace) -> PTPerfResult:
	x_dim = args.x_dim
	y_dim = args.y_dim
	data_width = args.data_width
	word_bytes = data_width // 8

	require_positive("m_write_lanes", args.m_write_lanes, y_dim)
	require_positive("m_export_lanes", args.m_export_lanes, y_dim)
	require_positive("a_load_lanes", args.a_load_lanes, x_dim)
	require_positive("b_load_lanes", args.b_load_lanes, y_dim)
	if args.m_physical_copies not in (1, 2, 3):
		raise ValueError("m_physical_copies must be one of 1, 2, 3")
	if args.matmul_overlap_depth not in (1, 2):
		raise ValueError("matmul_overlap_depth must be 1 or 2")

	ext_in_beats_per_cycle, ext_out_beats_per_cycle, target_freq_mhz = derive_rates(args, word_bytes)
	ext_in_bytes_per_cycle = ext_in_beats_per_cycle * word_bytes
	ext_out_bytes_per_cycle = ext_out_beats_per_cycle * word_bytes * args.m_export_lanes

	cold_ratio = (
		args.cold_ratio
		if args.scenario == "steady_stream_mixed"
		else (1.0 if args.scenario in ("cold_miss", "steady_stream_cold") else 0.0)
	)

	peak_macs_per_cycle = float(x_dim * y_dim)
	peak_ops_per_cycle = 2.0 * peak_macs_per_cycle
	macs_per_tile = x_dim * y_dim * x_dim
	ops_per_tile = 2 * macs_per_tile

	a_input_beats_per_tile = float(math.ceil((x_dim * x_dim) / args.a_load_lanes))
	b_input_beats_per_tile = float(math.ceil((y_dim * y_dim) / args.b_load_lanes))
	cold_input_beats = a_input_beats_per_tile + b_input_beats_per_tile
	export_beats_per_tile = float(x_dim * math.ceil(y_dim / args.m_export_lanes))
	cold_input_bytes = float((x_dim * x_dim + y_dim * y_dim) * word_bytes)
	cold_output_bytes = float(x_dim * y_dim * word_bytes)

	a_load_cycles = ceil_div_rate(a_input_beats_per_tile, ext_in_beats_per_cycle) + args.dma_req_overhead_cycles + args.dma_done_latency_cycles
	b_load_cycles = ceil_div_rate(b_input_beats_per_tile, ext_in_beats_per_cycle) + args.dma_req_overhead_cycles + args.dma_done_latency_cycles
	cold_input_phase_cycles = a_load_cycles + b_load_cycles

	internal_issue_cycles = 1
	internal_start_cycles = 1
	internal_feed_cycles = x_dim
	# GEMM streams rows directly from PE FIFOs, so the old collect bubble is gone.
	internal_collect_cycles = 0
	chunks_per_row = math.ceil(y_dim / args.m_write_lanes)
	if args.m_write_lanes >= y_dim:
		# Full-width MATMUL drain writes each row directly in ST_MATMUL_DRAIN,
		# so the visible tail is just one streamed row per X.
		internal_drain_cycles = x_dim
		internal_row_capture_cycles = 0
		internal_m_writeback_cycles = 0
	else:
		internal_drain_cycles = 0
		internal_row_capture_cycles = x_dim
		internal_m_writeback_cycles = x_dim * chunks_per_row
	internal_resp_merge_cycles = 1
	internal_total_cycles = (
		internal_issue_cycles
		+ internal_start_cycles
		+ internal_feed_cycles
		+ internal_collect_cycles
		+ internal_row_capture_cycles
		+ internal_m_writeback_cycles
		+ internal_drain_cycles
		+ internal_resp_merge_cycles
	)
	internal_overlap_steady_cycles = float(internal_total_cycles)
	if args.matmul_overlap_depth >= 2:
		internal_overlap_steady_cycles = float(
			max(
				internal_feed_cycles,
				internal_drain_cycles + internal_row_capture_cycles + internal_m_writeback_cycles,
			)
		)

	export_phase_cycles = ceil_div_rate(export_beats_per_tile, ext_out_beats_per_cycle) + args.dma_req_overhead_cycles + args.m_dma_done_latency_cycles

	logical_onchip_operand_read_bytes = word_bytes * x_dim * (x_dim + y_dim)
	logical_onchip_m_writeback_bytes = word_bytes * x_dim * y_dim
	physical_onchip_m_writeback_bytes = logical_onchip_m_writeback_bytes * args.m_physical_copies
	logical_onchip_export_read_bytes = word_bytes * x_dim * y_dim
	logical_onchip_total_bytes = (
		logical_onchip_operand_read_bytes
		+ logical_onchip_m_writeback_bytes
		+ logical_onchip_export_read_bytes
	)
	physical_onchip_total_bytes = (
		logical_onchip_operand_read_bytes
		+ physical_onchip_m_writeback_bytes
		+ logical_onchip_export_read_bytes
	)

	if args.scenario == "cold_miss":
		input_phase_cycles = cold_input_phase_cycles
		external_input_beats = cold_input_beats
		external_output_beats = export_beats_per_tile
		ctrl_resp_visible_cycles = input_phase_cycles + internal_total_cycles
		single_tile_latency_cycles = input_phase_cycles + internal_total_cycles + export_phase_cycles
		sustained_cycles_per_tile = single_tile_latency_cycles
	elif args.scenario in ("cache_hit", "m_window"):
		input_phase_cycles = 0.0
		external_input_beats = 0.0
		external_output_beats = export_beats_per_tile
		ctrl_resp_visible_cycles = internal_total_cycles
		single_tile_latency_cycles = internal_total_cycles + export_phase_cycles
		sustained_cycles_per_tile = (
			max(internal_overlap_steady_cycles, export_phase_cycles)
			if args.matmul_overlap_depth >= 2
			else single_tile_latency_cycles
		)
	elif args.scenario == "steady_stream_cold":
		input_phase_cycles = cold_input_phase_cycles
		external_input_beats = cold_input_beats
		external_output_beats = export_beats_per_tile
		ctrl_resp_visible_cycles = input_phase_cycles + internal_total_cycles
		single_tile_latency_cycles = cold_input_phase_cycles + internal_total_cycles + export_phase_cycles
		sustained_cycles_per_tile = max(cold_input_phase_cycles, internal_overlap_steady_cycles, export_phase_cycles)
	elif args.scenario == "steady_stream_mixed":
		input_phase_cycles = cold_input_phase_cycles * cold_ratio
		external_input_beats = cold_input_beats * cold_ratio
		external_output_beats = export_beats_per_tile
		ctrl_resp_visible_cycles = input_phase_cycles + internal_total_cycles
		single_tile_latency_cycles = input_phase_cycles + internal_total_cycles + export_phase_cycles
		sustained_cycles_per_tile = max(input_phase_cycles, internal_overlap_steady_cycles, export_phase_cycles)
	else:
		raise ValueError(f"unsupported scenario {args.scenario!r}")

	external_total_beats = external_input_beats + external_output_beats
	if args.scenario == "steady_stream_mixed":
		external_input_bytes = cold_input_bytes * cold_ratio
	elif args.scenario in ("cold_miss", "steady_stream_cold"):
		external_input_bytes = cold_input_bytes
	else:
		external_input_bytes = 0.0
	external_output_bytes = cold_output_bytes
	external_total_bytes = external_input_bytes + external_output_bytes

	sustained_ops_per_cycle = ops_per_tile / sustained_cycles_per_tile
	sustained_macs_per_cycle = macs_per_tile / sustained_cycles_per_tile
	effective_util_pct = pct(sustained_ops_per_cycle, peak_ops_per_cycle)

	input_bytes_per_op = maybe_ratio(external_input_bytes, ops_per_tile)
	output_bytes_per_op = maybe_ratio(external_output_bytes, ops_per_tile)

	overall_candidates = {
		"external_input": input_phase_cycles,
		"internal_execution": float(internal_total_cycles),
		"external_export": export_phase_cycles,
	}
	overall_bottleneck_stage = max(overall_candidates, key=overall_candidates.get)
	external_candidates = {
		"external_input": input_phase_cycles,
		"external_export": export_phase_cycles,
	}
	external_bottleneck_stage = max(external_candidates, key=external_candidates.get)
	internal_stage_candidates = {
		"issue_dispatch": internal_issue_cycles,
		"exec_start": internal_start_cycles,
		"gemm_feed": internal_feed_cycles,
		"gemm_collect": internal_collect_cycles,
		"quant_row_capture": internal_row_capture_cycles,
		"m_writeback": internal_m_writeback_cycles,
		"matmul_drain": internal_drain_cycles,
		"resp_merge": internal_resp_merge_cycles,
	}
	internal_bottleneck_stage = max(internal_stage_candidates, key=internal_stage_candidates.get)

	internal_stage_shares = {
		name: pct(value, internal_total_cycles) for name, value in internal_stage_candidates.items()
	}
	latency_stage_shares = {
		"external_input": pct(input_phase_cycles, single_tile_latency_cycles),
		"internal_execution": pct(internal_total_cycles, single_tile_latency_cycles),
		"external_export": pct(export_phase_cycles, single_tile_latency_cycles),
	}

	latency_ns = None
	sustained_gops = None
	sustained_tops = None
	if target_freq_mhz is not None:
		latency_ns = single_tile_latency_cycles / target_freq_mhz * 1000.0
		sustained_gops = sustained_ops_per_cycle * target_freq_mhz / 1000.0
		sustained_tops = sustained_gops / 1000.0

	roofline_ops_per_cycle_ext_in = None
	if input_bytes_per_op not in (None, 0.0):
		roofline_ops_per_cycle_ext_in = ext_in_bytes_per_cycle / input_bytes_per_op

	roofline_ops_per_cycle_ext_out = None
	if output_bytes_per_op not in (None, 0.0):
		roofline_ops_per_cycle_ext_out = ext_out_bytes_per_cycle / output_bytes_per_op

	return PTPerfResult(
		scenario=args.scenario,
		x_dim=x_dim,
		y_dim=y_dim,
		data_width=data_width,
		word_bytes=word_bytes,
		cold_ratio=cold_ratio,
		target_freq_mhz=target_freq_mhz,
		ext_in_beats_per_cycle=ext_in_beats_per_cycle,
		ext_out_beats_per_cycle=ext_out_beats_per_cycle,
		ext_in_bytes_per_cycle=ext_in_bytes_per_cycle,
		ext_out_bytes_per_cycle=ext_out_bytes_per_cycle,
		a_load_lanes=args.a_load_lanes,
		b_load_lanes=args.b_load_lanes,
		m_write_lanes=args.m_write_lanes,
		m_export_lanes=args.m_export_lanes,
		m_physical_copies=args.m_physical_copies,
		matmul_overlap_depth=args.matmul_overlap_depth,
		peak_macs_per_cycle=peak_macs_per_cycle,
		peak_ops_per_cycle=peak_ops_per_cycle,
		macs_per_tile=macs_per_tile,
		ops_per_tile=ops_per_tile,
		a_input_beats_per_tile=a_input_beats_per_tile,
		b_input_beats_per_tile=b_input_beats_per_tile,
		export_beats_per_tile=export_beats_per_tile,
		external_input_beats=external_input_beats,
		external_output_beats=external_output_beats,
		external_total_beats=external_total_beats,
		external_input_bytes=external_input_bytes,
		external_output_bytes=external_output_bytes,
		external_total_bytes=external_total_bytes,
		input_bytes_per_op=input_bytes_per_op,
		output_bytes_per_op=output_bytes_per_op,
		external_bytes_per_op=(external_total_bytes / ops_per_tile),
		external_beats_per_op=(external_total_beats / ops_per_tile),
		logical_onchip_operand_read_bytes=logical_onchip_operand_read_bytes,
		logical_onchip_m_writeback_bytes=logical_onchip_m_writeback_bytes,
		physical_onchip_m_writeback_bytes=physical_onchip_m_writeback_bytes,
		logical_onchip_export_read_bytes=logical_onchip_export_read_bytes,
		logical_onchip_total_bytes=logical_onchip_total_bytes,
		physical_onchip_total_bytes=physical_onchip_total_bytes,
		logical_onchip_bytes_per_op=(logical_onchip_total_bytes / ops_per_tile),
		physical_onchip_bytes_per_op=(physical_onchip_total_bytes / ops_per_tile),
		a_load_cycles=a_load_cycles,
		b_load_cycles=b_load_cycles,
		input_phase_cycles=input_phase_cycles,
		internal_issue_cycles=internal_issue_cycles,
		internal_start_cycles=internal_start_cycles,
		internal_feed_cycles=internal_feed_cycles,
		internal_collect_cycles=internal_collect_cycles,
		internal_drain_cycles=internal_drain_cycles,
		internal_row_capture_cycles=internal_row_capture_cycles,
		internal_m_writeback_cycles=internal_m_writeback_cycles,
		internal_resp_merge_cycles=internal_resp_merge_cycles,
		internal_total_cycles=internal_total_cycles,
		internal_overlap_steady_cycles=internal_overlap_steady_cycles,
		export_phase_cycles=export_phase_cycles,
		ctrl_resp_visible_cycles=ctrl_resp_visible_cycles,
		single_tile_latency_cycles=single_tile_latency_cycles,
		sustained_cycles_per_tile=sustained_cycles_per_tile,
		sustained_ops_per_cycle=sustained_ops_per_cycle,
		sustained_macs_per_cycle=sustained_macs_per_cycle,
		effective_util_pct=effective_util_pct,
		latency_ns=latency_ns,
		sustained_gops=sustained_gops,
		sustained_tops=sustained_tops,
		roofline_ops_per_cycle_ext_in=roofline_ops_per_cycle_ext_in,
		roofline_ops_per_cycle_ext_out=roofline_ops_per_cycle_ext_out,
		external_input_min_cycles_ideal=cold_input_beats if args.scenario in ("cold_miss", "steady_stream_cold") else (cold_input_beats * cold_ratio if args.scenario == "steady_stream_mixed" else 0.0),
		external_output_min_cycles_ideal=export_beats_per_tile,
		overall_bottleneck_stage=overall_bottleneck_stage,
		external_bottleneck_stage=external_bottleneck_stage,
		internal_bottleneck_stage=internal_bottleneck_stage,
		internal_stage_shares=internal_stage_shares,
		latency_stage_shares=latency_stage_shares,
	)


def print_text(result: PTPerfResult) -> None:
	print(f"Scenario: {result.scenario}")
	print(f"Tile: {result.x_dim}x{result.y_dim}, data_width={result.data_width}")
	print(
		f"Structure: a_load_lanes={result.a_load_lanes}, b_load_lanes={result.b_load_lanes}, "
		f"m_write_lanes={result.m_write_lanes}, "
		f"m_export_lanes={result.m_export_lanes}, m_physical_copies={result.m_physical_copies}, "
		f"matmul_overlap_depth={result.matmul_overlap_depth}"
	)
	if result.scenario == "steady_stream_mixed":
		print(f"Mixed cold ratio: {result.cold_ratio:.3f}")
	print("")
	print("Compute")
	print(f"  Peak MAC/cycle      : {result.peak_macs_per_cycle:.6f}")
	print(f"  Peak OP/cycle       : {result.peak_ops_per_cycle:.6f}")
	print(f"  MACs/tile           : {result.macs_per_tile}")
	print(f"  Ops/tile            : {result.ops_per_tile}")
	print("")
	print("Latency / Throughput")
	print(f"  To ctrl_resp cycles : {result.ctrl_resp_visible_cycles:.3f}")
	print(f"  Single-tile cycles  : {result.single_tile_latency_cycles:.3f}")
	print(f"  Sustained cyc/tile  : {result.sustained_cycles_per_tile:.3f}")
	print(f"  Sustained MAC/cycle : {result.sustained_macs_per_cycle:.6f}")
	print(f"  Sustained OP/cycle  : {result.sustained_ops_per_cycle:.6f}")
	print(f"  Utilization (%)     : {result.effective_util_pct:.3f}")
	if result.latency_ns is not None:
		print(f"  Single-tile ns      : {result.latency_ns:.3f}")
		print(f"  Sustained GOPS      : {result.sustained_gops:.6f}")
		print(f"  Sustained TOPS      : {result.sustained_tops:.6f}")
	print("")
	print("External Memory")
	print(f"  Input beats         : {result.external_input_beats:.3f}")
	print(f"  A load beats/tile   : {result.a_input_beats_per_tile:.3f}")
	print(f"  B load beats/tile   : {result.b_input_beats_per_tile:.3f}")
	print(f"  Output beats        : {result.external_output_beats:.3f}")
	print(f"  Total beats         : {result.external_total_beats:.3f}")
	print(f"  Input bytes         : {result.external_input_bytes:.3f}")
	print(f"  Output bytes        : {result.external_output_bytes:.3f}")
	print(f"  Total bytes         : {result.external_total_bytes:.3f}")
	print(f"  Input bytes/op      : {0.0 if result.input_bytes_per_op is None else result.input_bytes_per_op:.6f}")
	print(f"  Output bytes/op     : {0.0 if result.output_bytes_per_op is None else result.output_bytes_per_op:.6f}")
	print(f"  Total bytes/op      : {result.external_bytes_per_op:.6f}")
	print(f"  Beats/op            : {result.external_beats_per_op:.6f}")
	print(f"  Ext in bytes/cycle  : {result.ext_in_bytes_per_cycle:.6f}")
	print(f"  Ext out bytes/cycle : {result.ext_out_bytes_per_cycle:.6f}")
	print(f"  Roofline in op/cyc  : {'n/a' if result.roofline_ops_per_cycle_ext_in is None else f'{result.roofline_ops_per_cycle_ext_in:.6f}'}")
	print(f"  Roofline out op/cyc : {'n/a' if result.roofline_ops_per_cycle_ext_out is None else f'{result.roofline_ops_per_cycle_ext_out:.6f}'}")
	print(f"  Ideal in cycles     : {result.external_input_min_cycles_ideal:.3f}")
	print(f"  Ideal out cycles    : {result.external_output_min_cycles_ideal:.3f}")
	print(f"  Effective in cycles : {result.input_phase_cycles:.3f}")
	print(f"  Effective out cycles: {result.export_phase_cycles:.3f}")
	print(f"  Ext bottleneck      : {result.external_bottleneck_stage}")
	print("")
	print("On-chip Memory")
	print(f"  Operand read bytes  : {result.logical_onchip_operand_read_bytes}")
	print(f"  Logical M writeback : {result.logical_onchip_m_writeback_bytes}")
	print(f"  Physical M writes   : {result.physical_onchip_m_writeback_bytes}")
	print(f"  Export read bytes   : {result.logical_onchip_export_read_bytes}")
	print(f"  Logical total bytes : {result.logical_onchip_total_bytes}")
	print(f"  Physical total bytes: {result.physical_onchip_total_bytes}")
	print(f"  Logical bytes/op    : {result.logical_onchip_bytes_per_op:.6f}")
	print(f"  Physical bytes/op   : {result.physical_onchip_bytes_per_op:.6f}")
	print("")
	print("Internal Stage Cycles")
	print(f"  issue_dispatch      : {result.internal_issue_cycles}")
	print(f"  exec_start          : {result.internal_start_cycles}")
	print(f"  gemm_feed           : {result.internal_feed_cycles}")
	print(f"  gemm_collect        : {result.internal_collect_cycles}")
	print(f"  matmul_drain        : {result.internal_drain_cycles}")
	print(f"  quant_row_capture   : {result.internal_row_capture_cycles}")
	print(f"  m_writeback         : {result.internal_m_writeback_cycles}")
	print(f"  resp_merge          : {result.internal_resp_merge_cycles}")
	print(f"  internal_total      : {result.internal_total_cycles}")
	print(f"  overlap_steady_ii   : {result.internal_overlap_steady_cycles:.3f}")
	print(f"  Internal bottleneck : {result.internal_bottleneck_stage}")
	print("")
	print("Latency Stage Shares (%)")
	for name, share in result.latency_stage_shares.items():
		print(f"  {name:18s}: {share:8.3f}")
	print("")
	print(f"Overall bottleneck    : {result.overall_bottleneck_stage}")


def parse_args() -> argparse.Namespace:
	parser = argparse.ArgumentParser(description="PT tile throughput and memory bottleneck estimator")
	parser.add_argument("--x-dim", type=int, required=True)
	parser.add_argument("--y-dim", type=int, required=True)
	parser.add_argument("--data-width", type=int, default=32)
	parser.add_argument("--freq-mhz", type=float, default=None, help="Backward-compatible alias for --target-freq-mhz")
	parser.add_argument("--target-freq-mhz", type=float, default=None)
	parser.add_argument("--ext-in-beats-per-cycle", type=float, default=1.0)
	parser.add_argument("--ext-out-beats-per-cycle", type=float, default=1.0)
	parser.add_argument("--ext-in-gbps", type=float, default=None, help="Absolute input bandwidth in GB/s")
	parser.add_argument("--ext-out-gbps", type=float, default=None, help="Absolute output bandwidth in GB/s")
	parser.add_argument("--dma-req-overhead-cycles", type=float, default=2.0)
	parser.add_argument("--dma-done-latency-cycles", type=float, default=2.0)
	parser.add_argument("--m-dma-done-latency-cycles", type=float, default=2.0)
	parser.add_argument("--cold-ratio", type=float, default=0.5, help="Used only for steady_stream_mixed")
	parser.add_argument("--a-load-lanes", type=int, default=1)
	parser.add_argument("--b-load-lanes", type=int, default=1)
	parser.add_argument("--m-write-lanes", type=int, default=1)
	parser.add_argument("--m-export-lanes", type=int, default=1)
	parser.add_argument("--m-physical-copies", type=int, default=3)
	parser.add_argument("--matmul-overlap-depth", type=int, default=None,
		help="Pipeline overlap depth. Default: 2 when m_write_lanes >= y_dim (full-width drain), else 1.")
	parser.add_argument("--scenario", choices=SCENARIOS, required=True)
	parser.add_argument("--format", choices=("text", "json"), default="text")
	args = parser.parse_args()
	if args.matmul_overlap_depth is None:
		args.matmul_overlap_depth = 2 if args.m_write_lanes >= args.y_dim else 1
	if args.data_width % 8 != 0:
		raise ValueError("data_width must be byte-aligned")
	if not (0.0 <= args.cold_ratio <= 1.0):
		raise ValueError("cold_ratio must be within [0, 1]")
	return args


def main() -> None:
	args = parse_args()
	result = build_result(args)
	if args.format == "json":
		print(json.dumps(asdict(result), indent=2, sort_keys=True))
	else:
		print_text(result)


if __name__ == "__main__":
	main()
