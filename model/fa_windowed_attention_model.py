from __future__ import annotations

import math
import random
import re
from dataclasses import dataclass
from pathlib import Path
from typing import List, Sequence, Tuple


Matrix = List[List[float]]

Q16_MAX = 0x7FFF_FFFF


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


def fixed_dense_qk_score_q16(
    q_tile_idx: int, q_row: int, kv_tile_idx: int, kv_col: int
) -> int:
    acc_q16 = 0
    for dim_idx in range(64):
        q_q88 = _dense_qk_q_word(q_tile_idx, q_row, dim_idx)
        k_q88 = _dense_qk_k_word(kv_tile_idx, kv_col, dim_idx)
        acc_q16 += q_q88 * k_q88
    return _sat_signed(acc_q16, 32)


def expected_dense_qk_fixed_o_word(row: int, col: int) -> int:
    old_m_q16 = _to_signed(0xFFC0_0000, 32)
    old_l_q16 = 0
    old_o_q412 = 0

    for kv_idx in range(16):
        scores_q16 = [
            fixed_dense_qk_score_q16(63, row, kv_idx, key_col_idx)
            for key_col_idx in range(16)
        ]
        new_m_q16 = max(scores_q16)
        if old_l_q16 != 0:
            new_m_q16 = max(old_m_q16, new_m_q16)
            alpha_q16 = _exp_lut_q16_16(_q16_delta_to_exp_idx(old_m_q16 - new_m_q16))
            alpha_l_old_q16 = _q16_mul_rn_sat(alpha_q16, old_l_q16)
        else:
            alpha_l_old_q16 = 0

        beta_q16 = [
            _exp_lut_q16_16(_q16_delta_to_exp_idx(score_q16 - new_m_q16))
            for score_q16 in scores_q16
        ]
        beta_sum_q16 = 0
        for beta in beta_q16:
            beta_sum_q16 = _q16_add_sat(beta_sum_q16, beta)

        new_l_q16 = _q16_add_sat(alpha_l_old_q16, beta_sum_q16)
        recip_q16 = _recip_q16_16(new_l_q16)
        scale_q16 = 0 if old_l_q16 == 0 else _q16_mul_rn_sat(alpha_l_old_q16, recip_q16)

        partial_acc_q16 = 0
        for key_col_idx, beta in enumerate(beta_q16):
            p_q16 = _q16_mul_rn_sat(beta, recip_q16)
            p_q88 = _q16_to_q88_rn_sat(p_q16)
            v_q88 = _dense_qk_v_word(kv_idx, key_col_idx, col)
            partial_acc_q16 += p_q88 * v_q88
        partial_q88 = _q16_16_to_q88_sat128(partial_acc_q16)
        old_o_q412 = _update_oacc_elem(old_o_q412, scale_q16, partial_q88)
        old_m_q16 = new_m_q16
        old_l_q16 = new_l_q16

    return _to_unsigned(old_o_q412, 16)


def fixed_dense_qk_window_output() -> List[List[int]]:
    return [
        [expected_dense_qk_fixed_o_word(row, col) for col in range(64)]
        for row in range(4)
    ]


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


def _dense_qk_q_word(q_tile_idx: int, row_idx: int, col_idx: int) -> int:
    row_tile_sum = ((row_idx & 0x3) + (q_tile_idx & 0x3)) & 0x3
    return 1 + row_tile_sum + (col_idx & 0x3)


def _dense_qk_k_word(kv_tile_idx: int, row_idx: int, col_idx: int) -> int:
    row_tile_sum = ((row_idx & 0x3) + (kv_tile_idx & 0x3)) & 0x3
    return 1 + row_tile_sum + (col_idx & 0x3)


def _dense_qk_v_word(kv_tile_idx: int, row_idx: int, col_idx: int) -> int:
    return 0x0010 + ((kv_tile_idx & 0xF) << 4) + (row_idx & 0xF) + col_idx


def _q16_add_sat(lhs: int, rhs: int) -> int:
    return _sat_signed(lhs + rhs, 32)


def _q16_mul_rn_sat(lhs: int, rhs: int) -> int:
    prod = lhs * rhs
    rounded = prod + 32768 if prod >= 0 else prod - 32768
    return _sat_signed(_arith_shift_right(rounded, 16), 32)


def _q16_delta_to_exp_idx(delta: int) -> int:
    clamped = min(0, max(delta, -524288))
    abs_mag = -clamped
    shifted = (abs_mag + 1024) >> 11
    return min(shifted, 256)


def _exp_lut_q16_16(idx: int) -> int:
    table = _exp_lut_table()
    return table.get(idx, 0x00000016)


def _q16_to_q88_rn_sat(value: int) -> int:
    rounded = value + 128 if value >= 0 else value - 128
    return _sat_signed(_arith_shift_right(rounded, 8), 16)


def _q16_to_q412_rn_sat(value: int) -> int:
    rounded = value + 8 if value >= 0 else value - 8
    return _sat_signed(_arith_shift_right(rounded, 4), 16)


def _q16_16_to_q88_sat128(value: int) -> int:
    rounded = value + 128 if value >= 0 else value - 128
    return _sat_signed(_arith_shift_right(rounded, 8), 16)


def _q88_to_q16(value: int) -> int:
    return _to_signed(value, 16) << 8


def _q412_to_q16(value: int) -> int:
    return _to_signed(value, 16) << 4


def _recip_q16_16(in_value: int) -> int:
    in_value = _to_unsigned(in_value, 32)
    if (in_value & 0x8000_0000) != 0 or in_value == 0:
        return 0
    quotient = 0x1_0000_0000 // in_value
    return min(quotient, Q16_MAX)


def _update_oacc_elem(old_q412_word: int, scale_word: int, partial_q88_word: int) -> int:
    old_q16 = _q412_to_q16(old_q412_word)
    scaled_old_q16 = _q16_mul_rn_sat(old_q16, scale_word)
    partial_q16 = _q88_to_q16(partial_q88_word)
    next_q16 = _q16_add_sat(scaled_old_q16, partial_q16)
    return _q16_to_q412_rn_sat(next_q16)


def _sat_signed(value: int, bits: int) -> int:
    min_value = -(1 << (bits - 1))
    max_value = (1 << (bits - 1)) - 1
    return min(max(value, min_value), max_value)


def _to_unsigned(value: int, bits: int) -> int:
    return value & ((1 << bits) - 1)


def _to_signed(value: int, bits: int) -> int:
    mask = (1 << bits) - 1
    value &= mask
    sign = 1 << (bits - 1)
    return value - (1 << bits) if value & sign else value


def _arith_shift_right(value: int, amount: int) -> int:
    return value >> amount


def _exp_lut_table() -> dict[int, int]:
    if not hasattr(_exp_lut_table, "_cache"):
        lut_path = Path(__file__).resolve().parents[1] / "rtl" / "fa_exp_lut_q16_16.vh"
        entries: dict[int, int] = {}
        for line in lut_path.read_text().splitlines():
            match = re.search(r"9'd(\d+):\s+fa_exp_lut_q16_16\s+=\s+32'h([0-9a-fA-F_]+)", line)
            if match:
                entries[int(match.group(1))] = int(match.group(2).replace("_", ""), 16)
        _exp_lut_table._cache = entries
    return _exp_lut_table._cache
