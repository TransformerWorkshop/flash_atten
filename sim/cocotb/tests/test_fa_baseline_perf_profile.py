from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

import cocotb
from cocotb.triggers import RisingEdge

from tests.fa_baseline_env import HEAD_DIM, SEQ_LEN, create_env, random_q88_matrix


FULL_RUN_COUNTS = {
    "q_load": 16,
    "k_load": 136,
    "v_load": 136,
    "row_init": 16,
    "oacc_clear": 16,
    "qk": 136,
    "score_post": 136,
    "pv": 136,
    "oacc_update": 136,
    "store": 16,
}
ROW_RELATION_COUNTS = {
    "future_masked": 0,
    "diagonal": 16,
    "history": 120,
}
FIRST_ITERATION_RELATION_COUNTS = {
    "future_masked": 0,
    "diagonal": 1,
    "history": 15,
}
REQUIRED_CONST_STAGES = [
    "q_load",
    "k_load",
    "v_load",
    "row_init",
    "oacc_clear",
    "qk",
    "score_post",
    "pv",
    "oacc_update",
    "store",
]
REQUIRED_ROW_STAGES = ["row_update", "row_state"]


def value_to_int(signal) -> int:
    value = signal.value
    is_resolvable = getattr(value, "is_resolvable", True)
    return int(value) if is_resolvable else 0


def relation_for(q_blk: int, kv_blk: int) -> str:
    if q_blk < kv_blk:
        return "future_masked"
    if q_blk == kv_blk:
        return "diagonal"
    return "history"


class SampleMonitor:
    def __init__(self, dut):
        self.dut = dut
        self.cycle = 0
        self.samples: dict[str, list[dict[str, Any]]] = {}
        self._active: dict[str, tuple[int, dict[str, Any]]] = {}
        self._active_load_stages: list[str] = []
        self._active_store = False
        self._stop = False

    def stop(self) -> None:
        self._stop = True

    def _record(self, stage: str, duration: int, meta: dict[str, Any]) -> None:
        bucket = self.samples.setdefault(stage, [])
        bucket.append({"duration": duration, **meta})

    def _begin(self, stage: str, *, meta: dict[str, Any] | None = None) -> None:
        if stage in self._active:
            raise AssertionError(f"stage {stage} started twice without finishing")
        self._active[stage] = (self.cycle, {} if meta is None else dict(meta))

    def _finish(self, stage: str) -> None:
        try:
            start_cycle, meta = self._active.pop(stage)
        except KeyError as exc:
            raise AssertionError(f"stage {stage} finished without start") from exc
        self._record(stage, self.cycle - start_cycle, meta)

    def has_required_samples(self) -> bool:
        for stage in REQUIRED_CONST_STAGES:
            if not self.samples.get(stage):
                return False
        for stage in REQUIRED_ROW_STAGES:
            required_relations = {name for name, count in ROW_RELATION_COUNTS.items() if count > 0}
            relations = {sample["relation"] for sample in self.samples.get(stage, [])}
            if relations != required_relations:
                return False
        return True

    async def run(self) -> None:
        core = self.dut.u_core
        while True:
            await RisingEdge(self.dut.clk)
            self.cycle += 1

            if value_to_int(core.u_rd_dma.req_valid) and value_to_int(core.u_rd_dma.req_ready):
                load_kind = value_to_int(core.u_rd_dma.req_kind)
                stage = {0: "q_load", 1: "k_load", 2: "v_load"}[load_kind]
                self._active_load_stages.append(stage)
                self._begin(stage)

            if value_to_int(core.u_row_state.init_valid) and value_to_int(core.u_row_state.init_ready):
                self._begin("row_init")
            if value_to_int(core.u_oacc_buf.clear_req_valid) and value_to_int(core.u_oacc_buf.clear_req_ready):
                self._begin("oacc_clear")
            if value_to_int(core.u_qk_pv_core.qk_req_valid) and value_to_int(core.u_qk_pv_core.qk_req_ready):
                self._begin("qk")
            if value_to_int(core.u_sched.score_req_valid) and "score_post" not in self._active:
                self._begin("score_post")
            if value_to_int(core.u_sched.row_update_valid) and "row_update" not in self._active:
                q_blk = value_to_int(core.u_sched.q_blk_idx)
                kv_blk = value_to_int(core.u_sched.kv_blk_idx)
                relation = relation_for(q_blk, kv_blk)
                meta = {"q_blk": q_blk, "kv_blk": kv_blk, "relation": relation}
                self._begin("row_update", meta=meta)
            if value_to_int(core.u_row_state.update_valid) and value_to_int(core.u_row_state.update_ready):
                q_blk = value_to_int(core.u_sched.q_blk_idx)
                kv_blk = value_to_int(core.u_sched.kv_blk_idx)
                relation = relation_for(q_blk, kv_blk)
                self._begin("row_state", meta={"q_blk": q_blk, "kv_blk": kv_blk, "relation": relation})
            if value_to_int(core.u_qk_pv_core.pv_req_valid) and value_to_int(core.u_qk_pv_core.pv_req_ready):
                self._begin("pv")
            if value_to_int(core.u_sched.oacc_update_valid) and "oacc_update" not in self._active:
                self._begin("oacc_update")
            if value_to_int(core.u_wr_dma.req_valid) and value_to_int(core.u_wr_dma.req_ready):
                self._active_store = True
                self._begin("store")

            if value_to_int(core.u_rd_dma.done_pulse):
                if not self._active_load_stages:
                    raise AssertionError("rd_dma finished without active stage")
                self._finish(self._active_load_stages.pop(0))
            if value_to_int(core.u_row_state.init_done_pulse):
                self._finish("row_init")
            if value_to_int(core.u_oacc_buf.clear_done_pulse):
                self._finish("oacc_clear")
            if value_to_int(core.u_qk_pv_core.qk_done_pulse):
                self._finish("qk")
            if value_to_int(core.score_done_pulse):
                self._finish("score_post")
            if value_to_int(core.u_row_state.done_pulse):
                self._finish("row_state")
            if value_to_int(core.row_update_done_pulse):
                self._finish("row_update")
            if value_to_int(core.u_qk_pv_core.pv_done_pulse):
                self._finish("pv")
            if value_to_int(core.oacc_update_done_pulse):
                self._finish("oacc_update")
            if value_to_int(core.u_wr_dma.done_pulse):
                if not self._active_store:
                    raise AssertionError("wr_dma finished without active store")
                self._finish("store")
                self._active_store = False

            if self._stop:
                return


def select_const_stage(samples: dict[str, list[dict[str, Any]]], stage: str) -> dict[str, Any]:
    durations = [int(sample["duration"]) for sample in samples[stage]]
    unique = sorted(set(durations))
    selected = unique[0] if len(unique) == 1 else int(round(sum(durations) / len(durations)))
    return {
        "selected_cycles": selected,
        "observed_unique_cycles": unique,
        "observed_count": len(durations),
    }


def select_relation_stage(samples: dict[str, list[dict[str, Any]]], stage: str) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    for relation in ROW_RELATION_COUNTS:
        durations = [int(sample["duration"]) for sample in samples[stage] if sample["relation"] == relation]
        if not durations:
            out[relation] = {
                "selected_cycles": 0,
                "observed_unique_cycles": [0],
                "observed_count": 0,
            }
            continue
        unique = sorted(set(durations))
        selected = unique[0] if len(unique) == 1 else int(round(sum(durations) / len(durations)))
        out[relation] = {
            "selected_cycles": selected,
            "observed_unique_cycles": unique,
            "observed_count": len(durations),
        }
    return out


def zero_relation_stage() -> dict[str, dict[str, Any]]:
    return {
        relation: {
            "selected_cycles": 0,
            "observed_unique_cycles": [0],
            "observed_count": 0,
        }
        for relation in ROW_RELATION_COUNTS
    }


def build_report(samples: dict[str, list[dict[str, Any]]]) -> dict[str, Any]:
    const_stage_cycles = {stage: select_const_stage(samples, stage) for stage in REQUIRED_CONST_STAGES}
    row_update_cycles = select_relation_stage(samples, "row_update")
    row_state_cycles = select_relation_stage(samples, "row_state")
    p_load_cycles = zero_relation_stage()

    top_stage_totals: dict[str, dict[str, Any]] = {}
    for stage, count in FULL_RUN_COUNTS.items():
        per_cycles = int(const_stage_cycles[stage]["selected_cycles"])
        top_stage_totals[stage] = {
            "per_invocation_cycles": per_cycles,
            "count": count,
            "total_cycles": per_cycles * count,
            "observed_unique_cycles": const_stage_cycles[stage]["observed_unique_cycles"],
            "observed_count": const_stage_cycles[stage]["observed_count"],
        }

    row_update_total = 0
    row_state_total = 0
    p_load_total = 0
    row_update_breakdown: dict[str, dict[str, Any]] = {}
    row_state_breakdown: dict[str, dict[str, Any]] = {}
    p_load_breakdown: dict[str, dict[str, Any]] = {}
    for relation, count in ROW_RELATION_COUNTS.items():
        row_update_sel = int(row_update_cycles[relation]["selected_cycles"])
        row_state_sel = int(row_state_cycles[relation]["selected_cycles"])
        p_load_sel = int(p_load_cycles[relation]["selected_cycles"])
        row_update_total += row_update_sel * count
        row_state_total += row_state_sel * count
        p_load_total += p_load_sel * count
        row_update_breakdown[relation] = {
            "per_invocation_cycles": row_update_sel,
            "count": count,
            "total_cycles": row_update_sel * count,
            "observed_unique_cycles": row_update_cycles[relation]["observed_unique_cycles"],
            "observed_count": row_update_cycles[relation]["observed_count"],
        }
        row_state_breakdown[relation] = {
            "per_invocation_cycles": row_state_sel,
            "count": count,
            "total_cycles": row_state_sel * count,
            "observed_unique_cycles": row_state_cycles[relation]["observed_unique_cycles"],
            "observed_count": row_state_cycles[relation]["observed_count"],
        }
        p_load_breakdown[relation] = {
            "per_invocation_cycles": p_load_sel,
            "count": count,
            "total_cycles": p_load_sel * count,
            "observed_unique_cycles": p_load_cycles[relation]["observed_unique_cycles"],
            "observed_count": p_load_cycles[relation]["observed_count"],
        }

    top_stage_totals["row_update"] = {
        "per_invocation_cycles": None,
        "count": sum(ROW_RELATION_COUNTS.values()),
        "total_cycles": row_update_total,
        "observed_unique_cycles": [],
        "observed_count": sum(entry["observed_count"] for entry in row_update_cycles.values()),
    }

    serial_total_cycles = sum(entry["total_cycles"] for entry in top_stage_totals.values())
    for entry in top_stage_totals.values():
        entry["share_pct"] = (entry["total_cycles"] * 100.0 / serial_total_cycles) if serial_total_cycles else 0.0
    for entry in row_update_breakdown.values():
        entry["share_pct"] = (entry["total_cycles"] * 100.0 / serial_total_cycles) if serial_total_cycles else 0.0
    for entry in row_state_breakdown.values():
        entry["share_pct"] = (entry["total_cycles"] * 100.0 / serial_total_cycles) if serial_total_cycles else 0.0
    for entry in p_load_breakdown.values():
        entry["share_pct"] = (entry["total_cycles"] * 100.0 / serial_total_cycles) if serial_total_cycles else 0.0

    q_load_cycles = int(const_stage_cycles["q_load"]["selected_cycles"])
    k_load_cycles = int(const_stage_cycles["k_load"]["selected_cycles"])
    v_load_cycles = int(const_stage_cycles["v_load"]["selected_cycles"])
    qk_cycles = int(const_stage_cycles["qk"]["selected_cycles"])
    score_cycles = int(const_stage_cycles["score_post"]["selected_cycles"])
    pv_cycles = int(const_stage_cycles["pv"]["selected_cycles"])
    oacc_update_cycles = int(const_stage_cycles["oacc_update"]["selected_cycles"])
    scheduler_overlap_total_cycles = (
        q_load_cycles
        + int(top_stage_totals["row_init"]["total_cycles"])
        + int(top_stage_totals["oacc_clear"]["total_cycles"])
        + int(top_stage_totals["store"]["total_cycles"])
    )
    scheduler_overlap_breakdown: dict[str, dict[str, Any]] = {}
    for relation, count in ROW_RELATION_COUNTS.items():
        row_update_sel = int(row_update_cycles[relation]["selected_cycles"])
        compute_before_pv_cycles = max(v_load_cycles, qk_cycles + score_cycles + row_update_sel)
        first_iteration_count = FIRST_ITERATION_RELATION_COUNTS[relation]
        steady_iteration_count = count - first_iteration_count
        first_iteration_cycles = k_load_cycles + compute_before_pv_cycles + pv_cycles + oacc_update_cycles
        steady_iteration_cycles = compute_before_pv_cycles + pv_cycles + oacc_update_cycles
        scheduler_overlap_breakdown[relation] = {
            "count": count,
            "first_iteration_count": first_iteration_count,
            "steady_iteration_count": steady_iteration_count,
            "first_iteration_cycles": first_iteration_cycles,
            "steady_iteration_cycles": steady_iteration_cycles,
            "hidden_v_load_cycles": max(0, v_load_cycles - (qk_cycles + score_cycles + row_update_sel)),
            "hidden_k_prefetch_cycles": k_load_cycles if steady_iteration_count else 0,
            "total_cycles": (first_iteration_cycles * first_iteration_count) + (steady_iteration_cycles * steady_iteration_count),
        }
        scheduler_overlap_total_cycles += scheduler_overlap_breakdown[relation]["total_cycles"]

    return {
        "method": "sampled_stage_latency_plus_scheduler_count_extrapolation",
        "shape": {"seq_len": SEQ_LEN, "head_dim": HEAD_DIM},
        "sampled_stages": const_stage_cycles,
        "sampled_row_update": row_update_cycles,
        "sampled_row_state": row_state_cycles,
        "sampled_p_load": p_load_cycles,
        "full_run_counts": FULL_RUN_COUNTS,
        "row_relation_counts": ROW_RELATION_COUNTS,
        "extrapolated_top_level": top_stage_totals,
        "extrapolated_row_update_breakdown": row_update_breakdown,
        "extrapolated_row_state_breakdown": row_state_breakdown,
        "extrapolated_p_load_breakdown": p_load_breakdown,
        "extrapolated_total_cycles": serial_total_cycles,
        "scheduler_overlap_model": "causal_future_tiles_skipped_v_load_overlapped_next_k_prefetched_next_q_prefetched_during_store",
        "scheduler_overlap_breakdown": scheduler_overlap_breakdown,
        "scheduler_overlap_total_cycles": scheduler_overlap_total_cycles,
        "scheduler_overlap_savings_cycles": serial_total_cycles - scheduler_overlap_total_cycles,
        "extrapolated_row_state_total_cycles": row_state_total,
        "extrapolated_p_load_total_cycles": p_load_total,
    }


def dump_report(report: dict[str, Any]) -> None:
    output_path = os.getenv("FA_PROFILE_JSON")
    if not output_path:
        return
    path = Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


@cocotb.test()
async def test_fa_baseline_profile(dut) -> None:
    env = await create_env(dut)
    monitor = SampleMonitor(dut)
    monitor_task = cocotb.start_soon(monitor.run())
    try:
        await env.reset()
        q = random_q88_matrix(SEQ_LEN, HEAD_DIM, 9001, amplitude=48)
        k = random_q88_matrix(SEQ_LEN, HEAD_DIM, 9002, amplitude=48)
        v = random_q88_matrix(SEQ_LEN, HEAD_DIM, 9003, amplitude=48)
        env.load_qkv(q, k, v)

        await env.start_run(causal=True)
        for _ in range(120000):
            if monitor.has_required_samples():
                break
            await RisingEdge(dut.clk)
        else:
            raise AssertionError("did not collect the required stage samples before timeout")

        await env.soft_reset()
        await RisingEdge(dut.clk)
        await RisingEdge(dut.clk)

        report = build_report(monitor.samples)
        dump_report(report)
    finally:
        monitor.stop()
        await monitor_task
        env.shutdown()
