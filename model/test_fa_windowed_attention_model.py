import unittest

from model.fa_windowed_attention_model import (
    WindowedAttentionConfig,
    compare_outputs,
    dense_attention,
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


if __name__ == "__main__":
    unittest.main()
