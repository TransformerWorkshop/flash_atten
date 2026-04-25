from __future__ import annotations

from typing import Sequence

from tests.fa_baseline_env import HEAD_DIM, SEQ_LEN, matrix_error, random_q88_matrix, zero_matrix


def first_rows(matrix, rows: int):
    return matrix[:rows]


def make_single_tile_case(seed_base: int):
    q = zero_matrix(SEQ_LEN, HEAD_DIM)
    k = zero_matrix(SEQ_LEN, HEAD_DIM)
    v = zero_matrix(SEQ_LEN, HEAD_DIM)
    q_tile = random_q88_matrix(16, HEAD_DIM, seed_base + 1, amplitude=72)
    k_tile = random_q88_matrix(16, HEAD_DIM, seed_base + 2, amplitude=72)
    v_tile = random_q88_matrix(16, HEAD_DIM, seed_base + 3, amplitude=72)
    for row in range(16):
        q[row] = q_tile[row]
        k[row] = k_tile[row]
        v[row] = v_tile[row]
    return q, k, v


def make_single_q_full_kv_case(seed_base: int):
    q = zero_matrix(SEQ_LEN, HEAD_DIM)
    k = random_q88_matrix(SEQ_LEN, HEAD_DIM, seed_base + 11, amplitude=64)
    v = random_q88_matrix(SEQ_LEN, HEAD_DIM, seed_base + 12, amplitude=64)
    q_tile = random_q88_matrix(16, HEAD_DIM, seed_base + 10, amplitude=64)
    for row in range(16):
        q[row] = q_tile[row]
    return q, k, v


def assert_matrix_close(
    actual: Sequence[Sequence[float]],
    expected: Sequence[Sequence[float]],
    *,
    mean_limit: float = 0.03,
    max_limit: float = 0.10,
    rows: int | None = None,
) -> None:
    lhs = first_rows(actual, rows) if rows is not None else actual
    rhs = first_rows(expected, rows) if rows is not None else expected
    mean_err, max_err = matrix_error(lhs, rhs)
    assert mean_err <= mean_limit, f"mean_err={mean_err}"
    assert max_err <= max_limit, f"max_err={max_err}"
