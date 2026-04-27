from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

if __package__ in {None, ""}:
	sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from app.pt_tiled_gemm import (
	DEFAULT_APP_TARGET,
	DEFAULT_OUT_DIR,
	DEFAULT_PROBLEM,
	ProblemSpec,
	SUPPORTED_APP_TARGETS,
	default_metrics_path,
	default_report_path,
	normalize_app_target,
)
from app.pt_tiled_gemm.multitile_runner import render_multitile_text, run_multitile_sweep
from app.pt_tiled_gemm.param_utils import load_pt_param_snapshot
from app.pt_tiled_gemm.planner import build_recommendation, build_report_markdown, render_text
from app.pt_tiled_gemm.regression_runner import render_regression_text, run_regression_matrix
from app.pt_tiled_gemm.submission import (
	SUBMISSION_MODE_LEGACY,
	SUBMISSION_MODE_SHADOW_DELTA,
	SUPPORTED_SUBMISSION_MODES,
)
from app.pt_tiled_gemm.verify_runner import render_verify_text, run_verification


def _problem_from_args(args: argparse.Namespace) -> ProblemSpec:
	return ProblemSpec(m_dim=args.m, k_dim=args.k, n_dim=args.n)


def _target_from_args(args: argparse.Namespace) -> str:
	return normalize_app_target(args.target)


def _add_problem_args(parser: argparse.ArgumentParser) -> None:
	parser.add_argument("--m", type=int, default=DEFAULT_PROBLEM.m_dim, help="矩阵 A 的行数 / 输出 C 的行数，必须是 16 的倍数")
	parser.add_argument("--k", type=int, default=DEFAULT_PROBLEM.k_dim, help="矩阵 A 的列数 / B 的行数，必须是 16 的倍数")
	parser.add_argument("--n", type=int, default=DEFAULT_PROBLEM.n_dim, help="矩阵 B 的列数 / 输出 C 的列数，必须是 16 的倍数")


def _add_target_arg(parser: argparse.ArgumentParser) -> None:
	parser.add_argument(
		"--target",
		default=DEFAULT_APP_TARGET,
		choices=list(SUPPORTED_APP_TARGETS),
		help="选择 app 运行目标：native `PT` 或 wrapper `PT_DMA_TOP`",
	)


def _parse_tile_list(value: str) -> tuple[int, ...]:
	snapshot = load_pt_param_snapshot()
	valid = set(snapshot.valid_tile_counts)
	items = []
	for token in value.split(","):
		text = token.strip()
		if not text:
			continue
		tile = int(text)
		if tile not in valid:
			raise argparse.ArgumentTypeError(f"tile count must be one of {sorted(valid)}, got {tile}")
		items.append(tile)
	if not items:
		raise argparse.ArgumentTypeError("tile list cannot be empty")
	return tuple(dict.fromkeys(items))


def _recommend_command(problem: ProblemSpec, target: str, as_json: bool) -> int:
	recommendation = build_recommendation(problem, default_metrics_path(problem, target), target=target)
	if as_json:
		print(json.dumps(recommendation.to_dict(), ensure_ascii=False, indent=2))
	else:
		print(render_text(recommendation))
	return 0


def _verify_command(problem: ProblemSpec, target: str, sim_name: str, submission_mode: str, waves: bool, as_json: bool) -> int:
	result = run_verification(problem=problem, target=target, sim_name=sim_name, submission_mode=submission_mode, waves=waves)
	if as_json:
		print(json.dumps(result.to_dict(), ensure_ascii=False, indent=2))
	else:
		print(render_verify_text(result))
	return 0 if result.success else 1


def _report_command(problem: ProblemSpec, target: str, sim_name: str, submission_mode: str, waves: bool, out_path: Path) -> int:
	out_path.parent.mkdir(parents=True, exist_ok=True)
	metrics_path = default_metrics_path(problem, target)
	initial_recommendation = build_recommendation(problem, metrics_path, target=target)
	verify_result = run_verification(problem=problem, target=target, sim_name=sim_name, submission_mode=submission_mode, waves=waves)
	if verify_result.success:
		recommendation = build_recommendation(
			problem,
			metrics_path,
			verify_metrics={
				"algorithms": verify_result.algorithms,
				"unsupported_paths": verify_result.unsupported_paths,
			},
			target=target,
		)
	else:
		recommendation = initial_recommendation

	report = build_report_markdown(recommendation, verify_result.to_dict())
	out_path.write_text(report, encoding="utf-8")
	print(f"report written to {out_path}")
	if not verify_result.success and verify_result.message:
		print(f"verify note: {verify_result.message}")
	return 0


def _multitile_command(
	*,
	target: str,
	sim_name: str,
	m_tiles: tuple[int, ...],
	n_tiles: tuple[int, ...],
	k_tiles: tuple[int, ...],
	submission_mode: str,
	waves: bool,
	as_json: bool,
	out_path: Path | None,
) -> int:
	result = run_multitile_sweep(
		target=target,
		sim_name=sim_name,
		m_tiles=m_tiles,
		n_tiles=n_tiles,
		k_tiles=k_tiles,
		submission_mode=submission_mode,
		waves=waves,
		out_path=out_path,
	)
	if as_json:
		print(json.dumps(result.to_dict(), ensure_ascii=False, indent=2))
	else:
		print(render_multitile_text(result))
	return 0 if result.success else 1


def _regress_command(*, sim_name: str, waves: bool, as_json: bool, out_path: Path | None) -> int:
	result = run_regression_matrix(sim_name=sim_name, waves=waves, out_path=out_path)
	if as_json:
		print(json.dumps(result.to_dict(), ensure_ascii=False, indent=2))
	else:
		print(render_regression_text(result))
	return 0 if result.success else 1


def parse_args() -> argparse.Namespace:
	parser = argparse.ArgumentParser(description="PT tiled application CLI")
	subparsers = parser.add_subparsers(dest="command", required=True)

	recommend = subparsers.add_parser("recommend", help="输出当前 M/K/N 下的算法推荐")
	_add_problem_args(recommend)
	_add_target_arg(recommend)
	recommend.add_argument("--json", action="store_true", help="输出机器可读 JSON")

	verify = subparsers.add_parser("verify", help="运行 app 本地 cocotb 验证")
	_add_problem_args(verify)
	_add_target_arg(verify)
	verify.add_argument("--sim", default="verilator", choices=["verilator", "questa"])
	verify.add_argument("--submission-mode", default=SUBMISSION_MODE_LEGACY, choices=list(SUPPORTED_SUBMISSION_MODES))
	verify.add_argument("--waves", action="store_true")
	verify.add_argument("--json", action="store_true", help="输出机器可读 JSON")

	report = subparsers.add_parser("report", help="生成 Markdown 报告并附带 verify 结果")
	_add_problem_args(report)
	_add_target_arg(report)
	report.add_argument("--sim", default="verilator", choices=["verilator", "questa"])
	report.add_argument("--submission-mode", default=SUBMISSION_MODE_LEGACY, choices=list(SUPPORTED_SUBMISSION_MODES))
	report.add_argument("--waves", action="store_true")
	report.add_argument("--out", type=Path, default=None, help="输出 Markdown 路径，默认使用 shape-specific 文件名")

	multitile = subparsers.add_parser("multitile", help="扫 m/n/k=1/2/4 组合并统计单命令吞吐量")
	_add_target_arg(multitile)
	multitile.add_argument("--sim", default="verilator", choices=["verilator", "questa"])
	multitile.add_argument("--submission-mode", default=SUBMISSION_MODE_SHADOW_DELTA, choices=list(SUPPORTED_SUBMISSION_MODES))
	multitile.add_argument("--m-tiles", type=_parse_tile_list, default=(1, 2, 4), help="逗号分隔的 m_tiles 列表，默认 1,2,4")
	multitile.add_argument("--n-tiles", type=_parse_tile_list, default=(1, 2, 4), help="逗号分隔的 n_tiles 列表，默认 1,2,4")
	multitile.add_argument("--k-tiles", type=_parse_tile_list, default=(1, 2, 4), help="逗号分隔的 k_tiles 列表，默认 1,2,4")
	multitile.add_argument("--waves", action="store_true")
	multitile.add_argument("--json", action="store_true", help="输出机器可读 JSON")
	multitile.add_argument("--out", type=Path, default=None, help="输出聚合 JSON 路径，默认写到 app/pt_tiled_gemm/out/")

	regress = subparsers.add_parser("regress", help="运行固定的 channel verify/multitile 回归矩阵")
	regress.add_argument("--sim", default="verilator", choices=["verilator", "questa"])
	regress.add_argument("--waves", action="store_true")
	regress.add_argument("--json", action="store_true", help="输出机器可读 JSON")
	regress.add_argument("--out", type=Path, default=None, help="输出聚合 JSON 路径，默认写到 app/pt_tiled_gemm/out/")

	return parser.parse_args()


def main() -> int:
	DEFAULT_OUT_DIR.mkdir(parents=True, exist_ok=True)
	args = parse_args()
	try:
		target = _target_from_args(args) if hasattr(args, "target") else DEFAULT_APP_TARGET
		if args.command not in {"multitile", "regress"}:
			problem = _problem_from_args(args)
			problem.validate()
		else:
			problem = None
	except ValueError as exc:
		print(f"invalid arguments: {exc}", file=sys.stderr)
		return 2

	if args.command == "recommend":
		assert problem is not None
		return _recommend_command(problem, target, args.json)
	if args.command == "verify":
		assert problem is not None
		return _verify_command(problem, target, args.sim, args.submission_mode, args.waves, args.json)
	if args.command == "report":
		assert problem is not None
		out_path = args.out if args.out is not None else default_report_path(problem, target)
		return _report_command(problem, target, args.sim, args.submission_mode, args.waves, out_path)
	if args.command == "multitile":
		return _multitile_command(
			target=target,
			sim_name=args.sim,
			m_tiles=args.m_tiles,
			n_tiles=args.n_tiles,
			k_tiles=args.k_tiles,
			submission_mode=args.submission_mode,
			waves=args.waves,
			as_json=args.json,
			out_path=args.out,
		)
	if args.command == "regress":
		return _regress_command(
			sim_name=args.sim,
			waves=args.waves,
			as_json=args.json,
			out_path=args.out,
		)
	raise ValueError(f"unsupported command {args.command!r}")


if __name__ == "__main__":
	raise SystemExit(main())
