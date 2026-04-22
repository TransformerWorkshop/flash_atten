from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import cocotb
from cocotb.utils import get_sim_time

REPO_ROOT = Path(__file__).resolve().parents[3]
COCOTB_ROOT = REPO_ROOT / "sim" / "cocotb"
if str(REPO_ROOT) not in sys.path:
	sys.path.insert(0, str(REPO_ROOT))
if str(COCOTB_ROOT) not in sys.path:
	sys.path.insert(0, str(COCOTB_ROOT))

from app.pt_tiled_gemm import TILE_DIM, app_target_label, normalize_app_target
from app.pt_tiled_gemm.multitile_utils import build_command_schedule, choose_partition_plan
from app.pt_tiled_gemm.submission import CommandSubmitter, normalize_submission_mode
from tests.pt_model import build_load_inst, build_matmul_inst, matmul_row_major, to_unsigned

APP_TARGET = normalize_app_target(os.getenv("PT_APP_TARGET", "pt"))
SUBMISSION_MODE = normalize_submission_mode(os.getenv("PT_APP_SUBMISSION_MODE", "legacy"))
if APP_TARGET in {"pt_dma_top", "pt_dma_top_v3"}:
	from tests.pt_dma_top_env import create_env, setup_bases_and_passthrough_qcfg
else:
	from tests.pt_blackbox_env import create_env, setup_bases_and_passthrough_qcfg


CLK_PERIOD_NS = 10


def env_int(name: str, default: int) -> int:
	return int(os.getenv(name, str(default)))


def cycle_now() -> int:
	return int(get_sim_time("ns") // CLK_PERIOD_NS)


def write_metrics(payload: dict[str, object]) -> None:
	metrics_path = os.getenv("PT_MT_METRICS_PATH")
	if not metrics_path:
		return
	path = Path(metrics_path)
	path.parent.mkdir(parents=True, exist_ok=True)
	path.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")


def make_a_matrix(x_dim: int, m_tiles: int, k_tiles: int, bits: int) -> list[int]:
	m_dim = x_dim * m_tiles
	k_dim = x_dim * k_tiles
	return [
		to_unsigned(1 + ((row * 3) + (col % x_dim) + (row // x_dim) * 5 + (col // x_dim) * 7) % 29, bits)
		for row in range(m_dim)
		for col in range(k_dim)
	]


def make_b_matrix(y_dim: int, k_tiles: int, n_tiles: int, bits: int) -> list[int]:
	k_dim = y_dim * k_tiles
	n_dim = y_dim * n_tiles
	return [
		to_unsigned(1 + ((col * 2) + (row % y_dim) + (col // y_dim) * 4 + (row // y_dim) * 6) % 31, bits)
		for row in range(k_dim)
		for col in range(n_dim)
	]


def extract_a_submatrix(
	*,
	a_matrix: list[int],
	full_k_dim: int,
	x_dim: int,
	m_tile_off: int,
	k_tile_off: int,
	m_tiles: int,
	k_tiles: int,
) -> list[int]:
	row_base = m_tile_off * x_dim
	col_base = k_tile_off * x_dim
	m_dim = m_tiles * x_dim
	k_dim = k_tiles * x_dim
	return [
		a_matrix[(row_base + row) * full_k_dim + (col_base + col)]
		for row in range(m_dim)
		for col in range(k_dim)
	]


def extract_b_submatrix(
	*,
	b_matrix: list[int],
	full_n_dim: int,
	y_dim: int,
	k_tile_off: int,
	n_tile_off: int,
	k_tiles: int,
	n_tiles: int,
) -> list[int]:
	row_base = k_tile_off * y_dim
	col_base = n_tile_off * y_dim
	k_dim = k_tiles * y_dim
	n_dim = n_tiles * y_dim
	return [
		b_matrix[(row_base + row) * full_n_dim + (col_base + col)]
		for row in range(k_dim)
		for col in range(n_dim)
	]


def accumulate_partial(
	*,
	c_matrix: list[int],
	full_n_dim: int,
	partial: list[int],
	x_dim: int,
	y_dim: int,
	m_tile_off: int,
	n_tile_off: int,
	m_tiles: int,
	n_tiles: int,
) -> None:
	row_base = m_tile_off * x_dim
	col_base = n_tile_off * y_dim
	m_dim = m_tiles * x_dim
	n_dim = n_tiles * y_dim
	for row in range(m_dim):
		for col in range(n_dim):
			index = (row_base + row) * full_n_dim + (col_base + col)
			c_matrix[index] = to_unsigned(c_matrix[index] + int(partial[row * n_dim + col]), 32)


@cocotb.test()
async def test_pt_multitile_single_case(dut) -> None:
	full_m_tiles = env_int("PT_MT_M_TILES", 1)
	full_n_tiles = env_int("PT_MT_N_TILES", 1)
	full_k_tiles = env_int("PT_MT_K_TILES", 1)
	max_encoded_elems = env_int("PT_MT_MAX_ENCODED_ELEMS", 1023)
	recycle_interval = env_int("PT_MT_RECYCLE_INTERVAL", env_int("PT_LUT_DEPTH", 8))
	ctrl_id_base = env_int("PT_MT_CTRL_ID_BASE", 0xB00)
	ctrl_id_pool_size = env_int("PT_APP_CTRL_ID_POOL_SIZE", env_int("PT_LUT_DEPTH", 8))
	x_dim = env_int("PT_X_DIM", TILE_DIM)
	y_dim = env_int("PT_Y_DIM", TILE_DIM)
	data_width = env_int("PT_DATA_WIDTH", 32)
	export_lanes = env_int("PT_M_EXPORT_LANES", y_dim)
	valid_tile_counts = tuple(int(item) for item in os.getenv("PT_MT_VALID_TILE_COUNTS", "1,2,4").split(",") if item.strip())

	env = await create_env(dut)
	try:
		await env.reset()
		await setup_bases_and_passthrough_qcfg(env)
		snapshot = env.snapshot()
		perf_counter_base = await env.read_perf_counters() if APP_TARGET in {"pt_dma_top", "pt_dma_top_v3"} and hasattr(env, "read_perf_counters") else None
		perf_counter_accum = None
		submitter = CommandSubmitter(
			env,
			target=APP_TARGET,
			submission_mode=SUBMISSION_MODE,
			ctrl_id_base=ctrl_id_base,
			ctrl_id_pool_size=ctrl_id_pool_size,
		)

		m_dim = x_dim * full_m_tiles
		k_dim = x_dim * full_k_tiles
		n_dim = y_dim * full_n_tiles
		a_matrix = make_a_matrix(x_dim, full_m_tiles, full_k_tiles, data_width)
		b_matrix = make_b_matrix(y_dim, full_k_tiles, full_n_tiles, data_width)
		golden = [
			to_unsigned(value, data_width)
			for value in matmul_row_major(a_matrix, b_matrix, m_dim, n_dim, k_dim)
		]

		m_parts, n_parts, k_parts = choose_partition_plan(
			m_tiles=full_m_tiles,
			n_tiles=full_n_tiles,
			k_tiles=full_k_tiles,
			valid_tile_counts=valid_tile_counts,
			max_encoded_elems=max_encoded_elems,
			x_dim=x_dim,
			y_dim=y_dim,
		)
		schedule = build_command_schedule(m_parts=m_parts, n_parts=n_parts, k_parts=k_parts)
		c_matrix = [0] * (m_dim * n_dim)
		first_accept_cycle = None
		last_resp_cycle = None
		clear_count = 0
		use_load_prefetch = (
			(APP_TARGET in {"pt_dma_top", "pt_dma_top_v3"})
			and (len(schedule) > 1)
			and (ctrl_id_pool_size >= 2)
			and (env_int("PT_MT_LOAD_PREFETCH", 1) != 0)
		)
		load_prefetch_count = 0

		def build_prefetch_item(command_idx: int) -> dict[str, object]:
			command = schedule[command_idx]
			ctrl_id = submitter.acquire_ctrl_id(ctrl_id_base + (command_idx % recycle_interval))
			a_sub = extract_a_submatrix(
				a_matrix=a_matrix,
				full_k_dim=k_dim,
				x_dim=x_dim,
				m_tile_off=command.m_tile_off,
				k_tile_off=command.k_tile_off,
				m_tiles=command.m_tiles,
				k_tiles=command.k_tiles,
			)
			b_sub = extract_b_submatrix(
				b_matrix=b_matrix,
				full_n_dim=n_dim,
				y_dim=y_dim,
				k_tile_off=command.k_tile_off,
				n_tile_off=command.n_tile_off,
				k_tiles=command.k_tiles,
				n_tiles=command.n_tiles,
			)
			env.register_external_matrix("A", ctrl_id, a_sub)
			env.register_external_matrix("B", ctrl_id, b_sub)
			load_inst = build_load_inst(
				len(a_sub),
				len(b_sub),
				need_a=True,
				need_b=True,
				m_tiles=command.m_tiles,
				n_tiles=command.n_tiles,
				k_tiles=command.k_tiles,
			)
			load_plan = env.plan_load(
				ctrl_id,
				len(a_sub),
				len(b_sub),
				need_a=True,
				need_b=True,
				reserved_lo=load_inst & 0x3F,
			)
			assert not load_plan.err
			return {
				"command": command,
				"ctrl_id": ctrl_id,
				"load_inst": load_inst,
				"load_plan": load_plan,
				"load_done": False,
			}

		async def issue_load(item: dict[str, object]) -> None:
			nonlocal first_accept_cycle, load_prefetch_count
			await submitter.send_ctrl(int(item["load_inst"]), int(item["ctrl_id"]))
			if first_accept_cycle is None:
				first_accept_cycle = cycle_now()
			load_prefetch_count += 1

		segment_start = 0
		while segment_start < len(schedule):
			if segment_start != 0:
				if perf_counter_base is not None:
					segment_counters = (await env.read_perf_counters()).delta(perf_counter_base)
					perf_counter_accum = segment_counters if perf_counter_accum is None else perf_counter_accum.add(segment_counters)
				clear_count += 1
				if APP_TARGET in {"pt_dma_top", "pt_dma_top_v3"}:
					await env.soft_clear()
				else:
					await env.pulse_clear(phase="multitile_bench")
					await setup_bases_and_passthrough_qcfg(env)
				perf_counter_base = await env.read_perf_counters() if APP_TARGET in {"pt_dma_top", "pt_dma_top_v3"} and hasattr(env, "read_perf_counters") else None

			segment_end = min(segment_start + recycle_interval, len(schedule))
			if use_load_prefetch:
				current_item = build_prefetch_item(segment_start)
				await issue_load(current_item)
				current_idx = segment_start
				while True:
					while not bool(current_item["load_done"]):
						resp_word = await env.wait_next_ctrl_resp(80000)
						last_resp_cycle = cycle_now()
						assert resp_word == current_item["load_plan"].response_word
						env.model.commit_load_success(current_item["load_plan"])
						current_item["load_done"] = True

					command = current_item["command"]
					matmul_plan = env.plan_matmul(
						int(current_item["ctrl_id"]),
						m_scale=command.m_tiles,
						n_scale=command.n_tiles,
						k_scale=command.k_tiles,
					)
					assert not matmul_plan.err
					assert len(matmul_plan.expected_dma_loads) == 0
					await submitter.send_ctrl(
						build_matmul_inst(command.m_tiles, command.n_tiles, command.k_tiles),
						int(current_item["ctrl_id"]),
					)
					export_target = env.export_done_count + 1

					next_item = None
					next_idx = current_idx + 1
					if next_idx < segment_end:
						next_item = build_prefetch_item(next_idx)
						await issue_load(next_item)

					matmul_done = False
					while not matmul_done:
						resp_word = await env.wait_next_ctrl_resp(80000)
						last_resp_cycle = cycle_now()
						if resp_word == matmul_plan.response_word:
							env.model.commit_success(matmul_plan)
							matmul_done = True
						elif next_item is not None and resp_word == next_item["load_plan"].response_word:
							env.model.commit_load_success(next_item["load_plan"])
							next_item["load_done"] = True
						else:
							raise AssertionError(f"unexpected ctrl_resp 0x{resp_word:08x} in prefetch pipeline")

					await env.wait_export_done(export_target, 80000)
					assert matmul_plan.result_matrix is not None
					accumulate_partial(
						c_matrix=c_matrix,
						full_n_dim=n_dim,
						partial=list(matmul_plan.result_matrix),
						x_dim=x_dim,
						y_dim=y_dim,
						m_tile_off=command.m_tile_off,
						n_tile_off=command.n_tile_off,
						m_tiles=command.m_tiles,
						n_tiles=command.n_tiles,
					)
					submitter.release_ctrl_id(int(current_item["ctrl_id"]))
					if next_item is None:
						break
					current_item = next_item
					current_idx = next_idx
			else:
				for command_idx in range(segment_start, segment_end):
					command = schedule[command_idx]
					ctrl_id = submitter.acquire_ctrl_id(ctrl_id_base + (command_idx % recycle_interval))
					a_sub = extract_a_submatrix(
						a_matrix=a_matrix,
						full_k_dim=k_dim,
						x_dim=x_dim,
						m_tile_off=command.m_tile_off,
						k_tile_off=command.k_tile_off,
						m_tiles=command.m_tiles,
						k_tiles=command.k_tiles,
					)
					b_sub = extract_b_submatrix(
						b_matrix=b_matrix,
						full_n_dim=n_dim,
						y_dim=y_dim,
						k_tile_off=command.k_tile_off,
						n_tile_off=command.n_tile_off,
						k_tiles=command.k_tiles,
						n_tiles=command.n_tiles,
					)
					env.register_external_matrix("A", ctrl_id, a_sub)
					env.register_external_matrix("B", ctrl_id, b_sub)
					plan = env.plan_matmul(ctrl_id, m_scale=command.m_tiles, n_scale=command.n_tiles, k_scale=command.k_tiles)
					assert not plan.err
					await submitter.send_ctrl(build_matmul_inst(command.m_tiles, command.n_tiles, command.k_tiles), ctrl_id)
					accept_cycle = cycle_now()
					if first_accept_cycle is None:
						first_accept_cycle = accept_cycle
					resp = await env.wait_ctrl_resp(plan.response_word, 80000)
					last_resp_cycle = cycle_now()
					env.model.commit_success(plan)
					await env.wait_export_done(env.export_done_count + 1, 80000)
					assert plan.result_matrix is not None
					accumulate_partial(
						c_matrix=c_matrix,
						full_n_dim=n_dim,
						partial=list(plan.result_matrix),
						x_dim=x_dim,
						y_dim=y_dim,
						m_tile_off=command.m_tile_off,
						n_tile_off=command.n_tile_off,
						m_tiles=command.m_tiles,
						n_tiles=command.n_tiles,
					)
					_ = resp
					submitter.release_ctrl_id(ctrl_id)

			segment_start = segment_end

		assert first_accept_cycle is not None
		assert last_resp_cycle is not None
		done_cycle = cycle_now()
		assert c_matrix == golden

		macs = m_dim * n_dim * k_dim
		ops = 2 * macs
		total_cycles = done_cycle - first_accept_cycle
		resp_cycles = last_resp_cycle - first_accept_cycle
		export_beats = sum((command.m_tiles * x_dim) * ((command.n_tiles * y_dim + export_lanes - 1) // export_lanes) for command in schedule)
		perf_counters = await env.read_perf_counters() if APP_TARGET in {"pt_dma_top", "pt_dma_top_v3"} and hasattr(env, "read_perf_counters") else None
		if perf_counters is not None and perf_counter_base is not None:
			perf_counters = perf_counters.delta(perf_counter_base)
			perf_counters = perf_counters if perf_counter_accum is None else perf_counter_accum.add(perf_counters)
		metrics = {
			"case": {
				"target": APP_TARGET,
				"target_label": app_target_label(APP_TARGET),
				"m_tiles": full_m_tiles,
				"n_tiles": full_n_tiles,
				"k_tiles": full_k_tiles,
				"m_dim": m_dim,
				"n_dim": n_dim,
				"k_dim": k_dim,
				"m_partitions": list(m_parts),
				"n_partitions": list(n_parts),
				"k_partitions": list(k_parts),
				"submission_mode": submitter.submission_mode,
				"load_prefetch_enabled": use_load_prefetch,
				"logical_command_count": len(schedule),
				"issued_command_count": submitter.stats.command_count,
				"load_prefetch_count": load_prefetch_count,
				"software_adapted": (tuple(m_parts), tuple(n_parts), tuple(k_parts)) != ((full_m_tiles,), (full_n_tiles,), (full_k_tiles,)),
				"command_count": len(schedule),
				"clear_count": clear_count,
			},
			"measurement": {
				"status": "passed",
				"accept_to_resp_cycles": resp_cycles,
				"accept_to_done_cycles": total_cycles,
				"axil_writes_total": submitter.stats.axil_writes_total,
				"axil_writes_per_command": submitter.stats.axil_writes_per_command,
				"axil_writes_per_logical_command": (0.0 if len(schedule) == 0 else (submitter.stats.axil_writes_total / len(schedule))),
				"descriptor_push_count": submitter.stats.descriptor_push_count,
				"dma_req_count": env.dma_req_count - snapshot.dma_req_count,
				"export_req_count": env.export_req_count - snapshot.export_req_count,
				"export_beats": export_beats,
				"macs": macs,
				"ops": ops,
				"macs_per_cycle": (macs / total_cycles) if total_cycles > 0 else 0.0,
				"ops_per_cycle": (ops / total_cycles) if total_cycles > 0 else 0.0,
				"tops_at_1ghz": (ops / total_cycles / 1000.0) if total_cycles > 0 else 0.0,
				"command_schedule": [
					{
						"m_tile_off": command.m_tile_off,
						"n_tile_off": command.n_tile_off,
						"k_tile_off": command.k_tile_off,
						"m_tiles": command.m_tiles,
						"n_tiles": command.n_tiles,
						"k_tiles": command.k_tiles,
					}
					for command in schedule
				],
			},
		}
		if perf_counters is not None:
			perf_other_cycles = total_cycles - (
				perf_counters.push_to_accept_cycles
				+ perf_counters.accept_to_resp_cycles
				+ perf_counters.resp_to_done_cycles
			)
			metrics["measurement"].update(
				{
					"perf_axil_write_count": perf_counters.axil_write_count,
					"perf_command_push_count": perf_counters.command_push_count,
					"perf_pt_accept_count": perf_counters.pt_accept_count,
					"perf_resp_enqueue_count": perf_counters.resp_enqueue_count,
					"perf_wr_dma_done_count": perf_counters.wr_dma_done_count,
					"perf_compact_commit_count": perf_counters.compact_commit_count,
					"perf_push_to_accept_cycles": perf_counters.push_to_accept_cycles,
					"perf_accept_to_resp_cycles": perf_counters.accept_to_resp_cycles,
					"perf_resp_to_done_cycles": perf_counters.resp_to_done_cycles,
					"perf_other_cycles": perf_other_cycles,
				}
			)
		write_metrics(metrics)
	finally:
		env.shutdown()
