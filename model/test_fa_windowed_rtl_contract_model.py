import unittest

from model.fa_windowed_rtl_contract_model import (
    WindowedRtlContractConfig,
    WindowedTopAxiLayoutConfig,
    axi_read_metrics_for_windowed_contract,
    axi_write_metrics_for_windowed_contract,
    build_windowed_rtl_contract,
    count_k_layout_roundtrip_errors,
    count_v_layout_roundtrip_errors,
    dense_qk_o_write_word32,
    dense_qk_axi_tile_beat64,
    dense_qk_direct_tile_beat64,
)
from model.fa_windowed_attention_model import (
    expected_dense_qk_fixed_o_word,
    expected_dense_qk_fixed_o_word_for_tile,
)


class WindowedRtlContractModelTest(unittest.TestCase):
    def test_s256_d64_windowed_contract_matches_vcs_smoke_counters(self):
        cfg = WindowedRtlContractConfig()

        contract = build_windowed_rtl_contract(cfg)

        self.assertEqual(contract.counters.q_group_count, 4)
        self.assertEqual(contract.counters.kv_window_count, 16)
        self.assertEqual(contract.counters.q_tile_visit_count, 256)
        self.assertEqual(contract.counters.q_tile_req_count, 256)
        self.assertEqual(contract.counters.q_tile_beat_count, 16384)
        self.assertEqual(contract.counters.k_tile_req_count, 64)
        self.assertEqual(contract.counters.k_tile_beat_count, 16384)
        self.assertEqual(contract.counters.v_tile_req_count, 64)
        self.assertEqual(contract.counters.v_tile_beat_count, 16384)
        self.assertEqual(contract.counters.micro_tile_count, 1024)
        self.assertEqual(contract.counters.kv_tile_count, 1024)
        self.assertEqual(contract.counters.state_fill_count, 256)
        self.assertEqual(contract.counters.state_spill_count, 256)
        self.assertEqual(contract.counters.core_start_count, 256)
        self.assertEqual(contract.counters.restore_start_count, 192)
        self.assertEqual(contract.counters.qk_task_count, 131072)
        self.assertEqual(contract.counters.pv_task_count, 131072)
        self.assertEqual(contract.counters.oacc_task_count, 1024)
        self.assertEqual(contract.counters.skipped_future_kv_tiles, 0)

    def test_causal_windowed_contract_skips_fully_future_compute_tiles(self):
        cfg = WindowedRtlContractConfig(causal=True)

        contract = build_windowed_rtl_contract(cfg)
        metrics = axi_read_metrics_for_windowed_contract(contract)

        self.assertEqual(contract.counters.micro_tile_count, 544)
        self.assertEqual(contract.counters.kv_tile_count, 544)
        self.assertEqual(contract.counters.skipped_future_kv_tiles, 480)
        self.assertEqual(contract.counters.qk_task_count, 69632)
        self.assertEqual(contract.counters.pv_task_count, 69632)
        self.assertEqual(contract.counters.oacc_task_count, 544)
        self.assertEqual(metrics.rd_bytes, 393216)

    def test_request_sequences_match_windowed_rtl_loop_order(self):
        contract = build_windowed_rtl_contract(WindowedRtlContractConfig())

        self.assertEqual(contract.q_tile_requests[:20], list(range(16)) + list(range(4)))
        self.assertEqual(contract.q_tile_requests[64:80], list(range(16, 32)))
        self.assertEqual(contract.k_tile_requests[:20], list(range(16)) + list(range(4)))
        self.assertEqual(contract.v_tile_requests[:20], list(range(16)) + list(range(4)))
        self.assertEqual(contract.k_tile_requests[16:32], list(range(16)))
        self.assertEqual(contract.v_tile_requests[48:64], list(range(16)))

    def test_restore_starts_are_only_after_first_kv_window_per_q_group(self):
        contract = build_windowed_rtl_contract(WindowedRtlContractConfig())

        self.assertFalse(any(event.restore for event in contract.core_starts[:16]))
        self.assertTrue(all(event.restore for event in contract.core_starts[16:64]))
        self.assertFalse(any(event.restore for event in contract.core_starts[64:80]))
        self.assertTrue(all(event.restore for event in contract.core_starts[80:128]))

    def test_v_sram_window_layout_roundtrips_all_resident_slots(self):
        cfg = WindowedRtlContractConfig()

        self.assertEqual(count_v_layout_roundtrip_errors(cfg), 0)
        self.assertGreater(
            count_v_layout_roundtrip_errors(cfg, v_write_bank_uses_slot_high=False),
            0,
        )

    def test_k_sram_window_layout_roundtrips_all_resident_slots(self):
        cfg = WindowedRtlContractConfig()

        self.assertEqual(count_k_layout_roundtrip_errors(cfg), 0)

    def test_windowed_top_axi_read_metrics_match_tile_stream_volume(self):
        contract = build_windowed_rtl_contract(WindowedRtlContractConfig())

        metrics = axi_read_metrics_for_windowed_contract(contract)

        self.assertEqual(metrics.ar_count, 1536)
        self.assertEqual(metrics.r_beat_count, 24576)
        self.assertEqual(metrics.rd_bytes, 393216)

    def test_windowed_top_axi_write_metrics_match_full_o_output(self):
        contract = build_windowed_rtl_contract(WindowedRtlContractConfig())

        metrics = axi_write_metrics_for_windowed_contract(contract)

        self.assertEqual(metrics.aw_count, 128)
        self.assertEqual(metrics.w_beat_count, 2048)
        self.assertEqual(metrics.wr_bytes, 32768)

    def test_dense_qk_axi_memory_layout_roundtrips_to_tile_beats(self):
        layout = WindowedTopAxiLayoutConfig()

        for q_tile_idx in range(64):
            for row_idx in range(4):
                for chunk_idx in range(16):
                    self.assertEqual(
                        dense_qk_axi_tile_beat64(layout, "q", q_tile_idx, row_idx, chunk_idx),
                        dense_qk_direct_tile_beat64("q", q_tile_idx, row_idx, chunk_idx),
                    )

        for kind in ("k", "v"):
            for kv_tile_idx in range(16):
                for row_idx in range(16):
                    for chunk_idx in range(16):
                        self.assertEqual(
                            dense_qk_axi_tile_beat64(
                                layout, kind, kv_tile_idx, row_idx, chunk_idx
                            ),
                        dense_qk_direct_tile_beat64(kind, kv_tile_idx, row_idx, chunk_idx),
                    )

    def test_dense_qk_o_write_layout_matches_group_dump_stream(self):
        layout = WindowedTopAxiLayoutConfig()

        def expected_o(q_tile_idx: int, row_idx: int, col_idx: int) -> int:
            return expected_dense_qk_fixed_o_word_for_tile(q_tile_idx, row_idx, col_idx)

        first_addr, first_word = dense_qk_o_write_word32(layout, 0, 0, 0, expected_o)
        last_addr, last_word = dense_qk_o_write_word32(layout, 63, 3, 31, expected_o)
        group1_addr, _ = dense_qk_o_write_word32(layout, 16, 0, 0, expected_o)

        self.assertEqual(first_addr, layout.o_base)
        self.assertEqual(first_word & 0xFFFF, expected_dense_qk_fixed_o_word_for_tile(0, 0, 0))
        self.assertEqual(first_word >> 16, expected_dense_qk_fixed_o_word_for_tile(0, 0, 1))
        self.assertEqual(group1_addr, layout.o_base + 8192)
        self.assertEqual(last_addr, layout.o_base + 32764)
        self.assertEqual(last_word & 0xFFFF, expected_dense_qk_fixed_o_word(3, 62))
        self.assertEqual(last_word >> 16, expected_dense_qk_fixed_o_word(3, 63))

    def test_o_write_layout_exhaustively_maps_every_q_tile_word(self):
        layout = WindowedTopAxiLayoutConfig()
        seen_addrs = set()

        def unique_o(q_tile_idx: int, row_idx: int, col_idx: int) -> int:
            return ((q_tile_idx & 0x3F) << 10) | ((row_idx & 0x3) << 8) | (col_idx & 0x3F)

        for q_tile_idx in range(64):
            for row_idx in range(4):
                for col_pair_idx in range(32):
                    addr, word = dense_qk_o_write_word32(
                        layout, q_tile_idx, row_idx, col_pair_idx, unique_o
                    )
                    expected_word_idx = (
                        ((q_tile_idx // 16) * 2048)
                        + ((q_tile_idx % 16) * 128)
                        + (row_idx * 32)
                        + col_pair_idx
                    )
                    expected_addr = layout.o_base + (expected_word_idx * 4)
                    col_idx = col_pair_idx * 2

                    self.assertEqual(addr, expected_addr)
                    self.assertEqual(word & 0xFFFF, unique_o(q_tile_idx, row_idx, col_idx))
                    self.assertEqual(word >> 16, unique_o(q_tile_idx, row_idx, col_idx + 1))
                    seen_addrs.add(addr)

        self.assertEqual(len(seen_addrs), 8192)
        self.assertEqual(min(seen_addrs), layout.o_base)
        self.assertEqual(max(seen_addrs), layout.o_base + 32764)


if __name__ == "__main__":
    unittest.main()
