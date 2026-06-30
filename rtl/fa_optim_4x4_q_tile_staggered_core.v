module FA_OPTIM_4X4_Q_TILE_STAGGERED_CORE (
    input  wire          clk,
    input  wire          rstn,
    input  wire          clear,
    input  wire          start,
    input  wire [4095:0] q_block_flat,
    output wire          k_rd_req_valid,
    input  wire          k_rd_req_ready,
    output wire [4:0]    k_rd_req_kv_idx,
    output wire [4:0]    k_rd_req_pair_idx,
    input  wire          k_rd_resp_valid,
    input  wire [511:0]  k_rd_resp_data,
    output wire          v_rd_req_valid,
    input  wire          v_rd_req_ready,
    output wire [4:0]    v_rd_req_kv_idx,
    output wire [1:0]    v_rd_req_wave_idx,
    output wire [2:0]    v_rd_req_pair_idx,
    input  wire          v_rd_resp_valid,
    input  wire [511:0]  v_rd_resp_data,
    output reg           busy,
    output reg           done,
    output reg           error,
    output wire [4095:0] o_tile_flat,
    output reg  [31:0]   cycles,
    output reg  [31:0]   micro_tile_count,
    output reg  [31:0]   kv_block_issue_count,
    output reg  [31:0]   qk_task_count,
    output reg  [31:0]   score_task_count,
    output reg  [31:0]   row_state_task_count,
    output reg  [31:0]   pv_task_count,
    output reg  [31:0]   oacc_task_count
);

    localparam integer SLOT_COUNT = 4;
    localparam integer KV_TILE_COUNT = 16;
    localparam [4:0] KV_TILE_COUNT_W = 5'd16;

    localparam [1:0] CORE_IDLE = 2'd0;
    localparam [1:0] CORE_INIT = 2'd1;
    localparam [1:0] CORE_RUN  = 2'd2;
    localparam [1:0] CORE_DONE = 2'd3;

    localparam [3:0] GEMM_IDLE     = 4'd0;
    localparam [3:0] GEMM_QK_REQ   = 4'd1;
    localparam [3:0] GEMM_QK_WAIT  = 4'd2;
    localparam [3:0] GEMM_QK_SEND  = 4'd3;
    localparam [3:0] GEMM_QK_DRAIN = 4'd4;
    localparam [3:0] GEMM_PV_REQ   = 4'd5;
    localparam [3:0] GEMM_PV_WAIT  = 4'd6;
    localparam [3:0] GEMM_PV_SEND  = 4'd7;
    localparam [3:0] GEMM_PV_DRAIN = 4'd8;

    reg [1:0] core_state_r;
    reg [3:0] gemm_state_r;
    reg [5:0] feed_count_r;
    reg [4:0] qk_issue_kv_idx_r;
    reg [4:0] row_next_kv_idx_r;
    reg [4:0] pv_next_kv_idx_r;
    reg [4:0] oacc_next_kv_idx_r;

    reg [SLOT_COUNT-1:0] slot_busy_r;
    reg [SLOT_COUNT-1:0] score_ready_r;
    reg [SLOT_COUNT-1:0] p_ready_r;
    reg [SLOT_COUNT-1:0] partial_ready_r;
    reg [4:0] slot_kv_idx_r [0:SLOT_COUNT-1];
    reg [2047:0] slot_score_block_flat_r [0:SLOT_COUNT-1];
    reg [1023:0] slot_p_block_flat_r [0:SLOT_COUNT-1];
    reg [127:0] slot_rescale_block_flat_r [0:SLOT_COUNT-1];
    reg [1023:0] slot_partial_o_row_r [0:SLOT_COUNT-1][0:3];
    reg [1023:0] o_tile_row_r [0:3];

    reg [1:0] qk_active_slot_r;
    reg [4:0] qk_active_kv_idx_r;
    reg [1:0] pv_active_slot_r;
    reg [4:0] pv_active_kv_idx_r;
    reg [1:0] pv_wave_r;
    reg [1:0] score_active_slot_r;
    reg       score_active_valid_r;
    reg [1:0] row_active_slot_r;
    reg       row_active_valid_r;
    reg [1:0] oacc_active_slot_r;
    reg       oacc_active_valid_r;

    reg       p_feed_valid_r;
    reg       v_feed_valid_r;
    reg       k_feed_valid_r;
    reg [511:0] p_feed_data_r;
    reg [511:0] v_feed_data_r;
    reg [511:0] k_feed_data_r;
    reg         p_rd_valid_r;
    reg [511:0] p_rd_data_r;
    reg [511:0] row_p_block_rd_data_w;

    reg [3:0]   gemm_start_r;
    reg [3:0]   gemm_valid_r;
    reg [31:0]  gemm_num_acc_r;
    reg [127:0] gemm_a_data_r;
    reg [511:0] gemm_b_data_r;

    reg row_init_valid_r;

    wire [3:0] gemm_a_ready_w;
    wire [3:0] gemm_b_ready_w;
    wire [3:0] gemm_start_ready_w;
    wire [3:0] gemm_group_valid_w;
    wire [3:0] gemm_last_w;
    wire [31:0] gemm_group_idx_w [0:3];
    wire [511:0] gemm_group_data_w [0:3];
    wire [3:0] gemm_lane_ready_w = gemm_a_ready_w & gemm_b_ready_w &
                                   ((~gemm_start_r) | gemm_start_ready_w);
    wire gemm_feed_accept_w = (|gemm_valid_r) &&
                              ((gemm_valid_r & (~gemm_lane_ready_w)) == 4'd0);
    wire gemm_all_output_valid_w = &gemm_group_valid_w;
    wire gemm_output_idx_match_w = (gemm_group_idx_w[1] == gemm_group_idx_w[0]) &&
                                   (gemm_group_idx_w[2] == gemm_group_idx_w[0]) &&
                                   (gemm_group_idx_w[3] == gemm_group_idx_w[0]);
    wire qk_output_accept_w = (gemm_state_r == GEMM_QK_DRAIN) &&
                              gemm_all_output_valid_w && gemm_output_idx_match_w;
    wire pv_output_accept_w = (gemm_state_r == GEMM_PV_DRAIN) &&
                              gemm_all_output_valid_w && gemm_output_idx_match_w;
    wire [3:0] gemm_group_ready_w =
        (gemm_state_r == GEMM_QK_DRAIN) ? {4{qk_output_accept_w}} :
        ((gemm_state_r == GEMM_PV_DRAIN) ? {4{pv_output_accept_w}} : 4'd0);

    reg qk_free_slot_valid_w;
    reg [1:0] qk_free_slot_idx_w;
    reg score_issue_valid_w;
    reg [1:0] score_issue_slot_w;
    reg pv_issue_valid_w;
    reg [1:0] pv_issue_slot_w;
    reg oacc_issue_valid_w;
    reg [1:0] oacc_issue_slot_w;
    wire qk_can_issue_w = (core_state_r == CORE_RUN) &&
                          (gemm_state_r == GEMM_IDLE) &&
                          (qk_issue_kv_idx_r < KV_TILE_COUNT_W) &&
                          qk_free_slot_valid_w;
    wire pv_can_issue_w = (core_state_r == CORE_RUN) &&
                          (gemm_state_r == GEMM_IDLE) &&
                          pv_issue_valid_w;
    wire qk_feed_valid_w = ((gemm_state_r == GEMM_QK_WAIT) && k_rd_resp_valid) ||
                           (gemm_state_r == GEMM_QK_SEND);
    wire qk_feed_accept_w = qk_feed_valid_w && gemm_feed_accept_w;
    wire qk_feed_last_w = (feed_count_r == 6'd31);
    wire qk_next_req_valid_w = qk_feed_accept_w && !qk_feed_last_w;
    wire [4:0] qk_next_pair_idx_w = feed_count_r[4:0] + 5'd1;
    wire k_rd_req_fire_w = k_rd_req_valid && k_rd_req_ready;
    wire qk_next_req_fire_w = qk_next_req_valid_w && k_rd_req_ready;

    wire [1023:0] row_p_block_flat_w =
        (pv_active_slot_r == 2'd0) ? slot_p_block_flat_r[0] :
        ((pv_active_slot_r == 2'd1) ? slot_p_block_flat_r[1] :
        ((pv_active_slot_r == 2'd2) ? slot_p_block_flat_r[2] :
                                      slot_p_block_flat_r[3]));
    wire p_rd_valid_w = p_rd_valid_r;
    wire [511:0] p_rd_data_w = p_rd_data_r;
    wire [511:0] pv_p_data_w = p_rd_valid_w ? p_rd_data_w : p_feed_data_r;
    wire [511:0] pv_v_data_w = v_rd_resp_valid ? v_rd_resp_data : v_feed_data_r;
    wire [511:0] pv_gemm_p_data_w = (gemm_state_r == GEMM_PV_WAIT) ? pv_p_data_w : p_feed_data_r;
    wire [511:0] pv_gemm_v_data_w = (gemm_state_r == GEMM_PV_WAIT) ? pv_v_data_w : v_feed_data_r;
    wire pv_operands_ready_w = (p_feed_valid_r || p_rd_valid_w) &&
                               (v_feed_valid_r || v_rd_resp_valid);
    wire pv_feed_valid_w = ((gemm_state_r == GEMM_PV_WAIT) && pv_operands_ready_w) ||
                           (gemm_state_r == GEMM_PV_SEND);
    wire pv_feed_accept_w = pv_feed_valid_w && gemm_feed_accept_w;
    wire pv_feed_last_w = (feed_count_r == 6'd7);
    wire pv_next_req_valid_w = pv_feed_accept_w && !pv_feed_last_w;
    wire [2:0] pv_next_pair_idx_w = feed_count_r[2:0] + 3'd1;
    wire v_rd_req_fire_w = v_rd_req_valid && v_rd_req_ready;
    wire pv_next_req_fire_w = pv_next_req_valid_w && v_rd_req_ready;

    wire score_req_ready_w;
    wire score_resp_valid_w;
    wire score_done_pulse_w;
    wire [3:0] masked_block_row_base_w;
    wire [63:0] masked_score_block_valid_w;
    wire [2047:0] masked_score_block_flat_w;
    wire [8191:0] unused_masked_score_tile_flat_w;
    wire unused_score_row_rd_en_w;
    wire [3:0] unused_score_row_rd_addr_w;
    wire score_req_valid_w = score_issue_valid_w && !score_active_valid_r;
    wire score_req_fire_w = score_req_valid_w && score_req_ready_w;

    wire row_init_ready_w;
    wire row_update_ready_w;
    wire row_init_done_pulse_w;
    wire row_resp_valid_w;
    wire row_done_pulse_w;
    wire [4095:0] p_tile_flat_w;
    wire [511:0] rescale_vec_flat_w;
    wire [511:0] unused_m_state_flat_w;
    wire [511:0] unused_l_state_flat_w;
    wire [15:0] unused_row_seen_w;
    wire row_update_valid_w = score_active_valid_r && score_resp_valid_w;
    wire row_update_fire_w = row_update_valid_w && row_update_ready_w;

    wire [1:0] oacc_selected_slot_w = oacc_active_valid_r ?
                                      oacc_active_slot_r : oacc_issue_slot_w;
    wire [127:0] oacc_rescale_block_flat_w =
        (oacc_selected_slot_w == 2'd0) ? slot_rescale_block_flat_r[0] :
        ((oacc_selected_slot_w == 2'd1) ? slot_rescale_block_flat_r[1] :
        ((oacc_selected_slot_w == 2'd2) ? slot_rescale_block_flat_r[2] :
                                          slot_rescale_block_flat_r[3]));
    wire [511:0] oacc_rescale_vec_flat_w = {384'd0, oacc_rescale_block_flat_w};
    wire oacc_req_ready_w;
    wire oacc_resp_valid_w;
    wire oacc_done_pulse_w;
    wire partial_row_rd_en_w;
    wire [3:0] partial_row_rd_addr_w;
    wire oacc_row_rd_en_w;
    wire [3:0] oacc_row_rd_addr_w;
    wire oacc_row_wr_en_w;
    wire [3:0] oacc_row_wr_addr_w;
    wire [1023:0] oacc_row_wr_data_w;
    reg partial_row_rd_valid_r;
    reg [1023:0] partial_row_rd_data_r;
    reg oacc_row_rd_valid_r;
    reg [1023:0] oacc_row_rd_data_r;
    wire oacc_req_valid_w = (core_state_r == CORE_RUN) &&
                            !oacc_active_valid_r &&
                            oacc_issue_valid_w;
    wire oacc_req_fire_w = oacc_req_valid_w && oacc_req_ready_w;

    integer lane_i;
    integer col_i;
    integer row_i;
    integer slot_i;
    integer p_row_i;
    integer o_row_i;
    integer global_col_i;

    assign o_tile_flat[1023:0] = o_tile_row_r[0];
    assign o_tile_flat[2047:1024] = o_tile_row_r[1];
    assign o_tile_flat[3071:2048] = o_tile_row_r[2];
    assign o_tile_flat[4095:3072] = o_tile_row_r[3];

    assign k_rd_req_valid = (core_state_r == CORE_RUN) &&
                            ((gemm_state_r == GEMM_QK_REQ) || qk_next_req_valid_w);
    assign k_rd_req_kv_idx = qk_active_kv_idx_r;
    assign k_rd_req_pair_idx = qk_next_req_valid_w ? qk_next_pair_idx_w : feed_count_r[4:0];
    assign v_rd_req_valid = (core_state_r == CORE_RUN) &&
                            ((gemm_state_r == GEMM_PV_REQ) || pv_next_req_valid_w);
    assign v_rd_req_kv_idx = pv_active_kv_idx_r;
    assign v_rd_req_wave_idx = pv_wave_r;
    assign v_rd_req_pair_idx = pv_next_req_valid_w ? pv_next_pair_idx_w : feed_count_r[2:0];

    function automatic [31:0] get_q_word;
        input integer row;
        input integer pair_idx;
        begin
            get_q_word = q_block_flat[((row * 32 + pair_idx) * 32) +: 32];
        end
    endfunction

    function automatic signed [31:0] clamp_q16_16_from_acc128;
        input signed [127:0] value;
        begin
            if (value > 128'sh0000000000000000000000007FFF_FFFF) begin
                clamp_q16_16_from_acc128 = 32'sh7FFF_FFFF;
            end else if (value < -128'sh0000000000000000000000008000_0000) begin
                clamp_q16_16_from_acc128 = -32'sh8000_0000;
            end else begin
                clamp_q16_16_from_acc128 = value[31:0];
            end
        end
    endfunction

    function automatic signed [15:0] q16_16_to_q88_sat128;
        input signed [127:0] value;
        reg signed [127:0] rounded;
        reg signed [127:0] shifted;
        begin
            if (value >= 0) begin
                rounded = value + 128'sd128;
            end else begin
                rounded = value - 128'sd128;
            end
            shifted = rounded >>> 8;
            if (shifted > 128'sd32767) begin
                q16_16_to_q88_sat128 = 16'sh7FFF;
            end else if (shifted < -128'sd32768) begin
                q16_16_to_q88_sat128 = -16'sh8000;
            end else begin
                q16_16_to_q88_sat128 = shifted[15:0];
            end
        end
    endfunction

    always @(*) begin
        row_p_block_rd_data_w = 512'd0;
        for (p_row_i = 0; p_row_i < 4; p_row_i = p_row_i + 1) begin
            row_p_block_rd_data_w[(p_row_i * 32) +: 32] =
                row_p_block_flat_w[(((p_row_i * 8) + v_rd_req_pair_idx) * 32) +: 32];
        end
    end

    always @(*) begin
        qk_free_slot_valid_w = 1'b0;
        qk_free_slot_idx_w = 2'd0;
        if (!slot_busy_r[0]) begin
            qk_free_slot_valid_w = 1'b1;
            qk_free_slot_idx_w = 2'd0;
        end else if (!slot_busy_r[1]) begin
            qk_free_slot_valid_w = 1'b1;
            qk_free_slot_idx_w = 2'd1;
        end else if (!slot_busy_r[2]) begin
            qk_free_slot_valid_w = 1'b1;
            qk_free_slot_idx_w = 2'd2;
        end else if (!slot_busy_r[3]) begin
            qk_free_slot_valid_w = 1'b1;
            qk_free_slot_idx_w = 2'd3;
        end
    end

    always @(*) begin
        score_issue_valid_w = 1'b0;
        score_issue_slot_w = 2'd0;
        if ((core_state_r == CORE_RUN) && (row_next_kv_idx_r < KV_TILE_COUNT_W) &&
            slot_busy_r[0] && score_ready_r[0] && (slot_kv_idx_r[0] == row_next_kv_idx_r)) begin
            score_issue_valid_w = 1'b1;
            score_issue_slot_w = 2'd0;
        end else if ((core_state_r == CORE_RUN) && (row_next_kv_idx_r < KV_TILE_COUNT_W) &&
            slot_busy_r[1] && score_ready_r[1] && (slot_kv_idx_r[1] == row_next_kv_idx_r)) begin
            score_issue_valid_w = 1'b1;
            score_issue_slot_w = 2'd1;
        end else if ((core_state_r == CORE_RUN) && (row_next_kv_idx_r < KV_TILE_COUNT_W) &&
            slot_busy_r[2] && score_ready_r[2] && (slot_kv_idx_r[2] == row_next_kv_idx_r)) begin
            score_issue_valid_w = 1'b1;
            score_issue_slot_w = 2'd2;
        end else if ((core_state_r == CORE_RUN) && (row_next_kv_idx_r < KV_TILE_COUNT_W) &&
            slot_busy_r[3] && score_ready_r[3] && (slot_kv_idx_r[3] == row_next_kv_idx_r)) begin
            score_issue_valid_w = 1'b1;
            score_issue_slot_w = 2'd3;
        end
    end

    always @(*) begin
        pv_issue_valid_w = 1'b0;
        pv_issue_slot_w = 2'd0;
        if ((pv_next_kv_idx_r < KV_TILE_COUNT_W) &&
            slot_busy_r[0] && p_ready_r[0] && (slot_kv_idx_r[0] == pv_next_kv_idx_r)) begin
            pv_issue_valid_w = 1'b1;
            pv_issue_slot_w = 2'd0;
        end else if ((pv_next_kv_idx_r < KV_TILE_COUNT_W) &&
            slot_busy_r[1] && p_ready_r[1] && (slot_kv_idx_r[1] == pv_next_kv_idx_r)) begin
            pv_issue_valid_w = 1'b1;
            pv_issue_slot_w = 2'd1;
        end else if ((pv_next_kv_idx_r < KV_TILE_COUNT_W) &&
            slot_busy_r[2] && p_ready_r[2] && (slot_kv_idx_r[2] == pv_next_kv_idx_r)) begin
            pv_issue_valid_w = 1'b1;
            pv_issue_slot_w = 2'd2;
        end else if ((pv_next_kv_idx_r < KV_TILE_COUNT_W) &&
            slot_busy_r[3] && p_ready_r[3] && (slot_kv_idx_r[3] == pv_next_kv_idx_r)) begin
            pv_issue_valid_w = 1'b1;
            pv_issue_slot_w = 2'd3;
        end
    end

    always @(*) begin
        oacc_issue_valid_w = 1'b0;
        oacc_issue_slot_w = 2'd0;
        if ((oacc_next_kv_idx_r < KV_TILE_COUNT_W) &&
            slot_busy_r[0] && partial_ready_r[0] && (slot_kv_idx_r[0] == oacc_next_kv_idx_r)) begin
            oacc_issue_valid_w = 1'b1;
            oacc_issue_slot_w = 2'd0;
        end else if ((oacc_next_kv_idx_r < KV_TILE_COUNT_W) &&
            slot_busy_r[1] && partial_ready_r[1] && (slot_kv_idx_r[1] == oacc_next_kv_idx_r)) begin
            oacc_issue_valid_w = 1'b1;
            oacc_issue_slot_w = 2'd1;
        end else if ((oacc_next_kv_idx_r < KV_TILE_COUNT_W) &&
            slot_busy_r[2] && partial_ready_r[2] && (slot_kv_idx_r[2] == oacc_next_kv_idx_r)) begin
            oacc_issue_valid_w = 1'b1;
            oacc_issue_slot_w = 2'd2;
        end else if ((oacc_next_kv_idx_r < KV_TILE_COUNT_W) &&
            slot_busy_r[3] && partial_ready_r[3] && (slot_kv_idx_r[3] == oacc_next_kv_idx_r)) begin
            oacc_issue_valid_w = 1'b1;
            oacc_issue_slot_w = 2'd3;
        end
    end

    always @(*) begin
        gemm_start_r = 4'd0;
        gemm_valid_r = 4'd0;
        gemm_num_acc_r = 32'd0;
        gemm_a_data_r = 128'd0;
        gemm_b_data_r = 512'd0;

        if (((gemm_state_r == GEMM_QK_WAIT) && k_rd_resp_valid) ||
            (gemm_state_r == GEMM_QK_SEND)) begin
            gemm_start_r = {4{feed_count_r == 6'd0}};
            gemm_valid_r = 4'hf;
            gemm_num_acc_r = 32'd32;
            for (row_i = 0; row_i < 4; row_i = row_i + 1) begin
                gemm_a_data_r[(row_i * 32) +: 32] = get_q_word(row_i, feed_count_r);
            end
            if (gemm_state_r == GEMM_QK_WAIT) begin
                gemm_b_data_r = k_rd_resp_data;
            end else begin
                gemm_b_data_r = k_feed_data_r;
            end
        end else if (gemm_state_r == GEMM_QK_DRAIN) begin
            gemm_num_acc_r = 32'd32;
        end else if (((gemm_state_r == GEMM_PV_WAIT) && pv_operands_ready_w) ||
                     (gemm_state_r == GEMM_PV_SEND)) begin
            gemm_start_r = {4{feed_count_r == 6'd0}};
            gemm_valid_r = 4'hf;
            gemm_num_acc_r = 32'd8;
            for (row_i = 0; row_i < 4; row_i = row_i + 1) begin
                gemm_a_data_r[(row_i * 32) +: 32] = pv_gemm_p_data_w[(row_i * 32) +: 32];
            end
            gemm_b_data_r = pv_gemm_v_data_w;
        end else if (gemm_state_r == GEMM_PV_DRAIN) begin
            gemm_num_acc_r = 32'd8;
        end
    end

    generate
        genvar lane_gi;
        for (lane_gi = 0; lane_gi < 4; lane_gi = lane_gi + 1) begin : gen_sa_lane
            GEMM_V3 #(
                .WIDTH(32),
                .ELEM_WIDTH(16),
                .PACK_LANES(2),
                .X_DIM(4),
                .Y_DIM(4),
                .OUTPUT_BY_ROW(1)
            ) u_gemm_4x4 (
                .clk(clk),
                .rstn(rstn),
                .clear(clear),
                .start(gemm_start_r[lane_gi]),
                .num_acc(gemm_num_acc_r),
                .a_valid(gemm_valid_r[lane_gi]),
                .a_ready(gemm_a_ready_w[lane_gi]),
                .a(gemm_a_data_r),
                .b_valid(gemm_valid_r[lane_gi]),
                .b_ready(gemm_b_ready_w[lane_gi]),
                .b(gemm_b_data_r[(lane_gi * 128) +: 128]),
                .start_ready(gemm_start_ready_w[lane_gi]),
                .m_group_data(gemm_group_data_w[lane_gi]),
                .m_group_valid(gemm_group_valid_w[lane_gi]),
                .m_group_ready(gemm_group_ready_w[lane_gi]),
                .m_group_idx(gemm_group_idx_w[lane_gi]),
                .m_last(gemm_last_w[lane_gi])
            );
        end
    endgenerate

    FA_SCORE_POST_REAL #(
        .USE_SCORE_ROW_INPUT(0),
        .USE_SCORE_BLOCK_INPUT(1)
    ) u_score_post (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .req_valid(score_req_valid_w),
        .req_ready(score_req_ready_w),
        .q_blk_idx(4'd0),
        .kv_blk_idx(slot_kv_idx_r[score_issue_slot_w][3:0]),
        .causal_en(1'b0),
        .scale_word(32'h0001_0000),
        .neg_large_word(32'hffc0_0000),
        .score_tile_flat(8192'd0),
        .score_block_row_base(4'd0),
        .score_block_flat(slot_score_block_flat_r[score_issue_slot_w]),
        .score_row_rd_en(unused_score_row_rd_en_w),
        .score_row_rd_addr(unused_score_row_rd_addr_w),
        .score_row_rd_valid(1'b0),
        .score_row_rd_data(512'd0),
        .resp_valid(score_resp_valid_w),
        .resp_ready(row_update_ready_w),
        .masked_block_row_base(masked_block_row_base_w),
        .masked_score_block_valid(masked_score_block_valid_w),
        .masked_score_block_flat(masked_score_block_flat_w),
        .done_pulse(score_done_pulse_w),
        .masked_score_tile_flat(unused_masked_score_tile_flat_w)
    );

    FA_ROW_STATE_REAL #(
        .USE_MASKED_BLOCK_INPUT(1),
        .USE_VALID_MASK_INPUT(1)
    ) u_row_state (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .init_valid(row_init_valid_r),
        .init_ready(row_init_ready_w),
        .init_done_pulse(row_init_done_pulse_w),
        .update_valid(row_update_valid_w),
        .update_ready(row_update_ready_w),
        .neg_large_word(32'hffc0_0000),
        .masked_score_tile_flat(8192'd0),
        .update_row_base(masked_block_row_base_w),
        .masked_score_block_valid(masked_score_block_valid_w),
        .masked_score_block_flat(masked_score_block_flat_w),
        .resp_valid(row_resp_valid_w),
        .resp_ready(1'b1),
        .p_tile_flat(p_tile_flat_w),
        .rescale_vec_flat(rescale_vec_flat_w),
        .done_pulse(row_done_pulse_w),
        .debug_m_state_flat(unused_m_state_flat_w),
        .debug_l_state_flat(unused_l_state_flat_w),
        .debug_row_seen(unused_row_seen_w)
    );

    FA_OACC_UPDATE_REAL #(
        .USE_PARTIAL_ROW_INPUT(1),
        .USE_PARTIAL_BLOCK_INPUT(0)
    ) u_oacc_update (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .req_valid(oacc_req_valid_w),
        .req_ready(oacc_req_ready_w),
        .rescale_vec_flat(oacc_rescale_vec_flat_w),
        .partial_o_tile_flat(16384'd0),
        .req_row_base(4'd0),
        .partial_o_block_flat(4096'd0),
        .partial_row_rd_en(partial_row_rd_en_w),
        .partial_row_rd_addr(partial_row_rd_addr_w),
        .partial_row_rd_valid(partial_row_rd_valid_r),
        .partial_row_rd_data(partial_row_rd_data_r),
        .oacc_row_rd_en(oacc_row_rd_en_w),
        .oacc_row_rd_addr(oacc_row_rd_addr_w),
        .oacc_row_rd_valid(oacc_row_rd_valid_r),
        .oacc_row_rd_data(oacc_row_rd_data_r),
        .oacc_row_wr_en(oacc_row_wr_en_w),
        .oacc_row_wr_addr(oacc_row_wr_addr_w),
        .oacc_row_wr_data(oacc_row_wr_data_w),
        .resp_valid(oacc_resp_valid_w),
        .resp_ready(1'b1),
        .done_pulse(oacc_done_pulse_w)
    );

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            p_rd_valid_r <= 1'b0;
            p_rd_data_r <= 512'd0;
        end else if (clear) begin
            p_rd_valid_r <= 1'b0;
            p_rd_data_r <= 512'd0;
        end else begin
            p_rd_valid_r <= v_rd_req_fire_w;
            if (v_rd_req_fire_w) begin
                p_rd_data_r <= row_p_block_rd_data_w;
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            partial_row_rd_valid_r <= 1'b0;
            partial_row_rd_data_r <= 1024'd0;
            oacc_row_rd_valid_r <= 1'b0;
            oacc_row_rd_data_r <= 1024'd0;
        end else if (clear) begin
            partial_row_rd_valid_r <= 1'b0;
            partial_row_rd_data_r <= 1024'd0;
            oacc_row_rd_valid_r <= 1'b0;
            oacc_row_rd_data_r <= 1024'd0;
        end else begin
            partial_row_rd_valid_r <= partial_row_rd_en_w;
            partial_row_rd_data_r <= slot_partial_o_row_r[oacc_selected_slot_w][partial_row_rd_addr_w[1:0]];
            oacc_row_rd_valid_r <= oacc_row_rd_en_w;
            oacc_row_rd_data_r <= o_tile_row_r[oacc_row_rd_addr_w[1:0]];
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            core_state_r <= CORE_IDLE;
            gemm_state_r <= GEMM_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            cycles <= 32'd0;
            micro_tile_count <= 32'd0;
            kv_block_issue_count <= 32'd0;
            qk_task_count <= 32'd0;
            score_task_count <= 32'd0;
            row_state_task_count <= 32'd0;
            pv_task_count <= 32'd0;
            oacc_task_count <= 32'd0;
            feed_count_r <= 6'd0;
            qk_issue_kv_idx_r <= 5'd0;
            row_next_kv_idx_r <= 5'd0;
            pv_next_kv_idx_r <= 5'd0;
            oacc_next_kv_idx_r <= 5'd0;
            slot_busy_r <= {SLOT_COUNT{1'b0}};
            score_ready_r <= {SLOT_COUNT{1'b0}};
            p_ready_r <= {SLOT_COUNT{1'b0}};
            partial_ready_r <= {SLOT_COUNT{1'b0}};
            qk_active_slot_r <= 2'd0;
            qk_active_kv_idx_r <= 5'd0;
            pv_active_slot_r <= 2'd0;
            pv_active_kv_idx_r <= 5'd0;
            pv_wave_r <= 2'd0;
            score_active_slot_r <= 2'd0;
            score_active_valid_r <= 1'b0;
            row_active_slot_r <= 2'd0;
            row_active_valid_r <= 1'b0;
            oacc_active_slot_r <= 2'd0;
            oacc_active_valid_r <= 1'b0;
            p_feed_valid_r <= 1'b0;
            v_feed_valid_r <= 1'b0;
            k_feed_valid_r <= 1'b0;
            p_feed_data_r <= 512'd0;
            v_feed_data_r <= 512'd0;
            k_feed_data_r <= 512'd0;
            row_init_valid_r <= 1'b0;
            for (slot_i = 0; slot_i < SLOT_COUNT; slot_i = slot_i + 1) begin
                slot_kv_idx_r[slot_i] <= 5'd0;
                slot_score_block_flat_r[slot_i] <= 2048'd0;
                slot_p_block_flat_r[slot_i] <= 1024'd0;
                slot_rescale_block_flat_r[slot_i] <= 128'd0;
                for (o_row_i = 0; o_row_i < 4; o_row_i = o_row_i + 1) begin
                    slot_partial_o_row_r[slot_i][o_row_i] <= 1024'd0;
                end
            end
            for (o_row_i = 0; o_row_i < 4; o_row_i = o_row_i + 1) begin
                o_tile_row_r[o_row_i] <= 1024'd0;
            end
        end else if (clear) begin
            core_state_r <= CORE_IDLE;
            gemm_state_r <= GEMM_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            cycles <= 32'd0;
            micro_tile_count <= 32'd0;
            kv_block_issue_count <= 32'd0;
            qk_task_count <= 32'd0;
            score_task_count <= 32'd0;
            row_state_task_count <= 32'd0;
            pv_task_count <= 32'd0;
            oacc_task_count <= 32'd0;
            feed_count_r <= 6'd0;
            qk_issue_kv_idx_r <= 5'd0;
            row_next_kv_idx_r <= 5'd0;
            pv_next_kv_idx_r <= 5'd0;
            oacc_next_kv_idx_r <= 5'd0;
            slot_busy_r <= {SLOT_COUNT{1'b0}};
            score_ready_r <= {SLOT_COUNT{1'b0}};
            p_ready_r <= {SLOT_COUNT{1'b0}};
            partial_ready_r <= {SLOT_COUNT{1'b0}};
            qk_active_slot_r <= 2'd0;
            qk_active_kv_idx_r <= 5'd0;
            pv_active_slot_r <= 2'd0;
            pv_active_kv_idx_r <= 5'd0;
            pv_wave_r <= 2'd0;
            score_active_slot_r <= 2'd0;
            score_active_valid_r <= 1'b0;
            row_active_slot_r <= 2'd0;
            row_active_valid_r <= 1'b0;
            oacc_active_slot_r <= 2'd0;
            oacc_active_valid_r <= 1'b0;
            p_feed_valid_r <= 1'b0;
            v_feed_valid_r <= 1'b0;
            k_feed_valid_r <= 1'b0;
            p_feed_data_r <= 512'd0;
            v_feed_data_r <= 512'd0;
            k_feed_data_r <= 512'd0;
            row_init_valid_r <= 1'b0;
            for (slot_i = 0; slot_i < SLOT_COUNT; slot_i = slot_i + 1) begin
                slot_kv_idx_r[slot_i] <= 5'd0;
                slot_score_block_flat_r[slot_i] <= 2048'd0;
                slot_p_block_flat_r[slot_i] <= 1024'd0;
                slot_rescale_block_flat_r[slot_i] <= 128'd0;
                for (o_row_i = 0; o_row_i < 4; o_row_i = o_row_i + 1) begin
                    slot_partial_o_row_r[slot_i][o_row_i] <= 1024'd0;
                end
            end
            for (o_row_i = 0; o_row_i < 4; o_row_i = o_row_i + 1) begin
                o_tile_row_r[o_row_i] <= 1024'd0;
            end
        end else begin
            done <= 1'b0;
            if (busy) begin
                cycles <= cycles + 32'd1;
            end

            if (score_req_fire_w) begin
                score_ready_r[score_issue_slot_w] <= 1'b0;
                score_active_slot_r <= score_issue_slot_w;
                score_active_valid_r <= 1'b1;
                score_task_count <= score_task_count + 32'd1;
            end

            if (row_update_fire_w) begin
                row_active_slot_r <= score_active_slot_r;
                row_active_valid_r <= 1'b1;
                score_active_valid_r <= 1'b0;
                row_next_kv_idx_r <= row_next_kv_idx_r + 5'd1;
                row_state_task_count <= row_state_task_count + 32'd1;
            end

            if (row_done_pulse_w && row_active_valid_r) begin
                slot_p_block_flat_r[row_active_slot_r] <= p_tile_flat_w[1023:0];
                slot_rescale_block_flat_r[row_active_slot_r] <= rescale_vec_flat_w[127:0];
                p_ready_r[row_active_slot_r] <= 1'b1;
                row_active_valid_r <= 1'b0;
            end

            if (oacc_req_fire_w) begin
                partial_ready_r[oacc_issue_slot_w] <= 1'b0;
                oacc_active_slot_r <= oacc_issue_slot_w;
                oacc_active_valid_r <= 1'b1;
                oacc_task_count <= oacc_task_count + 32'd1;
            end

            if (oacc_row_wr_en_w) begin
                o_tile_row_r[oacc_row_wr_addr_w[1:0]] <= oacc_row_wr_data_w;
            end

            if (oacc_done_pulse_w && oacc_active_valid_r) begin
                slot_busy_r[oacc_active_slot_r] <= 1'b0;
                partial_ready_r[oacc_active_slot_r] <= 1'b0;
                p_ready_r[oacc_active_slot_r] <= 1'b0;
                score_ready_r[oacc_active_slot_r] <= 1'b0;
                oacc_active_valid_r <= 1'b0;
                oacc_next_kv_idx_r <= oacc_next_kv_idx_r + 5'd1;
                micro_tile_count <= micro_tile_count + 32'd1;
                if (oacc_next_kv_idx_r == (KV_TILE_COUNT_W - 5'd1)) begin
                    core_state_r <= CORE_DONE;
                end
            end

            case (core_state_r)
                CORE_IDLE: begin
                    if (start) begin
                        core_state_r <= CORE_INIT;
                        gemm_state_r <= GEMM_IDLE;
                        busy <= 1'b1;
                        error <= 1'b0;
                        cycles <= 32'd0;
                        micro_tile_count <= 32'd0;
                        kv_block_issue_count <= 32'd0;
                        qk_task_count <= 32'd0;
                        score_task_count <= 32'd0;
                        row_state_task_count <= 32'd0;
                        pv_task_count <= 32'd0;
                        oacc_task_count <= 32'd0;
                        for (o_row_i = 0; o_row_i < 4; o_row_i = o_row_i + 1) begin
                            o_tile_row_r[o_row_i] <= 1024'd0;
                        end
                        feed_count_r <= 6'd0;
                        qk_issue_kv_idx_r <= 5'd0;
                        row_next_kv_idx_r <= 5'd0;
                        pv_next_kv_idx_r <= 5'd0;
                        oacc_next_kv_idx_r <= 5'd0;
                        slot_busy_r <= {SLOT_COUNT{1'b0}};
                        score_ready_r <= {SLOT_COUNT{1'b0}};
                        p_ready_r <= {SLOT_COUNT{1'b0}};
                        partial_ready_r <= {SLOT_COUNT{1'b0}};
                        score_active_valid_r <= 1'b0;
                        row_active_valid_r <= 1'b0;
                        oacc_active_valid_r <= 1'b0;
                        p_feed_valid_r <= 1'b0;
                        v_feed_valid_r <= 1'b0;
                        k_feed_valid_r <= 1'b0;
                        row_init_valid_r <= 1'b1;
                    end
                end
                CORE_INIT: begin
                    if (row_init_valid_r && row_init_ready_w) begin
                        row_init_valid_r <= 1'b0;
                    end
                    if (row_init_done_pulse_w) begin
                        core_state_r <= CORE_RUN;
                    end
                end
                CORE_RUN: begin
                    case (gemm_state_r)
                        GEMM_IDLE: begin
                            feed_count_r <= 6'd0;
                            p_feed_valid_r <= 1'b0;
                            v_feed_valid_r <= 1'b0;
                            k_feed_valid_r <= 1'b0;
                            if (pv_can_issue_w) begin
                                pv_active_slot_r <= pv_issue_slot_w;
                                pv_active_kv_idx_r <= slot_kv_idx_r[pv_issue_slot_w];
                                pv_wave_r <= 2'd0;
                                gemm_state_r <= GEMM_PV_REQ;
                            end else if (qk_can_issue_w) begin
                                qk_active_slot_r <= qk_free_slot_idx_w;
                                qk_active_kv_idx_r <= qk_issue_kv_idx_r;
                                slot_busy_r[qk_free_slot_idx_w] <= 1'b1;
                                slot_kv_idx_r[qk_free_slot_idx_w] <= qk_issue_kv_idx_r;
                                score_ready_r[qk_free_slot_idx_w] <= 1'b0;
                                p_ready_r[qk_free_slot_idx_w] <= 1'b0;
                                partial_ready_r[qk_free_slot_idx_w] <= 1'b0;
                                qk_issue_kv_idx_r <= qk_issue_kv_idx_r + 5'd1;
                                kv_block_issue_count <= kv_block_issue_count + 32'd1;
                                gemm_state_r <= GEMM_QK_REQ;
                            end
                        end
                        GEMM_QK_REQ: begin
                            if (k_rd_req_fire_w) begin
                                gemm_state_r <= GEMM_QK_WAIT;
                            end
                        end
                        GEMM_QK_WAIT: begin
                            if (k_rd_resp_valid) begin
                                if (gemm_feed_accept_w) begin
                                    qk_task_count <= qk_task_count + 32'd4;
                                    if (qk_feed_last_w) begin
                                        feed_count_r <= 6'd0;
                                        gemm_state_r <= GEMM_QK_DRAIN;
                                    end else begin
                                        feed_count_r <= feed_count_r + 6'd1;
                                        gemm_state_r <= qk_next_req_fire_w ? GEMM_QK_WAIT : GEMM_QK_REQ;
                                    end
                                end else begin
                                    k_feed_valid_r <= 1'b1;
                                    k_feed_data_r <= k_rd_resp_data;
                                    gemm_state_r <= GEMM_QK_SEND;
                                end
                            end
                        end
                        GEMM_QK_SEND: begin
                            if (gemm_feed_accept_w) begin
                                qk_task_count <= qk_task_count + 32'd4;
                                k_feed_valid_r <= 1'b0;
                                if (qk_feed_last_w) begin
                                    feed_count_r <= 6'd0;
                                    gemm_state_r <= GEMM_QK_DRAIN;
                                end else begin
                                    feed_count_r <= feed_count_r + 6'd1;
                                    gemm_state_r <= qk_next_req_fire_w ? GEMM_QK_WAIT : GEMM_QK_REQ;
                                end
                            end
                        end
                        GEMM_QK_DRAIN: begin
                            if (qk_output_accept_w) begin
                                for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1) begin
                                    for (col_i = 0; col_i < 4; col_i = col_i + 1) begin
                                        slot_score_block_flat_r[qk_active_slot_r][(((gemm_group_idx_w[0][1:0] * 16) + (lane_i * 4) + col_i) * 32) +: 32] <=
                                            clamp_q16_16_from_acc128(gemm_group_data_w[lane_i][(col_i * 128) +: 128]);
                                    end
                                end
                                if (gemm_last_w[0]) begin
                                    score_ready_r[qk_active_slot_r] <= 1'b1;
                                    gemm_state_r <= GEMM_IDLE;
                                end
                            end
                        end
                        GEMM_PV_REQ: begin
                            if (v_rd_req_fire_w) begin
                                gemm_state_r <= GEMM_PV_WAIT;
                            end
                        end
                        GEMM_PV_WAIT: begin
                            if (p_rd_valid_w) begin
                                p_feed_valid_r <= 1'b1;
                                p_feed_data_r <= p_rd_data_w;
                            end
                            if (v_rd_resp_valid) begin
                                v_feed_valid_r <= 1'b1;
                                v_feed_data_r <= v_rd_resp_data;
                            end
                            if (pv_operands_ready_w) begin
                                if (gemm_feed_accept_w) begin
                                    pv_task_count <= pv_task_count + 32'd4;
                                    p_feed_valid_r <= 1'b0;
                                    v_feed_valid_r <= 1'b0;
                                    if (pv_feed_last_w) begin
                                        feed_count_r <= 6'd0;
                                        gemm_state_r <= GEMM_PV_DRAIN;
                                    end else begin
                                        feed_count_r <= feed_count_r + 6'd1;
                                        gemm_state_r <= pv_next_req_fire_w ? GEMM_PV_WAIT : GEMM_PV_REQ;
                                    end
                                end else begin
                                    p_feed_valid_r <= 1'b1;
                                    v_feed_valid_r <= 1'b1;
                                    p_feed_data_r <= pv_p_data_w;
                                    v_feed_data_r <= pv_v_data_w;
                                    gemm_state_r <= GEMM_PV_SEND;
                                end
                            end
                        end
                        GEMM_PV_SEND: begin
                            if (gemm_feed_accept_w) begin
                                pv_task_count <= pv_task_count + 32'd4;
                                p_feed_valid_r <= 1'b0;
                                v_feed_valid_r <= 1'b0;
                                if (pv_feed_last_w) begin
                                    feed_count_r <= 6'd0;
                                    gemm_state_r <= GEMM_PV_DRAIN;
                                end else begin
                                    feed_count_r <= feed_count_r + 6'd1;
                                    gemm_state_r <= pv_next_req_fire_w ? GEMM_PV_WAIT : GEMM_PV_REQ;
                                end
                            end
                        end
                        GEMM_PV_DRAIN: begin
                            if (pv_output_accept_w) begin
                                for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1) begin
                                    for (col_i = 0; col_i < 4; col_i = col_i + 1) begin
                                        global_col_i = (pv_wave_r * 16) + (lane_i * 4) + col_i;
                                        slot_partial_o_row_r[pv_active_slot_r][gemm_group_idx_w[0][1:0]][((global_col_i >> 1) * 32) + ((global_col_i & 1) * 16) +: 16] <=
                                            q16_16_to_q88_sat128(gemm_group_data_w[lane_i][(col_i * 128) +: 128]);
                                    end
                                end
                                if (gemm_last_w[0]) begin
                                    if (pv_wave_r == 2'd3) begin
                                        p_ready_r[pv_active_slot_r] <= 1'b0;
                                        partial_ready_r[pv_active_slot_r] <= 1'b1;
                                        pv_next_kv_idx_r <= pv_next_kv_idx_r + 5'd1;
                                        gemm_state_r <= GEMM_IDLE;
                                    end else begin
                                        pv_wave_r <= pv_wave_r + 2'd1;
                                        feed_count_r <= 6'd0;
                                        gemm_state_r <= GEMM_PV_REQ;
                                    end
                                end
                            end
                        end
                        default: begin
                            gemm_state_r <= GEMM_IDLE;
                            error <= 1'b1;
                        end
                    endcase
                end
                CORE_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    core_state_r <= CORE_IDLE;
                end
                default: begin
                    core_state_r <= CORE_IDLE;
                    gemm_state_r <= GEMM_IDLE;
                    busy <= 1'b0;
                    error <= 1'b1;
                end
            endcase
        end
    end

endmodule
