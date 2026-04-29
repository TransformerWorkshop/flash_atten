from __future__ import annotations

import argparse
import json
import math
import random
import sys
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]
COCOTB_ROOT = REPO_ROOT / "sim" / "cocotb"
if str(COCOTB_ROOT) not in sys.path:
    sys.path.insert(0, str(COCOTB_ROOT))
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from tests.fa_baseline_env import (  # noqa: E402
    HEAD_DIM,
    SEQ_LEN,
    TILE_ROWS,
    attention_golden_rows,
    q16_16_from_float,
    q16_16_to_float,
    q88_from_float,
    q88_to_float,
    unpack_q88_row_major_words,
    zero_matrix,
)
from tests.test_fa_baseline import (  # noqa: E402
    expected_oacc_update_q412_words,
    expected_pv_tile_words,
    expected_qk_tile_words,
    expected_row_state_update,
    expected_score_post_words,
    q16_mul_rn_sat_py,
    q412_oacc_words_to_q88_words,
    s32,
    unpack_q88_tile_words,
)


SCALE = 1.0 / math.sqrt(HEAD_DIM)
Q88_MAX_RAW = 32767
Q88_MIN_RAW = -32768
S32_MAX = 0x7FFF_FFFF
S32_MIN = -0x8000_0000


@dataclass
class ErrorMetrics:
    mean_abs: float
    max_abs: float
    worst_row: int
    worst_col: int
    actual: float
    expected: float


@dataclass
class QkMetrics:
    saturated_scores: int
    total_scores: int
    saturation_pct: float
    max_abs_dot_raw: int
    max_score_delta: float


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
class ExtremeCase:
    name: str
    description: str
    q_matrix: list[list[float]]
    k_matrix: list[list[float]]
    v_matrix: list[list[float]]
    causal: bool
    q_row_start: int = 0


@dataclass
class ExtremePrecisionReport:
    case_name: str
    description: str
    causal: bool
    q_row_start: int
    input_quantization: ErrorMetrics
    qk_saturation_scale: ErrorMetrics
    row_state_probability: ErrorMetrics
    pv_quantization: ErrorMetrics
    oacc_quantization: ErrorMetrics
    total_vs_quantized_golden: ErrorMetrics
    total_vs_float_golden: ErrorMetrics
    qk_metrics: QkMetrics
    probability_metrics: ProbabilityMetrics
    worst_stage_by_max: str
    worst_stage_by_mean: str
    passes_precision: bool


def clamp_raw16(raw: int) -> int:
    return max(Q88_MIN_RAW, min(Q88_MAX_RAW, int(raw)))


def q88_float_from_raw(raw: int) -> float:
    return q88_to_float(clamp_raw16(raw) & 0xFFFF)


def raw_matrix(rows: int, cols: int, raw: int = 0) -> list[list[float]]:
    value = q88_float_from_raw(raw)
    return [[value for _ in range(cols)] for _ in range(rows)]


def set_row_raw(matrix: list[list[float]], row_idx: int, raw: int | Iterable[int]) -> None:
    if isinstance(raw, int):
        matrix[row_idx] = [q88_float_from_raw(raw) for _ in range(HEAD_DIM)]
        return
    values = [q88_float_from_raw(value) for value in raw]
    if len(values) != HEAD_DIM:
        raise ValueError(f"expected {HEAD_DIM} values, got {len(values)}")
    matrix[row_idx] = values


def quantize_matrix(matrix: list[list[float]]) -> list[list[float]]:
    return [[q88_to_float(q88_from_float(value) & 0xFFFF) for value in row] for row in matrix]


def matrix_error(actual: list[list[float]], expected: list[list[float]]) -> ErrorMetrics:
    total = 0.0
    count = 0
    worst = -1.0
    worst_row = 0
    worst_col = 0
    actual_value = 0.0
    expected_value = 0.0
    for row_idx, row in enumerate(actual):
        for col_idx, value in enumerate(row):
            err = abs(value - expected[row_idx][col_idx])
            total += err
            count += 1
            if err > worst:
                worst = err
                worst_row = row_idx
                worst_col = col_idx
                actual_value = value
                expected_value = expected[row_idx][col_idx]
    return ErrorMetrics(
        mean_abs=total / max(count, 1),
        max_abs=max(worst, 0.0),
        worst_row=worst_row,
        worst_col=worst_col,
        actual=actual_value,
        expected=expected_value,
    )


def q88_raw(value: float) -> int:
    raw = q88_from_float(value) & 0xFFFF
    if raw & 0x8000:
        raw -= 0x10000
    return raw


def clamp_s32(value: int) -> int:
    return max(S32_MIN, min(S32_MAX, int(value)))


def qk_dot_raw(q_row: list[float], k_row: list[float]) -> int:
    return sum(q88_raw(q_row[dim]) * q88_raw(k_row[dim]) for dim in range(HEAD_DIM))


def scaled_score_from_dot(dot_raw: int, scale_word: int, *, saturate_qk: bool) -> float:
    dot = clamp_s32(dot_raw) if saturate_qk else dot_raw
    if saturate_qk:
        scaled_word = q16_mul_rn_sat_py(dot & 0xFFFF_FFFF, scale_word)
        return q16_16_to_float(scaled_word)
    return (dot / 65536.0) * q16_16_to_float(scale_word)


def score_rows(
    q_rows: list[list[float]],
    k_matrix: list[list[float]],
    *,
    q_row_start: int,
    causal: bool,
    scale_word: int,
    saturate_qk: bool,
) -> tuple[list[list[float | None]], QkMetrics]:
    rows: list[list[float | None]] = []
    saturated = 0
    total = 0
    max_abs_dot = 0
    max_score_delta = 0.0

    for local_row, q_row in enumerate(q_rows):
        global_q = q_row_start + local_row
        score_row: list[float | None] = []
        for global_k, k_row in enumerate(k_matrix):
            if causal and global_k > global_q:
                score_row.append(None)
                continue
            dot_raw = qk_dot_raw(q_row, k_row)
            total += 1
            if dot_raw > S32_MAX or dot_raw < S32_MIN:
                saturated += 1
            max_abs_dot = max(max_abs_dot, abs(dot_raw))
            exact_score = scaled_score_from_dot(dot_raw, scale_word, saturate_qk=False)
            sat_score = scaled_score_from_dot(dot_raw, scale_word, saturate_qk=True)
            max_score_delta = max(max_score_delta, abs(exact_score - sat_score))
            score_row.append(sat_score if saturate_qk else exact_score)
        rows.append(score_row)

    return rows, QkMetrics(
        saturated_scores=saturated,
        total_scores=total,
        saturation_pct=100.0 * saturated / max(total, 1),
        max_abs_dot_raw=max_abs_dot,
        max_score_delta=max_score_delta,
    )


def attention_from_score_rows(
    score_rows_i: list[list[float | None]],
    v_matrix: list[list[float]],
) -> list[list[float]]:
    out = zero_matrix(len(score_rows_i), HEAD_DIM)
    for row_idx, scores in enumerate(score_rows_i):
        valid_scores = [score for score in scores if score is not None]
        if not valid_scores:
            continue
        row_max = max(valid_scores)
        exp_scores: list[float] = []
        exp_sum = 0.0
        for score in scores:
            if score is None:
                exp_scores.append(0.0)
                continue
            value = math.exp(score - row_max)
            exp_scores.append(value)
            exp_sum += value
        if exp_sum == 0.0:
            continue
        for key_idx, exp_value in enumerate(exp_scores):
            if exp_value == 0.0:
                continue
            prob = exp_value / exp_sum
            for dim in range(HEAD_DIM):
                out[row_idx][dim] += prob * v_matrix[key_idx][dim]
    return out


def probability_metrics(
    approx_probs: list[list[float]],
    exact_score_rows: list[list[float | None]],
) -> ProbabilityMetrics:
    exact_probs: list[list[float]] = []
    for scores in exact_score_rows:
        valid_scores = [score for score in scores if score is not None]
        if not valid_scores:
            exact_probs.append([0.0 for _ in scores])
            continue
        row_max = max(valid_scores)
        exps: list[float] = []
        exp_sum = 0.0
        for score in scores:
            if score is None:
                exps.append(0.0)
                continue
            value = math.exp(score - row_max)
            exps.append(value)
            exp_sum += value
        exact_probs.append([value / exp_sum if exp_sum else 0.0 for value in exps])

    sums = [sum(row) for row in approx_probs]
    l1s = [
        sum(abs(approx_row[idx] - exact_row[idx]) for idx in range(len(approx_row)))
        for approx_row, exact_row in zip(approx_probs, exact_probs)
    ]
    nonzero_counts = [sum(1 for value in row if value != 0.0) for row in approx_probs]
    return ProbabilityMetrics(
        sum_min=min(sums),
        sum_max=max(sums),
        sum_avg=sum(sums) / len(sums),
        l1_avg=sum(l1s) / len(l1s),
        l1_max=max(l1s),
        nonzero_avg=sum(nonzero_counts) / len(nonzero_counts),
        nonzero_min=min(nonzero_counts),
        nonzero_max=max(nonzero_counts),
    )


def rtl_like_pipeline(
    q_matrix: list[list[float]],
    k_matrix: list[list[float]],
    v_matrix: list[list[float]],
    *,
    causal: bool,
    q_row_start: int,
    scale_word: int,
    neg_large_word: int,
) -> tuple[list[list[float]], list[list[float]], list[list[float]], list[list[float]], ProbabilityMetrics]:
    m_state = [neg_large_word for _ in range(TILE_ROWS)]
    l_state = [0 for _ in range(TILE_ROWS)]
    row_seen = [0 for _ in range(TILE_ROWS)]
    oacc_q412_words = [0 for _ in range(TILE_ROWS * HEAD_DIM)]
    oacc_from_probs = zero_matrix(TILE_ROWS, HEAD_DIM)
    oacc_from_pv = zero_matrix(TILE_ROWS, HEAD_DIM)
    approx_probabilities = zero_matrix(TILE_ROWS, SEQ_LEN)

    q_tile = q_matrix[q_row_start : q_row_start + TILE_ROWS]
    for kv_blk in range(SEQ_LEN // TILE_ROWS):
        k_tile = k_matrix[kv_blk * TILE_ROWS : (kv_blk + 1) * TILE_ROWS]
        v_tile = v_matrix[kv_blk * TILE_ROWS : (kv_blk + 1) * TILE_ROWS]

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
        oacc_q412_words = expected_oacc_update_q412_words(oacc_q412_words, rescale_words, pv_words)

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

    rtl_like = unpack_q88_row_major_words(q412_oacc_words_to_q88_words(oacc_q412_words), TILE_ROWS, HEAD_DIM)
    sat_score_rows, _ = score_rows(
        q_tile,
        k_matrix,
        q_row_start=q_row_start,
        causal=causal,
        scale_word=scale_word,
        saturate_qk=True,
    )
    probs = probability_metrics(approx_probabilities, sat_score_rows)
    return oacc_from_probs, oacc_from_pv, rtl_like, approx_probabilities, probs


def analyze_extreme_case(
    case: ExtremeCase,
    *,
    mean_limit: float = 0.03,
    max_limit: float = 0.10,
) -> ExtremePrecisionReport:
    q_quant = quantize_matrix(case.q_matrix)
    k_quant = quantize_matrix(case.k_matrix)
    v_quant = quantize_matrix(case.v_matrix)
    scale_word = q16_16_from_float(SCALE) & 0xFFFF_FFFF
    scale_q16 = q16_16_to_float(scale_word)
    neg_large_word = q16_16_from_float(-64.0) & 0xFFFF_FFFF
    q_tile = q_quant[case.q_row_start : case.q_row_start + TILE_ROWS]

    float_reference = attention_golden_rows(
        case.q_matrix,
        case.k_matrix,
        case.v_matrix,
        scale=SCALE,
        causal=case.causal,
        q_start=case.q_row_start,
        q_rows=TILE_ROWS,
    )
    quant_reference = attention_golden_rows(
        q_quant,
        k_quant,
        v_quant,
        scale=scale_q16,
        causal=case.causal,
        q_start=case.q_row_start,
        q_rows=TILE_ROWS,
    )
    sat_scores, qk_metrics = score_rows(
        q_tile,
        k_quant,
        q_row_start=case.q_row_start,
        causal=case.causal,
        scale_word=scale_word,
        saturate_qk=True,
    )
    qk_saturated_reference = attention_from_score_rows(sat_scores, v_quant)
    row_state_output, pv_output, rtl_like, _, prob_metrics = rtl_like_pipeline(
        q_quant,
        k_quant,
        v_quant,
        causal=case.causal,
        q_row_start=case.q_row_start,
        scale_word=scale_word,
        neg_large_word=neg_large_word,
    )

    stage_errors = {
        "input_quantization": matrix_error(quant_reference, float_reference),
        "qk_saturation_scale": matrix_error(qk_saturated_reference, quant_reference),
        "row_state_probability": matrix_error(row_state_output, qk_saturated_reference),
        "pv_quantization": matrix_error(pv_output, row_state_output),
        "oacc_quantization": matrix_error(rtl_like, pv_output),
    }
    total_vs_quant = matrix_error(rtl_like, quant_reference)
    total_vs_float = matrix_error(rtl_like, float_reference)
    worst_stage_by_max = max(stage_errors.items(), key=lambda item: item[1].max_abs)[0]
    worst_stage_by_mean = max(stage_errors.items(), key=lambda item: item[1].mean_abs)[0]

    return ExtremePrecisionReport(
        case_name=case.name,
        description=case.description,
        causal=case.causal,
        q_row_start=case.q_row_start,
        input_quantization=stage_errors["input_quantization"],
        qk_saturation_scale=stage_errors["qk_saturation_scale"],
        row_state_probability=stage_errors["row_state_probability"],
        pv_quantization=stage_errors["pv_quantization"],
        oacc_quantization=stage_errors["oacc_quantization"],
        total_vs_quantized_golden=total_vs_quant,
        total_vs_float_golden=total_vs_float,
        qk_metrics=qk_metrics,
        probability_metrics=prob_metrics,
        worst_stage_by_max=worst_stage_by_max,
        worst_stage_by_mean=worst_stage_by_mean,
        passes_precision=total_vs_quant.mean_abs <= mean_limit and total_vs_quant.max_abs <= max_limit,
    )


def rtl_like_output_for_case(case: ExtremeCase) -> list[list[float]]:
    q_quant = quantize_matrix(case.q_matrix)
    k_quant = quantize_matrix(case.k_matrix)
    v_quant = quantize_matrix(case.v_matrix)
    _, _, rtl_like, _, _ = rtl_like_pipeline(
        q_quant,
        k_quant,
        v_quant,
        causal=case.causal,
        q_row_start=case.q_row_start,
        scale_word=q16_16_from_float(SCALE) & 0xFFFF_FFFF,
        neg_large_word=q16_16_from_float(-64.0) & 0xFFFF_FFFF,
    )
    return rtl_like


def build_oacc_uniform_case(raw_v: int, *, name: str, causal: bool) -> ExtremeCase:
    q = raw_matrix(SEQ_LEN, HEAD_DIM, 0)
    k = raw_matrix(SEQ_LEN, HEAD_DIM, 0)
    v = raw_matrix(SEQ_LEN, HEAD_DIM, raw_v)
    return ExtremeCase(
        name=name,
        description="Uniform scores with full-range V, isolating the Q4.12 OACC range limit.",
        q_matrix=q,
        k_matrix=k,
        v_matrix=v,
        causal=causal,
        q_row_start=0,
    )


def build_qk_saturation_tie_case() -> ExtremeCase:
    q = raw_matrix(SEQ_LEN, HEAD_DIM, 0)
    k = raw_matrix(SEQ_LEN, HEAD_DIM, Q88_MIN_RAW)
    v = raw_matrix(SEQ_LEN, HEAD_DIM, 0)
    for row in range(TILE_ROWS):
        set_row_raw(q, row, Q88_MAX_RAW)
    set_row_raw(k, 0, Q88_MAX_RAW)
    set_row_raw(k, 1, Q88_MAX_RAW - 64)
    set_row_raw(v, 0, Q88_MAX_RAW)
    set_row_raw(v, 1, Q88_MIN_RAW)
    return ExtremeCase(
        name="qk_saturation_tie_flip",
        description="Two very large QK scores both saturate to int32 max, erasing the exact ordering.",
        q_matrix=q,
        k_matrix=k,
        v_matrix=v,
        causal=False,
        q_row_start=0,
    )


def build_probability_tail_case(*, many_tails: bool, raw_v: int) -> ExtremeCase:
    q = raw_matrix(SEQ_LEN, HEAD_DIM, 0)
    k = raw_matrix(SEQ_LEN, HEAD_DIM, Q88_MIN_RAW)
    v = raw_matrix(SEQ_LEN, HEAD_DIM, 0)
    for row in range(TILE_ROWS):
        set_row_raw(q, row, 256)
    set_row_raw(k, 0, 0)
    tail_rows = range(1, SEQ_LEN) if many_tails else range(1, 2)
    for row in tail_rows:
        set_row_raw(k, row, -205)
        set_row_raw(v, row, raw_v)
    return ExtremeCase(
        name="p_lsb_many_tails_vmax" if many_tails else "p_lsb_single_tail_vmax",
        description=(
            "Many probabilities sit below one half of the Q8.8 P LSB and can disappear after P quantization."
            if many_tails
            else "A single high-value V tail sits near the Q8.8 P rounding boundary."
        ),
        q_matrix=q,
        k_matrix=k,
        v_matrix=v,
        causal=False,
        q_row_start=0,
    )


def build_causal_first_token_case() -> ExtremeCase:
    q = raw_matrix(SEQ_LEN, HEAD_DIM, 0)
    k = raw_matrix(SEQ_LEN, HEAD_DIM, 0)
    v = raw_matrix(SEQ_LEN, HEAD_DIM, 0)
    set_row_raw(v, 0, Q88_MAX_RAW)
    return ExtremeCase(
        name="causal_first_token_vmax",
        description="Causal row 0 has a one-hot probability on a full-range V value, stressing final OACC range.",
        q_matrix=q,
        k_matrix=k,
        v_matrix=v,
        causal=True,
        q_row_start=0,
    )


def build_random_extreme_case(seed: int, amp_raw: int, *, causal: bool, q_row_start: int) -> ExtremeCase:
    rng = random.Random(seed)
    q = raw_matrix(SEQ_LEN, HEAD_DIM, 0)
    k = raw_matrix(SEQ_LEN, HEAD_DIM, 0)
    v = raw_matrix(SEQ_LEN, HEAD_DIM, 0)

    def rand_raw() -> int:
        return rng.randint(-amp_raw, amp_raw)

    for row in range(q_row_start, q_row_start + TILE_ROWS):
        set_row_raw(q, row, [rand_raw() for _ in range(HEAD_DIM)])
    for row in range(SEQ_LEN):
        set_row_raw(k, row, [rand_raw() for _ in range(HEAD_DIM)])
        set_row_raw(v, row, [rand_raw() for _ in range(HEAD_DIM)])
    return ExtremeCase(
        name=f"random_amp{amp_raw}_seed{seed}_{'causal' if causal else 'noncausal'}_q{q_row_start}",
        description="Random Q/K/V sweep at a selected raw Q8.8 amplitude.",
        q_matrix=q,
        k_matrix=k,
        v_matrix=v,
        causal=causal,
        q_row_start=q_row_start,
    )


def deterministic_cases() -> list[ExtremeCase]:
    return [
        build_oacc_uniform_case(Q88_MAX_RAW, name="oacc_uniform_vmax_noncausal", causal=False),
        build_oacc_uniform_case(Q88_MIN_RAW, name="oacc_uniform_vmin_noncausal", causal=False),
        build_causal_first_token_case(),
        build_qk_saturation_tie_case(),
        build_probability_tail_case(many_tails=False, raw_v=Q88_MAX_RAW),
        build_probability_tail_case(many_tails=True, raw_v=Q88_MAX_RAW),
    ]


def deterministic_case_by_name(name: str) -> ExtremeCase:
    for case in deterministic_cases():
        if case.name == name:
            return case
    raise KeyError(f"unknown deterministic extreme case: {name}")


def collect_cases(random_cases: int, seed: int) -> list[ExtremeCase]:
    cases = deterministic_cases()
    amplitudes = [256, 1024, 4096, 16384, Q88_MAX_RAW]
    for idx in range(random_cases):
        amp = amplitudes[idx % len(amplitudes)]
        causal = bool(idx & 1)
        q_row_start = [0, 112, 240][idx % 3] if causal else 0
        cases.append(build_random_extreme_case(seed + idx, amp, causal=causal, q_row_start=q_row_start))
    return cases


def fmt_metric(metric: ErrorMetrics) -> str:
    return f"mean={metric.mean_abs:.6f} max={metric.max_abs:.6f} @r{metric.worst_row}c{metric.worst_col}"


def write_markdown_report(reports: list[ExtremePrecisionReport], out_dir: Path) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"{datetime.now().strftime('%Y%m%d')}_fa_extreme_precision_report.md"
    ranked = sorted(reports, key=lambda report: report.total_vs_quantized_golden.max_abs, reverse=True)
    lines = [
        "# FA Extreme Precision Diagnostic",
        "",
        "This report uses adversarial Q8.8 inputs to decompose precision loss into QK saturation/scale, row-state probability, PV quantization, and OACC quantization.",
        "",
        "## Ranked Cases",
        "",
        "| Rank | Case | Pass | Total mean | Total max | Worst stage max | Worst stage mean | QK sat | Prob L1 max |",
        "|---:|---|---:|---:|---:|---|---|---:|---:|",
    ]
    for rank, report in enumerate(ranked, start=1):
        lines.append(
            f"| {rank} | `{report.case_name}` | {'yes' if report.passes_precision else 'no'} "
            f"| {report.total_vs_quantized_golden.mean_abs:.6f} "
            f"| {report.total_vs_quantized_golden.max_abs:.6f} "
            f"| `{report.worst_stage_by_max}` "
            f"| `{report.worst_stage_by_mean}` "
            f"| {report.qk_metrics.saturation_pct:.2f}% "
            f"| {report.probability_metrics.l1_max:.6f} |"
        )
    lines.extend(["", "## Stage Detail", ""])
    for report in ranked:
        lines.extend(
            [
                f"### {report.case_name}",
                "",
                f"- Description: {report.description}",
                f"- Mode: causal={report.causal}, q_row_start={report.q_row_start}",
                f"- QK saturation: {report.qk_metrics.saturated_scores}/{report.qk_metrics.total_scores} "
                f"({report.qk_metrics.saturation_pct:.2f}%), max_score_delta={report.qk_metrics.max_score_delta:.6f}",
                f"- Probability: sum_avg={report.probability_metrics.sum_avg:.6f}, "
                f"sum_min={report.probability_metrics.sum_min:.6f}, sum_max={report.probability_metrics.sum_max:.6f}, "
                f"l1_avg={report.probability_metrics.l1_avg:.6f}, l1_max={report.probability_metrics.l1_max:.6f}, "
                f"nonzero_avg={report.probability_metrics.nonzero_avg:.2f}",
                "",
                "| Stage | Mean abs | Max abs | Worst element | Actual | Expected |",
                "|---|---:|---:|---|---:|---:|",
            ]
        )
        for stage_name in [
            "input_quantization",
            "qk_saturation_scale",
            "row_state_probability",
            "pv_quantization",
            "oacc_quantization",
            "total_vs_quantized_golden",
            "total_vs_float_golden",
        ]:
            metric = getattr(report, stage_name)
            lines.append(
                f"| `{stage_name}` | {metric.mean_abs:.6f} | {metric.max_abs:.6f} "
                f"| r{metric.worst_row} c{metric.worst_col} | {metric.actual:.6f} | {metric.expected:.6f} |"
            )
        lines.append("")
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run aggressive FA precision-loss diagnostics")
    parser.add_argument("--random-cases", type=int, default=10, help="Number of random amplitude-sweep cases to add")
    parser.add_argument("--seed", type=int, default=20260429)
    parser.add_argument("--top", type=int, default=8, help="Number of worst cases to print")
    parser.add_argument("--mean-limit", type=float, default=0.03)
    parser.add_argument("--max-limit", type=float, default=0.10)
    parser.add_argument("--out-dir", type=Path, default=None, help="Write a markdown report under this directory")
    parser.add_argument("--json", action="store_true", help="Emit JSON instead of text")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    reports = [
        analyze_extreme_case(case, mean_limit=args.mean_limit, max_limit=args.max_limit)
        for case in collect_cases(args.random_cases, args.seed)
    ]
    ranked = sorted(reports, key=lambda report: report.total_vs_quantized_golden.max_abs, reverse=True)

    if args.json:
        print(json.dumps([asdict(report) for report in ranked], indent=2, ensure_ascii=True))
    else:
        print("FA extreme precision diagnostic")
        print(f"cases={len(reports)} mean_limit={args.mean_limit} max_limit={args.max_limit}")
        for rank, report in enumerate(ranked[: args.top], start=1):
            print(f"{rank}. {report.case_name}")
            print(f"   total_vs_quantized_golden {fmt_metric(report.total_vs_quantized_golden)}")
            print(f"   worst_stage_by_max={report.worst_stage_by_max} worst_stage_by_mean={report.worst_stage_by_mean}")
            print(
                "   stages "
                f"qk={report.qk_saturation_scale.max_abs:.6f} "
                f"row_state={report.row_state_probability.max_abs:.6f} "
                f"pv={report.pv_quantization.max_abs:.6f} "
                f"oacc={report.oacc_quantization.max_abs:.6f}"
            )
            print(
                "   diagnostics "
                f"qk_sat={report.qk_metrics.saturation_pct:.2f}% "
                f"prob_l1_max={report.probability_metrics.l1_max:.6f} "
                f"prob_nz_avg={report.probability_metrics.nonzero_avg:.2f}"
            )
        failing = [report for report in reports if not report.passes_precision]
        print(f"precision_failures={len(failing)}/{len(reports)}")

    if args.out_dir is not None:
        path = write_markdown_report(reports, args.out_dir)
        if not args.json:
            print(f"report={path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
