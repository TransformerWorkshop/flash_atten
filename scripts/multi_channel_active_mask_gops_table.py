from __future__ import annotations

import os
from pathlib import Path

from app.pt_tiled_gemm.multitile_runner import run_multitile_sweep


REPO_ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = REPO_ROOT / "app" / "pt_tiled_gemm" / "out"

SIM = "icarus"
SUBMISSION_MODE = "compact"

MASK_CLASSES = {
	"pt_dma_top_v3_ch2": {
		1: {"rep": 0x1, "masks": [0x1, 0x2]},
		2: {"rep": 0x3, "masks": [0x3]},
	},
	"pt_dma_top_v3_ch4": {
		1: {"rep": 0x1, "masks": [0x1, 0x2, 0x4, 0x8]},
		2: {"rep": 0x3, "masks": [0x3, 0x5, 0x6, 0x9, 0xA, 0xC]},
		4: {"rep": 0xF, "masks": [0xF]},
	},
}


def run_rep_multitile(target: str, active_mask: int):
	prev_mask = os.environ.get("PT_ACTIVE_CHANNEL_MASK")
	os.environ["PT_ACTIVE_CHANNEL_MASK"] = str(active_mask)
	try:
		return run_multitile_sweep(
			target=target,
			sim_name=SIM,
			m_tiles=(1, 2, 4),
			n_tiles=(1, 2, 4),
			k_tiles=(1, 2, 4),
			submission_mode=SUBMISSION_MODE,
			waves=False,
		)
	finally:
		if prev_mask is None:
			os.environ.pop("PT_ACTIVE_CHANNEL_MASK", None)
		else:
			os.environ["PT_ACTIVE_CHANNEL_MASK"] = prev_mask


def render_table(summary_rows: list[dict[str, object]], detail_rows: list[dict[str, object]]) -> str:
	lines = [
		"# Multi-Channel Active Mask GOPS Table",
		"",
		"- simulator: `icarus`",
		"- mode: `compact`",
		"- formula: `GOPS@200MHz = ops_per_cycle * 0.2`",
		"- note: masks with the same active-channel count are measured via a representative mask and expanded to equivalent masks",
		"",
		"## Summary",
		"",
		"| Target | Active Mask | Active Ch | Representative | Avg GOPS @200MHz | Best Shape | Best GOPS @200MHz | `16x16x16` | `32x32x32` | `32x64x64` | `64x64x64` |",
		"| --- | ---: | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: |",
	]
	for row in summary_rows:
		lines.append(
			f"| {row['target']} | `0x{row['active_mask']:X}` | {row['active_channels']} | `0x{row['rep_mask']:X}` | "
			f"{row['avg_gops_200']:.3f} | {row['best_shape']} | {row['best_gops_200']:.3f} | "
			f"{row['shape_16_16_16']:.3f} | {row['shape_32_32_32']:.3f} | {row['shape_32_64_64']:.3f} | {row['shape_64_64_64']:.3f} |"
		)
	lines.extend(
		[
			"",
			"## Full Shape Scan",
			"",
			"| Target | Active Mask | Active Ch | Representative | Shape | Done Cycles | Logical Cmds | GOPS @200MHz |",
			"| --- | ---: | ---: | ---: | --- | ---: | ---: | ---: |",
		]
	)
	for row in detail_rows:
		lines.append(
			f"| {row['target']} | `0x{row['active_mask']:X}` | {row['active_channels']} | `0x{row['rep_mask']:X}` | "
			f"{row['shape']} | {row['done_cycles']} | {row['logical_cmds']} | {row['gops_200']:.3f} |"
		)
	return "\n".join(lines) + "\n"


def main() -> int:
	summary_rows: list[dict[str, object]] = []
	detail_rows: list[dict[str, object]] = []

	for target, class_map in MASK_CLASSES.items():
		rep_results = {}
		for active_channels, spec in class_map.items():
			rep_results[active_channels] = run_rep_multitile(target, spec["rep"])

		for active_channels, spec in class_map.items():
			rep_mask = spec["rep"]
			passed = [case.to_dict() for case in rep_results[active_channels].cases if case.status == "passed"]
			best = max(passed, key=lambda case: float(case["ops_per_cycle"]))
			avg_gops_200 = sum(float(case["ops_per_cycle"]) for case in passed) / len(passed) * 0.2
			shape_map = {
				(int(case["m_dim"]), int(case["n_dim"]), int(case["k_dim"])): case
				for case in passed
			}
			for mask in spec["masks"]:
				summary_rows.append(
					{
						"target": target,
						"active_mask": mask,
						"active_channels": active_channels,
						"rep_mask": rep_mask,
						"avg_gops_200": avg_gops_200,
						"best_shape": f"{best['m_dim']}x{best['n_dim']}x{best['k_dim']}",
						"best_gops_200": float(best["ops_per_cycle"]) * 0.2,
						"shape_16_16_16": float(shape_map[(16, 16, 16)]["ops_per_cycle"]) * 0.2,
						"shape_32_32_32": float(shape_map[(32, 32, 32)]["ops_per_cycle"]) * 0.2,
						"shape_32_64_64": float(shape_map[(32, 64, 64)]["ops_per_cycle"]) * 0.2,
						"shape_64_64_64": float(shape_map[(64, 64, 64)]["ops_per_cycle"]) * 0.2,
					}
				)
				for case in passed:
					detail_rows.append(
						{
							"target": target,
							"active_mask": mask,
							"active_channels": active_channels,
							"rep_mask": rep_mask,
							"shape": f"{case['m_dim']}x{case['n_dim']}x{case['k_dim']}",
							"done_cycles": int(case["accept_to_done_cycles"]),
							"logical_cmds": int(case["command_count"]),
							"gops_200": float(case["ops_per_cycle"]) * 0.2,
						}
					)

	summary_rows.sort(key=lambda row: (row["target"], row["active_channels"], row["active_mask"]))
	detail_rows.sort(key=lambda row: (row["target"], row["active_channels"], row["active_mask"], tuple(int(part) for part in row["shape"].split("x"))))
	out_path = OUT_DIR / "multi_channel_active_mask_gops_table.md"
	out_path.write_text(render_table(summary_rows, detail_rows), encoding="utf-8")
	print(out_path)
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
