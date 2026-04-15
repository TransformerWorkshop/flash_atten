from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

if __package__ in {None, ""}:
	sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from app.pt_tiled_gemm import DEFAULT_OUT_DIR, DEFAULT_PROBLEM, ProblemSpec, default_metrics_path, default_report_path
from app.pt_tiled_gemm.planner import build_recommendation, build_report_markdown, render_text
from app.pt_tiled_gemm.verify_runner import render_verify_text, run_verification


def _problem_from_args(args: argparse.Namespace) -> ProblemSpec:
	return ProblemSpec(m_dim=args.m, k_dim=args.k, n_dim=args.n)


def _add_problem_args(parser: argparse.ArgumentParser) -> None:
	parser.add_argument("--m", type=int, default=DEFAULT_PROBLEM.m_dim, help="矩阵 A 的行数 / 输出 C 的行数，必须是 16 的倍数")
	parser.add_argument("--k", type=int, default=DEFAULT_PROBLEM.k_dim, help="矩阵 A 的列数 / B 的行数，必须是 16 的倍数")
	parser.add_argument("--n", type=int, default=DEFAULT_PROBLEM.n_dim, help="矩阵 B 的列数 / 输出 C 的列数，必须是 16 的倍数")


def _recommend_command(problem: ProblemSpec, as_json: bool) -> int:
	recommendation = build_recommendation(problem, default_metrics_path(problem))
	if as_json:
		print(json.dumps(recommendation.to_dict(), ensure_ascii=False, indent=2))
	else:
		print(render_text(recommendation))
	return 0


def _verify_command(problem: ProblemSpec, sim_name: str, waves: bool, as_json: bool) -> int:
	result = run_verification(problem=problem, sim_name=sim_name, waves=waves)
	if as_json:
		print(json.dumps(result.to_dict(), ensure_ascii=False, indent=2))
	else:
		print(render_verify_text(result))
	return 0 if result.success else 1


def _report_command(problem: ProblemSpec, sim_name: str, waves: bool, out_path: Path) -> int:
	out_path.parent.mkdir(parents=True, exist_ok=True)
	metrics_path = default_metrics_path(problem)
	initial_recommendation = build_recommendation(problem, metrics_path)
	verify_result = run_verification(problem=problem, sim_name=sim_name, waves=waves)
	if verify_result.success:
		recommendation = build_recommendation(
			problem,
			metrics_path,
			verify_metrics={
				"algorithms": verify_result.algorithms,
				"unsupported_paths": verify_result.unsupported_paths,
			},
		)
	else:
		recommendation = initial_recommendation

	report = build_report_markdown(recommendation, verify_result.to_dict())
	out_path.write_text(report, encoding="utf-8")
	print(f"report written to {out_path}")
	if not verify_result.success and verify_result.message:
		print(f"verify note: {verify_result.message}")
	return 0


def parse_args() -> argparse.Namespace:
	parser = argparse.ArgumentParser(description="PT tiled application CLI")
	subparsers = parser.add_subparsers(dest="command", required=True)

	recommend = subparsers.add_parser("recommend", help="输出当前 M/K/N 下的算法推荐")
	_add_problem_args(recommend)
	recommend.add_argument("--json", action="store_true", help="输出机器可读 JSON")

	verify = subparsers.add_parser("verify", help="运行 app 本地 cocotb 验证")
	_add_problem_args(verify)
	verify.add_argument("--sim", default="icarus", choices=["icarus", "verilator", "questa"])
	verify.add_argument("--waves", action="store_true")
	verify.add_argument("--json", action="store_true", help="输出机器可读 JSON")

	report = subparsers.add_parser("report", help="生成 Markdown 报告并附带 verify 结果")
	_add_problem_args(report)
	report.add_argument("--sim", default="icarus", choices=["icarus", "verilator", "questa"])
	report.add_argument("--waves", action="store_true")
	report.add_argument("--out", type=Path, default=None, help="输出 Markdown 路径，默认使用 shape-specific 文件名")

	return parser.parse_args()


def main() -> int:
	DEFAULT_OUT_DIR.mkdir(parents=True, exist_ok=True)
	args = parse_args()
	try:
		problem = _problem_from_args(args)
		problem.validate()
	except ValueError as exc:
		print(f"invalid problem shape: {exc}", file=sys.stderr)
		return 2

	if args.command == "recommend":
		return _recommend_command(problem, args.json)
	if args.command == "verify":
		return _verify_command(problem, args.sim, args.waves, args.json)
	if args.command == "report":
		out_path = args.out if args.out is not None else default_report_path(problem)
		return _report_command(problem, args.sim, args.waves, out_path)
	raise ValueError(f"unsupported command {args.command!r}")


if __name__ == "__main__":
	raise SystemExit(main())
