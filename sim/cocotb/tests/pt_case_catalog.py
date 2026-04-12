from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, Tuple

from tests.pt_model import (
	PT_QGRAN_PER_TENSOR,
	PT_QGRAN_X_WISE,
	PT_QGRAN_X_WISE_DIV2,
	PT_QGRAN_Y_WISE,
	PT_QGRAN_Y_WISE_DIV2,
)


@dataclass(frozen=True)
class ScenarioCase:
	case_name: str
	bb_id: str
	primary_group: str
	subgroup: str
	description: str
	dims: Tuple[int, ...]
	suite_tags: Tuple[str, ...]
	profile: str
	data: Dict[str, Any] = field(default_factory=dict)


def _case(
	case_name: str,
	bb_id: str,
	primary_group: str,
	subgroup: str,
	description: str,
	dims: Tuple[int, ...],
	suite_tags: Tuple[str, ...],
	profile: str,
	**data: Any,
) -> ScenarioCase:
	return ScenarioCase(
		case_name=case_name,
		bb_id=bb_id,
		primary_group=primary_group,
		subgroup=subgroup,
		description=description,
		dims=dims,
		suite_tags=suite_tags,
		profile=profile,
		data=data,
	)


SMOKE_CASES = [
	_case("test_pt_smoke_typical_dense_pos_balanced_01", "PT-BB-001", "典型值测试", "dense_pos", "标准正数稠密矩阵", (4, 8), ("smoke", "full"), "dense_pos_balanced", a_mode="pattern", a_args=(3, 1, 0), b_mode="pattern", b_args=(2, 4, 1)),
	_case("test_pt_smoke_typical_dense_pos_row_dominant_02", "PT-BB-001", "典型值测试", "dense_pos", "A 行增益更高的正数矩阵", (4, 8), ("smoke", "full"), "dense_pos_row_dominant", a_mode="pattern", a_args=(5, 1, 1), b_mode="pattern", b_args=(2, 3, 0)),
	_case("test_pt_smoke_typical_dense_pos_col_dominant_03", "PT-BB-001", "典型值测试", "dense_pos", "B 列增益更高的正数矩阵", (4, 8), ("smoke", "full"), "dense_pos_col_dominant", a_mode="pattern", a_args=(1, 4, 2), b_mode="pattern", b_args=(3, 1, 1)),
	_case("test_pt_smoke_typical_sparse_a_dense_b_04", "PT-BB-001", "典型值测试", "sparse_mix", "稀疏 A 与稠密 B 的主流程", (4, 8), ("smoke", "full"), "sparse_a_dense_b", a_mode="repeat", a_args=[1, 0, 0, 2, 0, 3, 0, 4], b_mode="pattern", b_args=(2, 2, 1)),
	_case("test_pt_smoke_typical_dense_a_sparse_b_05", "PT-BB-001", "典型值测试", "sparse_mix", "稠密 A 与稀疏 B 的主流程", (4, 8), ("smoke", "full"), "dense_a_sparse_b", a_mode="pattern", a_args=(4, 2, 0), b_mode="repeat", b_args=[1, 0, 2, 0, 3, 0, 4, 0]),
	_case("test_pt_smoke_typical_monotonic_small_range_06", "PT-BB-001", "典型值测试", "monotonic", "小动态范围单调递增矩阵", (4, 8), ("smoke", "full"), "monotonic_small_range", a_mode="pattern", a_args=(2, 1, 1), b_mode="repeat", b_args=[1, 2, 3, 4, 5, 6, 7, 8]),
	_case("test_pt_smoke_typical_monotonic_wide_range_07", "PT-BB-001", "典型值测试", "monotonic", "较宽动态范围单调递增矩阵", (4, 8), ("smoke", "full"), "monotonic_wide_range", a_mode="pattern", a_args=(6, 3, 0), b_mode="pattern", b_args=(5, 2, 1)),
	_case("test_pt_smoke_typical_checkerboard_low_range_08", "PT-BB-001", "典型值测试", "checkerboard", "低动态范围棋盘型合法矩阵", (4, 8), ("smoke", "full"), "checkerboard_low_range", a_mode="checker", a_args=(1, 4), b_mode="checker", b_args=(2, 5)),
	_case("test_pt_smoke_typical_cache_reuse_dense_09", "PT-BB-001", "典型值测试", "cache_reuse", "缓存命中友好的稠密矩阵", (4, 8), ("smoke", "full"), "cache_reuse_dense", a_mode="pattern", a_args=(3, 3, 1), b_mode="pattern", b_args=(4, 2, 0)),
	_case("test_pt_smoke_typical_single_hot_mix_10", "PT-BB-001", "典型值测试", "single_hot", "单热点与稠密矩阵组合", (4, 8), ("smoke", "full"), "single_hot_mix", a_mode="single_hot", a_args=(0, 1), b_mode="pattern", b_args=(2, 1, 3)),
	_case("test_pt_smoke_boundary_zero_row_a_11", "PT-BB-001", "边界值测试", "zero_stripe", "A 中包含一整行零值", (4, 8), ("smoke", "full"), "zero_row_a", a_mode="zero_row_pattern", a_args=((3, 1, 0), 0), b_mode="pattern", b_args=(2, 4, 1)),
	_case("test_pt_smoke_boundary_zero_row_b_12", "PT-BB-001", "边界值测试", "zero_stripe", "B 中包含一整行零值", (4, 8), ("smoke", "full"), "zero_row_b", a_mode="pattern", a_args=(3, 1, 0), b_mode="zero_row_pattern", b_args=((2, 4, 1), 1)),
	_case("test_pt_smoke_boundary_zero_col_a_13", "PT-BB-001", "边界值测试", "zero_stripe", "A 中包含一整列零值", (4, 8), ("smoke", "full"), "zero_col_a", a_mode="zero_col_pattern", a_args=((4, 1, 1), 1), b_mode="pattern", b_args=(2, 2, 2)),
	_case("test_pt_smoke_boundary_zero_col_b_14", "PT-BB-001", "边界值测试", "zero_stripe", "B 中包含一整列零值", (4, 8), ("smoke", "full"), "zero_col_b", a_mode="pattern", a_args=(4, 1, 1), b_mode="zero_col_pattern", b_args=((2, 2, 2), 0)),
	_case("test_pt_smoke_boundary_identity_a_passthrough_15", "PT-BB-001", "边界值测试", "identity_drive", "单位 A 驱动 B 直通", (4, 8), ("smoke", "full"), "identity_a_passthrough", a_mode="identity", a_args=(), b_mode="pattern", b_args=(2, 5, 1)),
	_case("test_pt_smoke_boundary_identity_b_passthrough_16", "PT-BB-001", "边界值测试", "identity_drive", "单位 B 驱动 A 直通", (4, 8), ("smoke", "full"), "identity_b_passthrough", a_mode="pattern", a_args=(5, 1, 2), b_mode="identity", b_args=()),
	_case("test_pt_smoke_boundary_low_dynamic_range_17", "PT-BB-001", "边界值测试", "dynamic_range", "极低动态范围合法矩阵", (4, 8), ("smoke", "full"), "low_dynamic_range", a_mode="repeat", a_args=[0, 1, 0, 1], b_mode="repeat", b_args=[1, 1, 0, 0]),
	_case("test_pt_smoke_boundary_high_dynamic_range_18", "PT-BB-001", "边界值测试", "dynamic_range", "较高动态范围但不越界的矩阵", (4, 8), ("smoke", "full"), "high_dynamic_range", a_mode="repeat", a_args=[1, 8, 16, 32, 2, 4, 12, 24], b_mode="repeat", b_args=[3, 9, 27, 18, 6, 12, 24, 30]),
	_case("test_pt_smoke_boundary_single_hot_a_19", "PT-BB-001", "边界值测试", "single_hot", "单热点 A 的最小激活路径", (4, 8), ("smoke", "full"), "single_hot_a", a_mode="single_hot", a_args=(3, 2), b_mode="repeat", b_args=[1, 2, 3, 4]),
	_case("test_pt_smoke_boundary_single_hot_b_20", "PT-BB-001", "边界值测试", "single_hot", "单热点 B 的最小激活路径", (4, 8), ("smoke", "full"), "single_hot_b", a_mode="repeat", a_args=[1, 2, 3, 4], b_mode="single_hot", b_args=(2, 3)),
]


NUMERIC_CASES = [
	_case("test_pt_numeric_typical_zero_01", "PT-BB-002", "典型值测试", "zero", "零值矩阵", (2, 4, 8), ("full",), "zero", granularity=PT_QGRAN_PER_TENSOR, scales=[0x0001_0000], b_mode="zero"),
	_case("test_pt_numeric_typical_ones_02", "PT-BB-002", "典型值测试", "const", "常数 1 矩阵", (2, 4, 8), ("full",), "ones", granularity=PT_QGRAN_PER_TENSOR, scales=[0x0001_0000], b_mode="constant", b_args=(1,)),
	_case("test_pt_numeric_typical_neg_ones_03", "PT-BB-002", "典型值测试", "const", "通过负 scale 产生 -1 输出", (2, 4, 8), ("full",), "neg_ones", granularity=PT_QGRAN_PER_TENSOR, scales=[0xFFFF_0000], b_mode="constant", b_args=(1,)),
	_case("test_pt_numeric_typical_alternating_sign_04", "PT-BB-002", "典型值测试", "sign_mix", "按列交替正负输出", (2, 4, 8), ("full",), "alternating_sign", granularity=PT_QGRAN_Y_WISE, scales=[0x0001_0000, 0xFFFF_0000], b_mode="constant", b_args=(1,)),
	_case("test_pt_numeric_typical_sparse_low_range_05", "PT-BB-002", "典型值测试", "sparse", "稀疏低动态范围矩阵", (2, 4, 8), ("full",), "sparse_low_range", granularity=PT_QGRAN_PER_TENSOR, scales=[0x0001_0000], b_mode="repeat", b_args=([0, 1, 0, 2, 0, 3, 0, 4],)),
	_case("test_pt_numeric_typical_identity_like_06", "PT-BB-002", "典型值测试", "shape", "identity-like 输出", (2, 4, 8), ("full",), "identity_like", granularity=PT_QGRAN_PER_TENSOR, scales=[0x0001_0000], b_mode="identity"),
	_case("test_pt_numeric_typical_monotonic_small_range_07", "PT-BB-002", "典型值测试", "monotonic", "单调小范围输出", (2, 4, 8), ("full",), "monotonic_small_range", granularity=PT_QGRAN_PER_TENSOR, scales=[0x0001_0000], b_mode="repeat", b_args=([1, 2, 3, 4, 5, 6, 7, 8],)),
	_case("test_pt_numeric_typical_mixed_sign_low_range_08", "PT-BB-002", "典型值测试", "sign_mix", "按行混合正负低范围输出", (2, 4, 8), ("full",), "mixed_sign_low_range", granularity=PT_QGRAN_X_WISE, scales=[0x0001_0000, 0xFFFF_0000, 0x0002_0000, 0xFFFF_8000], b_mode="repeat", b_args=([1, 2, 1, 2, 3, 4, 3, 4],)),
	_case("test_pt_numeric_boundary_upper_sat_pos_09", "PT-BB-002", "边界值测试", "saturation", "正向饱和边界", (2, 4, 8), ("full",), "upper_sat_pos", granularity=PT_QGRAN_PER_TENSOR, scales=[0x0001_0000], b_mode="repeat", b_args=([0x7FFF_FFFE, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF],)),
	_case("test_pt_numeric_boundary_upper_sat_neg_10", "PT-BB-002", "边界值测试", "saturation", "负向饱和边界", (2, 4, 8), ("full",), "upper_sat_neg", granularity=PT_QGRAN_PER_TENSOR, scales=[0xFFFF_0000], b_mode="repeat", b_args=([0x7FFF_FFFE, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF],)),
	_case("test_pt_numeric_boundary_threshold_before_sat_11", "PT-BB-002", "边界值测试", "saturation_threshold", "饱和前阈值", (2, 4, 8), ("full",), "threshold_before_sat", granularity=PT_QGRAN_PER_TENSOR, scales=[0x0001_0000], b_mode="repeat", b_args=([0x7FFF_FFFE, 0x7FFF_0000, 0x7FFE_FFFF, 0x7FFD_FFFF],)),
	_case("test_pt_numeric_boundary_threshold_after_sat_12", "PT-BB-002", "边界值测试", "saturation_threshold", "饱和后阈值", (2, 4, 8), ("full",), "threshold_after_sat", granularity=PT_QGRAN_PER_TENSOR, scales=[0x0001_0000], b_mode="repeat", b_args=([0x8000_0000, 0x8000_0001, 0x9000_0000, 0xFFFF_FFFF],)),
	_case("test_pt_numeric_boundary_round_tie_pos_13", "PT-BB-002", "边界值测试", "rounding", "正向 tie rounding", (2, 4, 8), ("full",), "round_tie_pos", granularity=PT_QGRAN_PER_TENSOR, scales=[0x0000_8000], b_mode="repeat", b_args=([1, 3, 5, 7, 9, 11, 13, 15],)),
	_case("test_pt_numeric_boundary_round_tie_neg_14", "PT-BB-002", "边界值测试", "rounding", "负向 tie rounding", (2, 4, 8), ("full",), "round_tie_neg", granularity=PT_QGRAN_PER_TENSOR, scales=[0xFFFF_8000], b_mode="repeat", b_args=([1, 3, 5, 7, 9, 11, 13, 15],)),
	_case("test_pt_numeric_boundary_near_zero_quantize_15", "PT-BB-002", "边界值测试", "near_zero", "极小 scale 下量化到 0", (2, 4, 8), ("full",), "near_zero_quantize", granularity=PT_QGRAN_PER_TENSOR, scales=[0x0000_0001], b_mode="repeat", b_args=([0x0000_FFFF, 0x0001_0000, 0x0001_FFFF, 0x0000_0010],)),
	_case("test_pt_numeric_boundary_near_zero_sign_flip_16", "PT-BB-002", "边界值测试", "near_zero", "极小负 scale 下量化到 0 或 -1", (2, 4, 8), ("full",), "near_zero_sign_flip", granularity=PT_QGRAN_PER_TENSOR, scales=[0xFFFF_FFFF], b_mode="repeat", b_args=([0x0000_FFFF, 0x0001_0000, 0x0001_FFFF, 0x0000_0010],)),
	_case("test_pt_numeric_boundary_min_nonzero_scale_17", "PT-BB-002", "边界值测试", "small_scale", "最小非零有效输出", (2, 4, 8), ("full",), "min_nonzero_scale", granularity=PT_QGRAN_PER_TENSOR, scales=[0x0000_4000], b_mode="repeat", b_args=([4, 8, 12, 16, 20, 24, 28, 32],)),
	_case("test_pt_numeric_boundary_scale_sign_flip_18", "PT-BB-002", "边界值测试", "sign_flip", "按列 scale 正负翻转", (2, 4, 8), ("full",), "scale_sign_flip", granularity=PT_QGRAN_Y_WISE, scales=[0x0001_0000, 0xFFFF_0000, 0x0000_8000, 0xFFFF_8000], b_mode="repeat", b_args=([3, 3, 5, 5, 7, 7, 9, 9],)),
	_case("test_pt_numeric_boundary_max_payload_magnitude_19", "PT-BB-002", "边界值测试", "large_payload", "最大有效 payload 量级", (2, 4, 8), ("full",), "max_payload_magnitude", granularity=PT_QGRAN_X_WISE, scales=[0x0002_0000, 0x0001_0000, 0xFFFF_0000, 0x0000_8000], b_mode="repeat", b_args=([0x7FFF_FFFF, 0x4000_0000, 0x3FFF_FFFF, 0x2000_0000],)),
	_case("test_pt_numeric_boundary_div2_sign_mix_20", "PT-BB-002", "边界值测试", "sign_mix", "半粒度下的符号混合边界", (2, 4, 8), ("full",), "div2_sign_mix", granularity=PT_QGRAN_X_WISE_DIV2, scales=[0x0001_0000, 0xFFFF_0000, 0x0000_8000, 0xFFFF_8000], b_mode="repeat", b_args=([1, 2, 3, 4, 5, 6, 7, 8],)),
]


QCFG_CASES = [
	_case("test_pt_qcfg_typical_per_tensor_unity_01", "PT-BB-003", "典型值测试", "per_tensor", "PER_TENSOR 标准 unity scale", (4, 8), ("full",), "per_tensor_unity", granularity=PT_QGRAN_PER_TENSOR, scales=[0x0001_0000], b_values=[2, 5, 8, 11, 14, 17, 20, 23]),
	_case("test_pt_qcfg_typical_per_tensor_half_02", "PT-BB-003", "典型值测试", "per_tensor", "PER_TENSOR 半缩放", (4, 8), ("full",), "per_tensor_half", granularity=PT_QGRAN_PER_TENSOR, scales=[0x0000_8000], b_values=[3, 6, 9, 12, 15, 18, 21, 24]),
	_case("test_pt_qcfg_typical_x_wise_gradient_pos_03", "PT-BB-003", "典型值测试", "x_wise", "X_WISE 行渐变正 scale", (4, 8), ("full",), "x_wise_gradient_pos", granularity=PT_QGRAN_X_WISE, scales=[0x0001_0000, 0x0001_8000, 0x0002_0000, 0x0002_8000], b_values=[4, 7, 10, 13, 16, 19, 22, 25]),
	_case("test_pt_qcfg_typical_x_wise_gradient_signflip_04", "PT-BB-003", "典型值测试", "x_wise", "X_WISE 行渐变正负交错 scale", (4, 8), ("full",), "x_wise_gradient_signflip", granularity=PT_QGRAN_X_WISE, scales=[0x0001_0000, 0xFFFF_0000, 0x0002_0000, 0xFFFF_8000], b_values=[5, 9, 13, 17, 21, 25, 29, 33]),
	_case("test_pt_qcfg_typical_y_wise_gradient_pos_05", "PT-BB-003", "典型值测试", "y_wise", "Y_WISE 列渐变正 scale", (4, 8), ("full",), "y_wise_gradient_pos", granularity=PT_QGRAN_Y_WISE, scales=[0x0001_0000, 0x0001_8000, 0x0002_0000, 0x0002_8000], b_values=[6, 8, 10, 12, 14, 16, 18, 20]),
	_case("test_pt_qcfg_typical_y_wise_gradient_signflip_06", "PT-BB-003", "典型值测试", "y_wise", "Y_WISE 列渐变正负交错 scale", (4, 8), ("full",), "y_wise_gradient_signflip", granularity=PT_QGRAN_Y_WISE, scales=[0xFFFF_0000, 0x0001_0000, 0x0002_0000, 0x0000_8000], b_values=[7, 11, 15, 19, 23, 27, 31, 35]),
	_case("test_pt_qcfg_typical_x_div2_balanced_07", "PT-BB-003", "典型值测试", "x_div2", "X_WISE_DIV2 平衡 scale", (4, 8), ("full",), "x_div2_balanced", granularity=PT_QGRAN_X_WISE_DIV2, scales=[0x0001_0000, 0x0000_8000, 0x0002_0000, 0x0001_8000], b_values=[8, 13, 18, 23, 28, 33, 38, 43]),
	_case("test_pt_qcfg_typical_y_div2_balanced_08", "PT-BB-003", "典型值测试", "y_div2", "Y_WISE_DIV2 平衡 scale", (4, 8), ("full",), "y_div2_balanced", granularity=PT_QGRAN_Y_WISE_DIV2, scales=[0x0001_0000, 0x0000_8000, 0x0002_0000, 0x0001_8000], b_values=[9, 15, 21, 27, 33, 39, 45, 51]),
	_case("test_pt_qcfg_boundary_per_tensor_neg_unit_09", "PT-BB-003", "边界值测试", "per_tensor", "PER_TENSOR 负 unity scale", (4, 8), ("full",), "per_tensor_neg_unit", granularity=PT_QGRAN_PER_TENSOR, scales=[0xFFFF_0000], b_values=[2, 5, 8, 11, 14, 17, 20, 23]),
	_case("test_pt_qcfg_boundary_per_tensor_small_scale_10", "PT-BB-003", "边界值测试", "per_tensor", "PER_TENSOR 极小合法 scale", (4, 8), ("full",), "per_tensor_small_scale", granularity=PT_QGRAN_PER_TENSOR, scales=[0x0000_0001], b_values=[2, 5, 8, 11, 14, 17, 20, 23]),
	_case("test_pt_qcfg_boundary_x_wise_small_scale_mix_11", "PT-BB-003", "边界值测试", "x_wise", "X_WISE 极小/极大混合 scale", (4, 8), ("full",), "x_wise_small_scale_mix", granularity=PT_QGRAN_X_WISE, scales=[0x0000_0001, 0x0001_0000, 0x0002_0000, 0xFFFF_0000], b_values=[3, 6, 9, 12, 15, 18, 21, 24]),
	_case("test_pt_qcfg_boundary_x_wise_large_scale_mix_12", "PT-BB-003", "边界值测试", "x_wise", "X_WISE 大动态 scale 混合", (4, 8), ("full",), "x_wise_large_scale_mix", granularity=PT_QGRAN_X_WISE, scales=[0x0002_8000, 0x0002_0000, 0x0001_8000, 0x0001_0000], b_values=[4, 8, 12, 16, 20, 24, 28, 32]),
	_case("test_pt_qcfg_boundary_y_wise_small_scale_mix_13", "PT-BB-003", "边界值测试", "y_wise", "Y_WISE 极小/极大混合 scale", (4, 8), ("full",), "y_wise_small_scale_mix", granularity=PT_QGRAN_Y_WISE, scales=[0x0000_0001, 0x0001_0000, 0x0002_0000, 0xFFFF_0000], b_values=[5, 10, 15, 20, 25, 30, 35, 40]),
	_case("test_pt_qcfg_boundary_y_wise_large_scale_mix_14", "PT-BB-003", "边界值测试", "y_wise", "Y_WISE 大动态 scale 混合", (4, 8), ("full",), "y_wise_large_scale_mix", granularity=PT_QGRAN_Y_WISE, scales=[0x0002_8000, 0x0002_0000, 0x0001_8000, 0x0001_0000], b_values=[6, 12, 18, 24, 30, 36, 42, 48]),
	_case("test_pt_qcfg_boundary_x_div2_sign_flip_15", "PT-BB-003", "边界值测试", "x_div2", "X_WISE_DIV2 正负翻转", (4, 8), ("full",), "x_div2_sign_flip", granularity=PT_QGRAN_X_WISE_DIV2, scales=[0x0001_0000, 0xFFFF_0000, 0x0000_8000, 0xFFFF_8000], b_values=[7, 13, 19, 25, 31, 37, 43, 49]),
	_case("test_pt_qcfg_boundary_y_div2_sign_flip_16", "PT-BB-003", "边界值测试", "y_div2", "Y_WISE_DIV2 正负翻转", (4, 8), ("full",), "y_div2_sign_flip", granularity=PT_QGRAN_Y_WISE_DIV2, scales=[0x0001_0000, 0xFFFF_0000, 0x0000_8000, 0xFFFF_8000], b_values=[8, 15, 22, 29, 36, 43, 50, 57]),
	_case("test_pt_qcfg_config_x_wise_payload_floor_17", "PT-BB-003", "约束/配置测试", "payload_count", "X_WISE payload 个数边界", (4, 8), ("full",), "x_wise_payload_floor", granularity=PT_QGRAN_X_WISE, scales=[0x0001_0000, 0x0001_0000, 0x0001_0000, 0x0001_0000], b_values=[1, 3, 5, 7, 9, 11, 13, 15]),
	_case("test_pt_qcfg_config_y_wise_payload_floor_18", "PT-BB-003", "约束/配置测试", "payload_count", "Y_WISE payload 个数边界", (4, 8), ("full",), "y_wise_payload_floor", granularity=PT_QGRAN_Y_WISE, scales=[0x0001_0000, 0x0001_0000, 0x0001_0000, 0x0001_0000], b_values=[2, 4, 6, 8, 10, 12, 14, 16]),
	_case("test_pt_qcfg_config_x_div2_payload_boundary_19", "PT-BB-003", "约束/配置测试", "payload_count", "X_WISE_DIV2 payload 映射边界", (4, 8), ("full",), "x_div2_payload_boundary", granularity=PT_QGRAN_X_WISE_DIV2, scales=[0x0001_0000, 0x0001_8000, 0x0002_0000, 0x0002_8000], b_values=[3, 6, 9, 12, 15, 18, 21, 24]),
	_case("test_pt_qcfg_config_y_div2_payload_boundary_20", "PT-BB-003", "约束/配置测试", "payload_count", "Y_WISE_DIV2 payload 映射边界", (4, 8), ("full",), "y_div2_payload_boundary", granularity=PT_QGRAN_Y_WISE_DIV2, scales=[0x0001_0000, 0x0001_8000, 0x0002_0000, 0x0002_8000], b_values=[4, 8, 12, 16, 20, 24, 28, 32]),
]


PROTOCOL_CASES = [
	_case("test_pt_protocol_error_control_invalid_scale_n_01", "PT-BB-004", "异常路径测试", "控制编码异常", "N scale 非法", (4,), ("full",), "control_invalid_scale_n", kind="invalid_scale", params={"m_scale": 0x3, "n_scale": 0x2, "k_scale": 0x3}),
	_case("test_pt_protocol_error_control_invalid_scale_m_02", "PT-BB-004", "异常路径测试", "控制编码异常", "M scale 非法", (4,), ("full",), "control_invalid_scale_m", kind="invalid_scale", params={"m_scale": 0x2, "n_scale": 0x3, "k_scale": 0x3}),
	_case("test_pt_protocol_error_control_invalid_scale_k_03", "PT-BB-004", "异常路径测试", "控制编码异常", "K scale 非法", (4,), ("full",), "control_invalid_scale_k", kind="invalid_scale", params={"m_scale": 0x3, "n_scale": 0x3, "k_scale": 0x2}),
	_case("test_pt_protocol_error_control_invalid_scale_all_04", "PT-BB-004", "异常路径测试", "控制编码异常", "MNK scale 全非法", (4,), ("full",), "control_invalid_scale_all", kind="invalid_scale", params={"m_scale": 0x2, "n_scale": 0x2, "k_scale": 0x2}),
	_case("test_pt_protocol_error_align_bad_a_off_05", "PT-BB-004", "异常路径测试", "地址/对齐异常", "A offset 非对齐 1", (4,), ("full",), "align_bad_a_off_1", kind="bad_align", params={"a_off": 0x001, "b_off": 0x000}),
	_case("test_pt_protocol_error_align_bad_b_off_06", "PT-BB-004", "异常路径测试", "地址/对齐异常", "B offset 非对齐 1", (4,), ("full",), "align_bad_b_off_1", kind="bad_align", params={"a_off": 0x000, "b_off": 0x001}),
	_case("test_pt_protocol_error_align_bad_a_off_07", "PT-BB-004", "异常路径测试", "地址/对齐异常", "A offset 非对齐 3", (4,), ("full",), "align_bad_a_off_3", kind="bad_align", params={"a_off": 0x003, "b_off": 0x000}),
	_case("test_pt_protocol_error_align_bad_b_off_08", "PT-BB-004", "异常路径测试", "地址/对齐异常", "B offset 非对齐 3", (4,), ("full",), "align_bad_b_off_3", kind="bad_align", params={"a_off": 0x000, "b_off": 0x003}),
	_case("test_pt_protocol_error_qcfg_bad_qtype_09", "PT-BB-004", "异常路径测试", "QCFG 交互异常", "QCFG qtype=01", (4,), ("full",), "qcfg_bad_qtype_01", kind="bad_qtype", params={"qtype": 0b01}),
	_case("test_pt_protocol_error_qcfg_bad_qtype_10", "PT-BB-004", "异常路径测试", "QCFG 交互异常", "QCFG qtype=10", (4,), ("full",), "qcfg_bad_qtype_10", kind="bad_qtype", params={"qtype": 0b10}),
	_case("test_pt_protocol_error_qcfg_id_mismatch_x_11", "PT-BB-004", "异常路径测试", "QCFG 交互异常", "X_WISE payload ID 错配", (4,), ("full",), "qcfg_id_mismatch_x", kind="qcfg_id_mismatch_x", params={}),
	_case("test_pt_protocol_error_qcfg_id_mismatch_y_12", "PT-BB-004", "异常路径测试", "QCFG 交互异常", "Y_WISE payload ID 错配", (4,), ("full",), "qcfg_id_mismatch_y", kind="qcfg_id_mismatch_y", params={}),
	_case("test_pt_protocol_error_stream_wrong_tuser_a_13", "PT-BB-004", "异常路径测试", "输入流异常", "A stream wrong_tuser", (4,), ("full",), "stream_wrong_tuser_a", kind="wrong_tuser_a", params={}),
	_case("test_pt_protocol_error_stream_wrong_tuser_b_14", "PT-BB-004", "异常路径测试", "输入流异常", "B stream wrong_tuser", (4,), ("full",), "stream_wrong_tuser_b", kind="wrong_tuser_b", params={}),
	_case("test_pt_protocol_error_stream_dma_error_a_short_15", "PT-BB-004", "异常路径测试", "输入流异常", "A stream before_stream error 短延迟", (4,), ("full",), "stream_dma_error_a_short", kind="dma_error_before_a", params={"delay": 2}),
	_case("test_pt_protocol_error_stream_dma_error_b_short_16", "PT-BB-004", "异常路径测试", "输入流异常", "B stream before_stream error 短延迟", (4,), ("full",), "stream_dma_error_b_short", kind="dma_error_before_b", params={"delay": 2}),
	_case("test_pt_protocol_error_stream_dma_error_b_long_17", "PT-BB-004", "异常路径测试", "输入流异常", "B stream before_stream error 长延迟", (4,), ("full",), "stream_dma_error_b_long", kind="dma_error_before_b", params={"delay": 4}),
	_case("test_pt_protocol_error_export_error_short_18", "PT-BB-004", "异常路径测试", "导出异常", "导出 DMA error 短延迟", (4,), ("full",), "export_error_short", kind="export_error", params={"delay": 1}),
	_case("test_pt_protocol_error_export_error_mid_19", "PT-BB-004", "异常路径测试", "导出异常", "导出 DMA error 中延迟", (4,), ("full",), "export_error_mid", kind="export_error", params={"delay": 2}),
	_case("test_pt_protocol_error_export_error_long_20", "PT-BB-004", "异常路径测试", "导出异常", "导出 DMA error 长延迟", (4,), ("full",), "export_error_long", kind="export_error", params={"delay": 4}),
]


BACKPRESSURE_CASES = [
	_case("test_pt_backpressure_timing_light_balanced_01", "PT-BB-006", "时序扰动测试", "轻度回压", "轻度均衡回压", (4, 8), ("full",), "light_balanced_01", patterns=([1, 1, 1, 0, 1, 1, 1, 1], [1, 1, 0, 1, 1, 1, 1, 1], [1, 1, 1, 0, 1, 1, 1], [1, 1, 0, 1, 1, 1, 1])),
	_case("test_pt_backpressure_timing_light_input_soft_02", "PT-BB-006", "时序扰动测试", "轻度回压", "输入侧轻微空洞", (4, 8), ("full",), "light_input_soft_02", patterns=([1, 0, 1, 1, 1, 1, 0, 1], [1, 1, 1, 0, 1, 1, 1, 1], [1, 1, 1, 1, 0, 1, 1], [1, 0, 1, 1, 0, 1, 1])),
	_case("test_pt_backpressure_timing_light_output_soft_03", "PT-BB-006", "时序扰动测试", "轻度回压", "输出侧轻微空洞", (4, 8), ("full",), "light_output_soft_03", patterns=([1, 1, 1, 0, 1, 1, 1, 1], [1, 1, 1, 0, 1, 1, 1, 1], [1, 0, 1, 1, 1, 0, 1], [1, 1, 0, 1, 1, 1, 1])),
	_case("test_pt_backpressure_timing_light_phase_shift_04", "PT-BB-006", "时序扰动测试", "轻度回压", "轻度错相回压", (4, 8), ("full",), "light_phase_shift_04", patterns=([0, 1, 1, 1, 1, 0, 1, 1], [1, 1, 0, 1, 1, 1, 0, 1], [1, 0, 1, 1, 1, 0, 1], [0, 1, 1, 0, 1, 1, 1])),
	_case("test_pt_backpressure_timing_medium_balanced_05", "PT-BB-006", "时序扰动测试", "中度回压", "中度均衡回压", (4, 8), ("full",), "medium_balanced_05", patterns=([1, 0, 1, 1, 1, 0, 1, 1], [1, 1, 0, 1, 1, 1, 0, 1], [1, 1, 0, 1, 1, 0, 1], [1, 0, 1, 1, 0, 1, 1, 1])),
	_case("test_pt_backpressure_timing_medium_input_biased_06", "PT-BB-006", "时序扰动测试", "中度回压", "输入侧偏压", (4, 8), ("full",), "medium_input_biased_06", patterns=([1, 1, 0, 1, 1, 0, 1, 1], [1, 1, 0, 1, 1, 0, 1, 1], [1, 1, 0, 1, 0, 1, 1], [0, 1, 0, 1, 0, 1, 1, 1]), matrix_profile=16),
	_case("test_pt_backpressure_timing_medium_output_biased_07", "PT-BB-006", "时序扰动测试", "中度回压", "输出侧偏压", (4, 8), ("full",), "medium_output_biased_07", patterns=([1, 1, 0, 1, 1, 1, 0, 1], [1, 0, 1, 1, 1, 0, 1, 1], [1, 0, 1, 1, 0, 1, 1], [1, 1, 0, 1, 1, 1, 0, 1])),
	_case("test_pt_backpressure_timing_medium_phase_shift_08", "PT-BB-006", "时序扰动测试", "中度回压", "中度错相回压", (4, 8), ("full",), "medium_phase_shift_08", patterns=([0, 1, 1, 1, 0, 1, 1, 1], [1, 1, 0, 1, 1, 0, 1, 1], [1, 0, 1, 1, 0, 1, 1], [0, 1, 1, 1, 0, 1, 1, 1])),
	_case("test_pt_backpressure_timing_heavy_balanced_09", "PT-BB-006", "时序扰动测试", "重度回压", "重度均衡回压", (4, 8), ("full",), "heavy_balanced_09", patterns=([0, 1, 1, 0, 1, 0, 1, 1], [1, 0, 0, 1, 1, 0, 1, 1], [1, 1, 0, 1, 1, 0, 1], [0, 1, 0, 1, 1, 1, 0, 1])),
	_case("test_pt_backpressure_timing_heavy_input_biased_10", "PT-BB-006", "时序扰动测试", "重度回压", "输入侧重度回压", (4, 8), ("full",), "heavy_input_biased_10", patterns=([0, 0, 1, 1, 1, 0, 1, 1], [1, 1, 0, 1, 1, 0, 1, 1], [1, 1, 0, 1, 1, 0, 1], [0, 1, 1, 0, 1, 0, 1, 1])),
	_case("test_pt_backpressure_timing_heavy_output_biased_11", "PT-BB-006", "时序扰动测试", "重度回压", "输出侧重度回压", (4, 8), ("full",), "heavy_output_biased_11", patterns=([1, 1, 0, 1, 1, 0, 1, 1], [0, 1, 1, 0, 1, 1, 0, 1], [1, 0, 1, 1, 0, 1, 1], [1, 1, 0, 1, 1, 0, 1, 1])),
	_case("test_pt_backpressure_timing_heavy_phase_shift_12", "PT-BB-006", "时序扰动测试", "重度回压", "重度错相回压", (4, 8), ("full",), "heavy_phase_shift_12", patterns=([0, 1, 1, 0, 1, 0, 1, 1], [1, 0, 0, 1, 1, 0, 1, 1], [1, 1, 0, 1, 1, 0, 1], [0, 1, 0, 1, 1, 1, 0, 1])),
	_case("test_pt_backpressure_timing_phase_shift_dma_lead_13", "PT-BB-006", "时序扰动测试", "相位错位回压", "DMA ready 领先", (4, 8), ("full",), "phase_shift_dma_lead_13", patterns=([0, 1, 1, 1, 1, 0, 1, 1], [1, 1, 0, 1, 1, 0, 1, 1], [1, 0, 1, 1, 1, 0, 1], [0, 1, 1, 0, 1, 1, 1])),
	_case("test_pt_backpressure_timing_phase_shift_export_lead_14", "PT-BB-006", "时序扰动测试", "相位错位回压", "导出通路领先", (4, 8), ("full",), "phase_shift_export_lead_14", patterns=([0, 1, 1, 0, 1, 1, 0, 1], [1, 1, 0, 0, 1, 0, 1, 1], [0, 1, 1, 0, 1, 1, 1], [1, 0, 1, 1, 0, 1, 1, 1])),
	_case("test_pt_backpressure_timing_input_dma_req_bias_15", "PT-BB-006", "时序扰动测试", "输入侧偏压", "A/B DMA request 更受限", (4, 8), ("full",), "input_dma_req_bias_15", patterns=([0, 1, 0, 1, 1, 0, 1, 1], [1, 0, 1, 1, 1, 0, 1, 1], [1, 1, 1, 0, 1, 0, 1], [0, 1, 1, 0, 1, 0, 1, 1])),
	_case("test_pt_backpressure_timing_input_s_axis_bias_16", "PT-BB-006", "时序扰动测试", "输入侧偏压", "s_axis_valid 更受限", (4, 8), ("full",), "input_s_axis_bias_16", patterns=([1, 1, 0, 1, 1, 0, 1, 1], [1, 1, 0, 1, 1, 0, 1, 1], [1, 1, 0, 1, 0, 1, 1], [0, 1, 0, 1, 0, 1, 1, 1])),
	_case("test_pt_backpressure_timing_input_dual_bias_17", "PT-BB-006", "时序扰动测试", "输入侧偏压", "DMA 与 s_axis 双偏压", (4, 8), ("full",), "input_dual_bias_17", patterns=([0, 1, 0, 1, 1, 0, 1, 1], [1, 0, 1, 1, 1, 0, 1, 1], [1, 1, 1, 0, 1, 0, 1], [0, 1, 1, 0, 1, 0, 1, 1])),
	_case("test_pt_backpressure_timing_output_req_bias_18", "PT-BB-006", "时序扰动测试", "输出侧偏压", "m_dma_req_ready 更受限", (4, 8), ("full",), "output_req_bias_18", patterns=([1, 1, 0, 1, 1, 0, 1, 1], [1, 1, 0, 1, 1, 0, 1, 1], [0, 1, 0, 1, 0, 1, 1], [1, 1, 0, 1, 1, 0, 1, 1])),
	_case("test_pt_backpressure_timing_output_axis_bias_19", "PT-BB-006", "时序扰动测试", "输出侧偏压", "m_axis_tready 更受限", (4, 8), ("full",), "output_axis_bias_19", patterns=([1, 1, 0, 1, 1, 0, 1, 1], [1, 1, 0, 1, 1, 0, 1, 1], [0, 1, 0, 1, 0, 1, 1], [1, 1, 0, 1, 1, 0, 1, 1])),
	_case("test_pt_backpressure_timing_output_dual_bias_20", "PT-BB-006", "时序扰动测试", "输出侧偏压", "导出请求与数据通路双偏压", (4, 8), ("full",), "output_dual_bias_20", patterns=([1, 1, 0, 1, 1, 0, 1, 1], [0, 1, 0, 1, 1, 0, 1, 1], [0, 1, 1, 0, 1, 0, 1], [1, 1, 0, 1, 1, 0, 1, 1])),
]


RANDOMIZED_PROFILES = [
	_case("test_pt_randomized_profile_balanced_mix_4x4_01", "PT-BB-007", "随机扰动测试", "balanced_mix", "4x4 均衡随机流量", (4,), ("randomized",), "balanced_mix_4x4", seed=410, random_cases=20, weights={"legal": 4, "hit": 2, "mwindow": 2, "qcfg": 2, "invalid": 2, "wrong_tuser": 1, "export_error": 1}, ready_probs={"dma_req_ready": 0.78, "m_dma_req_ready": 0.82, "m_axis_ready": 0.74, "s_axis_valid": 0.82}),
	_case("test_pt_randomized_profile_legal_heavy_4x4_02", "PT-BB-007", "随机扰动测试", "legal_heavy", "4x4 合法流量偏置", (4,), ("randomized",), "legal_heavy_4x4", seed=411, random_cases=20, weights={"legal": 8, "hit": 3, "mwindow": 2, "qcfg": 2, "invalid": 1, "wrong_tuser": 1, "export_error": 1}, ready_probs={"dma_req_ready": 0.82, "m_dma_req_ready": 0.86, "m_axis_ready": 0.78, "s_axis_valid": 0.85}),
	_case("test_pt_randomized_profile_hit_heavy_4x4_03", "PT-BB-007", "随机扰动测试", "hit_heavy", "4x4 cache hit 偏置", (4,), ("randomized",), "hit_heavy_4x4", seed=412, random_cases=20, weights={"legal": 2, "hit": 7, "mwindow": 3, "qcfg": 2, "invalid": 1, "wrong_tuser": 1, "export_error": 1}, ready_probs={"dma_req_ready": 0.80, "m_dma_req_ready": 0.84, "m_axis_ready": 0.76, "s_axis_valid": 0.82}),
	_case("test_pt_randomized_profile_mwindow_heavy_4x4_04", "PT-BB-007", "随机扰动测试", "mwindow_heavy", "4x4 M-window 偏置", (4,), ("randomized",), "mwindow_heavy_4x4", seed=413, random_cases=20, weights={"legal": 2, "hit": 3, "mwindow": 7, "qcfg": 2, "invalid": 1, "wrong_tuser": 1, "export_error": 1}, ready_probs={"dma_req_ready": 0.79, "m_dma_req_ready": 0.84, "m_axis_ready": 0.75, "s_axis_valid": 0.81}),
	_case("test_pt_randomized_profile_qcfg_heavy_4x4_05", "PT-BB-007", "随机扰动测试", "qcfg_heavy", "4x4 QCFG 交互偏置", (4,), ("randomized",), "qcfg_heavy_4x4", seed=414, random_cases=20, weights={"legal": 2, "hit": 2, "mwindow": 2, "qcfg": 8, "invalid": 2, "wrong_tuser": 1, "export_error": 1}, ready_probs={"dma_req_ready": 0.80, "m_dma_req_ready": 0.82, "m_axis_ready": 0.74, "s_axis_valid": 0.83}),
	_case("test_pt_randomized_profile_invalid_heavy_4x4_06", "PT-BB-007", "随机扰动测试", "error_heavy", "4x4 非法事务偏置", (4,), ("randomized",), "invalid_heavy_4x4", seed=415, random_cases=20, weights={"legal": 2, "hit": 1, "mwindow": 1, "qcfg": 2, "invalid": 7, "wrong_tuser": 3, "export_error": 2}, ready_probs={"dma_req_ready": 0.77, "m_dma_req_ready": 0.80, "m_axis_ready": 0.72, "s_axis_valid": 0.80}),
	_case("test_pt_randomized_profile_wrong_tuser_heavy_4x4_07", "PT-BB-007", "随机扰动测试", "wrong_tuser_heavy", "4x4 输入协议错误偏置", (4,), ("randomized",), "wrong_tuser_heavy_4x4", seed=416, random_cases=20, weights={"legal": 2, "hit": 1, "mwindow": 1, "qcfg": 2, "invalid": 2, "wrong_tuser": 8, "export_error": 2}, ready_probs={"dma_req_ready": 0.76, "m_dma_req_ready": 0.80, "m_axis_ready": 0.72, "s_axis_valid": 0.79}),
	_case("test_pt_randomized_profile_export_error_heavy_4x4_08", "PT-BB-007", "随机扰动测试", "export_error_heavy", "4x4 导出错误偏置", (4,), ("randomized",), "export_error_heavy_4x4", seed=417, random_cases=20, weights={"legal": 3, "hit": 2, "mwindow": 2, "qcfg": 2, "invalid": 1, "wrong_tuser": 1, "export_error": 7}, ready_probs={"dma_req_ready": 0.78, "m_dma_req_ready": 0.78, "m_axis_ready": 0.70, "s_axis_valid": 0.80}),
	_case("test_pt_randomized_profile_backpressure_heavy_4x4_09", "PT-BB-007", "随机扰动测试", "backpressure_heavy", "4x4 重回压随机偏置", (4,), ("randomized",), "backpressure_heavy_4x4", seed=418, random_cases=20, weights={"legal": 4, "hit": 2, "mwindow": 2, "qcfg": 2, "invalid": 2, "wrong_tuser": 1, "export_error": 1}, ready_probs={"dma_req_ready": 0.62, "m_dma_req_ready": 0.66, "m_axis_ready": 0.58, "s_axis_valid": 0.66}),
	_case("test_pt_randomized_profile_cache_reuse_heavy_4x4_10", "PT-BB-007", "随机扰动测试", "cache_reuse_heavy", "4x4 cache reuse 偏置", (4,), ("randomized",), "cache_reuse_heavy_4x4", seed=419, random_cases=20, weights={"legal": 2, "hit": 6, "mwindow": 5, "qcfg": 2, "invalid": 1, "wrong_tuser": 1, "export_error": 1}, ready_probs={"dma_req_ready": 0.80, "m_dma_req_ready": 0.84, "m_axis_ready": 0.76, "s_axis_valid": 0.82}),
	_case("test_pt_randomized_profile_balanced_mix_8x8_11", "PT-BB-007", "随机扰动测试", "balanced_mix", "8x8 均衡随机流量", (8,), ("randomized",), "balanced_mix_8x8", seed=810, random_cases=20, weights={"legal": 4, "hit": 2, "mwindow": 2, "qcfg": 2, "invalid": 2, "wrong_tuser": 1, "export_error": 1}, ready_probs={"dma_req_ready": 0.78, "m_dma_req_ready": 0.82, "m_axis_ready": 0.74, "s_axis_valid": 0.82}),
	_case("test_pt_randomized_profile_legal_heavy_8x8_12", "PT-BB-007", "随机扰动测试", "legal_heavy", "8x8 合法流量偏置", (8,), ("randomized",), "legal_heavy_8x8", seed=811, random_cases=20, weights={"legal": 8, "hit": 3, "mwindow": 2, "qcfg": 2, "invalid": 1, "wrong_tuser": 1, "export_error": 1}, ready_probs={"dma_req_ready": 0.82, "m_dma_req_ready": 0.86, "m_axis_ready": 0.78, "s_axis_valid": 0.85}),
	_case("test_pt_randomized_profile_hit_heavy_8x8_13", "PT-BB-007", "随机扰动测试", "hit_heavy", "8x8 cache hit 偏置", (8,), ("randomized",), "hit_heavy_8x8", seed=812, random_cases=20, weights={"legal": 2, "hit": 7, "mwindow": 3, "qcfg": 2, "invalid": 1, "wrong_tuser": 1, "export_error": 1}, ready_probs={"dma_req_ready": 0.80, "m_dma_req_ready": 0.84, "m_axis_ready": 0.76, "s_axis_valid": 0.82}),
	_case("test_pt_randomized_profile_mwindow_heavy_8x8_14", "PT-BB-007", "随机扰动测试", "mwindow_heavy", "8x8 M-window 偏置", (8,), ("randomized",), "mwindow_heavy_8x8", seed=813, random_cases=20, weights={"legal": 2, "hit": 3, "mwindow": 7, "qcfg": 2, "invalid": 1, "wrong_tuser": 1, "export_error": 1}, ready_probs={"dma_req_ready": 0.79, "m_dma_req_ready": 0.84, "m_axis_ready": 0.75, "s_axis_valid": 0.81}),
	_case("test_pt_randomized_profile_qcfg_heavy_8x8_15", "PT-BB-007", "随机扰动测试", "qcfg_heavy", "8x8 QCFG 交互偏置", (8,), ("randomized",), "qcfg_heavy_8x8", seed=814, random_cases=20, weights={"legal": 2, "hit": 2, "mwindow": 2, "qcfg": 8, "invalid": 2, "wrong_tuser": 1, "export_error": 1}, ready_probs={"dma_req_ready": 0.80, "m_dma_req_ready": 0.82, "m_axis_ready": 0.74, "s_axis_valid": 0.83}),
	_case("test_pt_randomized_profile_invalid_heavy_8x8_16", "PT-BB-007", "随机扰动测试", "error_heavy", "8x8 非法事务偏置", (8,), ("randomized",), "invalid_heavy_8x8", seed=815, random_cases=20, weights={"legal": 2, "hit": 1, "mwindow": 1, "qcfg": 2, "invalid": 7, "wrong_tuser": 3, "export_error": 2}, ready_probs={"dma_req_ready": 0.77, "m_dma_req_ready": 0.80, "m_axis_ready": 0.72, "s_axis_valid": 0.80}),
	_case("test_pt_randomized_profile_wrong_tuser_heavy_8x8_17", "PT-BB-007", "随机扰动测试", "wrong_tuser_heavy", "8x8 输入协议错误偏置", (8,), ("randomized",), "wrong_tuser_heavy_8x8", seed=816, random_cases=20, weights={"legal": 2, "hit": 1, "mwindow": 1, "qcfg": 2, "invalid": 2, "wrong_tuser": 8, "export_error": 2}, ready_probs={"dma_req_ready": 0.76, "m_dma_req_ready": 0.80, "m_axis_ready": 0.72, "s_axis_valid": 0.79}),
	_case("test_pt_randomized_profile_export_error_heavy_8x8_18", "PT-BB-007", "随机扰动测试", "export_error_heavy", "8x8 导出错误偏置", (8,), ("randomized",), "export_error_heavy_8x8", seed=817, random_cases=20, weights={"legal": 3, "hit": 2, "mwindow": 2, "qcfg": 2, "invalid": 1, "wrong_tuser": 1, "export_error": 7}, ready_probs={"dma_req_ready": 0.78, "m_dma_req_ready": 0.78, "m_axis_ready": 0.70, "s_axis_valid": 0.80}),
	_case("test_pt_randomized_profile_backpressure_heavy_8x8_19", "PT-BB-007", "随机扰动测试", "backpressure_heavy", "8x8 重回压随机偏置", (8,), ("randomized",), "backpressure_heavy_8x8", seed=818, random_cases=20, weights={"legal": 4, "hit": 2, "mwindow": 2, "qcfg": 2, "invalid": 2, "wrong_tuser": 1, "export_error": 1}, ready_probs={"dma_req_ready": 0.62, "m_dma_req_ready": 0.66, "m_axis_ready": 0.58, "s_axis_valid": 0.66}),
	_case("test_pt_randomized_profile_cache_reuse_heavy_8x8_20", "PT-BB-007", "随机扰动测试", "cache_reuse_heavy", "8x8 cache reuse 偏置", (8,), ("randomized",), "cache_reuse_heavy_8x8", seed=819, random_cases=20, weights={"legal": 2, "hit": 6, "mwindow": 5, "qcfg": 2, "invalid": 1, "wrong_tuser": 1, "export_error": 1}, ready_probs={"dma_req_ready": 0.80, "m_dma_req_ready": 0.84, "m_axis_ready": 0.76, "s_axis_valid": 0.82}),
]


GUARD_PROFILES = [
	_case("test_pt_guard_config_odd_x_only_x3_y2_01", "PT-BB-005", "约束/配置测试", "odd-X only", "仅 X 为奇数", (3, 2), ("full",), "odd_x_only_x3_y2", x_dim=3, y_dim=2),
	_case("test_pt_guard_config_odd_y_only_x2_y3_02", "PT-BB-005", "约束/配置测试", "odd-Y only", "仅 Y 为奇数", (2, 3), ("full",), "odd_y_only_x2_y3", x_dim=2, y_dim=3),
	_case("test_pt_guard_config_both_odd_x3_y3_03", "PT-BB-005", "约束/配置测试", "both odd", "X/Y 同时为奇数", (3, 3), ("full",), "both_odd_x3_y3", x_dim=3, y_dim=3),
	_case("test_pt_guard_config_non_pow_even_x6_y4_04", "PT-BB-005", "约束/配置测试", "non-power even", "X 为非 2 的幂偶数", (6, 4), ("full",), "non_pow_even_x6_y4", x_dim=6, y_dim=4),
	_case("test_pt_guard_config_non_pow_even_x4_y6_05", "PT-BB-005", "约束/配置测试", "non-power even", "Y 为非 2 的幂偶数", (4, 6), ("full",), "non_pow_even_x4_y6", x_dim=4, y_dim=6),
	_case("test_pt_guard_config_non_pow_even_x6_y6_06", "PT-BB-005", "约束/配置测试", "non-power even", "X/Y 同时为非 2 的幂偶数", (6, 6), ("full",), "non_pow_even_x6_y6", x_dim=6, y_dim=6),
	_case("test_pt_guard_config_small_invalid_x3_y4_07", "PT-BB-005", "约束/配置测试", "small invalid", "小尺寸 X 非法", (3, 4), ("full",), "small_invalid_x3_y4", x_dim=3, y_dim=4),
	_case("test_pt_guard_config_small_invalid_x4_y3_08", "PT-BB-005", "约束/配置测试", "small invalid", "小尺寸 Y 非法", (4, 3), ("full",), "small_invalid_x4_y3", x_dim=4, y_dim=3),
	_case("test_pt_guard_config_asym_invalid_x5_y8_09", "PT-BB-005", "约束/配置测试", "asymmetric invalid", "X 奇数、Y 合法 2 的幂", (5, 8), ("full",), "asym_invalid_x5_y8", x_dim=5, y_dim=8),
	_case("test_pt_guard_config_asym_invalid_x8_y5_10", "PT-BB-005", "约束/配置测试", "asymmetric invalid", "X 合法 2 的幂、Y 奇数", (8, 5), ("full",), "asym_invalid_x8_y5", x_dim=8, y_dim=5),
	_case("test_pt_guard_config_odd_x_only_x7_y4_11", "PT-BB-005", "约束/配置测试", "odd-X only", "更大奇数 X", (7, 4), ("full",), "odd_x_only_x7_y4", x_dim=7, y_dim=4),
	_case("test_pt_guard_config_odd_y_only_x4_y7_12", "PT-BB-005", "约束/配置测试", "odd-Y only", "更大奇数 Y", (4, 7), ("full",), "odd_y_only_x4_y7", x_dim=4, y_dim=7),
	_case("test_pt_guard_config_both_odd_x5_y5_13", "PT-BB-005", "约束/配置测试", "both odd", "中等尺寸双奇数", (5, 5), ("full",), "both_odd_x5_y5", x_dim=5, y_dim=5),
	_case("test_pt_guard_config_non_pow_even_x10_y8_14", "PT-BB-005", "约束/配置测试", "non-power even", "更大非幂偶数 X", (10, 8), ("full",), "non_pow_even_x10_y8", x_dim=10, y_dim=8),
	_case("test_pt_guard_config_non_pow_even_x8_y10_15", "PT-BB-005", "约束/配置测试", "non-power even", "更大非幂偶数 Y", (8, 10), ("full",), "non_pow_even_x8_y10", x_dim=8, y_dim=10),
	_case("test_pt_guard_config_small_invalid_x6_y2_16", "PT-BB-005", "约束/配置测试", "small invalid", "小尺寸非幂 X", (6, 2), ("full",), "small_invalid_x6_y2", x_dim=6, y_dim=2),
	_case("test_pt_guard_config_small_invalid_x2_y6_17", "PT-BB-005", "约束/配置测试", "small invalid", "小尺寸非幂 Y", (2, 6), ("full",), "small_invalid_x2_y6", x_dim=2, y_dim=6),
	_case("test_pt_guard_config_asym_invalid_x12_y8_18", "PT-BB-005", "约束/配置测试", "asymmetric invalid", "X 非幂偶数、Y 合法", (12, 8), ("full",), "asym_invalid_x12_y8", x_dim=12, y_dim=8),
	_case("test_pt_guard_config_asym_invalid_x8_y12_19", "PT-BB-005", "约束/配置测试", "asymmetric invalid", "X 合法、Y 非幂偶数", (8, 12), ("full",), "asym_invalid_x8_y12", x_dim=8, y_dim=12),
	_case("test_pt_guard_config_both_odd_x7_y9_20", "PT-BB-005", "约束/配置测试", "both odd", "更大双奇数组合", (7, 9), ("full",), "both_odd_x7_y9", x_dim=7, y_dim=9),
]


RANDOMIZED_PROFILE_BY_NAME = {case.profile: case for case in RANDOMIZED_PROFILES}
GUARD_PROFILE_BY_NAME = {case.profile: case for case in GUARD_PROFILES}
