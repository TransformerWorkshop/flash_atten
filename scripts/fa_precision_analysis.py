from __future__ import annotations

import argparse
import json
import math
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable


REPO_ROOT = Path(__file__).resolve().parents[1]
COCOTB_ROOT = REPO_ROOT / "sim" / "cocotb"
if str(COCOTB_ROOT) not in sys.path:
    sys.path.insert(0, str(COCOTB_ROOT))

from tests.fa_baseline_env import (  # noqa: E402
    attention_golden_rows,
    q16_16_from_float,
    q16_16_to_float,
    q88_from_float,
    q88_to_float,
    unpack_q88_row_major_words,
)
from tests.fa_baseline_case_utils import make_single_q_full_kv_case_at_row, make_single_tile_case  # noqa: E402
from tests.test_fa_baseline import (  # noqa: E402
    expected_oacc_update_words,
    expected_pv_tile_words,
    expected_qk_tile_words,
    expected_row_state_update,
    expected_score_post_words,
    unpack_q88_tile_words,
)


HEAD_DIM = 64
SEQ_LEN = 256
TILE_ROWS = 16
SCALE = 1.0 / math.sqrt(HEAD_DIM)


@dataclass
class ErrorMetrics:
    mean_abs: float
    max_abs: float


@dataclass
class ProbabilityMetrics:
    sum_min: float
    sum_max: float
    sum_avg: float
    l1_avg: float
    l1_max: float
    nonzero_avg: float
    nonzero_min: int
    nonzero_max: int


@dataclass
class PrecisionBreakdown:
    case_name: str
    q_row_start: int
    scale_word_hex: str
    scale_q16_16: float
    input_quantization_error: ErrorMetrics
    row_state_error: ErrorMetrics
    pv_quantization_error: ErrorMetrics
    oacc_quantization_error: ErrorMetrics
    total_error: ErrorMetrics
    probability_metrics: ProbabilityMetrics


def quantize_matrix(matrix: list[list[float]]) -> list[list[float]]:
    return [[q88_to_float(q88_from_float(value) & 0xFFFF) for value in row] for row in matrix]


def matrix_error(lhs: list[list[float]], rhs: list[list[float]]) -> ErrorMetrics:
    total = 0.0
    worst = 0.0
    count = 0
    for row_idx in range(len(lhs)):
        for col_idx in range(len(lhs[row_idx])):
            error = abs(lhs[row_idx][col_idx] - rhs[row_idx][col_idx])
            total += error
            worst = max(worst, error)
            count += 1
    return ErrorMetrics(mean_abs=(total / max(count, 1)), max_abs=worst)


def exact_probabilities(
    q_rows: list[list[float]],
    k_matrix: list[list[float]],
    *,
    scale: float,
    causal: bool,
    q_row_start: int,
) -> list[list[float]]:
    probabilities: list[list[float]] = []
    for local_row, q_row in enumerate(q_rows):
        global_q = q_row_start + local_row
        scores: list[float | None] = []
        for global_k, k_row in enumerate(k_matrix):
            if causal and global_k > global_q:
                scores.append(None)
                continue
            dot = 0.0
            for dim in range(HEAD_DIM):
                dot += q_row[dim] * k_row[dim]
            scores.append(dot * scale)
        valid_scores = [score for score in scores if score is not None]
        row_max = max(valid_scores)
        exp_scores: list[float] = []
        exp_sum = 0.0
        for score in scores:
            if score is None:
                exp_scores.append(0.0)
            else:
                value = math.exp(score - row_max)
                exp_scores.append(value)
                exp_sum += value
        probabilities.append([value / exp_sum for value in exp_scores])
    return probabilities


def probability_metrics(
    approx_probs: list[list[float]],
    exact_probs: list[list[float]],
) -> ProbabilityMetrics:
    sums = [sum(row) for row in approx_probs]
    l1s = [
        sum(abs(approx_row[idx] - exact_row[idx]) for idx in range(len(approx_row)))
        for approx_row, exact_row in zip(approx_probs, exact_probs)
    ]
    nonzero_counts = [sum(1 for value in row if abs(value) > 0.0) for row in approx_probs]
    return ProbabilityMetrics(
        sum_min=min(sums),
        sum_max=max(sums),
        sum_avg=(sum(sums) / len(sums)),
        l1_avg=(sum(l1s) / len(l1s)),
        l1_max=max(l1s),
        nonzero_avg=(sum(nonzero_counts) / len(nonzero_counts)),
        nonzero_min=min(nonzero_counts),
        nonzero_max=max(nonzero_counts),
    )


def build_case_single_tile_noncausal(q_row_start: int) -> tuple[list[list[float]], list[list[float]], list[list[float]], bool]:
    if q_row_start != 0:
        raise ValueError("single_tile_noncausal only supports q_row_start=0")
    q_matrix, k_matrix, v_matrix = make_single_tile_case(1000)
    return q_matrix, k_matrix, v_matrix, False


def build_case_single_q_full_kv_causal(q_row_start: int) -> tuple[list[list[float]], list[list[float]], list[list[float]], bool]:
    q_matrix, k_matrix, v_matrix = make_single_q_full_kv_case_at_row(1010, q_row_start)
    return q_matrix, k_matrix, v_matrix, True


CASE_BUILDERS: dict[str, Callable[[int], tuple[list[list[float]], list[list[float]], list[list[float]], bool]]] = {
    "single_tile_noncausal": build_case_single_tile_noncausal,
    "single_q_full_kv_causal": build_case_single_q_full_kv_causal,
}


def analyze_case(case_name: str, q_row_start: int) -> PrecisionBreakdown:
    q_matrix, k_matrix, v_matrix, causal = CASE_BUILDERS[case_name](q_row_start)
    q_quant = quantize_matrix(q_matrix)
    k_quant = quantize_matrix(k_matrix)
    v_quant = quantize_matrix(v_matrix)
    scale_word = q16_16_from_float(SCALE) & 0xFFFF_FFFF
    scale_q16 = q16_16_to_float(scale_word)
    neg_large_word = q16_16_from_float(-64.0) & 0xFFFF_FFFF

    float_reference = attention_golden_rows(
        q_matrix,
        k_matrix,
        v_matrix,
        scale=SCALE,
        causal=causal,
        q_start=q_row_start,
        q_rows=TILE_ROWS,
    )
    quant_reference = attention_golden_rows(
        q_quant,
        k_quant,
        v_quant,
        scale=scale_q16,
        causal=causal,
        q_start=q_row_start,
        q_rows=TILE_ROWS,
    )

    m_state = [neg_large_word for _ in range(TILE_ROWS)]
    l_state = [0 for _ in range(TILE_ROWS)]
    row_seen = [0 for _ in range(TILE_ROWS)]
    oacc_words = [0 for _ in range(TILE_ROWS * 32)]
    oacc_from_probs = [[0.0 for _ in range(HEAD_DIM)] for _ in range(TILE_ROWS)]
    oacc_from_pv = [[0.0 for _ in range(HEAD_DIM)] for _ in range(TILE_ROWS)]
    approx_probabilities = [[0.0 for _ in range(SEQ_LEN)] for _ in range(TILE_ROWS)]

    q_tile = q_quant[q_row_start : q_row_start + TILE_ROWS]
    for kv_blk in range(SEQ_LEN // TILE_ROWS):
        k_tile = k_quant[kv_blk * TILE_ROWS : (kv_blk + 1) * TILE_ROWS]
        v_tile = v_quant[kv_blk * TILE_ROWS : (kv_blk + 1) * TILE_ROWS]

        qk_words = expected_qk_tile_words(q_tile, k_tile)
        masked_words = expected_score_post_words(
            qk_words,
            q_row_start // TILE_ROWS,
            kv_blk,
            causal=causal,
            scale_word=scale_word,
            neg_large_word=neg_large_word,
        )
        p_words, rescale_words, m_state, l_state, row_seen = expected_row_state_update(
            masked_words,
            neg_large_word=neg_large_word,
            m_state=m_state,
            l_state=l_state,
            row_seen=row_seen,
        )
        pv_words = expected_pv_tile_words(p_words, v_tile)
        oacc_words = expected_oacc_update_words(oacc_words, rescale_words, pv_words)

        p_tile_int = unpack_q88_tile_words(p_words, TILE_ROWS, TILE_ROWS)
        p_tile = [[cell / 256.0 for cell in row] for row in p_tile_int]
        pv_tile = unpack_q88_row_major_words(pv_words, TILE_ROWS, HEAD_DIM)
        rescale = [q16_16_to_float(word) for word in rescale_words]

        for row_idx in range(TILE_ROWS):
            for global_k in range(SEQ_LEN):
                approx_probabilities[row_idx][global_k] *= rescale[row_idx]
            for local_k in range(TILE_ROWS):
                approx_probabilities[row_idx][kv_blk * TILE_ROWS + local_k] = p_tile[row_idx][local_k]
            for dim in range(HEAD_DIM):
                oacc_from_probs[row_idx][dim] *= rescale[row_idx]
                oacc_from_pv[row_idx][dim] *= rescale[row_idx]
                weighted_sum = 0.0
                for local_k in range(TILE_ROWS):
                    weighted_sum += p_tile[row_idx][local_k] * v_tile[local_k][dim]
                oacc_from_probs[row_idx][dim] += weighted_sum
                oacc_from_pv[row_idx][dim] += pv_tile[row_idx][dim]

    rtl_like = unpack_q88_row_major_words(oacc_words, TILE_ROWS, HEAD_DIM)
    exact_probs = exact_probabilities(q_tile, k_quant, scale=scale_q16, causal=causal, q_row_start=q_row_start)

    return PrecisionBreakdown(
        case_name=case_name,
        q_row_start=q_row_start,
        scale_word_hex=hex(scale_word),
        scale_q16_16=scale_q16,
        input_quantization_error=matrix_error(float_reference, quant_reference),
        row_state_error=matrix_error(quant_reference, oacc_from_probs),
        pv_quantization_error=matrix_error(oacc_from_probs, oacc_from_pv),
        oacc_quantization_error=matrix_error(oacc_from_pv, rtl_like),
        total_error=matrix_error(quant_reference, rtl_like),
        probability_metrics=probability_metrics(approx_probabilities, exact_probs),
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Analyze FA baseline precision loss by stage")
    parser.add_argument(
        "--case",
        choices=sorted(CASE_BUILDERS.keys()),
        default="single_q_full_kv_causal",
    )
    parser.add_argument(
        "--q-row-start",
        type=int,
        action="append",
        help="Global query row start for the 16-row tile. Can be passed multiple times.",
    )
    parser.add_argument("--json", action="store_true", help="Emit machine-readable JSON")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    q_row_starts = args.q_row_start if args.q_row_start else ([0] if args.case == "single_tile_noncausal" else [0, 112, 240])
    reports = [analyze_case(args.case, q_row_start) for q_row_start in q_row_starts]
    if args.json:
        print(json.dumps([asdict(report) for report in reports], indent=2, ensure_ascii=True))
        return 0

    for report in reports:
        print(f"case={report.case_name} q_row_start={report.q_row_start}")
        print(f"  scale={report.scale_word_hex} -> {report.scale_q16_16:.6f}")
        print(
            "  input_quantization"
            f"  mean={report.input_quantization_error.mean_abs:.6f}"
            f" max={report.input_quantization_error.max_abs:.6f}"
        )
        print(
            "  row_state"
            f"           mean={report.row_state_error.mean_abs:.6f}"
            f" max={report.row_state_error.max_abs:.6f}"
        )
        print(
            "  pv_quantization"
            f"     mean={report.pv_quantization_error.mean_abs:.6f}"
            f" max={report.pv_quantization_error.max_abs:.6f}"
        )
        print(
            "  oacc_quantization"
            f"   mean={report.oacc_quantization_error.mean_abs:.6f}"
            f" max={report.oacc_quantization_error.max_abs:.6f}"
        )
        print(
            "  total"
            f"               mean={report.total_error.mean_abs:.6f}"
            f" max={report.total_error.max_abs:.6f}"
        )
        pm = report.probability_metrics
        print(
            "  probs"
            f" sum_avg={pm.sum_avg:.6f}"
            f" sum_min={pm.sum_min:.6f}"
            f" sum_max={pm.sum_max:.6f}"
            f" l1_avg={pm.l1_avg:.6f}"
            f" l1_max={pm.l1_max:.6f}"
            f" nz_avg={pm.nonzero_avg:.2f}"
            f" nz_min={pm.nonzero_min}"
            f" nz_max={pm.nonzero_max}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
