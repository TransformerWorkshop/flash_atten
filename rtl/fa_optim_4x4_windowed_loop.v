module FA_OPTIM_4X4_WINDOWED_LOOP (
    input  wire         clk,
    input  wire         rstn,
    input  wire         clear,
    input  wire         start,
    output wire         q_tile_req_valid,
    input  wire         q_tile_req_ready,
    output wire [5:0]   q_tile_req_q_idx,
    input  wire         q_tile_beat_valid,
    output wire         q_tile_beat_ready,
    input  wire [1:0]   q_tile_beat_row_idx,
    input  wire [3:0]   q_tile_beat_chunk_idx,
    input  wire [63:0]  q_tile_beat_data,
    input  wire         q_tile_beat_last,
    output wire         k_tile_req_valid,
    input  wire         k_tile_req_ready,
    output wire [4:0]   k_tile_req_kv_idx,
    input  wire         k_tile_beat_valid,
    output wire         k_tile_beat_ready,
    input  wire [3:0]   k_tile_beat_row_idx,
    input  wire [3:0]   k_tile_beat_chunk_idx,
    input  wire [63:0]  k_tile_beat_data,
    input  wire         k_tile_beat_last,
    output wire         v_tile_req_valid,
    input  wire         v_tile_req_ready,
    output wire [4:0]   v_tile_req_kv_idx,
    input  wire         v_tile_beat_valid,
    output wire         v_tile_beat_ready,
    input  wire [3:0]   v_tile_beat_row_idx,
    input  wire [3:0]   v_tile_beat_chunk_idx,
    input  wire [63:0]  v_tile_beat_data,
    input  wire         v_tile_beat_last,
    output wire         busy,
    output wire         done,
    output wire         error,
    output wire [31:0]  cycles,
    output wire [31:0]  micro_tile_count,
    output wire [31:0]  q_group_count,
    output wire [31:0]  kv_window_count,
    output wire [31:0]  q_tile_visit_count,
    output wire [31:0]  kv_tile_count,
    output wire [31:0]  q_tile_req_count,
    output wire [31:0]  q_tile_beat_count,
    output wire [31:0]  k_tile_req_count,
    output wire [31:0]  k_tile_beat_count,
    output wire [31:0]  v_tile_req_count,
    output wire [31:0]  v_tile_beat_count,
    output wire [31:0]  state_fill_count,
    output wire [31:0]  state_spill_count,
    output wire [31:0]  qk_task_count,
    output wire [31:0]  pv_task_count,
    output wire [31:0]  oacc_task_count,
    output wire         o_dump_valid,
    input  wire         o_dump_ready,
    output wire [1:0]   o_dump_group_idx,
    output wire [10:0]  o_dump_word_idx,
    output wire [31:0]  o_dump_word,
    output wire         o_dump_last,
    output wire [4095:0] o_block_flat
);

    localparam integer SEQ_LEN = 256;
    localparam integer HEAD_DIM = 64;
    localparam integer Q_GROUP_ROWS = 64;
    localparam integer Q_TILE_ROWS = 4;
    localparam integer Q_TILES_PER_GROUP = 16;
    localparam integer Q_GROUP_COUNT = 4;
    localparam integer KV_TILE_COUNT = 16;
    localparam integer KV_WINDOW_TILES = 4;
    localparam integer KV_WINDOWS_PER_GROUP = 4;
    localparam integer Q_TILE_BEATS = 64;
    localparam integer K_TILE_BEATS = 256;
    localparam integer V_TILE_BEATS = 256;
    localparam integer K_SRAM_BANK_COUNT = 16;
    localparam integer V_SRAM_BANK_COUNT = 16;
    localparam integer O_DUMP_WORDS_PER_GROUP = 2048;

    localparam [3:0] ST_IDLE        = 4'd0;
    localparam [3:0] ST_GROUP_START = 4'd1;
    localparam [3:0] ST_K_LOAD_REQ  = 4'd2;
    localparam [3:0] ST_K_LOAD_WAIT = 4'd3;
    localparam [3:0] ST_V_LOAD_REQ  = 4'd4;
    localparam [3:0] ST_V_LOAD_WAIT = 4'd5;
    localparam [3:0] ST_Q_LOAD_REQ  = 4'd6;
    localparam [3:0] ST_Q_LOAD_WAIT = 4'd7;
    localparam [3:0] ST_START_TILE  = 4'd8;
    localparam [3:0] ST_WAIT_TILE   = 4'd9;
    localparam [3:0] ST_DUMP_GROUP  = 4'd10;
    localparam [3:0] ST_DONE        = 4'd11;

    reg [3:0] state_r;
    reg [3:0] state_n;
    reg [1:0] q_group_idx_r;
    reg [1:0] kv_window_idx_r;
    reg [1:0] kv_load_slot_idx_r;
    reg [3:0] q_tile_in_group_idx_r;
    reg [6:0] q_tile_load_count_r;
    reg [8:0] k_tile_load_count_r;
    reg [8:0] v_tile_load_count_r;
    reg [1:0] o_dump_group_idx_r;
    reg [10:0] o_dump_word_idx_r;
    reg busy_r;
    reg done_r;
    reg error_r;
    reg core_start_r;
    reg [31:0] cycles_r;
    reg [31:0] micro_tile_count_r;
    reg [31:0] q_group_count_r;
    reg [31:0] kv_window_count_r;
    reg [31:0] q_tile_visit_count_r;
    reg [31:0] kv_tile_count_r;
    reg [31:0] q_tile_req_count_r;
    reg [31:0] q_tile_beat_count_r;
    reg [31:0] k_tile_req_count_r;
    reg [31:0] k_tile_beat_count_r;
    reg [31:0] v_tile_req_count_r;
    reg [31:0] v_tile_beat_count_r;
    reg [31:0] state_fill_count_r;
    reg [31:0] state_spill_count_r;
    reg [31:0] qk_task_count_r;
    reg [31:0] pv_task_count_r;
    reg [31:0] oacc_task_count_r;
    reg [4095:0] q_block_flat_r;
    reg [KV_WINDOW_TILES-1:0] kv_window_resident_valid_r;
    reg [511:0] q_tile_m_state_r [0:Q_TILES_PER_GROUP-1];
    reg [511:0] q_tile_l_state_r [0:Q_TILES_PER_GROUP-1];
    reg [15:0] q_tile_row_seen_r [0:Q_TILES_PER_GROUP-1];
    reg [4095:0] q_tile_o_state_r [0:Q_TILES_PER_GROUP-1];

    wire [5:0] q_group_base_tile_idx_w = {q_group_idx_r, 4'd0};
    wire [5:0] q_current_tile_idx_w = q_group_base_tile_idx_w + {2'd0, q_tile_in_group_idx_r};
    wire [4:0] kv_window_base_idx_w = {1'b0, kv_window_idx_r, 2'b00};
    wire [4:0] kv_load_tile_idx_w = kv_window_base_idx_w + {3'd0, kv_load_slot_idx_r};
    wire [4:0] core_kv_base_idx_w = kv_window_base_idx_w;
    wire core_first_kv_window_w = (kv_window_idx_r == 2'd0);
    wire core_last_kv_window_w = (kv_window_idx_r == (KV_WINDOWS_PER_GROUP - 1));
    wire window_is_last_q_tile_w = (q_tile_in_group_idx_r == (Q_TILES_PER_GROUP - 1));
    wire group_is_last_window_w = (kv_window_idx_r == (KV_WINDOWS_PER_GROUP - 1));
    wire group_is_last_group_w = (q_group_idx_r == (Q_GROUP_COUNT - 1));
    wire o_dump_fire_w = o_dump_valid && o_dump_ready;
    wire o_dump_last_word_w = (o_dump_word_idx_r == (O_DUMP_WORDS_PER_GROUP - 1));
    wire [3:0] o_dump_q_tile_idx_w = o_dump_word_idx_r[10:7];
    wire [6:0] o_dump_word_in_tile_w = o_dump_word_idx_r[6:0];

    wire q_tile_req_fire_w = q_tile_req_valid && q_tile_req_ready;
    wire q_tile_beat_fire_w = q_tile_beat_valid && q_tile_beat_ready;
    wire q_tile_last_beat_count_w = (q_tile_load_count_r == (Q_TILE_BEATS - 1));
    wire q_tile_load_done_w = q_tile_beat_fire_w && q_tile_last_beat_count_w;
    wire q_tile_last_mismatch_w = q_tile_beat_fire_w
                                && (q_tile_beat_last != q_tile_last_beat_count_w);
    wire k_tile_req_fire_w = k_tile_req_valid && k_tile_req_ready;
    wire k_tile_beat_fire_w = k_tile_beat_valid && k_tile_beat_ready;
    wire k_tile_last_beat_count_w = (k_tile_load_count_r == (K_TILE_BEATS - 1));
    wire k_tile_load_done_w = k_tile_beat_fire_w && k_tile_last_beat_count_w;
    wire k_tile_last_mismatch_w = k_tile_beat_fire_w
                                && (k_tile_beat_last != k_tile_last_beat_count_w);
    wire v_tile_req_fire_w = v_tile_req_valid && v_tile_req_ready;
    wire v_tile_beat_fire_w = v_tile_beat_valid && v_tile_beat_ready;
    wire v_tile_last_beat_count_w = (v_tile_load_count_r == (V_TILE_BEATS - 1));
    wire v_tile_load_done_w = v_tile_beat_fire_w && v_tile_last_beat_count_w;
    wire v_tile_last_mismatch_w = v_tile_beat_fire_w
                                && (v_tile_beat_last != v_tile_last_beat_count_w);

    wire micro_k_rd_req_valid_w;
    wire micro_k_rd_req_ready_w;
    wire [4:0] micro_k_rd_req_kv_idx_w;
    wire [4:0] micro_k_rd_req_pair_idx_w;
    wire micro_k_rd_resp_valid_w;
    wire [511:0] micro_k_rd_resp_data_w;
    wire micro_v_rd_req_valid_w;
    wire micro_v_rd_req_ready_w;
    wire [4:0] micro_v_rd_req_kv_idx_w;
    wire [1:0] micro_v_rd_req_wave_idx_w;
    wire [2:0] micro_v_rd_req_pair_idx_w;
    wire micro_v_rd_resp_valid_w;
    wire [511:0] micro_v_rd_resp_data_w;
    wire micro_busy_w;
    wire micro_done_w;
    wire micro_error_w;
    wire [31:0] micro_cycles_w;
    wire [31:0] micro_tile_count_w;
    wire [31:0] micro_kv_block_issue_count_w;
    wire [31:0] micro_qk_task_count_w;
    wire [31:0] micro_score_task_count_w;
    wire [31:0] micro_row_state_task_count_w;
    wire [31:0] micro_pv_task_count_w;
    wire [31:0] micro_oacc_task_count_w;
    wire [511:0] micro_snapshot_m_state_w;
    wire [511:0] micro_snapshot_l_state_w;
    wire [15:0] micro_snapshot_row_seen_w;

    wire [3:0] k_sram_wr_bank_idx_w = k_tile_beat_row_idx;
    wire [3:0] k_sram_wr_row_idx_w = {2'd0, kv_load_slot_idx_r};
    wire [3:0] k_sram_wr_chunk_idx_w = k_tile_beat_chunk_idx;
    wire [3:0] k_sram_rd_slot_idx_w = micro_k_rd_req_kv_idx_w - core_kv_base_idx_w;
    wire [3:0] k_sram_rd_row_idx_w = {2'd0, k_sram_rd_slot_idx_w[1:0]};
    wire [3:0] k_sram_rd_chunk_idx_w = micro_k_rd_req_pair_idx_w[4:1];
    wire [K_SRAM_BANK_COUNT-1:0] k_sram_wr_en_w;
    wire [K_SRAM_BANK_COUNT-1:0] k_sram_rd_valid_w;
    wire [15:0] k_sram_selected_rd_valid_w;
    wire [63:0] k_sram_rd_data_w [0:K_SRAM_BANK_COUNT-1];
    wire k_sram_rd_fire_w;
    reg [4:0] k_sram_rd_resp_pair_idx_r;

    wire [3:0] v_sram_wr_bank_idx_w = {kv_load_slot_idx_r[1], v_tile_beat_row_idx[0], v_tile_beat_chunk_idx[1:0]};
    wire [3:0] v_sram_wr_row_idx_w = {1'b0, kv_load_slot_idx_r, v_tile_beat_row_idx[3]};
    wire [3:0] v_sram_wr_chunk_idx_w = {v_tile_beat_row_idx[2:1], v_tile_beat_chunk_idx[3:2]};
    wire [3:0] v_sram_rd_slot_idx_w = micro_v_rd_req_kv_idx_w - core_kv_base_idx_w;
    wire [3:0] v_sram_rd_row_idx_w = {1'b0, v_sram_rd_slot_idx_w[1:0], micro_v_rd_req_pair_idx_w[2]};
    wire [3:0] v_sram_rd_chunk_idx_w = {micro_v_rd_req_pair_idx_w[1:0], micro_v_rd_req_wave_idx_w};
    wire [V_SRAM_BANK_COUNT-1:0] v_sram_wr_en_w;
    wire [V_SRAM_BANK_COUNT-1:0] v_sram_rd_valid_w;
    wire [7:0] v_sram_selected_rd_valid_w;
    wire [63:0] v_sram_rd_data_w [0:V_SRAM_BANK_COUNT-1];
    wire v_sram_rd_fire_w;
    reg [4:0] v_sram_rd_resp_kv_idx_r;

    wire window_resident_valid_w = &kv_window_resident_valid_r;
    wire [1:0] micro_k_rd_window_slot_idx_w = k_sram_rd_slot_idx_w[1:0];
    wire [1:0] micro_v_rd_window_slot_idx_w = v_sram_rd_slot_idx_w[1:0];
    wire current_k_rd_resident_w =
        kv_window_resident_valid_r[micro_k_rd_window_slot_idx_w];
    wire current_v_rd_resident_w =
        kv_window_resident_valid_r[micro_v_rd_window_slot_idx_w];
    wire unused_micro_counts_w = ((|micro_cycles_w) & 1'b0)
                               | ((|micro_score_task_count_w) & 1'b0)
                               | ((|micro_row_state_task_count_w) & 1'b0)
                               | (micro_busy_w & 1'b0)
                               | (window_resident_valid_w & 1'b0);
    wire config_invalid_w = (SEQ_LEN != 256)
                          || (HEAD_DIM != 64)
                          || (Q_TILE_ROWS != 4)
                          || (KV_TILE_COUNT != 16)
                          || unused_micro_counts_w;

    integer q_tile_state_i;

    assign q_tile_req_valid = (state_r == ST_Q_LOAD_REQ);
    assign q_tile_req_q_idx = q_current_tile_idx_w;
    assign q_tile_beat_ready = (state_r == ST_Q_LOAD_WAIT);
    assign k_tile_req_valid = (state_r == ST_K_LOAD_REQ);
    assign k_tile_req_kv_idx = kv_load_tile_idx_w;
    assign k_tile_beat_ready = (state_r == ST_K_LOAD_WAIT);
    assign v_tile_req_valid = (state_r == ST_V_LOAD_REQ);
    assign v_tile_req_kv_idx = kv_load_tile_idx_w;
    assign v_tile_beat_ready = (state_r == ST_V_LOAD_WAIT);
    assign busy = busy_r;
    assign done = done_r;
    assign error = error_r;
    assign cycles = cycles_r;
    assign micro_tile_count = micro_tile_count_r;
    assign q_group_count = q_group_count_r;
    assign kv_window_count = kv_window_count_r;
    assign q_tile_visit_count = q_tile_visit_count_r;
    assign kv_tile_count = kv_tile_count_r;
    assign q_tile_req_count = q_tile_req_count_r;
    assign q_tile_beat_count = q_tile_beat_count_r;
    assign k_tile_req_count = k_tile_req_count_r;
    assign k_tile_beat_count = k_tile_beat_count_r;
    assign v_tile_req_count = v_tile_req_count_r;
    assign v_tile_beat_count = v_tile_beat_count_r;
    assign state_fill_count = state_fill_count_r;
    assign state_spill_count = state_spill_count_r;
    assign qk_task_count = qk_task_count_r;
    assign pv_task_count = pv_task_count_r;
    assign oacc_task_count = oacc_task_count_r;

    FA_OPTIM_4X4_Q_TILE_STAGGERED_CORE u_q_tile_core (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(core_start_r),
        .q_block_flat(q_block_flat_r),
        .kv_base_idx(core_kv_base_idx_w),
        .kv_count(5'd4),
        .first_kv_window(core_first_kv_window_w),
        .last_kv_window(core_last_kv_window_w),
        .restore_state_valid(!core_first_kv_window_w),
        .restore_m_state_flat(q_tile_m_state_r[q_tile_in_group_idx_r]),
        .restore_l_state_flat(q_tile_l_state_r[q_tile_in_group_idx_r]),
        .restore_row_seen(q_tile_row_seen_r[q_tile_in_group_idx_r]),
        .restore_o_tile_flat(q_tile_o_state_r[q_tile_in_group_idx_r]),
        .k_rd_req_valid(micro_k_rd_req_valid_w),
        .k_rd_req_ready(micro_k_rd_req_ready_w),
        .k_rd_req_kv_idx(micro_k_rd_req_kv_idx_w),
        .k_rd_req_pair_idx(micro_k_rd_req_pair_idx_w),
        .k_rd_resp_valid(micro_k_rd_resp_valid_w),
        .k_rd_resp_data(micro_k_rd_resp_data_w),
        .v_rd_req_valid(micro_v_rd_req_valid_w),
        .v_rd_req_ready(micro_v_rd_req_ready_w),
        .v_rd_req_kv_idx(micro_v_rd_req_kv_idx_w),
        .v_rd_req_wave_idx(micro_v_rd_req_wave_idx_w),
        .v_rd_req_pair_idx(micro_v_rd_req_pair_idx_w),
        .v_rd_resp_valid(micro_v_rd_resp_valid_w),
        .v_rd_resp_data(micro_v_rd_resp_data_w),
        .busy(micro_busy_w),
        .done(micro_done_w),
        .error(micro_error_w),
        .o_tile_flat(o_block_flat),
        .cycles(micro_cycles_w),
        .micro_tile_count(micro_tile_count_w),
        .kv_block_issue_count(micro_kv_block_issue_count_w),
        .qk_task_count(micro_qk_task_count_w),
        .score_task_count(micro_score_task_count_w),
        .row_state_task_count(micro_row_state_task_count_w),
        .pv_task_count(micro_pv_task_count_w),
        .oacc_task_count(micro_oacc_task_count_w),
        .snapshot_m_state_flat(micro_snapshot_m_state_w),
        .snapshot_l_state_flat(micro_snapshot_l_state_w),
        .snapshot_row_seen(micro_snapshot_row_seen_w)
    );

    assign micro_k_rd_req_ready_w = (state_r == ST_WAIT_TILE) && current_k_rd_resident_w;
    assign micro_k_rd_resp_valid_w = &k_sram_selected_rd_valid_w;
    assign micro_v_rd_req_ready_w = (state_r == ST_WAIT_TILE) && current_v_rd_resident_w;
    assign micro_v_rd_resp_valid_w = &v_sram_selected_rd_valid_w;
    assign o_dump_valid = (state_r == ST_DUMP_GROUP);
    assign o_dump_group_idx = o_dump_group_idx_r;
    assign o_dump_word_idx = o_dump_word_idx_r;
    assign o_dump_word = q_tile_o_state_r[o_dump_q_tile_idx_w]
                       [(o_dump_word_in_tile_w * 32) +: 32];
    assign o_dump_last = o_dump_last_word_w;
    assign k_sram_rd_fire_w = micro_k_rd_req_valid_w && micro_k_rd_req_ready_w;
    assign v_sram_rd_fire_w = micro_v_rd_req_valid_w && micro_v_rd_req_ready_w;

    genvar bank_gi;
    generate
        for (bank_gi = 0; bank_gi < K_SRAM_BANK_COUNT; bank_gi = bank_gi + 1) begin : gen_k_tile_sram_bank
            localparam [3:0] BANK_IDX = bank_gi[3:0];
            assign k_sram_wr_en_w[bank_gi] =
                k_tile_beat_fire_w && (k_sram_wr_bank_idx_w == BANK_IDX);
            FA_LOCAL_TILE_SRAM_16X64X16 u_k_tile_sram (
                .clk(clk),
                .rstn(rstn),
                .clear(clear),
                .wr_en(k_sram_wr_en_w[bank_gi]),
                .wr_row_idx(k_sram_wr_row_idx_w),
                .wr_chunk_idx(k_sram_wr_chunk_idx_w),
                .wr_data(k_tile_beat_data),
                .wr_mask(64'hffff_ffff_ffff_ffff),
                .rd_en(k_sram_rd_fire_w),
                .rd_row_idx(k_sram_rd_row_idx_w),
                .rd_chunk_idx(k_sram_rd_chunk_idx_w),
                .rd_valid(k_sram_rd_valid_w[bank_gi]),
                .rd_data(k_sram_rd_data_w[bank_gi])
            );
        end
        for (bank_gi = 0; bank_gi < V_SRAM_BANK_COUNT; bank_gi = bank_gi + 1) begin : gen_v_tile_sram_bank
            localparam [3:0] BANK_IDX = bank_gi[3:0];
            assign v_sram_wr_en_w[bank_gi] =
                v_tile_beat_fire_w && (v_sram_wr_bank_idx_w == BANK_IDX);
            FA_LOCAL_TILE_SRAM_16X64X16 u_v_tile_sram (
                .clk(clk),
                .rstn(rstn),
                .clear(clear),
                .wr_en(v_sram_wr_en_w[bank_gi]),
                .wr_row_idx(v_sram_wr_row_idx_w),
                .wr_chunk_idx(v_sram_wr_chunk_idx_w),
                .wr_data(v_tile_beat_data),
                .wr_mask(64'hffff_ffff_ffff_ffff),
                .rd_en(v_sram_rd_fire_w),
                .rd_row_idx(v_sram_rd_row_idx_w),
                .rd_chunk_idx(v_sram_rd_chunk_idx_w),
                .rd_valid(v_sram_rd_valid_w[bank_gi]),
                .rd_data(v_sram_rd_data_w[bank_gi])
            );
        end
    endgenerate

    genvar k_row_gi;
    generate
        for (k_row_gi = 0; k_row_gi < 16; k_row_gi = k_row_gi + 1) begin : gen_k_read_pack
            localparam integer K_ELEM_BANK = k_row_gi;
            assign k_sram_selected_rd_valid_w[k_row_gi] = k_sram_rd_valid_w[K_ELEM_BANK];
            assign micro_k_rd_resp_data_w[(k_row_gi * 32) +: 32] =
                (k_sram_rd_resp_pair_idx_r[0] == 1'b0) ?
                k_sram_rd_data_w[K_ELEM_BANK][31:0] :
                k_sram_rd_data_w[K_ELEM_BANK][63:32];
        end
    endgenerate

    genvar v_pair_word_gi;
    generate
        for (v_pair_word_gi = 0; v_pair_word_gi < 8; v_pair_word_gi = v_pair_word_gi + 1) begin : gen_v_valid_pack
            assign v_sram_selected_rd_valid_w[v_pair_word_gi] =
                (v_sram_rd_resp_kv_idx_r[1] == 1'b0) ?
                v_sram_rd_valid_w[v_pair_word_gi] :
                v_sram_rd_valid_w[8 + v_pair_word_gi];
        end
        for (v_pair_word_gi = 0; v_pair_word_gi < 16; v_pair_word_gi = v_pair_word_gi + 1) begin : gen_v_read_pack
            localparam integer V_CHUNK_IDX = v_pair_word_gi / 4;
            localparam integer V_ELEM_IDX = v_pair_word_gi % 4;
            assign micro_v_rd_resp_data_w[(v_pair_word_gi * 32) +: 32] = {
                ((v_sram_rd_resp_kv_idx_r[1] == 1'b0) ?
                    v_sram_rd_data_w[4 + V_CHUNK_IDX][(V_ELEM_IDX * 16) +: 16] :
                    v_sram_rd_data_w[12 + V_CHUNK_IDX][(V_ELEM_IDX * 16) +: 16]),
                ((v_sram_rd_resp_kv_idx_r[1] == 1'b0) ?
                    v_sram_rd_data_w[V_CHUNK_IDX][(V_ELEM_IDX * 16) +: 16] :
                    v_sram_rd_data_w[8 + V_CHUNK_IDX][(V_ELEM_IDX * 16) +: 16])
            };
        end
    endgenerate

    always @(*) begin
        state_n = state_r;
        case (state_r)
            ST_IDLE: begin
                if (start) begin
                    state_n = ST_GROUP_START;
                end
            end
            ST_GROUP_START: begin
                state_n = ST_K_LOAD_REQ;
            end
            ST_K_LOAD_REQ: begin
                if (k_tile_req_fire_w) begin
                    state_n = ST_K_LOAD_WAIT;
                end
            end
            ST_K_LOAD_WAIT: begin
                if (k_tile_last_mismatch_w) begin
                    state_n = ST_DONE;
                end else if (k_tile_load_done_w) begin
                    state_n = ST_V_LOAD_REQ;
                end
            end
            ST_V_LOAD_REQ: begin
                if (v_tile_req_fire_w) begin
                    state_n = ST_V_LOAD_WAIT;
                end
            end
            ST_V_LOAD_WAIT: begin
                if (v_tile_last_mismatch_w) begin
                    state_n = ST_DONE;
                end else if (v_tile_load_done_w) begin
                    if (kv_load_slot_idx_r == (KV_WINDOW_TILES - 1)) begin
                        state_n = ST_Q_LOAD_REQ;
                    end else begin
                        state_n = ST_K_LOAD_REQ;
                    end
                end
            end
            ST_Q_LOAD_REQ: begin
                if (q_tile_req_fire_w) begin
                    state_n = ST_Q_LOAD_WAIT;
                end
            end
            ST_Q_LOAD_WAIT: begin
                if (q_tile_last_mismatch_w) begin
                    state_n = ST_DONE;
                end else if (q_tile_load_done_w) begin
                    state_n = ST_START_TILE;
                end
            end
            ST_START_TILE: begin
                state_n = ST_WAIT_TILE;
            end
            ST_WAIT_TILE: begin
                if (micro_done_w) begin
                    if (micro_error_w) begin
                        state_n = ST_DONE;
                    end else if (window_is_last_q_tile_w) begin
                        if (group_is_last_window_w) begin
                            state_n = ST_DUMP_GROUP;
                        end else begin
                            state_n = ST_K_LOAD_REQ;
                        end
                    end else begin
                        state_n = ST_Q_LOAD_REQ;
                    end
                end
            end
            ST_DUMP_GROUP: begin
                if (o_dump_fire_w && o_dump_last_word_w) begin
                    if (group_is_last_group_w) begin
                        state_n = ST_DONE;
                    end else begin
                        state_n = ST_GROUP_START;
                    end
                end
            end
            ST_DONE: begin
                state_n = ST_IDLE;
            end
            default: begin
                state_n = ST_IDLE;
            end
        endcase
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
        end else if (clear) begin
            state_r <= ST_IDLE;
        end else begin
            state_r <= state_n;
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            busy_r <= 1'b0;
            done_r <= 1'b0;
            error_r <= 1'b0;
            cycles_r <= 32'd0;
            micro_tile_count_r <= 32'd0;
            q_group_count_r <= 32'd0;
            kv_window_count_r <= 32'd0;
            q_tile_visit_count_r <= 32'd0;
            kv_tile_count_r <= 32'd0;
            q_tile_req_count_r <= 32'd0;
            q_tile_beat_count_r <= 32'd0;
            k_tile_req_count_r <= 32'd0;
            k_tile_beat_count_r <= 32'd0;
            v_tile_req_count_r <= 32'd0;
            v_tile_beat_count_r <= 32'd0;
            state_fill_count_r <= 32'd0;
            state_spill_count_r <= 32'd0;
            qk_task_count_r <= 32'd0;
            pv_task_count_r <= 32'd0;
            oacc_task_count_r <= 32'd0;
            q_group_idx_r <= 2'd0;
            kv_window_idx_r <= 2'd0;
            kv_load_slot_idx_r <= 2'd0;
            q_tile_in_group_idx_r <= 4'd0;
            q_tile_load_count_r <= 7'd0;
            k_tile_load_count_r <= 9'd0;
            v_tile_load_count_r <= 9'd0;
            o_dump_group_idx_r <= 2'd0;
            o_dump_word_idx_r <= 11'd0;
            core_start_r <= 1'b0;
            q_block_flat_r <= 4096'd0;
            kv_window_resident_valid_r <= {KV_WINDOW_TILES{1'b0}};
            k_sram_rd_resp_pair_idx_r <= 5'd0;
            v_sram_rd_resp_kv_idx_r <= 5'd0;
            for (q_tile_state_i = 0; q_tile_state_i < Q_TILES_PER_GROUP; q_tile_state_i = q_tile_state_i + 1) begin
                q_tile_m_state_r[q_tile_state_i] <= 512'd0;
                q_tile_l_state_r[q_tile_state_i] <= 512'd0;
                q_tile_row_seen_r[q_tile_state_i] <= 16'd0;
                q_tile_o_state_r[q_tile_state_i] <= 4096'd0;
            end
        end else if (clear) begin
            busy_r <= 1'b0;
            done_r <= 1'b0;
            error_r <= 1'b0;
            cycles_r <= 32'd0;
            micro_tile_count_r <= 32'd0;
            q_group_count_r <= 32'd0;
            kv_window_count_r <= 32'd0;
            q_tile_visit_count_r <= 32'd0;
            kv_tile_count_r <= 32'd0;
            q_tile_req_count_r <= 32'd0;
            q_tile_beat_count_r <= 32'd0;
            k_tile_req_count_r <= 32'd0;
            k_tile_beat_count_r <= 32'd0;
            v_tile_req_count_r <= 32'd0;
            v_tile_beat_count_r <= 32'd0;
            state_fill_count_r <= 32'd0;
            state_spill_count_r <= 32'd0;
            qk_task_count_r <= 32'd0;
            pv_task_count_r <= 32'd0;
            oacc_task_count_r <= 32'd0;
            q_group_idx_r <= 2'd0;
            kv_window_idx_r <= 2'd0;
            kv_load_slot_idx_r <= 2'd0;
            q_tile_in_group_idx_r <= 4'd0;
            q_tile_load_count_r <= 7'd0;
            k_tile_load_count_r <= 9'd0;
            v_tile_load_count_r <= 9'd0;
            o_dump_group_idx_r <= 2'd0;
            o_dump_word_idx_r <= 11'd0;
            core_start_r <= 1'b0;
            q_block_flat_r <= 4096'd0;
            kv_window_resident_valid_r <= {KV_WINDOW_TILES{1'b0}};
            k_sram_rd_resp_pair_idx_r <= 5'd0;
            v_sram_rd_resp_kv_idx_r <= 5'd0;
            for (q_tile_state_i = 0; q_tile_state_i < Q_TILES_PER_GROUP; q_tile_state_i = q_tile_state_i + 1) begin
                q_tile_m_state_r[q_tile_state_i] <= 512'd0;
                q_tile_l_state_r[q_tile_state_i] <= 512'd0;
                q_tile_row_seen_r[q_tile_state_i] <= 16'd0;
                q_tile_o_state_r[q_tile_state_i] <= 4096'd0;
            end
        end else begin
            done_r <= 1'b0;
            core_start_r <= 1'b0;

            if (k_sram_rd_fire_w) begin
                k_sram_rd_resp_pair_idx_r <= micro_k_rd_req_pair_idx_w;
            end

            if (v_sram_rd_fire_w) begin
                v_sram_rd_resp_kv_idx_r <= {3'd0, micro_v_rd_window_slot_idx_w};
            end

            if (busy_r) begin
                cycles_r <= cycles_r + 32'd1;
            end

            if (state_r == ST_IDLE && start) begin
                busy_r <= 1'b1;
                error_r <= config_invalid_w;
                cycles_r <= 32'd0;
                micro_tile_count_r <= 32'd0;
                q_group_count_r <= 32'd0;
                kv_window_count_r <= 32'd0;
                q_tile_visit_count_r <= 32'd0;
                kv_tile_count_r <= 32'd0;
                q_tile_req_count_r <= 32'd0;
                q_tile_beat_count_r <= 32'd0;
                k_tile_req_count_r <= 32'd0;
                k_tile_beat_count_r <= 32'd0;
                v_tile_req_count_r <= 32'd0;
                v_tile_beat_count_r <= 32'd0;
                state_fill_count_r <= 32'd0;
                state_spill_count_r <= 32'd0;
                qk_task_count_r <= 32'd0;
                pv_task_count_r <= 32'd0;
                oacc_task_count_r <= 32'd0;
                q_group_idx_r <= 2'd0;
                kv_window_idx_r <= 2'd0;
                kv_load_slot_idx_r <= 2'd0;
                q_tile_in_group_idx_r <= 4'd0;
                q_tile_load_count_r <= 7'd0;
                k_tile_load_count_r <= 9'd0;
                v_tile_load_count_r <= 9'd0;
                o_dump_group_idx_r <= 2'd0;
                o_dump_word_idx_r <= 11'd0;
                kv_window_resident_valid_r <= {KV_WINDOW_TILES{1'b0}};
                for (q_tile_state_i = 0; q_tile_state_i < Q_TILES_PER_GROUP; q_tile_state_i = q_tile_state_i + 1) begin
                    q_tile_m_state_r[q_tile_state_i] <= 512'd0;
                    q_tile_l_state_r[q_tile_state_i] <= 512'd0;
                    q_tile_row_seen_r[q_tile_state_i] <= 16'd0;
                    q_tile_o_state_r[q_tile_state_i] <= 4096'd0;
                end
            end

            if (state_r == ST_GROUP_START) begin
                q_group_count_r <= q_group_count_r + 32'd1;
                kv_window_idx_r <= 2'd0;
                kv_load_slot_idx_r <= 2'd0;
                q_tile_in_group_idx_r <= 4'd0;
                kv_window_resident_valid_r <= {KV_WINDOW_TILES{1'b0}};
                for (q_tile_state_i = 0; q_tile_state_i < Q_TILES_PER_GROUP; q_tile_state_i = q_tile_state_i + 1) begin
                    q_tile_m_state_r[q_tile_state_i] <= 512'd0;
                    q_tile_l_state_r[q_tile_state_i] <= 512'd0;
                    q_tile_row_seen_r[q_tile_state_i] <= 16'd0;
                    q_tile_o_state_r[q_tile_state_i] <= 4096'd0;
                end
            end

            if (k_tile_req_fire_w) begin
                k_tile_req_count_r <= k_tile_req_count_r + 32'd1;
                k_tile_load_count_r <= 9'd0;
            end

            if (k_tile_beat_fire_w) begin
                k_tile_beat_count_r <= k_tile_beat_count_r + 32'd1;
                if (k_tile_last_mismatch_w) begin
                    error_r <= 1'b1;
                    k_tile_load_count_r <= 9'd0;
                end else if (k_tile_last_beat_count_w) begin
                    k_tile_load_count_r <= 9'd0;
                end else begin
                    k_tile_load_count_r <= k_tile_load_count_r + 9'd1;
                end
            end

            if (v_tile_req_fire_w) begin
                v_tile_req_count_r <= v_tile_req_count_r + 32'd1;
                v_tile_load_count_r <= 9'd0;
            end

            if (v_tile_beat_fire_w) begin
                v_tile_beat_count_r <= v_tile_beat_count_r + 32'd1;
                if (v_tile_last_mismatch_w) begin
                    error_r <= 1'b1;
                    v_tile_load_count_r <= 9'd0;
                end else if (v_tile_last_beat_count_w) begin
                    kv_window_resident_valid_r[kv_load_slot_idx_r] <= 1'b1;
                    if (kv_load_slot_idx_r == (KV_WINDOW_TILES - 1)) begin
                        kv_load_slot_idx_r <= 2'd0;
                        kv_window_count_r <= kv_window_count_r + 32'd1;
                    end else begin
                        kv_load_slot_idx_r <= kv_load_slot_idx_r + 1'b1;
                    end
                    v_tile_load_count_r <= 9'd0;
                end else begin
                    v_tile_load_count_r <= v_tile_load_count_r + 9'd1;
                end
            end

            if (q_tile_req_fire_w) begin
                q_tile_req_count_r <= q_tile_req_count_r + 32'd1;
                q_tile_visit_count_r <= q_tile_visit_count_r + 32'd1;
                state_fill_count_r <= state_fill_count_r + 32'd1;
                q_tile_load_count_r <= 7'd0;
            end

            if (q_tile_beat_fire_w) begin
                q_tile_beat_count_r <= q_tile_beat_count_r + 32'd1;
                q_block_flat_r[(((q_tile_beat_row_idx * 32)
                               + (q_tile_beat_chunk_idx * 2)) * 32) +: 64] <=
                    q_tile_beat_data;
                if (q_tile_last_mismatch_w) begin
                    error_r <= 1'b1;
                    q_tile_load_count_r <= 7'd0;
                end else if (q_tile_last_beat_count_w) begin
                    q_tile_load_count_r <= 7'd0;
                end else begin
                    q_tile_load_count_r <= q_tile_load_count_r + 7'd1;
                end
            end

            if (state_r == ST_START_TILE) begin
                core_start_r <= 1'b1;
            end

            if (state_r == ST_WAIT_TILE && micro_done_w) begin
                micro_tile_count_r <= micro_tile_count_r + micro_tile_count_w;
                kv_tile_count_r <= kv_tile_count_r + micro_kv_block_issue_count_w;
                qk_task_count_r <= qk_task_count_r + micro_qk_task_count_w;
                pv_task_count_r <= pv_task_count_r + micro_pv_task_count_w;
                oacc_task_count_r <= oacc_task_count_r + micro_oacc_task_count_w;
                if (micro_error_w) begin
                    error_r <= 1'b1;
                end else begin
                    state_spill_count_r <= state_spill_count_r + 32'd1;
                    q_tile_m_state_r[q_tile_in_group_idx_r] <= micro_snapshot_m_state_w;
                    q_tile_l_state_r[q_tile_in_group_idx_r] <= micro_snapshot_l_state_w;
                    q_tile_row_seen_r[q_tile_in_group_idx_r] <= micro_snapshot_row_seen_w;
                    q_tile_o_state_r[q_tile_in_group_idx_r] <= o_block_flat;
                    if (window_is_last_q_tile_w) begin
                        q_tile_in_group_idx_r <= 4'd0;
                        kv_window_resident_valid_r <= {KV_WINDOW_TILES{1'b0}};
                        if (group_is_last_window_w) begin
                            kv_window_idx_r <= 2'd0;
                            o_dump_group_idx_r <= q_group_idx_r;
                            o_dump_word_idx_r <= 11'd0;
                        end else begin
                            kv_window_idx_r <= kv_window_idx_r + 1'b1;
                        end
                    end else begin
                        q_tile_in_group_idx_r <= q_tile_in_group_idx_r + 1'b1;
                    end
                end
            end

            if (state_r == ST_DUMP_GROUP && o_dump_fire_w) begin
                if (o_dump_last_word_w) begin
                    o_dump_word_idx_r <= 11'd0;
                    if (!group_is_last_group_w) begin
                        q_group_idx_r <= q_group_idx_r + 1'b1;
                    end
                end else begin
                    o_dump_word_idx_r <= o_dump_word_idx_r + 11'd1;
                end
            end

            if (state_r == ST_DONE) begin
                busy_r <= 1'b0;
                done_r <= 1'b1;
            end
        end
    end

endmodule
