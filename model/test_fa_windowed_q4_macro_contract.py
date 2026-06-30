from pathlib import Path
import unittest

from model.fa_windowed_rtl_contract_model import (
    WindowedRtlContractConfig,
    build_windowed_rtl_contract,
)


REPO_ROOT = Path(__file__).resolve().parents[1]


def read_rtl(name: str) -> str:
    return (REPO_ROOT / "rtl" / name).read_text()


class WindowedQ4MacroContractTest(unittest.TestCase):
    def test_model_contract_uses_q4_state_and_20_total_macros(self):
        cfg = WindowedRtlContractConfig()
        contract = build_windowed_rtl_contract(cfg)

        self.assertEqual(cfg.state_group_rows, 4)
        self.assertEqual(cfg.k_sram_macro_count, 8)
        self.assertEqual(cfg.v_sram_macro_count, 8)
        self.assertEqual(cfg.oacc_sram_macro_count, 4)
        self.assertEqual(cfg.total_sram_macro_count, 20)
        self.assertEqual(contract.counters.state_fill_count, 256)
        self.assertEqual(contract.counters.state_spill_count, 256)
        self.assertEqual(contract.counters.restore_start_count, 192)
        self.assertEqual(contract.counters.state_restore_count, 192)
        self.assertEqual(contract.counters.oacc_restore_cycle_count, 3072)
        self.assertEqual(contract.counters.oacc_spill_cycle_count, 4096)

    def test_windowed_loop_rtl_lands_q4_oacc_macro_contract(self):
        text = read_rtl("fa_optim_4x4_windowed_loop.v")

        self.assertIn("localparam integer STATE_GROUP_ROWS = 4", text)
        self.assertIn("localparam integer K_SRAM_BANK_COUNT = 8", text)
        self.assertIn("localparam integer V_SRAM_BANK_COUNT = 8", text)
        self.assertIn("localparam integer OACC_SRAM_BANK_COUNT = 4", text)
        self.assertIn("FA_OACC_GROUP_SRAM_64X64X16", text)
        self.assertNotIn("reg [4095:0] q_tile_o_state_r [0:Q_TILES_PER_GROUP-1]", text)


if __name__ == "__main__":
    unittest.main()
