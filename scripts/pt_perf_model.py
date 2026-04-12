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


def ceil_div_rate(beats: float, beats_per_cycle: float) -> float:
	if beats_per_cycle <= 0:
		raise ValueError("beats_per_cycle must be > 0")
	return math.ceil(beats / beats_per_cycle)


def pct(part: float, total: float) -> float:
	return 0.0 if total == 0 else (100.0 * part / total)


@dataclass
class PTPerfResult:
	scenario: str
	x_dim: int
	y_dim: int
	data_width: int
	word_bytes: int
	cold_ratio: float
	macs_per_tile: int
	ops_per_tile: int
	external_input_beats: float
	external_output_beats: float
	external_total_beats: float
	external_input_bytes: float
	external_output_bytes: float
	external_total_bytes: float
	external_bytes_per_op: float
	external_beats_per_op: float
	onchip_operand_read_bytes: int
	onchip_m_writeback_bytes: int
	onchip_export_read_bytes: int
	onchip_total_bytes: int
	onchip_bytes_per_op: float
	a_load_cycles: float
	b_load_cycles: float
	input_phase_cycles: float
	internal_issue_cycles: int
	internal_start_cycles: int
	internal_feed_cycles: int
	internal_collect_cycles: int
	internal_row_capture_cycles: int
	internal_m_writeback_cycles: int
	internal_resp_merge_cycles: int
	internal_total_cycles: int
	export_phase_cycles: float
	ctrl_resp_visible_cycles: float
	single_tile_latency_cycles: float
	sustained_cycles_per_tile: float
	sustained_ops_per_cycle: float
	sustained_macs_per_cycle: float
	latency_ns: float | None
	sustained_gops: float | None
	sustained_tops: float | None
	external_input_min_cycles_ideal: float
	external_output_min_cycles_ideal: float
	overall_bottleneck_stage: str
	external_bottleneck_stage: str
	internal_bottleneck_stage: str
	internal_stage_shares: Dict[str, float]
	latency_stage_shares: Dict[str, float]


def build_result(args: argparse.Namespace) -> PTPerfResult:
	x_dim = args.x_dim
	y_dim = args.y_dim
	data_width = args.data_width
	word_bytes = data_width // 8
	cold_ratio = args.cold_ratio if args.scenario == "steady_stream_mixed" else (1.0 if args.scenario in ("cold_miss", "steady_stream_cold") else 0.0)

	macs_per_tile = x_dim * y_dim * x_dim
	ops_per_tile = 2 * macs_per_tile

	cold_input_beats = float((x_dim * x_dim) + (y_dim * y_dim))
	cold_output_beats = float(x_dim * y_dim)
	cold_total_beats = cold_input_beats + cold_output_beats

	cold_input_bytes = cold_input_beats * word_bytes
	cold_output_bytes = cold_output_beats * word_bytes

	a_load_cycles = ceil_div_rate(x_dim * x_dim, args.ext_in_beats_per_cycle) + args.dma_req_overhead_cycles + args.dma_done_latency_cycles
	b_load_cycles = ceil_div_rate(y_dim * y_dim, args.ext_in_beats_per_cycle) + args.dma_req_overhead_cycles + args.dma_done_latency_cycles
	cold_input_phase_cycles = a_load_cycles + b_load_cycles

	internal_issue_cycles = 1
	internal_start_cycles = 1
	internal_feed_cycles = x_dim
	internal_collect_cycles = 2
	internal_row_capture_cycles = x_dim
	internal_m_writeback_cycles = x_dim * y_dim
	internal_resp_merge_cycles = 1
	internal_total_cycles = (
		internal_issue_cycles
		+ internal_start_cycles
		+ internal_feed_cycles
		+ internal_collect_cycles
		+ internal_row_capture_cycles
		+ internal_m_writeback_cycles
		+ internal_resp_merge_cycles
	)

	export_phase_cycles = ceil_div_rate(x_dim * y_dim, args.ext_out_beats_per_cycle) + args.dma_req_overhead_cycles + args.m_dma_done_latency_cycles

	onchip_operand_read_bytes = word_bytes * x_dim * (x_dim + y_dim)
	onchip_m_writeback_bytes = word_bytes * x_dim * y_dim * 2
	onchip_export_read_bytes = word_bytes * x_dim * y_dim
	onchip_total_bytes = onchip_operand_read_bytes + onchip_m_writeback_bytes + onchip_export_read_bytes

	if args.scenario == "cold_miss":
		input_phase_cycles = cold_input_phase_cycles
		external_input_beats = cold_input_beats
		external_output_beats = cold_output_beats
		ctrl_resp_visible_cycles = input_phase_cycles + internal_total_cycles
		single_tile_latency_cycles = input_phase_cycles + internal_total_cycles + export_phase_cycles
		sustained_cycles_per_tile = single_tile_latency_cycles
	elif args.scenario in ("cache_hit", "m_window"):
		input_phase_cycles = 0.0
		external_input_beats = 0.0
		external_output_beats = cold_output_beats
		ctrl_resp_visible_cycles = internal_total_cycles
		single_tile_latency_cycles = internal_total_cycles + export_phase_cycles
		sustained_cycles_per_tile = single_tile_latency_cycles
	elif args.scenario == "steady_stream_cold":
		input_phase_cycles = cold_input_phase_cycles
		external_input_beats = cold_input_beats
		external_output_beats = cold_output_beats
		ctrl_resp_visible_cycles = input_phase_cycles + internal_total_cycles
		single_tile_latency_cycles = cold_input_phase_cycles + internal_total_cycles + export_phase_cycles
		sustained_cycles_per_tile = max(cold_input_phase_cycles, internal_total_cycles, export_phase_cycles)
	elif args.scenario == "steady_stream_mixed":
		input_phase_cycles = cold_input_phase_cycles * cold_ratio
		external_input_beats = cold_input_beats * cold_ratio
		external_output_beats = cold_output_beats
		ctrl_resp_visible_cycles = input_phase_cycles + internal_total_cycles
		single_tile_latency_cycles = (cold_input_phase_cycles * cold_ratio) + internal_total_cycles + export_phase_cycles
		sustained_cycles_per_tile = max(input_phase_cycles, internal_total_cycles, export_phase_cycles)
	else:
		raise ValueError(f"unsupported scenario {args.scenario!r}")

	external_total_beats = external_input_beats + external_output_beats
	external_input_bytes = external_input_beats * word_bytes
	external_output_bytes = external_output_beats * word_bytes
	external_total_bytes = external_input_bytes + external_output_bytes

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
	if args.freq_mhz is not None:
		latency_ns = single_tile_latency_cycles / args.freq_mhz * 1000.0
		sustained_gops = sustained_ops_per_cycle * args.freq_mhz / 1000.0
		sustained_tops = sustained_gops / 1000.0

	return PTPerfResult(
		scenario=args.scenario,
		x_dim=x_dim,
		y_dim=y_dim,
		data_width=data_width,
		word_bytes=word_bytes,
		cold_ratio=cold_ratio,
		macs_per_tile=macs_per_tile,
		ops_per_tile=ops_per_tile,
		external_input_beats=external_input_beats,
		external_output_beats=external_output_beats,
		external_total_beats=external_total_beats,
		external_input_bytes=external_input_bytes,
		external_output_bytes=external_output_bytes,
		external_total_bytes=external_total_bytes,
		external_bytes_per_op=(external_total_bytes / ops_per_tile),
		external_beats_per_op=(external_total_beats / ops_per_tile),
		onchip_operand_read_bytes=onchip_operand_read_bytes,
		onchip_m_writeback_bytes=onchip_m_writeback_bytes,
		onchip_export_read_bytes=onchip_export_read_bytes,
		onchip_total_bytes=onchip_total_bytes,
		onchip_bytes_per_op=(onchip_total_bytes / ops_per_tile),
		a_load_cycles=a_load_cycles,
		b_load_cycles=b_load_cycles,
		input_phase_cycles=input_phase_cycles,
		internal_issue_cycles=internal_issue_cycles,
		internal_start_cycles=internal_start_cycles,
		internal_feed_cycles=internal_feed_cycles,
		internal_collect_cycles=internal_collect_cycles,
		internal_row_capture_cycles=internal_row_capture_cycles,
		internal_m_writeback_cycles=internal_m_writeback_cycles,
		internal_resp_merge_cycles=internal_resp_merge_cycles,
		internal_total_cycles=internal_total_cycles,
		export_phase_cycles=export_phase_cycles,
		ctrl_resp_visible_cycles=ctrl_resp_visible_cycles,
		single_tile_latency_cycles=single_tile_latency_cycles,
		sustained_cycles_per_tile=sustained_cycles_per_tile,
		sustained_ops_per_cycle=(ops_per_tile / sustained_cycles_per_tile),
		sustained_macs_per_cycle=(macs_per_tile / sustained_cycles_per_tile),
		latency_ns=latency_ns,
		sustained_gops=sustained_gops,
		sustained_tops=sustained_tops,
		external_input_min_cycles_ideal=cold_input_beats if args.scenario in ("cold_miss", "steady_stream_cold") else (cold_input_beats * cold_ratio if args.scenario == "steady_stream_mixed" else 0.0),
		external_output_min_cycles_ideal=cold_output_beats,
		overall_bottleneck_stage=overall_bottleneck_stage,
		external_bottleneck_stage=external_bottleneck_stage,
		internal_bottleneck_stage=internal_bottleneck_stage,
		internal_stage_shares=internal_stage_shares,
		latency_stage_shares=latency_stage_shares,
	)


def print_text(result: PTPerfResult) -> None:
	print(f"Scenario: {result.scenario}")
	print(f"Tile: {result.x_dim}x{result.y_dim}, data_width={result.data_width}")
	if result.scenario == "steady_stream_mixed":
		print(f"Mixed cold ratio: {result.cold_ratio:.3f}")
	print("")
	print("Compute")
	print(f"  MACs/tile           : {result.macs_per_tile}")
	print(f"  Ops/tile            : {result.ops_per_tile}")
	print("")
	print("Latency / Throughput")
	print(f"  To ctrl_resp cycles  : {result.ctrl_resp_visible_cycles:.3f}")
	print(f"  Single-tile cycles  : {result.single_tile_latency_cycles:.3f}")
	print(f"  Sustained cyc/tile  : {result.sustained_cycles_per_tile:.3f}")
	print(f"  Sustained MAC/cycle : {result.sustained_macs_per_cycle:.6f}")
	print(f"  Sustained OP/cycle  : {result.sustained_ops_per_cycle:.6f}")
	if result.latency_ns is not None:
		print(f"  Single-tile ns      : {result.latency_ns:.3f}")
		print(f"  Sustained GOPS      : {result.sustained_gops:.6f}")
		print(f"  Sustained TOPS      : {result.sustained_tops:.6f}")
	print("")
	print("External Memory")
	print(f"  Input beats         : {result.external_input_beats:.3f}")
	print(f"  Output beats        : {result.external_output_beats:.3f}")
	print(f"  Total beats         : {result.external_total_beats:.3f}")
	print(f"  Input bytes         : {result.external_input_bytes:.3f}")
	print(f"  Output bytes        : {result.external_output_bytes:.3f}")
	print(f"  Total bytes         : {result.external_total_bytes:.3f}")
	print(f"  Bytes/op            : {result.external_bytes_per_op:.6f}")
	print(f"  Beats/op            : {result.external_beats_per_op:.6f}")
	print(f"  Ideal in cycles@1   : {result.external_input_min_cycles_ideal:.3f}")
	print(f"  Ideal out cycles@1  : {result.external_output_min_cycles_ideal:.3f}")
	print(f"  Effective in cycles : {result.input_phase_cycles:.3f}")
	print(f"  Effective out cycles: {result.export_phase_cycles:.3f}")
	print(f"  Ext bottleneck      : {result.external_bottleneck_stage}")
	print("")
	print("On-chip Memory")
	print(f"  Operand read bytes  : {result.onchip_operand_read_bytes}")
	print(f"  M writeback bytes   : {result.onchip_m_writeback_bytes}")
	print(f"  Export read bytes   : {result.onchip_export_read_bytes}")
	print(f"  Total bytes         : {result.onchip_total_bytes}")
	print(f"  Bytes/op            : {result.onchip_bytes_per_op:.6f}")
	print("")
	print("Internal Stage Cycles")
	print(f"  issue_dispatch      : {result.internal_issue_cycles}")
	print(f"  exec_start          : {result.internal_start_cycles}")
	print(f"  gemm_feed           : {result.internal_feed_cycles}")
	print(f"  gemm_collect        : {result.internal_collect_cycles}")
	print(f"  quant_row_capture   : {result.internal_row_capture_cycles}")
	print(f"  m_writeback         : {result.internal_m_writeback_cycles}")
	print(f"  resp_merge          : {result.internal_resp_merge_cycles}")
	print(f"  internal_total      : {result.internal_total_cycles}")
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
	parser.add_argument("--freq-mhz", type=float, default=None)
	parser.add_argument("--ext-in-beats-per-cycle", type=float, default=1.0)
	parser.add_argument("--ext-out-beats-per-cycle", type=float, default=1.0)
	parser.add_argument("--dma-req-overhead-cycles", type=float, default=2.0)
	parser.add_argument("--dma-done-latency-cycles", type=float, default=2.0)
	parser.add_argument("--m-dma-done-latency-cycles", type=float, default=2.0)
	parser.add_argument("--cold-ratio", type=float, default=0.5, help="Used only for steady_stream_mixed")
	parser.add_argument("--scenario", choices=SCENARIOS, required=True)
	parser.add_argument("--format", choices=("text", "json"), default="text")
	args = parser.parse_args()
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
