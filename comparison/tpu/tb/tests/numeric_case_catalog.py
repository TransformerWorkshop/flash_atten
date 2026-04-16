from __future__ import annotations

from dataclasses import dataclass
from random import Random


PM_INT8_ALL = 1
PM_INT8_INT32 = 3

INT32_MIN = -(1 << 31)
INT32_MAX = (1 << 31) - 1


@dataclass(frozen=True)
class NumericCase:
    name: str
    category: str
    precision_mode: int
    a_matrix: list[list[int]]
    b_matrix: list[list[int]]
    c_matrix: list[list[int]]
    expected_matrix: list[list[int]]
    tags: tuple[str, ...] = ()


def sat_int32(value: int) -> int:
    return max(INT32_MIN, min(INT32_MAX, value))


def zero_matrix(rows: int, cols: int) -> list[list[int]]:
    return [[0 for _ in range(cols)] for _ in range(rows)]


def constant_matrix(rows: int, cols: int, value: int) -> list[list[int]]:
    return [[value for _ in range(cols)] for _ in range(rows)]


def identity_matrix(dim: int, value: int = 1) -> list[list[int]]:
    return [[value if row == col else 0 for col in range(dim)] for row in range(dim)]


def permutation_matrix(dim: int, shift: int = 1) -> list[list[int]]:
    return [[1 if col == ((row + shift) % dim) else 0 for col in range(dim)] for row in range(dim)]


def single_hot_matrix(rows: int, cols: int, hot_row: int, hot_col: int, hot_value: int = 1) -> list[list[int]]:
    matrix = zero_matrix(rows, cols)
    matrix[hot_row][hot_col] = hot_value
    return matrix


def checker_matrix(rows: int, cols: int, first: int, second: int) -> list[list[int]]:
    return [[first if (row + col) % 2 == 0 else second for col in range(cols)] for row in range(rows)]


def triangular_matrix(dim: int, lower_value: int, upper_value: int = 0, diag_value: int | None = None) -> list[list[int]]:
    if diag_value is None:
        diag_value = lower_value
    matrix = zero_matrix(dim, dim)
    for row in range(dim):
        for col in range(dim):
            if row > col:
                matrix[row][col] = lower_value
            elif row < col:
                matrix[row][col] = upper_value
            else:
                matrix[row][col] = diag_value
    return matrix


def band_matrix(dim: int, diag_value: int, offdiag_value: int, bandwidth: int = 1) -> list[list[int]]:
    matrix = zero_matrix(dim, dim)
    for row in range(dim):
        for col in range(dim):
            if row == col:
                matrix[row][col] = diag_value
            elif abs(row - col) <= bandwidth:
                matrix[row][col] = offdiag_value
    return matrix


def sequential_positive_matrix(rows: int, cols: int, start: int = 1, stride: int = 1) -> list[list[int]]:
    value = start
    matrix: list[list[int]] = []
    for _ in range(rows):
        row_vals: list[int] = []
        for _ in range(cols):
            row_vals.append(value & 0x7F)
            value += stride
        matrix.append(row_vals)
    return matrix


def signed_ramp_matrix(rows: int, cols: int, start: int, step: int, low: int = -128, high: int = 127) -> list[list[int]]:
    value = start
    matrix: list[list[int]] = []
    span = high - low + 1
    for _ in range(rows):
        row_vals: list[int] = []
        for _ in range(cols):
            wrapped = low + ((value - low) % span)
            row_vals.append(wrapped)
            value += step
        matrix.append(row_vals)
    return matrix


def random_int8_matrix(rows: int, cols: int, seed: int, low: int = -8, high: int = 8) -> list[list[int]]:
    rng = Random(seed)
    return [[rng.randint(low, high) for _ in range(cols)] for _ in range(rows)]


def random_int32_matrix(rows: int, cols: int, seed: int, low: int = -5000, high: int = 5000) -> list[list[int]]:
    rng = Random(seed)
    return [[rng.randint(low, high) for _ in range(cols)] for _ in range(rows)]


def add_matrices(lhs: list[list[int]], rhs: list[list[int]], saturating: bool) -> list[list[int]]:
    rows = len(lhs)
    cols = len(lhs[0])
    out = zero_matrix(rows, cols)
    for row in range(rows):
        for col in range(cols):
            value = lhs[row][col] + rhs[row][col]
            out[row][col] = sat_int32(value) if saturating else value
    return out


def matmul(lhs: list[list[int]], rhs: list[list[int]]) -> list[list[int]]:
    rows = len(lhs)
    inner = len(lhs[0])
    cols = len(rhs[0])
    out = zero_matrix(rows, cols)
    for row in range(rows):
        for col in range(cols):
            acc = 0
            for k in range(inner):
                acc += lhs[row][k] * rhs[k][col]
            out[row][col] = acc
    return out


def build_case(
    name: str,
    category: str,
    precision_mode: int,
    a_matrix: list[list[int]],
    b_matrix: list[list[int]],
    c_matrix: list[list[int]],
    tags: tuple[str, ...] = (),
) -> NumericCase:
    product = matmul(a_matrix, b_matrix)
    expected = add_matrices(product, c_matrix, saturating=(precision_mode == PM_INT8_INT32))
    return NumericCase(
        name=name,
        category=category,
        precision_mode=precision_mode,
        a_matrix=a_matrix,
        b_matrix=b_matrix,
        c_matrix=c_matrix,
        expected_matrix=expected,
        tags=tags,
    )


def _edge_cases() -> list[NumericCase]:
    return [
        build_case("test_numeric_01_edge_identity_8_int8", "edge", PM_INT8_ALL, sequential_positive_matrix(8, 8, 1, 1), identity_matrix(8), zero_matrix(8, 8), tags=("pm_int8", "zero_c_case")),
        build_case("test_numeric_02_edge_identity_16_int8", "edge", PM_INT8_ALL, sequential_positive_matrix(16, 16, 1, 1), identity_matrix(16), zero_matrix(16, 16), tags=("pm_int8", "zero_c_case")),
        build_case("test_numeric_03_edge_zero_a_8_int8", "edge", PM_INT8_ALL, zero_matrix(8, 8), checker_matrix(8, 8, 3, -2), zero_matrix(8, 8), tags=("pm_int8", "zero_a_case", "zero_c_case")),
        build_case("test_numeric_04_edge_zero_b_8_int8", "edge", PM_INT8_ALL, signed_ramp_matrix(8, 8, -11, 3, -24, 24), zero_matrix(8, 8), zero_matrix(8, 8), tags=("pm_int8", "zero_b_case", "zero_c_case")),
        build_case("test_numeric_05_edge_zero_all_16_int8", "edge", PM_INT8_ALL, zero_matrix(16, 16), zero_matrix(16, 16), zero_matrix(16, 16), tags=("pm_int8", "zero_a_case", "zero_b_case", "zero_c_case")),
        build_case("test_numeric_06_edge_single_hot_a_8_int8", "edge", PM_INT8_ALL, single_hot_matrix(8, 8, 5, 3, 17), identity_matrix(8), zero_matrix(8, 8), tags=("pm_int8", "single_hot_case", "zero_c_case")),
        build_case("test_numeric_07_edge_single_hot_b_8_int8", "edge", PM_INT8_ALL, sequential_positive_matrix(8, 8, 1, 1), single_hot_matrix(8, 8, 2, 4, 1), zero_matrix(8, 8), tags=("pm_int8", "single_hot_case", "zero_c_case")),
        build_case("test_numeric_08_edge_zero_ab_plus_c_8_int8_int32", "edge", PM_INT8_INT32, zero_matrix(8, 8), zero_matrix(8, 8), checker_matrix(8, 8, 17, -23), tags=("pm_int8_int32", "zero_a_case", "zero_b_case")),
        build_case("test_numeric_09_edge_zero_ab_plus_c_16_int8_int32", "edge", PM_INT8_INT32, zero_matrix(16, 16), zero_matrix(16, 16), signed_ramp_matrix(16, 16, -97, 5, -512, 512), tags=("pm_int8_int32", "zero_a_case", "zero_b_case")),
        build_case("test_numeric_10_edge_signed_identity_8_int8", "edge", PM_INT8_ALL, checker_matrix(8, 8, -1, 1), identity_matrix(8), zero_matrix(8, 8), tags=("pm_int8", "signed_inputs_case", "zero_c_case")),
    ]


def _boundary_cases() -> list[NumericCase]:
    return [
        build_case("test_numeric_11_boundary_max_identity_8_int8", "boundary", PM_INT8_ALL, constant_matrix(8, 8, 127), identity_matrix(8), zero_matrix(8, 8), tags=("pm_int8", "boundary_value_case", "zero_c_case")),
        build_case("test_numeric_12_boundary_min_identity_8_int8", "boundary", PM_INT8_ALL, constant_matrix(8, 8, -128), identity_matrix(8), zero_matrix(8, 8), tags=("pm_int8", "boundary_value_case", "zero_c_case")),
        build_case("test_numeric_13_boundary_alt_extremes_8_int8", "boundary", PM_INT8_ALL, checker_matrix(8, 8, 127, -128), identity_matrix(8), zero_matrix(8, 8), tags=("pm_int8", "boundary_value_case", "signed_inputs_case", "zero_c_case")),
        build_case("test_numeric_14_boundary_sat_pos_8_int8_int32", "boundary", PM_INT8_INT32, constant_matrix(8, 8, 1), identity_matrix(8), constant_matrix(8, 8, INT32_MAX - 1), tags=("pm_int8_int32", "boundary_value_case", "saturation_pos_case")),
        build_case("test_numeric_15_boundary_sat_neg_8_int8_int32", "boundary", PM_INT8_INT32, constant_matrix(8, 8, -1), identity_matrix(8), constant_matrix(8, 8, INT32_MIN + 1), tags=("pm_int8_int32", "boundary_value_case", "saturation_neg_case")),
        build_case("test_numeric_16_boundary_large_bias_mix_8_int8_int32", "boundary", PM_INT8_INT32, constant_matrix(8, 8, 2), identity_matrix(8), checker_matrix(8, 8, INT32_MAX - 5, INT32_MIN + 5), tags=("pm_int8_int32", "boundary_value_case", "saturation_pos_case", "saturation_neg_case")),
        build_case("test_numeric_17_boundary_small_negative_16_int8", "boundary", PM_INT8_ALL, checker_matrix(16, 16, -128, -127), identity_matrix(16), zero_matrix(16, 16), tags=("pm_int8", "boundary_value_case", "signed_inputs_case", "zero_c_case")),
        build_case("test_numeric_18_boundary_small_positive_16_int8", "boundary", PM_INT8_ALL, checker_matrix(16, 16, 126, 127), identity_matrix(16), zero_matrix(16, 16), tags=("pm_int8", "boundary_value_case", "zero_c_case")),
        build_case("test_numeric_19_boundary_pos_margin_16_int8_int32", "boundary", PM_INT8_INT32, constant_matrix(16, 16, 3), identity_matrix(16), constant_matrix(16, 16, INT32_MAX - 3), tags=("pm_int8_int32", "boundary_value_case", "saturation_pos_case")),
        build_case("test_numeric_20_boundary_neg_margin_16_int8_int32", "boundary", PM_INT8_INT32, constant_matrix(16, 16, -3), identity_matrix(16), constant_matrix(16, 16, INT32_MIN + 3), tags=("pm_int8_int32", "boundary_value_case", "saturation_neg_case")),
    ]


def _typical_cases() -> list[NumericCase]:
    return [
        build_case("test_numeric_21_typical_bias_8_int8", "typical", PM_INT8_ALL, identity_matrix(8), sequential_positive_matrix(8, 8, 3, 2), sequential_positive_matrix(8, 8, 1, 1), tags=("pm_int8",)),
        build_case("test_numeric_22_typical_identity_16_int8", "typical", PM_INT8_ALL, sequential_positive_matrix(16, 16, 1, 1), identity_matrix(16), zero_matrix(16, 16), tags=("pm_int8", "zero_c_case")),
        build_case("test_numeric_23_typical_seq_perm_8_int8", "typical", PM_INT8_ALL, sequential_positive_matrix(8, 8, 2, 3), permutation_matrix(8, 3), zero_matrix(8, 8), tags=("pm_int8", "zero_c_case")),
        build_case("test_numeric_24_typical_checker_dense_8_int8", "typical", PM_INT8_ALL, checker_matrix(8, 8, 2, -3), band_matrix(8, 1, 1, 1), checker_matrix(8, 8, 1, -1), tags=("pm_int8", "signed_inputs_case")),
        build_case("test_numeric_25_typical_triangular_8_int8", "typical", PM_INT8_ALL, triangular_matrix(8, 1, 0, 2), triangular_matrix(8, 0, 2, 1), zero_matrix(8, 8), tags=("pm_int8", "zero_c_case")),
        build_case("test_numeric_26_typical_band_16_int8", "typical", PM_INT8_ALL, band_matrix(16, 3, 1, 2), permutation_matrix(16, 1), checker_matrix(16, 16, 2, 0), tags=("pm_int8",)),
        build_case("test_numeric_27_typical_dense_bias_8_int8_int32", "typical", PM_INT8_INT32, identity_matrix(8), sequential_positive_matrix(8, 8, 5, 1), signed_ramp_matrix(8, 8, -19, 2, -200, 200), tags=("pm_int8_int32",)),
        build_case("test_numeric_28_typical_checker_bias_8_int8_int32", "typical", PM_INT8_INT32, checker_matrix(8, 8, 1, -1), identity_matrix(8), checker_matrix(8, 8, 64, -64), tags=("pm_int8_int32", "signed_inputs_case")),
        build_case("test_numeric_29_typical_dense_bias_16_int8_int32", "typical", PM_INT8_INT32, sequential_positive_matrix(16, 16, 1, 1), identity_matrix(16), signed_ramp_matrix(16, 16, -33, 3, -500, 500), tags=("pm_int8_int32",)),
        build_case("test_numeric_30_typical_perm_bias_8_int8_int32", "typical", PM_INT8_INT32, sequential_positive_matrix(8, 8, 4, 1), permutation_matrix(8, 2), constant_matrix(8, 8, -7), tags=("pm_int8_int32",)),
    ]


def _random_cases() -> list[NumericCase]:
    specs = [
        ("test_numeric_31_random_seed101_8_int8", PM_INT8_ALL, 8, 101),
        ("test_numeric_32_random_seed102_8_int8", PM_INT8_ALL, 8, 102),
        ("test_numeric_33_random_seed103_16_int8", PM_INT8_ALL, 16, 103),
        ("test_numeric_34_random_seed104_8_int8", PM_INT8_ALL, 8, 104),
        ("test_numeric_35_random_seed105_16_int8", PM_INT8_ALL, 16, 105),
        ("test_numeric_36_random_seed201_8_int8_int32", PM_INT8_INT32, 8, 201),
        ("test_numeric_37_random_seed202_8_int8_int32", PM_INT8_INT32, 8, 202),
        ("test_numeric_38_random_seed203_16_int8_int32", PM_INT8_INT32, 16, 203),
        ("test_numeric_39_random_seed204_8_int8_int32", PM_INT8_INT32, 8, 204),
        ("test_numeric_40_random_seed205_16_int8_int32", PM_INT8_INT32, 16, 205),
    ]
    cases: list[NumericCase] = []
    for name, precision_mode, dim, seed in specs:
        a_matrix = random_int8_matrix(dim, dim, seed, low=-12, high=12)
        b_matrix = random_int8_matrix(dim, dim, seed + 1000, low=-12, high=12)
        if precision_mode == PM_INT8_ALL:
            c_matrix = random_int8_matrix(dim, dim, seed + 2000, low=-16, high=16)
            tags = ("pm_int8", "random_case", "signed_inputs_case")
        else:
            c_matrix = random_int32_matrix(dim, dim, seed + 3000, low=-40000, high=40000)
            tags = ("pm_int8_int32", "random_case", "signed_inputs_case")
        cases.append(build_case(name, "random", precision_mode, a_matrix, b_matrix, c_matrix, tags=tags))
    return cases


NUMERIC_CASES = [
    *_edge_cases(),
    *_boundary_cases(),
    *_typical_cases(),
    *_random_cases(),
]

assert len(NUMERIC_CASES) == 40, f"expected 40 numeric cases, got {len(NUMERIC_CASES)}"
