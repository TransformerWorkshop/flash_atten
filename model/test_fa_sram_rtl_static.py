import re
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
RTL_DIR = REPO_ROOT / "rtl"
RTL_SMOKE_DIR = REPO_ROOT / "sim" / "rtl_smoke"


def read_rtl(name: str) -> str:
    return (RTL_DIR / name).read_text(encoding="utf-8")


def read_rtl_smoke(name: str) -> str:
    return (RTL_SMOKE_DIR / name).read_text(encoding="utf-8")


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

    def test_optim_pipeline_prototype_has_rtl_counters_and_local_sram_banks(self):
        text = read_rtl("fa_optim_sa_pipeline_prototype.v")

        self.assertRegex(text, r"module\s+FA_OPTIM_SA_PIPELINE_PROTOTYPE\b")
        for port_name in (
            "cycles",
            "sa_busy_cycles",
            "feeder_busy_cycles",
            "row_state_busy_cycles",
            "qk_task_count",
            "pv_task_count",
            "oacc_task_count",
        ):
            self.assertIn(port_name, text)

        self.assertIn("parameter integer SRAM_BANK_COUNT = 21", text)
        self.assertRegex(text, r"FA_LOCAL_TILE_SRAM_16X64X16\s+u_bank")

    def test_optim_packed_pipeline_prototype_reuses_scheduler_with_nine_banks(self):
        text = read_rtl("fa_optim_sa_pipeline_prototype.v")

        self.assertRegex(text, r"module\s+FA_OPTIM_SA_PIPELINE_PACKED_PROTOTYPE\b")
        self.assertRegex(text, r"\.SRAM_BANK_COUNT\s*\(\s*9\s*\)")
        self.assertIn("packed_buffer_probe_data", text)

    def test_optim_packed_top_wraps_csr_and_packed_pipeline(self):
        text = read_rtl("fa_top_optim_packed.v")

        self.assertRegex(text, r"module\s+FA_TOP_OPTIM_PACKED\b")
        self.assertIn("FA_CSR u_fa_csr", text)
        self.assertIn("FA_OPTIM_SA_PIPELINE_PACKED_PROTOTYPE u_packed_core", text)
        self.assertIn("assign m_axi_arvalid = 1'b0", text)
        self.assertIn("assign m_axi_awvalid = 1'b0", text)
        self.assertIn("assign m_axi_wvalid = 1'b0", text)

    def test_optim_packed_top_smoke_checks_csr_cycles(self):
        text = read_rtl_smoke("fa_top_optim_packed_tb.v")

        self.assertRegex(text, r"module\s+fa_top_optim_packed_tb\b")
        self.assertIn("FA_TOP_OPTIM_PACKED dut", text)
        self.assertIn("axil_write(7'h00, 32'h0000_0001)", text)
        self.assertIn("axil_read(7'h40, read_data)", text)
        self.assertIn("32'd2242", text)

    def test_optim_packed_negative_smoke_covers_pv_feeder_reuse(self):
        text = read_rtl_smoke("fa_optim_sa_pipeline_packed_negative_tb.v")

        self.assertRegex(text, r"module\s+fa_optim_sa_pipeline_packed_negative_tb\b")
        self.assertRegex(text, r"\.PV_FEED_CYCLES\s*\(\s*16\s*\)")
        self.assertIn("32'd4418", text)
        self.assertIn("expect32(pv_feed_count, 32'd136", text)
        self.assertIn("expect32(feeder_busy_cycles, 32'd4352", text)
        self.assertIn("PASS: fa_optim_sa_pipeline_packed_negative_tb", text)

    def test_full_compute_smoke_uses_fixed_baseline_shape(self):
        text = read_rtl_smoke("fa_top_baseline_full_compute_tb.v")

        self.assertRegex(text, r"module\s+fa_top_baseline_full_compute_tb\b")
        self.assertIn("FA_TOP_BASELINE_SIM dut", text)
        self.assertIn("localparam integer SEQ_LEN = 256", text)
        self.assertIn("localparam integer HEAD_DIM = 64", text)
        self.assertIn("PASS: fa_top_baseline_full_compute_tb", text)
        self.assertIn("format=Q8.8", text)
        self.assertIn("rd_bytes=%0d", text)
        self.assertIn("wr_bytes=%0d", text)


if __name__ == "__main__":
    unittest.main()
