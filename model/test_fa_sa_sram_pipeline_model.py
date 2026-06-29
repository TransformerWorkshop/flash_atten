import unittest

from model.fa_sa_sram_pipeline_model import (
    ModelConfig,
    estimate_buffer_sizes,
    run_named_scenarios,
    simulate,
)


class SaSramPipelineModelTest(unittest.TestCase):
    def test_qk_only_one_feeder_keeps_only_one_cluster_busy(self):
        cfg = ModelConfig(
            tile_count=128,
            cluster_count=4,
            feeder_count=1,
            qk_feed_cycles=16,
            qk_cycles=16,
            pv_feed_cycles=0,
            pv_cycles=0,
            oacc_cycles=0,
            row_update_cycles=0,
            max_inflight_tiles=32,
        )

        result = simulate(cfg)

        self.assertGreaterEqual(result.sa_utilization, 0.20)
        self.assertLessEqual(result.sa_utilization, 0.30)
        self.assertEqual(result.max_active_clusters, 1)
        self.assertEqual(result.task_counts["qk"], 128)
        self.assertEqual(result.task_counts["pv"], 0)
        self.assertEqual(result.task_counts["oacc"], 0)


    def test_local_post_gemm_work_can_fill_four_clusters_with_one_feeder(self):
        cfg = ModelConfig(
            tile_count=128,
            cluster_count=4,
            feeder_count=1,
            qk_feed_cycles=16,
            qk_cycles=16,
            pv_feed_cycles=0,
            pv_cycles=32,
            oacc_cycles=16,
            row_update_cycles=1,
            max_inflight_tiles=32,
        )

        result = simulate(cfg)

        self.assertGreaterEqual(result.sa_utilization, 0.90)
        self.assertGreaterEqual(result.average_active_clusters, 3.6)
        self.assertGreater(result.active_cluster_histogram[4], result.cycles // 2)
        self.assertEqual(result.task_counts["qk"], 128)
        self.assertEqual(result.task_counts["pv"], 128)
        self.assertEqual(result.task_counts["oacc"], 128)

    def test_shared_row_state_pipe_can_be_reused_when_short(self):
        cfg = ModelConfig(
            tile_count=128,
            cluster_count=4,
            feeder_count=1,
            qk_feed_cycles=16,
            qk_cycles=16,
            pv_feed_cycles=0,
            pv_cycles=32,
            oacc_cycles=16,
            row_update_cycles=4,
            row_state_pipe_count=1,
            max_inflight_tiles=32,
        )

        result = simulate(cfg)

        self.assertGreaterEqual(result.sa_utilization, 0.90)
        self.assertGreaterEqual(result.average_active_clusters, 3.6)
        self.assertGreaterEqual(result.row_state_utilization, 0.20)
        self.assertLessEqual(result.row_state_utilization, 0.30)
        self.assertEqual(result.task_counts["row_update"], 128)

    def test_shared_row_state_pipe_becomes_bottleneck_when_long(self):
        cfg = ModelConfig(
            tile_count=128,
            cluster_count=4,
            feeder_count=1,
            qk_feed_cycles=16,
            qk_cycles=16,
            pv_feed_cycles=0,
            pv_cycles=32,
            oacc_cycles=16,
            row_update_cycles=32,
            row_state_pipe_count=1,
            max_inflight_tiles=32,
        )

        result = simulate(cfg)

        self.assertLess(result.sa_utilization, 0.90)
        self.assertGreater(result.row_state_utilization, 0.90)
        self.assertEqual(result.task_counts["row_update"], 128)


    def test_pv_using_same_feeder_exposes_operand_bandwidth_limit(self):
        local_cfg = ModelConfig(
            tile_count=128,
            cluster_count=4,
            feeder_count=1,
            qk_feed_cycles=16,
            qk_cycles=16,
            pv_feed_cycles=0,
            pv_cycles=32,
            oacc_cycles=16,
            row_update_cycles=1,
            max_inflight_tiles=32,
        )
        shared_feeder_cfg = ModelConfig(
            tile_count=128,
            cluster_count=4,
            feeder_count=1,
            qk_feed_cycles=16,
            qk_cycles=16,
            pv_feed_cycles=16,
            pv_cycles=32,
            oacc_cycles=16,
            row_update_cycles=1,
            max_inflight_tiles=32,
        )

        local_result = simulate(local_cfg)
        shared_feeder_result = simulate(shared_feeder_cfg)

        self.assertLess(shared_feeder_result.sa_utilization, local_result.sa_utilization)
        self.assertGreater(shared_feeder_result.feeder_utilization, local_result.feeder_utilization)
        self.assertEqual(shared_feeder_result.feed_counts["pv"], 128)


    def test_named_scenarios_report_expected_ordering(self):
        results = run_named_scenarios(tile_count=128)

        self.assertLess(
            results["qk_only_1_feeder"].sa_utilization,
            results["qk_pv_oacc_48_local_cycles"].sa_utilization,
        )
        self.assertLess(
            results["qk_pv_oacc_48_local_cycles"].sa_utilization,
            results["qk_pv_oacc_64_local_cycles"].sa_utilization,
        )
        self.assertGreaterEqual(
            results["qk_pv_oacc_64_local_cycles"].sa_utilization, 0.90
        )

    def test_buffer_size_estimate_for_one_4x4_cluster(self):
        cfg = ModelConfig(cluster_count=4, q_rows_per_cluster=4, kv_cols_per_cluster=4)

        sizes = estimate_buffer_sizes(cfg)

        self.assertEqual(sizes.shared_bytes["q_operand_buffer"], 512)
        self.assertEqual(sizes.per_cluster_bytes["k_operand_buffer"], 512)
        self.assertEqual(sizes.per_cluster_bytes["v_operand_buffer"], 512)
        self.assertEqual(sizes.per_cluster_bytes["p_tile_buffer"], 32)
        self.assertEqual(sizes.per_cluster_bytes["row_scale_buffer"], 48)
        self.assertEqual(sizes.per_cluster_bytes["pv_partial_buffer"], 512)
        self.assertEqual(sizes.per_cluster_bytes["oacc_old_buffer"], 512)
        self.assertEqual(sizes.per_cluster_bytes["oacc_new_buffer"], 512)
        self.assertEqual(sizes.per_cluster_total_bytes, 2640)

    def test_buffer_size_estimate_for_four_clusters(self):
        cfg = ModelConfig(
            cluster_count=4,
            q_rows_per_cluster=4,
            kv_cols_per_cluster=4,
            task_queue_depth=32,
        )

        sizes = estimate_buffer_sizes(cfg)

        self.assertEqual(sizes.all_clusters_local_bytes, 10560)
        self.assertEqual(sizes.shared_total_bytes, 512)
        self.assertEqual(sizes.task_queue_bytes, 512)
        self.assertEqual(sizes.total_estimated_bytes, 11584)


if __name__ == "__main__":
    unittest.main()
