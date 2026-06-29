module FA_OPTIM_4X4_MICRO_PIPELINE (
    input  wire          clk,
    input  wire          rstn,
    input  wire          clear,
    input  wire          start,
    input  wire          first_kv_tile,
    input  wire [4095:0] q_block_flat,
    input  wire [16383:0] k_tile_flat,
    input  wire [16383:0] v_tile_flat,
    output reg           busy,
    output reg           done,
    output reg           error,
    output reg  [4095:0] o_tile_flat,
    output reg  [31:0]  cycles,
    output reg  [31:0]  qk_task_count,
    output reg  [31:0]  score_task_count,
    output reg  [31:0]  row_state_task_count,
    output reg  [31:0]  pv_task_count,
    output reg  [31:0]  oacc_task_count
);

    localparam [3:0] ST_IDLE       = 4'd0;
    localparam [3:0] ST_ROW_INIT   = 4'd1;
    localparam [3:0] ST_QK_FEED    = 4'd2;
    localparam [3:0] ST_QK_DRAIN   = 4'd3;
    localparam [3:0] ST_SCORE      = 4'd4;
    localparam [3:0] ST_ROW_STATE  = 4'd5;
    localparam [3:0] ST_PV_REQ     = 4'd6;
    localparam [3:0] ST_PV_WAIT    = 4'd7;
    localparam [3:0] ST_PV_SEND    = 4'd8;
    localparam [3:0] ST_PV_DRAIN   = 4'd9;
    localparam [3:0] ST_OACC       = 4'd10;
    localparam [3:0] ST_DONE       = 4'd11;

    reg [3:0] state_r;
    reg [5:0] feed_count_r;
    reg [1:0] qk_key_group_r;
    reg [1:0] pv_wave_r;
    reg [511:0] p_feed_data_r;
    reg [2047:0] score_block_flat_r;
    reg [4095:0] partial_o_block_flat_r;

    reg [3:0]   gemm_start_r;
    reg [3:0]   gemm_valid_r;
    reg [31:0]  gemm_num_acc_r;
    reg [127:0] gemm_a_data_r;
    reg [511:0] gemm_b_data_r;

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
    wire qk_output_accept_w = (state_r == ST_QK_DRAIN) && gemm_group_valid_w[0];
    wire pv_output_accept_w = (state_r == ST_PV_DRAIN) &&
                              gemm_all_output_valid_w && gemm_output_idx_match_w;
    wire [3:0] gemm_group_ready_w =
        (state_r == ST_QK_DRAIN) ? {3'b000, qk_output_accept_w} :
        ((state_r == ST_PV_DRAIN) ? {4{pv_output_accept_w}} : 4'd0);

    wire score_req_valid_w;
    wire score_req_ready_w;
    wire score_resp_valid_w;
    wire score_done_pulse_w;
    wire [3:0] masked_block_row_base_w;
    wire [63:0] masked_score_block_valid_w;
    wire [2047:0] masked_score_block_flat_w;
    wire [8191:0] unused_masked_score_tile_flat_w;
    wire unused_score_row_rd_en_w;
    wire [3:0] unused_score_row_rd_addr_w;

    reg row_init_valid_r;
    wire row_update_valid_w;
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

    reg p_rd_en_r;
    wire p_rd_valid_w;
    wire [511:0] p_rd_data_w;

    wire oacc_req_valid_w;
    reg oacc_req_issued_r;
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
    reg oacc_row_rd_valid_r;
    reg [1023:0] oacc_row_rd_data_r;

    integer lane_i;
    integer col_i;
    integer row_i;
    integer global_col_i;

    assign score_req_valid_w = (state_r == ST_SCORE);
    assign row_update_valid_w = (state_r == ST_ROW_STATE) && score_resp_valid_w;
    assign oacc_req_valid_w = (state_r == ST_OACC) && !oacc_req_issued_r;

    function automatic [31:0] get_q_word;
        input integer row;
        input integer pair_idx;
        begin
            get_q_word = q_block_flat[((row * 32 + pair_idx) * 32) +: 32];
        end
    endfunction

    function automatic [31:0] get_k_word;
        input integer key_row;
        input integer pair_idx;
        begin
            get_k_word = k_tile_flat[((key_row * 32 + pair_idx) * 32) +: 32];
        end
    endfunction

    function automatic [15:0] get_v_elem;
        input integer row;
        input integer col;
        integer word_idx;
        begin
            word_idx = row * 32 + (col >> 1);
            if ((col & 1) == 0) begin
                get_v_elem = v_tile_flat[(word_idx * 32) +: 16];
            end else begin
                get_v_elem = v_tile_flat[(word_idx * 32 + 16) +: 16];
            end
        end
    endfunction

    function automatic [31:0] pack_v_pair;
        input integer pair_idx;
        input integer col;
        begin
            pack_v_pair = {get_v_elem((pair_idx * 2) + 1, col), get_v_elem(pair_idx * 2, col)};
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
        gemm_start_r = 4'd0;
        gemm_valid_r = 4'd0;
        gemm_num_acc_r = 32'd0;
        gemm_a_data_r = 128'd0;
        gemm_b_data_r = 512'd0;

        if (state_r == ST_QK_FEED) begin
            gemm_start_r[0] = (feed_count_r == 6'd0);
            gemm_valid_r[0] = 1'b1;
            gemm_num_acc_r = 32'd32;
            for (row_i = 0; row_i < 4; row_i = row_i + 1) begin
                gemm_a_data_r[(row_i * 32) +: 32] = get_q_word(row_i, feed_count_r);
            end
            for (col_i = 0; col_i < 4; col_i = col_i + 1) begin
                gemm_b_data_r[(col_i * 32) +: 32] =
                    get_k_word((qk_key_group_r * 4) + col_i, feed_count_r);
            end
        end else if (state_r == ST_QK_DRAIN) begin
            gemm_num_acc_r = 32'd32;
        end else if (state_r == ST_PV_SEND) begin
            gemm_start_r = {4{feed_count_r == 6'd0}};
            gemm_valid_r = 4'hf;
            gemm_num_acc_r = 32'd8;
            for (row_i = 0; row_i < 4; row_i = row_i + 1) begin
                gemm_a_data_r[(row_i * 32) +: 32] = p_feed_data_r[(row_i * 32) +: 32];
            end
            for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1) begin
                for (col_i = 0; col_i < 4; col_i = col_i + 1) begin
                    gemm_b_data_r[((lane_i * 4 + col_i) * 32) +: 32] =
                        pack_v_pair(feed_count_r, (pv_wave_r * 16) + (lane_i * 4) + col_i);
                end
            end
        end else if (state_r == ST_PV_DRAIN) begin
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
        .kv_blk_idx(4'd0),
        .causal_en(1'b0),
        .scale_word(32'h0001_0000),
        .neg_large_word(32'hffc0_0000),
        .score_tile_flat(8192'd0),
        .score_block_row_base(4'd0),
        .score_block_flat(score_block_flat_r),
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

    FA_P_BYPASS_REAL u_p_bypass (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .row_p_tile_flat(p_tile_flat_w),
        .rd_en(p_rd_en_r),
        .rd_addr(feed_count_r[2:0]),
        .rd_valid(p_rd_valid_w),
        .rd_data(p_rd_data_w)
    );

    FA_OACC_UPDATE_REAL #(
        .USE_PARTIAL_ROW_INPUT(0),
        .USE_PARTIAL_BLOCK_INPUT(1)
    ) u_oacc_update (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .req_valid(oacc_req_valid_w),
        .req_ready(oacc_req_ready_w),
        .rescale_vec_flat(rescale_vec_flat_w),
        .partial_o_tile_flat(16384'd0),
        .req_row_base(4'd0),
        .partial_o_block_flat(partial_o_block_flat_r),
        .partial_row_rd_en(partial_row_rd_en_w),
        .partial_row_rd_addr(partial_row_rd_addr_w),
        .partial_row_rd_valid(1'b0),
        .partial_row_rd_data(1024'd0),
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
            oacc_row_rd_valid_r <= 1'b0;
            oacc_row_rd_data_r <= 1024'd0;
        end else if (clear) begin
            oacc_row_rd_valid_r <= 1'b0;
            oacc_row_rd_data_r <= 1024'd0;
        end else begin
            oacc_row_rd_valid_r <= oacc_row_rd_en_w;
            oacc_row_rd_data_r <= o_tile_flat[(oacc_row_rd_addr_w[1:0] * 1024) +: 1024];
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            o_tile_flat <= 4096'd0;
            cycles <= 32'd0;
            qk_task_count <= 32'd0;
            score_task_count <= 32'd0;
            row_state_task_count <= 32'd0;
            pv_task_count <= 32'd0;
            oacc_task_count <= 32'd0;
            feed_count_r <= 6'd0;
            qk_key_group_r <= 2'd0;
            pv_wave_r <= 2'd0;
            p_feed_data_r <= 512'd0;
            score_block_flat_r <= 2048'd0;
            partial_o_block_flat_r <= 4096'd0;
            row_init_valid_r <= 1'b0;
            p_rd_en_r <= 1'b0;
            oacc_req_issued_r <= 1'b0;
        end else if (clear) begin
            state_r <= ST_IDLE;
            busy <= 1'b0;
            done <= 1'b0;
            error <= 1'b0;
            o_tile_flat <= 4096'd0;
            cycles <= 32'd0;
            qk_task_count <= 32'd0;
            score_task_count <= 32'd0;
            row_state_task_count <= 32'd0;
            pv_task_count <= 32'd0;
            oacc_task_count <= 32'd0;
            feed_count_r <= 6'd0;
            qk_key_group_r <= 2'd0;
            pv_wave_r <= 2'd0;
            p_feed_data_r <= 512'd0;
            score_block_flat_r <= 2048'd0;
            partial_o_block_flat_r <= 4096'd0;
            row_init_valid_r <= 1'b0;
            p_rd_en_r <= 1'b0;
            oacc_req_issued_r <= 1'b0;
        end else begin
            done <= 1'b0;
            p_rd_en_r <= 1'b0;
            if (busy) begin
                cycles <= cycles + 32'd1;
            end

            case (state_r)
                ST_IDLE: begin
                    if (start) begin
                        busy <= 1'b1;
                        cycles <= 32'd0;
                        error <= 1'b0;
                        if (first_kv_tile) begin
                            o_tile_flat <= 4096'd0;
                        end
                        qk_task_count <= 32'd0;
                        score_task_count <= 32'd0;
                        row_state_task_count <= 32'd0;
                        pv_task_count <= 32'd0;
                        oacc_task_count <= 32'd0;
                        feed_count_r <= 6'd0;
                        qk_key_group_r <= 2'd0;
                        pv_wave_r <= 2'd0;
                        score_block_flat_r <= 2048'd0;
                        partial_o_block_flat_r <= 4096'd0;
                        oacc_req_issued_r <= 1'b0;
                        if (first_kv_tile) begin
                            row_init_valid_r <= 1'b1;
                            state_r <= ST_ROW_INIT;
                        end else begin
                            row_init_valid_r <= 1'b0;
                            state_r <= ST_QK_FEED;
                        end
                    end
                end
                ST_ROW_INIT: begin
                    if (row_init_valid_r && row_init_ready_w) begin
                        row_init_valid_r <= 1'b0;
                    end
                    if (row_init_done_pulse_w) begin
                        state_r <= ST_QK_FEED;
                        feed_count_r <= 6'd0;
                    end
                end
                ST_QK_FEED: begin
                    if (gemm_feed_accept_w) begin
                        qk_task_count <= qk_task_count + 32'd1;
                        if (feed_count_r == 6'd31) begin
                            feed_count_r <= 6'd0;
                            state_r <= ST_QK_DRAIN;
                        end else begin
                            feed_count_r <= feed_count_r + 6'd1;
                        end
                    end
                end
                ST_QK_DRAIN: begin
                    if (qk_output_accept_w) begin
                        for (col_i = 0; col_i < 4; col_i = col_i + 1) begin
                            score_block_flat_r[(((gemm_group_idx_w[0][1:0] * 16) + (qk_key_group_r * 4) + col_i) * 32) +: 32] <=
                                clamp_q16_16_from_acc128(gemm_group_data_w[0][(col_i * 128) +: 128]);
                        end
                        if (gemm_last_w[0]) begin
                            if (qk_key_group_r == 2'd3) begin
                                state_r <= ST_SCORE;
                            end else begin
                                qk_key_group_r <= qk_key_group_r + 2'd1;
                                feed_count_r <= 6'd0;
                                state_r <= ST_QK_FEED;
                            end
                        end
                    end
                end
                ST_SCORE: begin
                    if (score_req_ready_w) begin
                        score_task_count <= score_task_count + 32'd1;
                        state_r <= ST_ROW_STATE;
                    end
                end
                ST_ROW_STATE: begin
                    if (row_update_valid_w && row_update_ready_w) begin
                        row_state_task_count <= row_state_task_count + 32'd1;
                    end
                    if (row_done_pulse_w) begin
                        state_r <= ST_PV_REQ;
                        pv_wave_r <= 2'd0;
                        feed_count_r <= 6'd0;
                    end
                end
                ST_PV_REQ: begin
                    p_rd_en_r <= 1'b1;
                    state_r <= ST_PV_WAIT;
                end
                ST_PV_WAIT: begin
                    if (p_rd_valid_w) begin
                        p_feed_data_r <= p_rd_data_w;
                        state_r <= ST_PV_SEND;
                    end
                end
                ST_PV_SEND: begin
                    if (gemm_feed_accept_w) begin
                        pv_task_count <= pv_task_count + 32'd4;
                        if (feed_count_r == 6'd7) begin
                            feed_count_r <= 6'd0;
                            state_r <= ST_PV_DRAIN;
                        end else begin
                            feed_count_r <= feed_count_r + 6'd1;
                            state_r <= ST_PV_REQ;
                        end
                    end
                end
                ST_PV_DRAIN: begin
                    if (pv_output_accept_w) begin
                        for (lane_i = 0; lane_i < 4; lane_i = lane_i + 1) begin
                            for (col_i = 0; col_i < 4; col_i = col_i + 1) begin
                                global_col_i = (pv_wave_r * 16) + (lane_i * 4) + col_i;
                                partial_o_block_flat_r[(((gemm_group_idx_w[0][1:0] * 32) + (global_col_i >> 1)) * 32) + (((global_col_i & 1) * 16)) +: 16] <=
                                    q16_16_to_q88_sat128(gemm_group_data_w[lane_i][(col_i * 128) +: 128]);
                            end
                        end
                        if (gemm_last_w[0]) begin
                            if (pv_wave_r == 2'd3) begin
                                state_r <= ST_OACC;
                            end else begin
                                pv_wave_r <= pv_wave_r + 2'd1;
                                feed_count_r <= 6'd0;
                                state_r <= ST_PV_REQ;
                            end
                        end
                    end
                end
                ST_OACC: begin
                    if (oacc_req_valid_w && oacc_req_ready_w) begin
                        oacc_req_issued_r <= 1'b1;
                        oacc_task_count <= oacc_task_count + 32'd1;
                    end
                    if (oacc_row_wr_en_w) begin
                        o_tile_flat[(oacc_row_wr_addr_w[1:0] * 1024) +: 1024] <= oacc_row_wr_data_w;
                    end
                    if (oacc_done_pulse_w) begin
                        state_r <= ST_DONE;
                    end
                end
                ST_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    oacc_req_issued_r <= 1'b0;
                    state_r <= ST_IDLE;
                end
                default: begin
                    state_r <= ST_IDLE;
                    busy <= 1'b0;
                    error <= 1'b1;
                end
            endcase
        end
    end

endmodule
