import unittest

from model.fa_windowed_rtl_contract_model import (
    WindowedRtlContractConfig,
    build_windowed_rtl_contract,
    count_k_layout_roundtrip_errors,
    count_v_layout_roundtrip_errors,
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


if __name__ == "__main__":
    unittest.main()
