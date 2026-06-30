from __future__ import annotations

import math
import random
from dataclasses import dataclass
from typing import List, Sequence, Tuple


Matrix = List[List[float]]


@dataclass(frozen=True)
class WindowedAttentionConfig:
    seq_len: int = 256
    head_dim: int = 64
    q_group_rows: int = 64
    q_tile_rows: int = 4
    kv_tile_rows: int = 16
    kv_window_tiles: int = 4
    oacc_slice_cols: int = 16
    score_slice_cols: int = 4
    scale: float = 0.125
    causal: bool = False

    def validate(self) -> None:
        positive_fields = {
            "seq_len": self.seq_len,
            "head_dim": self.head_dim,
            "q_group_rows": self.q_group_rows,
            "q_tile_rows": self.q_tile_rows,
            "kv_tile_rows": self.kv_tile_rows,
            "kv_window_tiles": self.kv_window_tiles,
            "oacc_slice_cols": self.oacc_slice_cols,
            "score_slice_cols": self.score_slice_cols,
        }
        for name, value in positive_fields.items():
            if value <= 0:
                raise ValueError(f"{name} must be positive")
        if self.seq_len % self.q_group_rows != 0:
            raise ValueError("seq_len must be divisible by q_group_rows")
        if self.q_group_rows % self.q_tile_rows != 0:
            raise ValueError("q_group_rows must be divisible by q_tile_rows")
        if self.seq_len % self.kv_tile_rows != 0:
            raise ValueError("seq_len must be divisible by kv_tile_rows")
        if (self.seq_len // self.kv_tile_rows) % self.kv_window_tiles != 0:
            raise ValueError("KV tile count must be divisible by kv_window_tiles")
        if self.head_dim % self.oacc_slice_cols != 0:
            raise ValueError("head_dim must be divisible by oacc_slice_cols")
        if self.kv_tile_rows % self.score_slice_cols != 0:
            raise ValueError("kv_tile_rows must be divisible by score_slice_cols")


@dataclass(frozen=True)
class WindowedAttentionCounters:
    q_group_count: int
    kv_window_count: int
    q_tile_visit_count: int
    kv_tile_compute_count: int
    skipped_future_kv_tiles: int
    score_slice_count: int
    oacc_slice_count: int
    state_spill_count: int
    state_fill_count: int


@dataclass(frozen=True)
class AttentionResult:
    output: Matrix
    counters: WindowedAttentionCounters


@dataclass(frozen=True)
class ErrorMetrics:
    mean_abs: float
    max_abs: float
    worst_row: int
    worst_col: int


def make_qkv(
    cfg: WindowedAttentionConfig, *, seed: int, amplitude: int = 24
) -> Tuple[Matrix, Matrix, Matrix]:
    cfg.validate()
    rng = random.Random(seed)
    return (
        _random_matrix(cfg, rng, amplitude),
        _random_matrix(cfg, rng, amplitude),
        _random_matrix(cfg, rng, amplitude),
    )


def dense_attention(
    q_matrix: Sequence[Sequence[float]],
    k_matrix: Sequence[Sequence[float]],
    v_matrix: Sequence[Sequence[float]],
    cfg: WindowedAttentionConfig,
) -> AttentionResult:
    cfg.validate()
    _validate_matrix(q_matrix, cfg.seq_len, cfg.head_dim, "q_matrix")
    _validate_matrix(k_matrix, cfg.seq_len, cfg.head_dim, "k_matrix")
    _validate_matrix(v_matrix, cfg.seq_len, cfg.head_dim, "v_matrix")

    output = _zero_matrix(cfg.seq_len, cfg.head_dim)
    for qi in range(cfg.seq_len):
        scores = []
        for kj in range(cfg.seq_len):
            if cfg.causal and kj > qi:
                scores.append(float("-inf"))
            else:
                scores.append(_dot(q_matrix[qi], k_matrix[kj]) * cfg.scale)
        row_max = max(scores)
        exp_values = [
            0.0 if score == float("-inf") else math.exp(score - row_max)
            for score in scores
        ]
        exp_sum = sum(exp_values)
        if exp_sum == 0.0:
            continue
        for kj, exp_value in enumerate(exp_values):
            prob = exp_value / exp_sum
            if prob == 0.0:
                continue
            for col in range(cfg.head_dim):
                output[qi][col] += prob * v_matrix[kj][col]

    return AttentionResult(
        output=output,
        counters=WindowedAttentionCounters(
            q_group_count=1,
            kv_window_count=1,
            q_tile_visit_count=cfg.seq_len // cfg.q_tile_rows,
            kv_tile_compute_count=(cfg.seq_len // cfg.q_tile_rows)
            * (cfg.seq_len // cfg.kv_tile_rows),
            skipped_future_kv_tiles=0,
            score_slice_count=0,
            oacc_slice_count=0,
            state_spill_count=0,
            state_fill_count=0,
        ),
    )


def windowed_attention(
    q_matrix: Sequence[Sequence[float]],
    k_matrix: Sequence[Sequence[float]],
    v_matrix: Sequence[Sequence[float]],
    cfg: WindowedAttentionConfig,
) -> AttentionResult:
    cfg.validate()
    _validate_matrix(q_matrix, cfg.seq_len, cfg.head_dim, "q_matrix")
    _validate_matrix(k_matrix, cfg.seq_len, cfg.head_dim, "k_matrix")
    _validate_matrix(v_matrix, cfg.seq_len, cfg.head_dim, "v_matrix")

    output = _zero_matrix(cfg.seq_len, cfg.head_dim)
    kv_tile_count = cfg.seq_len // cfg.kv_tile_rows
    kv_window_count_per_group = kv_tile_count // cfg.kv_window_tiles
    q_tile_count_per_group = cfg.q_group_rows // cfg.q_tile_rows
    oacc_slices_per_row = cfg.head_dim // cfg.oacc_slice_cols
    score_slices_per_row = cfg.kv_tile_rows // cfg.score_slice_cols

    q_group_count = 0
    kv_window_count = 0
    q_tile_visit_count = 0
    kv_tile_compute_count = 0
    skipped_future_kv_tiles = 0
    score_slice_count = 0
    oacc_slice_count = 0
    state_spill_count = 0
    state_fill_count = 0

    for q_group_base in range(0, cfg.seq_len, cfg.q_group_rows):
        q_group_count += 1
        group_rows = list(range(q_group_base, q_group_base + cfg.q_group_rows))
        row_max = [float("-inf") for _ in group_rows]
        row_sum = [0.0 for _ in group_rows]
        row_oacc = _zero_matrix(cfg.q_group_rows, cfg.head_dim)
        row_seen = [False for _ in group_rows]

        for kv_window_idx in range(kv_window_count_per_group):
            kv_window_count += 1
            kv_tile_base = kv_window_idx * cfg.kv_window_tiles
            for q_tile_offset in range(q_tile_count_per_group):
                q_tile_base = q_group_base + (q_tile_offset * cfg.q_tile_rows)
                q_tile_visit_count += 1
                state_fill_count += 1
                q_rows = range(q_tile_base, q_tile_base + cfg.q_tile_rows)

                for kv_tile_offset in range(cfg.kv_window_tiles):
                    kv_tile_idx = kv_tile_base + kv_tile_offset
                    kv_base = kv_tile_idx * cfg.kv_tile_rows
                    if _causal_tile_fully_future(cfg, q_tile_base, kv_base):
                        skipped_future_kv_tiles += 1
                        continue

                    kv_tile_compute_count += 1
                    score_slice_count += score_slices_per_row
                    oacc_slice_count += oacc_slices_per_row
                    for qi in q_rows:
                        group_row_idx = qi - q_group_base
                        score_values = [
                            _score_for_key(q_matrix, k_matrix, cfg, qi, kv_base + col)
                            for col in range(cfg.kv_tile_rows)
                        ]
                        valid_scores = [
                            score for score in score_values if score != float("-inf")
                        ]
                        if not valid_scores:
                            continue

                        old_max = row_max[group_row_idx]
                        old_sum = row_sum[group_row_idx]
                        tile_max = max(valid_scores)
                        new_max = max(old_max, tile_max)
                        old_scale = 0.0 if not row_seen[group_row_idx] else math.exp(old_max - new_max)
                        exp_values = [
                            0.0
                            if score == float("-inf")
                            else math.exp(score - new_max)
                            for score in score_values
                        ]
                        tile_sum = sum(exp_values)

                        for col_base in range(0, cfg.head_dim, cfg.oacc_slice_cols):
                            for out_col in range(col_base, col_base + cfg.oacc_slice_cols):
                                accum = row_oacc[group_row_idx][out_col] * old_scale
                                for local_k, exp_value in enumerate(exp_values):
                                    if exp_value == 0.0:
                                        continue
                                    accum += exp_value * v_matrix[kv_base + local_k][out_col]
                                row_oacc[group_row_idx][out_col] = accum

                        row_max[group_row_idx] = new_max
                        row_sum[group_row_idx] = old_sum * old_scale + tile_sum
                        row_seen[group_row_idx] = True

                state_spill_count += 1

        for local_row, qi in enumerate(group_rows):
            if row_sum[local_row] == 0.0:
                continue
            inv_sum = 1.0 / row_sum[local_row]
            for col in range(cfg.head_dim):
                output[qi][col] = row_oacc[local_row][col] * inv_sum

    counters = WindowedAttentionCounters(
        q_group_count=q_group_count,
        kv_window_count=kv_window_count,
        q_tile_visit_count=q_tile_visit_count,
        kv_tile_compute_count=kv_tile_compute_count,
        skipped_future_kv_tiles=skipped_future_kv_tiles,
        score_slice_count=score_slice_count,
        oacc_slice_count=oacc_slice_count,
        state_spill_count=state_spill_count,
        state_fill_count=state_fill_count,
    )
    return AttentionResult(output=output, counters=counters)


def compare_outputs(actual: AttentionResult, expected: AttentionResult) -> ErrorMetrics:
    if len(actual.output) != len(expected.output):
        raise ValueError("output row counts differ")
    total = 0.0
    count = 0
    max_abs = 0.0
    worst_row = 0
    worst_col = 0
    for row_idx, actual_row in enumerate(actual.output):
        expected_row = expected.output[row_idx]
        if len(actual_row) != len(expected_row):
            raise ValueError("output column counts differ")
        for col_idx, actual_value in enumerate(actual_row):
            err = abs(actual_value - expected_row[col_idx])
            total += err
            count += 1
            if err > max_abs:
                max_abs = err
                worst_row = row_idx
                worst_col = col_idx
    return ErrorMetrics(
        mean_abs=total / max(count, 1),
        max_abs=max_abs,
        worst_row=worst_row,
        worst_col=worst_col,
    )


def _random_matrix(
    cfg: WindowedAttentionConfig, rng: random.Random, amplitude: int
) -> Matrix:
    return [
        [rng.randint(-amplitude, amplitude) / 256.0 for _ in range(cfg.head_dim)]
        for _ in range(cfg.seq_len)
    ]


def _validate_matrix(
    matrix: Sequence[Sequence[float]], rows: int, cols: int, name: str
) -> None:
    if len(matrix) != rows:
        raise ValueError(f"{name} row count must be {rows}")
    for row in matrix:
        if len(row) != cols:
            raise ValueError(f"{name} column count must be {cols}")


def _dot(lhs: Sequence[float], rhs: Sequence[float]) -> float:
    return sum(a * b for a, b in zip(lhs, rhs))


def _score_for_key(
    q_matrix: Sequence[Sequence[float]],
    k_matrix: Sequence[Sequence[float]],
    cfg: WindowedAttentionConfig,
    qi: int,
    kj: int,
) -> float:
    if cfg.causal and kj > qi:
        return float("-inf")
    return _dot(q_matrix[qi], k_matrix[kj]) * cfg.scale


def _causal_tile_fully_future(
    cfg: WindowedAttentionConfig, q_tile_base: int, kv_base: int
) -> bool:
    if not cfg.causal:
        return False
    q_tile_last_row = q_tile_base + cfg.q_tile_rows - 1
    return kv_base > q_tile_last_row


def _zero_matrix(rows: int, cols: int) -> Matrix:
    return [[0.0 for _ in range(cols)] for _ in range(rows)]
