from __future__ import annotations

import json
import os
from pathlib import Path

import cocotb

from tests.pt_dma_top_env import create_env, setup_bases_and_passthrough_qcfg
from tests.pt_model import DMA_KIND_A, DMA_KIND_B, PT_SCALE_FULL, PT_TILES_1, PT_TILES_2, build_matmul_inst, identity_matrix


def sequential_row_major(dim: int) -> list[list[int]]:
	value = 1
	matrix: list[list[int]] = []
	for _ in range(dim):
		row: list[int] = []
		for _ in range(dim):
			row.append(value)
			value += 1
		matrix.append(row)
	return matrix


def make_a_matrix(x_dim: int, m_tiles: int, k_tiles: int) -> list[int]:
	m_dim = x_dim * m_tiles
	k_dim = x_dim * k_tiles
	return [
		((row * 3) + (col % x_dim) + (row // x_dim) * 5 + (col // x_dim) * 7 + 1)
		for row in range(m_dim)
		for col in range(k_dim)
	]


def make_b_matrix(y_dim: int, k_tiles: int, n_tiles: int) -> list[int]:
	k_dim = y_dim * k_tiles
	n_dim = y_dim * n_tiles
	return [
		((col * 2) + (row % y_dim) + (col // y_dim) * 4 + (row // y_dim) * 6 + 1)
		for row in range(k_dim)
		for col in range(n_dim)
	]


def write_metrics(payload: dict[str, object]) -> None:
	metrics_path = os.getenv("PT_ONEOFF_METRICS_PATH")
	if not metrics_path:
		return
	path = Path(metrics_path)
	path.parent.mkdir(parents=True, exist_ok=True)
	path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")


@cocotb.test()
async def test_pt_dma_top_direct_matmul_identity(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)
		ctrl_id = 0xD00
		env.register_external_matrix("A", ctrl_id, sequential_row_major(env.x_dim))
		env.register_external_matrix("B", ctrl_id, identity_matrix(env.y_dim, env.data_width))
		await env.send_desc_command(
			build_matmul_inst(PT_SCALE_FULL, PT_SCALE_FULL, PT_SCALE_FULL),
			ctrl_id,
			a_addr=0x1000_1000,
			b_addr=0x1000_2000,
			m_addr=0x1000_3000,
		)
		plan = env.plan_matmul(ctrl_id, m_scale=PT_SCALE_FULL, n_scale=PT_SCALE_FULL, k_scale=PT_SCALE_FULL)
		await env.wait_and_pop_resp(plan.response_word, 40000)
		await env.wait_export_done(1, 80000)
	finally:
		env.shutdown()


@cocotb.test()
async def test_pt_dma_top_accept_to_resp_substage_breakdown(dut) -> None:
	env = await create_env(dut)
	try:
		await setup_bases_and_passthrough_qcfg(env)

		cases = [
			{
				"name": "m1_n1_k2",
				"ctrl_id": 0xE100,
				"m_tiles": PT_TILES_1,
				"n_tiles": PT_TILES_1,
				"k_tiles": PT_TILES_2,
			},
			{
				"name": "m2_n2_k1",
				"ctrl_id": 0xE200,
				"m_tiles": PT_TILES_2,
				"n_tiles": PT_TILES_2,
				"k_tiles": PT_TILES_1,
			},
		]

		results: dict[str, object] = {}
		for case in cases:
			ctrl_id = case["ctrl_id"]
			m_tiles = case["m_tiles"]
			n_tiles = case["n_tiles"]
			k_tiles = case["k_tiles"]
			inst = build_matmul_inst(m_tiles, n_tiles, k_tiles)
			env.register_external_matrix("A", ctrl_id, make_a_matrix(env.x_dim, m_tiles, k_tiles))
			env.register_external_matrix("B", ctrl_id, make_b_matrix(env.y_dim, k_tiles, n_tiles))
			trace = await env.send_desc_command_timed(
				inst,
				ctrl_id,
				a_addr=0x1000_1000 + ((ctrl_id & 0xFF) << 8),
				b_addr=0x2000_1000 + ((ctrl_id & 0xFF) << 8),
				m_addr=0x4000_1000 + ((ctrl_id & 0xFF) << 8),
				mode="compact",
			)
			plan = env.plan_matmul(ctrl_id, m_scale=m_tiles, n_scale=n_tiles, k_scale=k_tiles)

			accept = await env.wait_pt_ctrl_accept(ctrl_id, after_cycle=trace.ctrl_write_start_cycle)
			malloc_issue = await env.wait_malloc_issue(ctrl_id, after_cycle=accept.cycle)
			fill_req_a = await env.wait_fill_req(ctrl_id, DMA_KIND_A, after_cycle=malloc_issue.cycle)
			fill_done_a = await env.wait_fill_done(ctrl_id, DMA_KIND_A, after_cycle=fill_req_a.cycle)
			fill_req_b = await env.wait_fill_req(ctrl_id, DMA_KIND_B, after_cycle=fill_done_a.cycle)
			fill_done_b = await env.wait_fill_done(ctrl_id, DMA_KIND_B, after_cycle=fill_req_b.cycle)
			ce_cmd = await env.wait_ce_cmd(ctrl_id, after_cycle=fill_done_b.cycle)
			ce_resp = await env.wait_ce_resp(plan.response_word, after_cycle=ce_cmd.cycle)
			ctrl_resp = await env.wait_resp_visible(plan.response_word, after_cycle=ce_resp.cycle)
			await env.wait_and_pop_resp(plan.response_word, 40000)
			await env.wait_export_done(env.export_done_count + 1, 80000)

			results[case["name"]] = {
				"accept_to_malloc_issue": malloc_issue.cycle - accept.cycle,
				"malloc_issue_to_fill_req_a": fill_req_a.cycle - malloc_issue.cycle,
				"fill_req_a_to_fill_done_a": fill_done_a.cycle - fill_req_a.cycle,
				"fill_done_a_to_fill_req_b": fill_req_b.cycle - fill_done_a.cycle,
				"fill_req_b_to_fill_done_b": fill_done_b.cycle - fill_req_b.cycle,
				"fill_done_b_to_ce_cmd": ce_cmd.cycle - fill_done_b.cycle,
				"ce_cmd_to_ce_resp": ce_resp.cycle - ce_cmd.cycle,
				"ce_resp_to_ctrl_resp": ctrl_resp.cycle - ce_resp.cycle,
				"accept_to_ctrl_resp": ctrl_resp.cycle - accept.cycle,
			}

		write_metrics({"accept_to_resp_substages": results})
	finally:
		env.shutdown()
