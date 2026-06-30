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

    def test_optim_4x4_micro_pipeline_uses_real_functional_blocks(self):
        text = read_rtl("fa_optim_4x4_micro_pipeline.v")

        self.assertRegex(text, r"module\s+FA_OPTIM_4X4_MICRO_PIPELINE\b")
        self.assertIn("GEMM_V3", text)
        self.assertRegex(text, r"\.X_DIM\s*\(\s*4\s*\)")
        self.assertRegex(text, r"\.Y_DIM\s*\(\s*4\s*\)")
        self.assertRegex(text, r"FA_SCORE_POST_REAL\s*#\s*\([\s\S]*?\)\s*u_score_post")
        self.assertRegex(text, r"FA_ROW_STATE_REAL\s*#\s*\([\s\S]*?\)\s*u_row_state")
        self.assertIn("FA_P_BYPASS_REAL u_p_bypass", text)
        self.assertRegex(text, r"FA_OACC_UPDATE_REAL\s*#\s*\([\s\S]*?\)\s*u_oacc_update")
        self.assertIn("o_tile_flat", text)
        self.assertNotIn("input  wire [16383:0] v_tile_flat", text)
        self.assertNotIn("input  wire [16383:0] k_tile_flat", text)
        self.assertIn("output wire          k_rd_req_valid", text)
        self.assertIn("input  wire          k_rd_req_ready", text)
        self.assertIn("output wire [4:0]    k_rd_req_pair_idx", text)
        self.assertIn("input  wire          k_rd_resp_valid", text)
        self.assertIn("input  wire [511:0]  k_rd_resp_data", text)
        self.assertIn("output wire          v_rd_req_valid", text)
        self.assertIn("input  wire          v_rd_req_ready", text)
        self.assertIn("output wire [1:0]    v_rd_req_wave_idx", text)
        self.assertIn("output wire [2:0]    v_rd_req_pair_idx", text)
        self.assertIn("input  wire          v_rd_resp_valid", text)
        self.assertIn("input  wire [511:0]  v_rd_resp_data", text)

    def test_optim_4x4_micro_pipeline_pipelines_qk_and_pv_feed(self):
        text = read_rtl("fa_optim_4x4_micro_pipeline.v")

        self.assertIn("ST_QK_REQ", text)
        self.assertIn("ST_QK_WAIT", text)
        self.assertIn("ST_QK_SEND", text)
        self.assertIn("qk_next_req_valid_w", text)
        self.assertIn("qk_next_req_fire_w", text)
        self.assertIn("gemm_valid_r = 4'hf", text)
        self.assertIn("qk_task_count <= qk_task_count + 32'd4", text)
        self.assertIn("k_rd_req_fire_w", text)
        self.assertIn("k_feed_data_r <= k_rd_resp_data", text)
        self.assertIn("state_r <= qk_next_req_fire_w ? ST_QK_WAIT : ST_QK_REQ", text)
        self.assertIn("ST_PV_WAIT", text)
        self.assertIn("pv_next_req_valid_w", text)
        self.assertIn("pv_next_req_fire_w", text)
        self.assertIn(".rd_en(v_rd_req_fire_w)", text)
        self.assertIn("v_feed_data_r <= v_rd_resp_data", text)
        self.assertIn("v_rd_req_fire_w", text)
        self.assertIn("state_r <= pv_next_req_fire_w ? ST_PV_WAIT : ST_PV_REQ", text)
        self.assertIn("gemm_valid_r = 4'hf", text)
        self.assertIn("pv_task_count <= pv_task_count + 32'd4", text)
        self.assertIn("first_kv_tile", text)
        self.assertIn("oacc_row_rd_data_r <= o_tile_flat", text)

    def test_optim_4x4_micro_pipeline_smoke_checks_output(self):
        text = read_rtl_smoke("fa_optim_4x4_micro_pipeline_tb.v")

        self.assertRegex(text, r"module\s+fa_optim_4x4_micro_pipeline_tb\b")
        self.assertIn("FA_OPTIM_4X4_MICRO_PIPELINE dut", text)
        self.assertIn(".first_kv_tile(first_kv_tile)", text)
        self.assertIn(".k_rd_req_valid(k_rd_req_valid)", text)
        self.assertIn("make_k_read_data", text)
        self.assertIn(".v_rd_req_valid(v_rd_req_valid)", text)
        self.assertIn("make_v_read_data", text)
        self.assertIn("expect_o_word", text)
        self.assertIn("expect_o_word_two_tiles", text)
        self.assertIn("run_tile(1'b0", text)
        self.assertIn("PASS: fa_optim_4x4_micro_pipeline_tb", text)

    def test_optim_4x4_full_loop_instantiates_real_micro_pipeline(self):
        rtl_path = RTL_DIR / "fa_optim_4x4_full_loop.v"
        self.assertTrue(rtl_path.exists(), "fa_optim_4x4_full_loop.v must exist")
        text = rtl_path.read_text(encoding="utf-8")

        self.assertRegex(text, r"module\s+FA_OPTIM_4X4_FULL_LOOP\b")
        self.assertIn("FA_OPTIM_4X4_Q_TILE_STAGGERED_CORE u_q_tile_core", text)
        self.assertIn("localparam integer Q_TILE_COUNT = 64", text)
        self.assertIn("localparam integer KV_TILE_COUNT = 16", text)
        self.assertNotIn("input  wire [16383:0] v_tile_flat", text)
        self.assertIn("localparam integer Q_TILE_BEATS = 64", text)
        self.assertIn("localparam integer K_TILE_BEATS = 256", text)
        self.assertIn("localparam integer V_TILE_BEATS = 256", text)
        self.assertIn("output wire         q_tile_req_valid", text)
        self.assertIn("input  wire [63:0]  q_tile_beat_data", text)
        self.assertIn("output wire         k_tile_req_valid", text)
        self.assertIn("input  wire [63:0]  k_tile_beat_data", text)
        self.assertIn("output wire         v_tile_req_valid", text)
        self.assertIn("input  wire         v_tile_req_ready", text)
        self.assertIn("output wire [4:0]   v_tile_req_kv_idx", text)
        self.assertIn("input  wire [63:0]  v_tile_beat_data", text)
        self.assertIn("wire q_tile_req_fire_w = q_tile_req_valid && q_tile_req_ready", text)
        self.assertIn("wire k_tile_req_fire_w = k_tile_req_valid && k_tile_req_ready", text)
        self.assertIn("wire v_tile_req_fire_w = v_tile_req_valid && v_tile_req_ready", text)
        self.assertIn("wire v_tile_beat_fire_w = v_tile_beat_valid && v_tile_beat_ready", text)
        self.assertNotIn("reg [16383:0] v_tile_flat_r", text)
        self.assertNotIn("wire [4095:0] q_block_flat_w = 4096'd0", text)
        self.assertNotIn("wire [16383:0] k_tile_flat_w = 16384'd0", text)
        self.assertIn("FA_LOCAL_TILE_SRAM_16X64X16 u_v_tile_sram", text)
        self.assertIn("reg [KV_TILE_COUNT-1:0] kv_resident_valid_r", text)
        self.assertIn("wire current_kv_resident_w", text)
        self.assertIn("wire current_k_rd_resident_w", text)
        self.assertIn("wire current_v_rd_resident_w", text)
        self.assertIn("localparam integer K_SRAM_BANK_COUNT = 16", text)
        self.assertIn("localparam integer V_SRAM_BANK_COUNT = 16", text)
        self.assertIn("state_n = ST_Q_LOAD_REQ", text)
        self.assertIn("wire [3:0] k_sram_wr_bank_idx_w = k_tile_beat_row_idx", text)
        self.assertIn("wire [3:0] k_sram_wr_row_idx_w = k_tile_req_kv_idx[3:0]", text)
        self.assertIn("wire [3:0] k_sram_rd_row_idx_w = micro_k_rd_req_kv_idx_w[3:0]", text)
        self.assertNotIn("k_sram_rd_resp_kv_idx_r", text)
        self.assertNotIn("16 + K_ELEM_BANK", text)
        self.assertIn("wire [3:0] v_sram_wr_bank_idx_w", text)
        self.assertIn(".k_rd_req_valid(micro_k_rd_req_valid_w)", text)
        self.assertIn(".k_rd_resp_data(micro_k_rd_resp_data_w)", text)
        self.assertIn(".wr_en(v_sram_wr_en_w[bank_gi])", text)
        self.assertIn(".v_rd_req_valid(micro_v_rd_req_valid_w)", text)
        self.assertIn(".v_rd_resp_data(micro_v_rd_resp_data_w)", text)
        self.assertIn("core_start_r <= 1'b1", text)
        self.assertIn("kv_block_issue_count", text)
        self.assertNotIn("FA_OPTIM_4X4_MICRO_PIPELINE u_micro_pipeline", text)
        self.assertIn("assign micro_tile_count = micro_tile_count_r", text)
        self.assertIn("micro_tile_count_r <= micro_tile_count_r + micro_tile_count_w", text)
        self.assertIn("kv_tile_count_r <= kv_tile_count_r + micro_kv_block_issue_count_w", text)
        self.assertIn("q_tile_count_r <= q_tile_count_r + 32'd1", text)
        self.assertNotIn("q_block_flat_r =", text)
        self.assertNotIn("k_tile_flat_r =", text)

    def test_optim_4x4_q_tile_staggered_core_uses_shared_real_pipes(self):
        text = read_rtl("fa_optim_4x4_q_tile_staggered_core.v")

        self.assertRegex(text, r"module\s+FA_OPTIM_4X4_Q_TILE_STAGGERED_CORE\b")
        self.assertIn("localparam integer SLOT_COUNT = 4", text)
        self.assertIn("kv_block_issue_count", text)
        self.assertIn("GEMM_V3", text)
        self.assertRegex(text, r"\.X_DIM\s*\(\s*4\s*\)")
        self.assertRegex(text, r"\.Y_DIM\s*\(\s*4\s*\)")
        self.assertRegex(text, r"FA_SCORE_POST_REAL\s*#\s*\([\s\S]*?\)\s*u_score_post")
        self.assertRegex(text, r"FA_ROW_STATE_REAL\s*#\s*\([\s\S]*?\)\s*u_row_state")
        self.assertIn("row_p_block_flat", text)
        self.assertRegex(text, r"FA_OACC_UPDATE_REAL\s*#\s*\([\s\S]*?\)\s*u_oacc_update")
        self.assertIn("slot_score_block_flat_r", text)
        self.assertIn("slot_p_block_flat_r", text)
        self.assertIn("slot_rescale_block_flat_r", text)
        self.assertNotIn("slot_p_tile_flat_r", text)
        self.assertNotIn("slot_rescale_vec_flat_r", text)
        self.assertIn("slot_p_block_flat_r[row_active_slot_r] <= p_tile_flat_w[1023:0]", text)
        self.assertIn("slot_rescale_block_flat_r[row_active_slot_r] <= rescale_vec_flat_w[127:0]", text)
        self.assertIn("slot_partial_o_row_r", text)
        self.assertIn("o_tile_row_r", text)
        self.assertIn(".USE_PARTIAL_ROW_INPUT(1)", text)
        self.assertIn(".USE_PARTIAL_BLOCK_INPUT(0)", text)
        self.assertIn(".partial_row_rd_valid(partial_row_rd_valid_r)", text)
        self.assertIn(".partial_row_rd_data(partial_row_rd_data_r)", text)
        self.assertIn("assign o_tile_flat[1023:0] = o_tile_row_r[0]", text)
        self.assertNotIn("slot_partial_o_block_flat_r", text)
        self.assertNotIn("oacc_partial_o_block_flat_w", text)
        self.assertNotIn("partial_o_block_flat(oacc_partial_o_block_flat_w)", text)
        self.assertIn("pv_can_issue_w", text)
        self.assertIn("qk_can_issue_w", text)
        self.assertIn("KV_TILE_COUNT_W = 5'd16", text)
        self.assertIn("input  wire [4:0]    kv_base_idx", text)
        self.assertIn("input  wire [4:0]    kv_count", text)
        self.assertIn("input  wire          first_kv_window", text)
        self.assertIn("input  wire          last_kv_window", text)
        self.assertIn("wire [4:0] kv_end_idx_w", text)
        self.assertIn("wire run_full_kv_range_w", text)
        self.assertIn("wire full_range_flag_invalid_w", text)
        self.assertIn("row_init_valid_r <= first_kv_window", text)
        self.assertIn("qk_issue_kv_idx_r <= kv_base_idx_w", text)
        self.assertIn("row_next_kv_idx_r <= kv_base_idx_w", text)
        self.assertIn("pv_next_kv_idx_r <= kv_base_idx_w", text)
        self.assertIn("oacc_next_kv_idx_r <= kv_base_idx_w", text)
        self.assertIn("if (oacc_next_kv_idx_r == (kv_end_idx_w - 5'd1))", text)

    def test_optim_windowed_scheduler_contract_exists(self):
        rtl_path = RTL_DIR / "fa_optim_windowed_sched_contract.v"
        self.assertTrue(rtl_path.exists(), "windowed scheduler contract RTL must exist")
        text = rtl_path.read_text(encoding="utf-8")

        self.assertRegex(text, r"module\s+FA_OPTIM_WINDOWED_SCHED_CONTRACT\b")
        for param_name in (
            "SEQ_LEN = 256",
            "HEAD_DIM = 64",
            "Q_GROUP_ROWS = 64",
            "Q_TILE_ROWS = 4",
            "KV_TILE_ROWS = 16",
            "KV_WINDOW_TILES = 4",
            "SCORE_SLICE_COLS = 4",
            "OACC_SLICE_COLS = 16",
        ):
            self.assertIn(param_name, text)

        for port_name in (
            "q_tile_req_valid",
            "q_tile_req_ready",
            "q_tile_req_q_idx",
            "k_tile_req_valid",
            "k_tile_req_ready",
            "k_tile_req_kv_idx",
            "v_tile_req_valid",
            "v_tile_req_ready",
            "v_tile_req_kv_idx",
            "q_group_count",
            "kv_window_count",
            "q_tile_visit_count",
            "kv_tile_compute_count",
            "skipped_future_kv_tiles",
            "score_slice_count",
            "oacc_slice_count",
            "state_fill_count",
            "state_spill_count",
        ):
            self.assertIn(port_name, text)

        self.assertIn("wire current_kv_tile_fully_future_w", text)
        self.assertIn("kv_window_base_idx_w", text)
        self.assertIn("q_group_idx_r", text)
        self.assertIn("q_tile_in_group_idx_r", text)

    def test_optim_windowed_scheduler_smoke_checks_contract_counters(self):
        text = read_rtl_smoke("fa_optim_windowed_sched_contract_tb.v")

        self.assertRegex(text, r"module\s+fa_optim_windowed_sched_contract_tb\b")
        self.assertIn("FA_OPTIM_WINDOWED_SCHED_CONTRACT dut", text)
        self.assertIn("run_case(1'b0", text)
        self.assertIn("run_case(1'b1", text)
        self.assertIn("expect32(q_group_count, 32'd4", text)
        self.assertIn("expect32(kv_window_count, 32'd16", text)
        self.assertIn("expect32(q_tile_visit_count, 32'd256", text)
        self.assertIn("expect32(kv_tile_compute_count, 32'd1024", text)
        self.assertIn("expect32(kv_tile_compute_count, 32'd544", text)
        self.assertIn("expect32(skipped_future_kv_tiles, 32'd480", text)
        self.assertIn("expect32(score_slice_count, 32'd4096", text)
        self.assertIn("expect32(oacc_slice_count, 32'd4096", text)
        self.assertIn("expect32(state_fill_count, 32'd256", text)
        self.assertIn("expect32(state_spill_count, 32'd256", text)
        self.assertIn("PASS: fa_optim_windowed_sched_contract_tb", text)

    def test_optim_windowed_real_core_top_lands_scheduler_into_staggered_core(self):
        rtl_path = RTL_DIR / "fa_optim_4x4_windowed_loop.v"
        self.assertTrue(rtl_path.exists(), "windowed real-core loop RTL must exist")
        text = rtl_path.read_text(encoding="utf-8")

        self.assertRegex(text, r"module\s+FA_OPTIM_4X4_WINDOWED_LOOP\b")
        self.assertIn("localparam integer Q_GROUP_ROWS = 64", text)
        self.assertIn("localparam integer KV_WINDOW_TILES = 4", text)
        self.assertIn("FA_OPTIM_4X4_Q_TILE_STAGGERED_CORE u_q_tile_core", text)
        self.assertIn(".kv_base_idx(core_kv_base_idx_w)", text)
        self.assertIn(".kv_count(5'd4)", text)
        self.assertIn(".first_kv_window(core_first_kv_window_w)", text)
        self.assertIn(".last_kv_window(core_last_kv_window_w)", text)
        self.assertIn("wire [4:0] core_kv_base_idx_w", text)
        self.assertIn("wire core_first_kv_window_w", text)
        self.assertIn("wire core_last_kv_window_w", text)
        self.assertIn("reg [1:0] q_group_idx_r", text)
        self.assertIn("reg [1:0] kv_window_idx_r", text)
        self.assertIn("reg [3:0] q_tile_in_group_idx_r", text)
        self.assertIn("q_tile_visit_count", text)
        self.assertIn("state_fill_count", text)
        self.assertIn("state_spill_count", text)
        self.assertIn("kv_tile_count_r <= kv_tile_count_r + micro_kv_block_issue_count_w", text)
        self.assertIn("q_tile_visit_count_r <= q_tile_visit_count_r + 32'd1", text)
        self.assertNotIn("FA_OPTIM_WINDOWED_SCHED_CONTRACT", text)

    def test_optim_windowed_real_core_top_uses_window_local_sram_layout(self):
        text = read_rtl("fa_optim_4x4_windowed_loop.v")

        self.assertIn("wire [3:0] k_sram_wr_bank_idx_w = k_tile_beat_row_idx", text)
        self.assertIn("wire [3:0] k_sram_wr_row_idx_w = {2'd0, kv_load_slot_idx_r}", text)
        self.assertIn("wire [3:0] k_sram_wr_chunk_idx_w = k_tile_beat_chunk_idx", text)
        self.assertIn("wire [3:0] k_sram_rd_row_idx_w = {2'd0, k_sram_rd_slot_idx_w[1:0]}", text)
        self.assertIn("wire [3:0] k_sram_rd_chunk_idx_w = micro_k_rd_req_pair_idx_w[4:1]", text)
        self.assertIn("wire [3:0] v_sram_wr_bank_idx_w = {1'b0, v_tile_beat_row_idx[0], v_tile_beat_chunk_idx[1:0]}", text)
        self.assertIn("wire [3:0] v_sram_wr_row_idx_w = {1'b0, kv_load_slot_idx_r, v_tile_beat_row_idx[3]}", text)
        self.assertIn("wire [3:0] v_sram_wr_chunk_idx_w = {v_tile_beat_row_idx[2:1], v_tile_beat_chunk_idx[3:2]}", text)
        self.assertIn("wire [3:0] v_sram_rd_row_idx_w = {1'b0, v_sram_rd_slot_idx_w[1:0], micro_v_rd_req_pair_idx_w[2]}", text)
        self.assertIn("wire [3:0] v_sram_rd_chunk_idx_w = {micro_v_rd_req_pair_idx_w[1:0], micro_v_rd_req_wave_idx_w}", text)
        self.assertIn("v_sram_rd_resp_kv_idx_r <= {3'd0, micro_v_rd_window_slot_idx_w}", text)

    def test_optim_staggered_core_exposes_window_state_snapshot_ports(self):
        text = read_rtl("fa_optim_4x4_q_tile_staggered_core.v")

        for port_decl in (
            "input  wire          restore_state_valid",
            "input  wire [511:0]  restore_m_state_flat",
            "input  wire [511:0]  restore_l_state_flat",
            "input  wire [15:0]   restore_row_seen",
            "input  wire [4095:0] restore_o_tile_flat",
            "output wire [511:0]  snapshot_m_state_flat",
            "output wire [511:0]  snapshot_l_state_flat",
            "output wire [15:0]   snapshot_row_seen",
        ):
            self.assertIn(port_decl, text)

        self.assertIn("row_init_valid_r <= first_kv_window || restore_state_valid", text)
        self.assertIn(".restore_valid(restore_state_valid)", text)
        self.assertIn(".restore_m_state_flat(restore_m_state_flat)", text)
        self.assertIn(".debug_m_state_flat(snapshot_m_state_flat)", text)
        self.assertIn("o_tile_row_r[o_row_i] <= restore_o_tile_flat[(o_row_i * 1024) +: 1024]", text)

    def test_row_state_real_can_restore_snapshot(self):
        text = read_rtl("fa_row_state_real.v")

        for port_decl in (
            "input  wire          restore_valid",
            "input  wire [511:0]  restore_m_state_flat",
            "input  wire [511:0]  restore_l_state_flat",
            "input  wire [15:0]   restore_row_seen",
        ):
            self.assertIn(port_decl, text)

        self.assertIn("m_state_r[row_i] <= restore_m_state_flat[(row_i * 32) +: 32]", text)
        self.assertIn("l_state_r[row_i] <= restore_l_state_flat[(row_i * 32) +: 32]", text)
        self.assertIn("row_seen_r[row_i] <= restore_row_seen[row_i]", text)

    def test_optim_windowed_top_persists_q_tile_state_snapshots(self):
        text = read_rtl("fa_optim_4x4_windowed_loop.v")

        self.assertIn("reg [511:0] q_tile_m_state_r [0:Q_TILES_PER_GROUP-1]", text)
        self.assertIn("reg [511:0] q_tile_l_state_r [0:Q_TILES_PER_GROUP-1]", text)
        self.assertIn("reg [15:0] q_tile_row_seen_r [0:Q_TILES_PER_GROUP-1]", text)
        self.assertIn("reg [4095:0] q_tile_o_state_r [0:Q_TILES_PER_GROUP-1]", text)
        self.assertIn(".restore_state_valid(!core_first_kv_window_w)", text)
        self.assertIn(".restore_m_state_flat(q_tile_m_state_r[q_tile_in_group_idx_r])", text)
        self.assertIn(".restore_o_tile_flat(q_tile_o_state_r[q_tile_in_group_idx_r])", text)
        self.assertIn("q_tile_m_state_r[q_tile_in_group_idx_r] <= micro_snapshot_m_state_w", text)
        self.assertIn("q_tile_o_state_r[q_tile_in_group_idx_r] <= o_block_flat", text)

    def test_optim_4x4_full_loop_smoke_checks_s256(self):
        smoke_path = RTL_SMOKE_DIR / "fa_optim_4x4_full_loop_tb.v"
        self.assertTrue(smoke_path.exists(), "fa_optim_4x4_full_loop_tb.v must exist")
        text = smoke_path.read_text(encoding="utf-8")

        self.assertRegex(text, r"module\s+fa_optim_4x4_full_loop_tb\b")
        self.assertIn("FA_OPTIM_4X4_FULL_LOOP dut", text)
        self.assertIn("localparam integer EXPECTED_MICRO_TILES = 1024", text)
        self.assertIn("expect32(micro_tile_count, 32'd1024", text)
        self.assertIn("expect32(q_tile_count, 32'd64", text)
        self.assertIn("expect32(kv_tile_count, 32'd1024", text)
        self.assertIn("expect32(q_tile_req_count, 32'd64", text)
        self.assertIn("expect32(q_tile_beat_count, 32'd4096", text)
        self.assertIn("localparam integer MAX_EXPECTED_CYCLES = 123202", text)
        self.assertIn("expect32(k_tile_req_count, 32'd16", text)
        self.assertIn("expect32(k_tile_beat_count, 32'd4096", text)
        self.assertIn("expect32(v_tile_req_count, 32'd16", text)
        self.assertIn("expect32(v_tile_beat_count, 32'd4096", text)
        self.assertIn("task drive_q_tile_beats", text)
        self.assertIn("task drive_k_tile_beats", text)
        self.assertIn("task check_k_sram_folded_layout", text)
        self.assertIn("expect64(k_folded_word", text)
        self.assertIn("task drive_v_tile_beats", text)
        self.assertIn("for (kv_i = 0; kv_i < EXPECTED_K_TILE_REQS", text)
        self.assertIn("wait (q_tile_req_valid === 1'b1)", text)
        self.assertIn("wait (k_tile_req_valid === 1'b1)", text)
        self.assertIn("wait (v_tile_req_valid === 1'b1)", text)
        self.assertIn("PASS: fa_optim_4x4_full_loop_tb", text)

    def test_optim_4x4_full_loop_has_dc_nand2_script(self):
        script_path = REPO_ROOT / "scripts" / "fa_optim_4x4_full_loop_area.tcl"
        self.assertTrue(script_path.exists(), "fa_optim_4x4_full_loop_area.tcl must exist")
        text = script_path.read_text(encoding="utf-8")

        self.assertIn("set top_name [getenv_default FA_TOP FA_OPTIM_4X4_FULL_LOOP]", text)
        self.assertIn("set sram_db_list [getenv_default FA_SRAM_DB_LIST \"\"]", text)
        self.assertIn("set k_sram_count 16", text)
        self.assertIn("set v_sram_count 16", text)
        self.assertIn("set total_sram_count [expr {$k_sram_count + $v_sram_count}]", text)
        self.assertIn("total_sram_nand2", text)
        self.assertIn("fa_sram_hard.v", text)
        self.assertIn("fa_sram_tile_buffers.v", text)
        self.assertIn("fa_optim_windowed_sched_contract.v", text)
        self.assertIn("fa_optim_4x4_full_loop.v", text)
        self.assertIn("fa_optim_4x4_windowed_loop.v", text)
        self.assertIn("fa_optim_4x4_q_tile_staggered_core.v", text)
        self.assertNotIn("fa_optim_4x4_micro_pipeline.v", text)
        self.assertIn("report_area -hierarchy", text)
        self.assertIn("set compile_mode [getenv_default FA_COMPILE_MODE ultra]", text)
        self.assertIn("compile -exact_map", text)
        self.assertIn("compile -map_effort low -area_effort low", text)
        self.assertIn("ND2D0BWP7T40P140", text)
        self.assertIn("CODEX_FA_OPTIM_FULL_LOOP_DC_NAND2", text)
        self.assertIn("proc get_area_report_value_or_zero", text)
        self.assertIn("Total cell area", text)
        self.assertIn("Macro/Black Box area", text)
        self.assertIn("full_mapped=1", text)
        self.assertIn("total_nand2", text)
        self.assertIn("logic_nand2", text)

    def test_optim_4x4_full_loop_has_hier_area_fallback(self):
        script_path = REPO_ROOT / "scripts" / "fa_optim_4x4_full_loop_area.tcl"
        self.assertTrue(script_path.exists(), "fa_optim_4x4_full_loop_area.tcl must exist")
        text = script_path.read_text(encoding="utf-8")

        self.assertIn("hier_area", text)
        self.assertIn("write_hier_area_log", text)
        self.assertIn("CODEX_FA_OPTIM_FULL_LOOP_DC_HIER_AREA", text)
        self.assertIn("FA_OPTIM_4X4_Q_TILE_STAGGERED_CORE", text)
        self.assertIn("full_mapped=0", text)

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
