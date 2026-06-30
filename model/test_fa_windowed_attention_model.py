import math
import unittest

from model.fa_windowed_attention_model import (
    WindowedAttentionConfig,
    AttentionResult,
    WindowedAttentionCounters,
    compare_outputs,
    dense_attention,
    expected_dense_qk_fixed_o_word,
    fixed_dense_qk_window_output,
    fixed_dense_qk_score_q16,
    make_qkv,
    windowed_attention,
)


class WindowedAttentionModelTest(unittest.TestCase):
    def test_windowed_noncausal_matches_dense_attention(self):
        cfg = WindowedAttentionConfig(
            seq_len=256,
            head_dim=64,
            q_group_rows=64,
            q_tile_rows=4,
            kv_tile_rows=16,
            kv_window_tiles=4,
            oacc_slice_cols=16,
            score_slice_cols=4,
            causal=False,
        )
        q, k, v = make_qkv(cfg, seed=11, amplitude=24)

        expected = dense_attention(q, k, v, cfg)
        actual = windowed_attention(q, k, v, cfg)
        err = compare_outputs(actual, expected)

        self.assertLess(err.max_abs, 1.0e-12)
        self.assertEqual(actual.counters.q_group_count, 4)
        self.assertEqual(actual.counters.kv_window_count, 16)
        self.assertEqual(actual.counters.kv_tile_compute_count, 1024)
        self.assertEqual(actual.counters.q_tile_visit_count, 256)
        self.assertEqual(actual.counters.score_slice_count, 4096)
        self.assertEqual(actual.counters.oacc_slice_count, 4096)

    def test_windowed_causal_matches_dense_attention(self):
        cfg = WindowedAttentionConfig(
            seq_len=256,
            head_dim=64,
            q_group_rows=64,
            q_tile_rows=4,
            kv_tile_rows=16,
            kv_window_tiles=4,
            oacc_slice_cols=16,
            score_slice_cols=4,
            causal=True,
        )
        q, k, v = make_qkv(cfg, seed=23, amplitude=24)

        expected = dense_attention(q, k, v, cfg)
        actual = windowed_attention(q, k, v, cfg)
        err = compare_outputs(actual, expected)

        self.assertLess(err.max_abs, 1.0e-12)
        self.assertEqual(actual.counters.kv_window_count, 16)
        self.assertEqual(actual.counters.kv_tile_compute_count, 544)
        self.assertEqual(actual.counters.skipped_future_kv_tiles, 480)

    def test_streaming_state_must_survive_across_kv_windows(self):
        cfg = WindowedAttentionConfig(
            seq_len=256,
            head_dim=64,
            q_group_rows=64,
            q_tile_rows=4,
            kv_tile_rows=16,
            kv_window_tiles=4,
            oacc_slice_cols=16,
            score_slice_cols=4,
            causal=False,
        )
        q, k, v = make_qkv(cfg, seed=37, amplitude=31)

        expected = dense_attention(q, k, v, cfg)
        actual = windowed_attention(q, k, v, cfg)
        reset_each_window = _last_window_only_attention(q, k, v, cfg)

        self.assertLess(compare_outputs(actual, expected).max_abs, 1.0e-12)
        self.assertGreater(compare_outputs(reset_each_window, expected).max_abs, 1.0e-4)

    def test_bad_window_shape_is_rejected(self):
        cfg = WindowedAttentionConfig(
            seq_len=256,
            head_dim=64,
            q_group_rows=48,
            q_tile_rows=4,
            kv_tile_rows=16,
            kv_window_tiles=4,
            oacc_slice_cols=16,
            score_slice_cols=4,
            causal=False,
        )

        with self.assertRaises(ValueError):
            cfg.validate()

    def test_fixed_dense_qk_model_matches_rtl_bench_reference_points(self):
        self.assertEqual(fixed_dense_qk_score_q16(63, 0, 0, 0), 960)
        self.assertEqual(fixed_dense_qk_score_q16(63, 3, 15, 15), 1376)
        self.assertEqual(expected_dense_qk_fixed_o_word(0, 0), 0x082C)
        self.assertEqual(expected_dense_qk_fixed_o_word(2, 31), 0x0A1F)
        self.assertEqual(expected_dense_qk_fixed_o_word(3, 63), 0x0C07)

        output = fixed_dense_qk_window_output()
        checksum = sum(
            (row_idx + 1) * (col_idx + 1) * output[row_idx][col_idx]
            for row_idx in range(4)
            for col_idx in range(64)
        ) & 0xFFFFFFFF

        self.assertEqual(len(output), 4)
        self.assertEqual(len(output[0]), 64)
        self.assertEqual(output[0][0], expected_dense_qk_fixed_o_word(0, 0))
        self.assertEqual(output[3][63], expected_dense_qk_fixed_o_word(3, 63))
        self.assertEqual(checksum, 0x03735A74)


def _last_window_only_attention(q_matrix, k_matrix, v_matrix, cfg):
    """Negative-control model for the forbidden per-window state reset."""
    output = [[0.0 for _ in range(cfg.head_dim)] for _ in range(cfg.seq_len)]
    kv_tile_count = cfg.seq_len // cfg.kv_tile_rows
    kv_window_count = kv_tile_count // cfg.kv_window_tiles
    last_kv_base = (kv_window_count - 1) * cfg.kv_window_tiles * cfg.kv_tile_rows
    for qi in range(cfg.seq_len):
        scores = []
        for kj in range(last_kv_base, cfg.seq_len):
            dot = sum(qv * kv for qv, kv in zip(q_matrix[qi], k_matrix[kj]))
            scores.append(dot * cfg.scale)
        row_max = max(scores)
        exp_values = [math.exp(score - row_max) for score in scores]
        exp_sum = sum(exp_values)
        for local_k, exp_value in enumerate(exp_values):
            prob = exp_value / exp_sum
            for col in range(cfg.head_dim):
                output[qi][col] += prob * v_matrix[last_kv_base + local_k][col]
    return AttentionResult(
        output=output,
        counters=WindowedAttentionCounters(
            q_group_count=0,
            kv_window_count=kv_window_count,
            q_tile_visit_count=0,
            kv_tile_compute_count=0,
            skipped_future_kv_tiles=0,
            score_slice_count=0,
            oacc_slice_count=0,
            state_spill_count=0,
            state_fill_count=0,
        ),
    )


if __name__ == "__main__":
    unittest.main()
