from __future__ import annotations

import argparse
import json
from collections import Counter, deque
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Deque, Dict, Iterable, List, Optional


TASK_QK = "qk"
TASK_PV = "pv"
TASK_OACC = "oacc"
TASK_IDLE = "idle"


@dataclass(frozen=True)
class ModelConfig:
    tile_count: int = 136
    cluster_count: int = 4
    feeder_count: int = 1
    q_rows_per_cluster: int = 4
    kv_cols_per_cluster: int = 4
    head_dim: int = 64
    element_bits: int = 16
    row_scale_bits: int = 32
    task_queue_depth: int = 32
    task_descriptor_bits: int = 128
    qk_feed_cycles: int = 16
    qk_cycles: int = 16
    pv_feed_cycles: int = 0
    pv_cycles: int = 32
    oacc_cycles: int = 16
    row_update_cycles: int = 1
    row_state_pipe_count: int = 1
    max_inflight_tiles: int = 32

    def validate(self) -> None:
        fields = asdict(self)
        for name, value in fields.items():
            if value < 0:
                raise ValueError(f"{name} must be non-negative")
        if self.tile_count <= 0:
            raise ValueError("tile_count must be positive")
        if self.cluster_count <= 0:
            raise ValueError("cluster_count must be positive")
        if self.feeder_count <= 0:
            raise ValueError("feeder_count must be positive")
        if self.q_rows_per_cluster <= 0:
            raise ValueError("q_rows_per_cluster must be positive")
        if self.kv_cols_per_cluster <= 0:
            raise ValueError("kv_cols_per_cluster must be positive")
        if self.head_dim <= 0:
            raise ValueError("head_dim must be positive")
        if self.element_bits <= 0:
            raise ValueError("element_bits must be positive")
        if self.row_scale_bits <= 0:
            raise ValueError("row_scale_bits must be positive")
        if self.task_queue_depth <= 0:
            raise ValueError("task_queue_depth must be positive")
        if self.task_descriptor_bits <= 0:
            raise ValueError("task_descriptor_bits must be positive")
        if self.qk_cycles <= 0:
            raise ValueError("qk_cycles must be positive")
        if self.row_state_pipe_count <= 0:
            raise ValueError("row_state_pipe_count must be positive")
        if self.max_inflight_tiles <= 0:
            raise ValueError("max_inflight_tiles must be positive")


@dataclass
class ModelResult:
    config: ModelConfig
    cycles: int
    sa_busy_cycles: int
    feeder_busy_cycles: int
    row_state_busy_cycles: int
    average_active_clusters: float
    max_active_clusters: int
    sa_utilization: float
    feeder_utilization: float
    row_state_utilization: float
    task_counts: Dict[str, int]
    feed_counts: Dict[str, int]
    stall_counts: Dict[str, int]
    active_cluster_histogram: Dict[int, int]

    def to_json_dict(self) -> Dict[str, object]:
        payload = asdict(self)
        payload["config"] = asdict(self.config)
        return payload


@dataclass
class BufferSizeEstimate:
    config: ModelConfig
    shared_bytes: Dict[str, int]
    per_cluster_bytes: Dict[str, int]
    shared_total_bytes: int
    per_cluster_total_bytes: int
    all_clusters_local_bytes: int
    task_queue_bytes: int
    total_estimated_bytes: int

    def to_json_dict(self) -> Dict[str, object]:
        payload = asdict(self)
        payload["config"] = asdict(self.config)
        return payload


@dataclass
class _Tile:
    tile_id: int
    state: str = "need_qk_feed"
    row_remaining: int = 0
    pv_feed_remaining: int = 0
    queued_pv: bool = False
    queued_oacc: bool = False


@dataclass
class _Cluster:
    task_kind: str = TASK_IDLE
    tile_id: int = -1
    remaining: int = 0

    @property
    def busy(self) -> bool:
        return self.remaining > 0


@dataclass
class _FeederJob:
    feed_kind: str
    tile_id: int
    remaining: int


@dataclass
class _RowStateJob:
    tile_id: int
    remaining: int


@dataclass
class _SimState:
    cfg: ModelConfig
    tiles: List[_Tile]
    clusters: List[_Cluster]
    feeders: List[Optional[_FeederJob]]
    row_state_pipes: List[Optional[_RowStateJob]]
    row_update_waiting: Deque[int] = field(default_factory=deque)
    next_tile_to_feed: int = 0
    qk_ready: Deque[int] = field(default_factory=deque)
    pv_ready: Deque[int] = field(default_factory=deque)
    oacc_ready: Deque[int] = field(default_factory=deque)
    qk_completed: int = 0
    pv_completed: int = 0
    oacc_completed: int = 0
    cycle: int = 0
    sa_busy_cycles: int = 0
    feeder_busy_cycles: int = 0
    row_state_busy_cycles: int = 0
    task_counts: Counter = field(default_factory=Counter)
    feed_counts: Counter = field(default_factory=Counter)
    stall_counts: Counter = field(default_factory=Counter)
    active_cluster_histogram: Counter = field(default_factory=Counter)


def simulate(cfg: ModelConfig) -> ModelResult:
    cfg.validate()
    state = _SimState(
        cfg=cfg,
        tiles=[_Tile(tile_id=i) for i in range(cfg.tile_count)],
        clusters=[_Cluster() for _ in range(cfg.cluster_count)],
        feeders=[None for _ in range(cfg.feeder_count)],
        row_state_pipes=[None for _ in range(cfg.row_state_pipe_count)],
    )

    max_cycles = _conservative_max_cycles(cfg)
    while not _done(state):
        if state.cycle >= max_cycles:
            raise RuntimeError(f"model did not finish within {max_cycles} cycles")
        _tick(state)

    total_cluster_slots = state.cycle * cfg.cluster_count
    total_feeder_slots = state.cycle * cfg.feeder_count
    total_row_state_slots = state.cycle * cfg.row_state_pipe_count
    average_active = state.sa_busy_cycles / state.cycle if state.cycle else 0.0
    sa_util = state.sa_busy_cycles / total_cluster_slots if total_cluster_slots else 0.0
    feeder_util = (
        state.feeder_busy_cycles / total_feeder_slots if total_feeder_slots else 0.0
    )
    row_state_util = (
        state.row_state_busy_cycles / total_row_state_slots
        if total_row_state_slots
        else 0.0
    )

    return ModelResult(
        config=cfg,
        cycles=state.cycle,
        sa_busy_cycles=state.sa_busy_cycles,
        feeder_busy_cycles=state.feeder_busy_cycles,
        row_state_busy_cycles=state.row_state_busy_cycles,
        average_active_clusters=average_active,
        max_active_clusters=max(state.active_cluster_histogram, default=0),
        sa_utilization=sa_util,
        feeder_utilization=feeder_util,
        row_state_utilization=row_state_util,
        task_counts=_counter_dict(
            state.task_counts, [TASK_QK, TASK_PV, TASK_OACC, "row_update"]
        ),
        feed_counts=_counter_dict(state.feed_counts, [TASK_QK, TASK_PV]),
        stall_counts=_counter_dict(
            state.stall_counts,
            ["cluster_wait_task", "feeder_wait_slot", "pv_wait_row_update"],
        ),
        active_cluster_histogram={
            idx: state.active_cluster_histogram.get(idx, 0)
            for idx in range(cfg.cluster_count + 1)
        },
    )


def run_named_scenarios(tile_count: int = 136) -> Dict[str, ModelResult]:
    scenarios = {
        "qk_only_1_feeder": ModelConfig(
            tile_count=tile_count,
            qk_feed_cycles=16,
            qk_cycles=16,
            pv_feed_cycles=0,
            pv_cycles=0,
            oacc_cycles=0,
            row_update_cycles=0,
        ),
        "qk_pv_oacc_48_local_cycles": ModelConfig(
            tile_count=tile_count,
            qk_feed_cycles=16,
            qk_cycles=16,
            pv_feed_cycles=0,
            pv_cycles=32,
            oacc_cycles=16,
            row_update_cycles=1,
        ),
        "qk_pv_oacc_64_local_cycles": ModelConfig(
            tile_count=tile_count,
            qk_feed_cycles=16,
            qk_cycles=16,
            pv_feed_cycles=0,
            pv_cycles=48,
            oacc_cycles=16,
            row_update_cycles=1,
        ),
        "pv_uses_same_feeder": ModelConfig(
            tile_count=tile_count,
            qk_feed_cycles=16,
            qk_cycles=16,
            pv_feed_cycles=16,
            pv_cycles=32,
            oacc_cycles=16,
            row_update_cycles=1,
        ),
        "two_feeders_local_post_gemm": ModelConfig(
            tile_count=tile_count,
            feeder_count=2,
            qk_feed_cycles=16,
            qk_cycles=16,
            pv_feed_cycles=0,
            pv_cycles=32,
            oacc_cycles=16,
            row_update_cycles=1,
        ),
        "shared_row_state_4cy": ModelConfig(
            tile_count=tile_count,
            qk_feed_cycles=16,
            qk_cycles=16,
            pv_feed_cycles=0,
            pv_cycles=32,
            oacc_cycles=16,
            row_update_cycles=4,
            row_state_pipe_count=1,
        ),
        "shared_row_state_32cy": ModelConfig(
            tile_count=tile_count,
            qk_feed_cycles=16,
            qk_cycles=16,
            pv_feed_cycles=0,
            pv_cycles=32,
            oacc_cycles=16,
            row_update_cycles=32,
            row_state_pipe_count=1,
        ),
    }

    return {name: simulate(cfg) for name, cfg in scenarios.items()}


def estimate_buffer_sizes(cfg: ModelConfig) -> BufferSizeEstimate:
    cfg.validate()

    q_tile_bits = cfg.q_rows_per_cluster * cfg.head_dim * cfg.element_bits
    kv_tile_bits = cfg.kv_cols_per_cluster * cfg.head_dim * cfg.element_bits
    p_tile_bits = cfg.q_rows_per_cluster * cfg.kv_cols_per_cluster * cfg.element_bits
    row_scale_bits = cfg.q_rows_per_cluster * 3 * cfg.row_scale_bits
    partial_bits = cfg.q_rows_per_cluster * cfg.head_dim * cfg.element_bits

    shared_bytes = {
        "q_operand_buffer": _bits_to_bytes(q_tile_bits),
    }
    per_cluster_bytes = {
        "k_operand_buffer": _bits_to_bytes(kv_tile_bits),
        "v_operand_buffer": _bits_to_bytes(kv_tile_bits),
        "p_tile_buffer": _bits_to_bytes(p_tile_bits),
        "row_scale_buffer": _bits_to_bytes(row_scale_bits),
        "pv_partial_buffer": _bits_to_bytes(partial_bits),
        "oacc_old_buffer": _bits_to_bytes(partial_bits),
        "oacc_new_buffer": _bits_to_bytes(partial_bits),
    }
    shared_total = sum(shared_bytes.values())
    per_cluster_total = sum(per_cluster_bytes.values())
    all_clusters = per_cluster_total * cfg.cluster_count
    task_queue_bytes = _bits_to_bytes(
        cfg.task_queue_depth * cfg.task_descriptor_bits
    )

    return BufferSizeEstimate(
        config=cfg,
        shared_bytes=shared_bytes,
        per_cluster_bytes=per_cluster_bytes,
        shared_total_bytes=shared_total,
        per_cluster_total_bytes=per_cluster_total,
        all_clusters_local_bytes=all_clusters,
        task_queue_bytes=task_queue_bytes,
        total_estimated_bytes=shared_total + all_clusters + task_queue_bytes,
    )


def write_report(results: Dict[str, ModelResult], output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    json_path = output_path.with_suffix(".json")
    buffer_estimate = estimate_buffer_sizes(next(iter(results.values())).config)
    json_path.write_text(
        json.dumps(
            {
                "scenarios": {
                    name: result.to_json_dict() for name, result in results.items()
                },
                "buffer_estimate": buffer_estimate.to_json_dict(),
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )

    lines = [
        "# FA 4x4 SA SRAM Pipeline Model",
        "",
        "This is a target architecture model, not current RTL evidence.",
        "",
        "| Scenario | Cycles | SA util | Avg active SA | Max active SA | Feeder util | Row-state util | QK | Row update | PV | OACC |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for name, result in results.items():
        lines.append(
            "| {name} | {cycles} | {sa:.3f} | {avg:.2f} | {max_active} | "
            "{feeder:.3f} | {row_state:.3f} | {qk} | {row_update} | {pv} | {oacc} |".format(
                name=name,
                cycles=result.cycles,
                sa=result.sa_utilization,
                avg=result.average_active_clusters,
                max_active=result.max_active_clusters,
                feeder=result.feeder_utilization,
                row_state=result.row_state_utilization,
                qk=result.task_counts[TASK_QK],
                row_update=result.task_counts["row_update"],
                pv=result.task_counts[TASK_PV],
                oacc=result.task_counts[TASK_OACC],
            )
        )
    lines.extend(
        [
            "",
            "## Buffer Sizing Contract",
            "",
            "Assumed target shape: 4 clusters, each cluster is one 4x4 SA. "
            "Q operands are shared across clusters; K/V/P/PV/OACC state is cluster-local.",
            "",
            "| Buffer | Scope | Bytes | Reason |",
            "|---|---|---:|---|",
        ]
    )
    for name, value in buffer_estimate.shared_bytes.items():
        lines.append(f"| `{name}` | shared | {value} | 4 Q rows x 64 dim x 16b |")
    buffer_reasons = {
        "k_operand_buffer": "4 K rows/cols x 64 dim x 16b",
        "v_operand_buffer": "4 V rows x 64 dim x 16b, avoids PV refetch through the same feeder",
        "p_tile_buffer": "4x4 P tile x 16b",
        "row_scale_buffer": "4 rows x old/new/scale x 32b",
        "pv_partial_buffer": "4 output rows x 64 dim x 16b",
        "oacc_old_buffer": "4 output rows x 64 dim x 16b",
        "oacc_new_buffer": "4 output rows x 64 dim x 16b",
    }
    for name, value in buffer_estimate.per_cluster_bytes.items():
        lines.append(
            f"| `{name}` | per cluster | {value} | {buffer_reasons[name]} |"
        )
    lines.extend(
        [
            "",
            f"- Per-cluster local buffer: {buffer_estimate.per_cluster_total_bytes} B.",
            f"- All cluster-local buffers: {buffer_estimate.all_clusters_local_bytes} B.",
            f"- Shared Q buffer: {buffer_estimate.shared_total_bytes} B.",
            f"- Task queues: {buffer_estimate.task_queue_bytes} B.",
            f"- Total modeled local buffer: {buffer_estimate.total_estimated_bytes} B.",
            "",
            "Interpretation:",
            "",
            "- `qk_only_1_feeder` is the negative-control case: one SRAM feeder can only keep one 4x4 cluster busy.",
            "- Local PV/OACC work increases the work per feed and can keep more clusters active if operands are buffered locally.",
            "- `pv_uses_same_feeder` shows the risk when PV has to consume the same SRAM feeder again.",
            "- A short shared row-state pipe can be reused by phase staggering; a long row-state pipe becomes the bottleneck.",
            "",
            f"JSON: `{json_path.as_posix()}`",
        ]
    )
    output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _tick(state: _SimState) -> None:
    _record_current_cycle(state)
    _advance_clusters(state)
    _advance_feeders(state)
    _advance_row_updates(state)
    _start_feeders(state)
    _start_clusters(state)
    state.cycle += 1


def _record_current_cycle(state: _SimState) -> None:
    active_clusters = sum(1 for cluster in state.clusters if cluster.busy)
    active_feeders = sum(1 for job in state.feeders if job is not None)
    active_row_state = sum(1 for job in state.row_state_pipes if job is not None)
    state.sa_busy_cycles += active_clusters
    state.feeder_busy_cycles += active_feeders
    state.row_state_busy_cycles += active_row_state
    state.active_cluster_histogram[active_clusters] += 1


def _advance_clusters(state: _SimState) -> None:
    for cluster in state.clusters:
        if not cluster.busy:
            continue
        cluster.remaining -= 1
        if cluster.remaining != 0:
            continue

        tile = state.tiles[cluster.tile_id]
        if cluster.task_kind == TASK_QK:
            state.qk_completed += 1
            if state.cfg.row_update_cycles > 0:
                tile.state = "row_update_wait"
                state.row_update_waiting.append(tile.tile_id)
            else:
                _make_pv_or_oacc_ready(state, tile)
        elif cluster.task_kind == TASK_PV:
            state.pv_completed += 1
            tile.state = "need_oacc"
            _enqueue_oacc(state, tile)
        elif cluster.task_kind == TASK_OACC:
            state.oacc_completed += 1
            tile.state = "done"
        else:
            raise RuntimeError(f"unknown cluster task {cluster.task_kind}")

        cluster.task_kind = TASK_IDLE
        cluster.tile_id = -1


def _advance_feeders(state: _SimState) -> None:
    for idx, job in enumerate(state.feeders):
        if job is None:
            continue
        job.remaining -= 1
        if job.remaining != 0:
            continue

        tile = state.tiles[job.tile_id]
        if job.feed_kind == TASK_QK:
            tile.state = "qk_ready"
            state.qk_ready.append(tile.tile_id)
        elif job.feed_kind == TASK_PV:
            _enqueue_pv(state, tile)
        else:
            raise RuntimeError(f"unknown feeder job {job.feed_kind}")
        state.feeders[idx] = None


def _advance_row_updates(state: _SimState) -> None:
    for idx, job in enumerate(state.row_state_pipes):
        if job is None:
            continue
        job.remaining -= 1
        if job.remaining != 0:
            continue
        tile = state.tiles[job.tile_id]
        state.task_counts["row_update"] += 1
        state.row_state_pipes[idx] = None
        _make_pv_or_oacc_ready(state, tile)

    for idx, job in enumerate(state.row_state_pipes):
        if job is not None:
            continue
        if not state.row_update_waiting:
            continue
        tile_id = state.row_update_waiting.popleft()
        state.tiles[tile_id].state = "row_update"
        state.row_state_pipes[idx] = _RowStateJob(
            tile_id=tile_id,
            remaining=state.cfg.row_update_cycles,
        )


def _start_feeders(state: _SimState) -> None:
    for idx, job in enumerate(state.feeders):
        if job is not None:
            continue

        feed_job = _select_feed_job(state)
        if feed_job is None:
            state.stall_counts["feeder_wait_slot"] += 1
            continue

        state.feeders[idx] = feed_job
        state.feed_counts[feed_job.feed_kind] += 1


def _start_clusters(state: _SimState) -> None:
    for cluster in state.clusters:
        if cluster.busy:
            continue

        task_kind, tile_id, cycles = _select_compute_task(state)
        if task_kind is None:
            state.stall_counts["cluster_wait_task"] += 1
            continue

        cluster.task_kind = task_kind
        cluster.tile_id = tile_id
        cluster.remaining = cycles
        state.task_counts[task_kind] += 1


def _select_feed_job(state: _SimState) -> Optional[_FeederJob]:
    tile = _find_tile_waiting_for_pv_feed(state)
    if tile is not None:
        tile.state = "pv_feed"
        return _FeederJob(TASK_PV, tile.tile_id, state.cfg.pv_feed_cycles)

    cfg = state.cfg
    while state.next_tile_to_feed < cfg.tile_count:
        inflight = _inflight_tile_count(state)
        if inflight >= cfg.max_inflight_tiles:
            return None
        tile = state.tiles[state.next_tile_to_feed]
        state.next_tile_to_feed += 1
        tile.state = "qk_feed"
        return _FeederJob(TASK_QK, tile.tile_id, cfg.qk_feed_cycles)

    return None


def _select_compute_task(state: _SimState) -> tuple[Optional[str], int, int]:
    if state.oacc_ready and state.cfg.oacc_cycles > 0:
        tile_id = state.oacc_ready.popleft()
        state.tiles[tile_id].state = "oacc_running"
        return TASK_OACC, tile_id, state.cfg.oacc_cycles

    if state.pv_ready and state.cfg.pv_cycles > 0:
        tile_id = state.pv_ready.popleft()
        state.tiles[tile_id].state = "pv_running"
        return TASK_PV, tile_id, state.cfg.pv_cycles

    if state.qk_ready:
        tile_id = state.qk_ready.popleft()
        state.tiles[tile_id].state = "qk_running"
        return TASK_QK, tile_id, state.cfg.qk_cycles

    return None, -1, 0


def _make_pv_or_oacc_ready(state: _SimState, tile: _Tile) -> None:
    if state.cfg.pv_cycles > 0:
        if state.cfg.pv_feed_cycles > 0:
            tile.state = "need_pv_feed"
            state.stall_counts["pv_wait_row_update"] += 1
        else:
            _enqueue_pv(state, tile)
    elif state.cfg.oacc_cycles > 0:
        _enqueue_oacc(state, tile)
    else:
        tile.state = "done"


def _enqueue_pv(state: _SimState, tile: _Tile) -> None:
    if tile.queued_pv:
        return
    tile.state = "pv_ready"
    tile.queued_pv = True
    state.pv_ready.append(tile.tile_id)


def _enqueue_oacc(state: _SimState, tile: _Tile) -> None:
    if tile.queued_oacc:
        return
    tile.state = "oacc_ready"
    tile.queued_oacc = True
    state.oacc_ready.append(tile.tile_id)


def _find_tile_waiting_for_pv_feed(state: _SimState) -> Optional[_Tile]:
    if state.cfg.pv_feed_cycles <= 0:
        return None
    for tile in state.tiles:
        if tile.state == "need_pv_feed":
            return tile
    return None


def _inflight_tile_count(state: _SimState) -> int:
    return sum(
        1
        for tile in state.tiles
        if tile.state
        not in (
            "need_qk_feed",
            "done",
        )
    )


def _done(state: _SimState) -> bool:
    return all(tile.state == "done" for tile in state.tiles)


def _conservative_max_cycles(cfg: ModelConfig) -> int:
    per_tile = (
        cfg.qk_feed_cycles
        + cfg.qk_cycles
        + cfg.row_update_cycles
        + cfg.pv_feed_cycles
        + cfg.pv_cycles
        + cfg.oacc_cycles
        + 8
    )
    return max(1024, per_tile * cfg.tile_count * 4)


def _counter_dict(counter: Counter, names: Iterable[str]) -> Dict[str, int]:
    return {name: counter.get(name, 0) for name in names}


def _bits_to_bytes(bit_count: int) -> int:
    return (bit_count + 7) // 8


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tiles", type=int, default=136)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("debug/20260629_fa_4x4_sa_sram_pipeline_model.md"),
    )
    args = parser.parse_args()

    results = run_named_scenarios(tile_count=args.tiles)
    write_report(results, args.output)

    for name, result in results.items():
        print(
            f"{name}: cycles={result.cycles} "
            f"sa_util={result.sa_utilization:.3f} "
            f"avg_active={result.average_active_clusters:.2f} "
            f"feeder_util={result.feeder_utilization:.3f}"
        )
    print(f"wrote {args.output}")
    print(f"wrote {args.output.with_suffix('.json')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
