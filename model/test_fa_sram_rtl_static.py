import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
RTL_DIR = REPO_ROOT / "rtl"


def read_rtl(name: str) -> str:
    return (RTL_DIR / name).read_text(encoding="utf-8")


class FaSramRtlStaticTest(unittest.TestCase):
    def test_tsmc_same_spec_macro_stubs_exist(self):
        text = read_rtl("tsmc_sram_macros.v")

        self.assertRegex(text, r"module\s+TEM5N28HPCPLVTA256X64M4SWSO\b")
        self.assertRegex(text, r"module\s+TEM5N28HPCPLVTA256X32M4SWSO\b")
        self.assertRegex(text, r"input\s+wire\s+\[7:0\]\s+A")
        self.assertRegex(text, r"input\s+wire\s+\[63:0\]\s+D")
        self.assertRegex(text, r"input\s+wire\s+\[31:0\]\s+D")

    def test_process_neutral_wrappers_map_to_tsmc_for_now(self):
        text = read_rtl("fa_sram_hard.v")

        for module_name in (
            "FA_SRAM256X64_1RW",
            "FA_SRAM256X32_1RW",
            "FA_SKY130_SRAM_256X64_1RW",
            "FA_SKY130_SRAM_256X32_1RW",
        ):
            self.assertRegex(text, rf"module\s+{module_name}\b")

        self.assertIn("TEM5N28HPCPLVTA256X64M4SWSO", text)
        self.assertIn("TEM5N28HPCPLVTA256X32M4SWSO", text)
        self.assertIn("wire        macro_ceb = ~en;", text)
        self.assertIn("wire        macro_web = ~we;", text)

    def test_storage_native_tile_scaffold_exists(self):
        text = read_rtl("fa_sram_tile_buffers.v")

        self.assertRegex(text, r"module\s+FA_LOCAL_TILE_SRAM_16X64X16\b")
        self.assertRegex(text, r"input\s+wire\s+\[3:0\]\s+wr_row_idx")
        self.assertRegex(text, r"input\s+wire\s+\[3:0\]\s+wr_chunk_idx")
        self.assertRegex(text, r"input\s+wire\s+\[63:0\]\s+wr_data")
        self.assertRegex(text, r"FA_SKY130_SRAM_256X64_1RW\s+u_sram")


if __name__ == "__main__":
    unittest.main()
