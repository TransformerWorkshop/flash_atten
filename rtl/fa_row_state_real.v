module FA_ROW_STATE_REAL #(
    parameter USE_MASKED_BLOCK_INPUT = 0,
    parameter USE_VALID_MASK_INPUT = 0
) (
    input  wire          clk,
    input  wire          rstn,
    input  wire          clear,
    input  wire          init_valid,
    output wire          init_ready,
    output reg           init_done_pulse,
    input  wire          update_valid,
    output wire          update_ready,
    input  wire [31:0]   neg_large_word,
    input  wire [8191:0] masked_score_tile_flat,
    input  wire [3:0]    update_row_base,
    input  wire [63:0]   masked_score_block_valid,
    input  wire [2047:0] masked_score_block_flat,
    output reg           resp_valid,
    input  wire          resp_ready,
    output reg  [4095:0] p_tile_flat,
    output reg  [511:0]  rescale_vec_flat,
    output reg           done_pulse,
    input  wire          restore_valid,
    input  wire [511:0]  restore_m_state_flat,
    input  wire [511:0]  restore_l_state_flat,
    input  wire [15:0]   restore_row_seen,
    //debug
    output wire [511:0]  debug_m_state_flat,
    output wire [511:0]  debug_l_state_flat,
    output wire [15:0]   debug_row_seen
);

    localparam [2:0] ST_IDLE        = 3'd0;
    localparam [2:0] ST_INIT        = 3'd1;
    localparam [2:0] ST_ROW_PREP    = 3'd2;
    localparam [2:0] ST_ROW_EXP     = 3'd3;
    localparam [2:0] ST_ROW_DIV_WAIT = 3'd4;
    localparam [2:0] ST_ROW_COMMIT  = 3'd5;
    localparam [2:0] ST_DONE        = 3'd6;

    localparam signed [31:0] Q16_ONE = 32'sh0001_0000;
    localparam signed [31:0] Q16_ZERO = 32'sh0000_0000;
    localparam signed [31:0] Q16_NEG_EIGHT = -32'sd524288;

    reg [2:0] state_r;
    reg [2:0] state_n;
    reg [3:0] row_idx_r;
    reg [3:0] row_idx_n;
    reg [31:0] neg_large_word_r;
    reg [3:0] update_row_base_r;
    reg [63:0] masked_score_block_valid_r;
    reg [2047:0] masked_score_block_flat_r;

    reg signed [31:0] m_state_r [0:15];
    reg signed [31:0] l_state_r [0:15];
    reg               row_seen_r [0:15];

    reg signed [31:0] row_score_r [0:15];
    reg [15:0]        row_valid_mask_r;
    reg               row_has_valid_r;
    reg               row_has_history_r;
    reg signed [31:0] old_m_r;
    reg signed [31:0] old_l_r;
    reg signed [31:0] tile_row_max_r;
    reg signed [31:0] m_new_r;
    reg signed [31:0] alpha_r;
    reg signed [31:0] alpha_l_old_r;
    reg signed [31:0] sum_beta_r;
    reg signed [31:0] l_new_r;
    reg signed [31:0] beta_r [0:15];
    reg signed [31:0] recip_l_new_r;

    wire         recip_req_ready_w;
    wire         recip_resp_valid_w;
    wire [31:0]  recip_out_value_w;
    wire         recip_done_pulse_w;
    wire         rowstate_unused_zero_w = (recip_done_pulse_w & 1'b0) | (alpha_r[0] & 1'b0) | (sum_beta_r[0] & 1'b0);
    wire [3:0]  row_limit_w;
    wire [3:0]  actual_row_idx_w;

    integer row_i;
    integer col_i;
    integer word_i;
    integer lane_i;
    reg signed [31:0] score_word_s;
    reg               score_valid_s;
    reg [15:0]        valid_mask_next;
    reg               row_has_valid_next;
    reg signed [31:0] tile_row_max_next;
    reg signed [31:0] clamped_delta_s;
    reg [8:0]         exp_idx_s;
    reg signed [31:0] exp_val_s;
    reg signed [31:0] beta_sum_next;
    reg signed [31:0] alpha_next;
    reg signed [31:0] alpha_l_old_next;
    reg signed [31:0] l_new_next;
    reg signed [31:0] m_new_next;
    reg signed [31:0] beta_next [0:15];
    reg signed [63:0] mul_tmp_s;
    reg signed [63:0] rounded_tmp_s;
    reg signed [31:0] p_q16_s;
    reg signed [15:0] p_q88_s;
    reg signed [31:0] rescale_q16_s;
    reg signed [31:0] m_debug_word_s;
    reg signed [31:0] l_debug_word_s;

    function automatic signed [31:0] q16_add_sat;
        input signed [31:0] lhs;
        input signed [31:0] rhs;
        reg signed [32:0] sum_ext;
        begin
            sum_ext = lhs + rhs;
            if (sum_ext > 33'sh0_7FFF_FFFF) begin
                q16_add_sat = 32'sh7FFF_FFFF;
            end else if (sum_ext < -33'sh0_8000_0000) begin
                q16_add_sat = -32'sh8000_0000;
            end else begin
                q16_add_sat = sum_ext[31:0];
            end
        end
    endfunction

    function automatic signed [31:0] q16_mul_rn_sat;
        input signed [31:0] lhs;
        input signed [31:0] rhs;
        reg signed [63:0] prod;
        reg signed [63:0] rounded;
        reg signed [63:0] shifted;
        begin
            prod = lhs * rhs;
            if (prod >= 0) begin
                rounded = prod + 64'sd32768;
            end else begin
                rounded = prod - 64'sd32768;
            end
            shifted = rounded >>> 16;
            if (shifted > 64'sh7FFF_FFFF) begin
                q16_mul_rn_sat = 32'sh7FFF_FFFF;
            end else if (shifted < -64'sh8000_0000) begin
                q16_mul_rn_sat = -32'sh8000_0000;
            end else begin
                q16_mul_rn_sat = shifted[31:0];
            end
        end
    endfunction

    function automatic signed [15:0] q16_to_q88_rn_sat;
        input signed [31:0] value;
        reg signed [31:0] rounded;
        reg signed [31:0] shifted;
        begin
            if (value >= 0) begin
                rounded = value + 32'sd128;
            end else begin
                rounded = value - 32'sd128;
            end
            shifted = rounded >>> 8;
            if (shifted > 32'sd32767) begin
                q16_to_q88_rn_sat = 16'sh7FFF;
            end else if (shifted < -32'sd32768) begin
                q16_to_q88_rn_sat = -16'sh8000;
            end else begin
                q16_to_q88_rn_sat = shifted[15:0];
            end
        end
    endfunction

    function automatic signed [31:0] q16_clamp_nonpos_neg8;
        input signed [31:0] value;
        begin
            if (value > Q16_ZERO) begin
                q16_clamp_nonpos_neg8 = Q16_ZERO;
            end else if (value < Q16_NEG_EIGHT) begin
                q16_clamp_nonpos_neg8 = Q16_NEG_EIGHT;
            end else begin
                q16_clamp_nonpos_neg8 = value;
            end
        end
    endfunction

    function automatic [8:0] q16_delta_to_exp_idx;
        input signed [31:0] delta;
        reg signed [31:0] clamped;
        reg [31:0] abs_mag;
        reg [31:0] rounded;
        reg [31:0] shifted;
        begin
            clamped = q16_clamp_nonpos_neg8(delta);
            abs_mag = -clamped;
            rounded = abs_mag + 32'd1024;
            shifted = rounded >> 11;
            if (shifted > 32'd256) begin
                q16_delta_to_exp_idx = 9'd256;
            end else begin
                q16_delta_to_exp_idx = shifted[8:0];
            end
        end
    endfunction

    function automatic [31:0] fa_exp_lut_q16_16;
        input [8:0] idx;
        begin
            case (idx)
`include "fa_exp_lut_q16_16.vh"
                default: fa_exp_lut_q16_16 = 32'h00000016;
            endcase
        end
    endfunction

    //debug
    generate
        genvar gi;
        for (gi = 0; gi < 16; gi = gi + 1) begin : gen_debug_flat
            assign debug_m_state_flat[(gi * 32) +: 32] = m_state_r[gi];
            assign debug_l_state_flat[(gi * 32) +: 32] = l_state_r[gi];
            assign debug_row_seen[gi] = row_seen_r[gi];
        end
    endgenerate

    assign init_ready = (state_r == ST_IDLE) && !resp_valid;
    assign update_ready = ((state_r == ST_IDLE) && !resp_valid) || rowstate_unused_zero_w;
    assign row_limit_w = (USE_MASKED_BLOCK_INPUT != 0) ? 4'd3 : 4'd15;
    assign actual_row_idx_w = (USE_MASKED_BLOCK_INPUT != 0) ? (update_row_base_r + row_idx_r) : row_idx_r;

    always @(*) begin
        state_n = state_r;
        row_idx_n = row_idx_r;

        if ((state_r == ST_DONE) && resp_valid && resp_ready) begin
            state_n = ST_IDLE;
        end

        case (state_r)
            ST_IDLE: begin
                if (init_valid && init_ready) begin
                    state_n = ST_INIT;
                end else if (update_valid && update_ready) begin
                    state_n = ST_ROW_PREP;
                    row_idx_n = 4'd0;
                end
            end
            ST_INIT: begin
                state_n = ST_IDLE;
            end
            ST_ROW_PREP: begin
                if (!row_has_valid_next) begin
                    state_n = ST_ROW_COMMIT;
                end else begin
                    state_n = ST_ROW_EXP;
                end
            end
            ST_ROW_EXP: begin
                if (recip_req_ready_w) begin
                    state_n = ST_ROW_DIV_WAIT;
                end
            end
            ST_ROW_DIV_WAIT: begin
                if (recip_resp_valid_w) begin
                    state_n = ST_ROW_COMMIT;
                end
            end
            ST_ROW_COMMIT: begin
                if (row_idx_r == row_limit_w) begin
                    state_n = ST_DONE;
                end else begin
                    row_idx_n = row_idx_r + 1'b1;
                    state_n = ST_ROW_PREP;
                end
            end
            ST_DONE: begin
            end
            default: begin
                state_n = ST_IDLE;
                row_idx_n = 4'd0;
            end
        endcase
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            row_idx_r <= 4'd0;
        end else if (clear) begin
            state_r <= ST_IDLE;
            row_idx_r <= 4'd0;
        end else begin
            state_r <= state_n;
            row_idx_r <= row_idx_n;
        end
    end

    FA_RECIP_Q16_16 u_recip (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .req_valid((state_r == ST_ROW_EXP) && row_has_valid_r),
        .req_ready(recip_req_ready_w),
        .in_value(l_new_next),
        .resp_valid(recip_resp_valid_w),
        .resp_ready(1'b1),
        .out_value(recip_out_value_w),
        .done_pulse(recip_done_pulse_w)
    );

    always @(*) begin
        valid_mask_next = 16'd0;
        row_has_valid_next = 1'b0;
        tile_row_max_next = neg_large_word_r;
        for (col_i = 0; col_i < 16; col_i = col_i + 1) begin
            if (USE_MASKED_BLOCK_INPUT != 0) begin
                score_word_s = masked_score_block_flat_r[((row_idx_r * 16) + col_i) * 32 +: 32];
            end else begin
                score_word_s = masked_score_tile_flat[((row_idx_r * 16) + col_i) * 32 +: 32];
            end
            if ((USE_VALID_MASK_INPUT != 0) && (USE_MASKED_BLOCK_INPUT != 0)) begin
                score_valid_s = masked_score_block_valid_r[(row_idx_r * 16) + col_i];
            end else begin
                score_valid_s = (score_word_s != neg_large_word_r);
            end
            if (score_valid_s) begin
                valid_mask_next[col_i] = 1'b1;
                if (!row_has_valid_next || (score_word_s > tile_row_max_next)) begin
                    tile_row_max_next = score_word_s;
                end
                row_has_valid_next = 1'b1;
            end
        end
    end

    always @(*) begin
        if (row_has_history_r) begin
            if (old_m_r > tile_row_max_r) begin
                m_new_next = old_m_r;
            end else begin
                m_new_next = tile_row_max_r;
            end
        end else begin
            m_new_next = tile_row_max_r;
        end

        if (row_has_history_r) begin
            alpha_next = fa_exp_lut_q16_16(q16_delta_to_exp_idx(old_m_r - m_new_next));
            alpha_l_old_next = q16_mul_rn_sat(alpha_next, old_l_r);
        end else begin
            alpha_next = Q16_ZERO;
            alpha_l_old_next = Q16_ZERO;
        end

        beta_sum_next = Q16_ZERO;
        for (col_i = 0; col_i < 16; col_i = col_i + 1) begin
            if (row_valid_mask_r[col_i]) begin
                beta_next[col_i] = fa_exp_lut_q16_16(q16_delta_to_exp_idx(row_score_r[col_i] - m_new_next));
            end else begin
                beta_next[col_i] = Q16_ZERO;
            end
            beta_sum_next = q16_add_sat(beta_sum_next, beta_next[col_i]);
        end
        l_new_next = q16_add_sat(alpha_l_old_next, beta_sum_next);
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            neg_large_word_r <= 32'd0;
            row_valid_mask_r <= 16'd0;
            row_has_valid_r <= 1'b0;
            row_has_history_r <= 1'b0;
            old_m_r <= Q16_ZERO;
            old_l_r <= Q16_ZERO;
            tile_row_max_r <= Q16_ZERO;
            m_new_r <= Q16_ZERO;
            alpha_r <= Q16_ZERO;
            alpha_l_old_r <= Q16_ZERO;
            sum_beta_r <= Q16_ZERO;
            l_new_r <= Q16_ZERO;
            recip_l_new_r <= Q16_ZERO;
            update_row_base_r <= 4'd0;
            masked_score_block_valid_r <= 64'd0;
            masked_score_block_flat_r <= 2048'd0;
`ifndef SYNTHESIS
            p_tile_flat <= 4096'd0;
            rescale_vec_flat <= 512'd0;
`endif
            init_done_pulse <= 1'b0;
            resp_valid <= 1'b0;
            done_pulse <= 1'b0;
            for (row_i = 0; row_i < 16; row_i = row_i + 1) begin
                m_state_r[row_i] <= Q16_ZERO;
                l_state_r[row_i] <= Q16_ZERO;
                row_seen_r[row_i] <= 1'b0;
            end
            for (col_i = 0; col_i < 16; col_i = col_i + 1) begin
                row_score_r[col_i] <= Q16_ZERO;
                beta_r[col_i] <= Q16_ZERO;
            end
        end else if (clear) begin
            neg_large_word_r <= 32'd0;
            row_valid_mask_r <= 16'd0;
            row_has_valid_r <= 1'b0;
            row_has_history_r <= 1'b0;
            old_m_r <= Q16_ZERO;
            old_l_r <= Q16_ZERO;
            tile_row_max_r <= Q16_ZERO;
            m_new_r <= Q16_ZERO;
            alpha_r <= Q16_ZERO;
            alpha_l_old_r <= Q16_ZERO;
            sum_beta_r <= Q16_ZERO;
            l_new_r <= Q16_ZERO;
            recip_l_new_r <= Q16_ZERO;
            update_row_base_r <= 4'd0;
            masked_score_block_valid_r <= 64'd0;
            masked_score_block_flat_r <= 2048'd0;
`ifndef SYNTHESIS
            p_tile_flat <= 4096'd0;
            rescale_vec_flat <= 512'd0;
`endif
            init_done_pulse <= 1'b0;
            resp_valid <= 1'b0;
            done_pulse <= 1'b0;
            for (row_i = 0; row_i < 16; row_i = row_i + 1) begin
                m_state_r[row_i] <= Q16_ZERO;
                l_state_r[row_i] <= Q16_ZERO;
                row_seen_r[row_i] <= 1'b0;
            end
            for (col_i = 0; col_i < 16; col_i = col_i + 1) begin
                row_score_r[col_i] <= Q16_ZERO;
                beta_r[col_i] <= Q16_ZERO;
            end
        end else begin
            init_done_pulse <= 1'b0;
            done_pulse <= 1'b0;

            if (resp_valid && resp_ready) begin
                resp_valid <= 1'b0;
                done_pulse <= 1'b1;
            end

            case (state_r)
                ST_IDLE: begin
                    if (init_valid && init_ready) begin
                        neg_large_word_r <= neg_large_word;
`ifndef SYNTHESIS
                        p_tile_flat <= 4096'd0;
                        rescale_vec_flat <= 512'd0;
`endif
                        for (row_i = 0; row_i < 16; row_i = row_i + 1) begin
                            if (restore_valid) begin
                                m_state_r[row_i] <= restore_m_state_flat[(row_i * 32) +: 32];
                                l_state_r[row_i] <= restore_l_state_flat[(row_i * 32) +: 32];
                                row_seen_r[row_i] <= restore_row_seen[row_i];
                            end else begin
                                m_state_r[row_i] <= neg_large_word;
                                l_state_r[row_i] <= Q16_ZERO;
                                row_seen_r[row_i] <= 1'b0;
                            end
                        end
                    end else if (update_valid && update_ready) begin
                        neg_large_word_r <= neg_large_word;
                        update_row_base_r <= update_row_base;
                        masked_score_block_valid_r <= masked_score_block_valid;
                        masked_score_block_flat_r <= masked_score_block_flat;
`ifndef SYNTHESIS
                        if ((USE_MASKED_BLOCK_INPUT == 0) || (update_row_base == 4'd0)) begin
                            p_tile_flat <= 4096'd0;
                            rescale_vec_flat <= 512'd0;
                        end
`endif
                    end
                end
                ST_INIT: begin
                    init_done_pulse <= 1'b1;
                end
                ST_ROW_PREP: begin
                    row_valid_mask_r <= valid_mask_next;
                    row_has_valid_r <= row_has_valid_next;
                    row_has_history_r <= row_seen_r[actual_row_idx_w];
                    old_m_r <= m_state_r[actual_row_idx_w];
                    old_l_r <= l_state_r[actual_row_idx_w];
                    tile_row_max_r <= tile_row_max_next;
                    for (col_i = 0; col_i < 16; col_i = col_i + 1) begin
                        if (USE_MASKED_BLOCK_INPUT != 0) begin
                            row_score_r[col_i] <= masked_score_block_flat_r[((row_idx_r * 16) + col_i) * 32 +: 32];
                        end else begin
                            row_score_r[col_i] <= masked_score_tile_flat[((row_idx_r * 16) + col_i) * 32 +: 32];
                        end
                    end
                end
                ST_ROW_EXP: begin
                    if (recip_req_ready_w) begin
                        m_new_r <= m_new_next;
                        alpha_r <= alpha_next;
                        alpha_l_old_r <= alpha_l_old_next;
                        sum_beta_r <= beta_sum_next;
                        l_new_r <= l_new_next;
                        for (col_i = 0; col_i < 16; col_i = col_i + 1) begin
                            beta_r[col_i] <= beta_next[col_i];
                        end
                    end
                end
                ST_ROW_DIV_WAIT: begin
                    if (recip_resp_valid_w) begin
                        recip_l_new_r <= recip_out_value_w;
                    end
                end
                ST_ROW_COMMIT: begin
                    if (!row_has_valid_r) begin
                        for (col_i = 0; col_i < 16; col_i = col_i + 1) begin
                            word_i = ((actual_row_idx_w * 16) + col_i) >> 1;
                            lane_i = col_i & 1;
                            p_tile_flat[(word_i * 32) + (lane_i * 16) +: 16] <= 16'd0;
                        end
                        if (row_has_history_r) begin
                            rescale_vec_flat[(actual_row_idx_w * 32) +: 32] <= Q16_ONE;
                        end else begin
                            rescale_vec_flat[(actual_row_idx_w * 32) +: 32] <= Q16_ZERO;
                            m_state_r[actual_row_idx_w] <= neg_large_word_r;
                            l_state_r[actual_row_idx_w] <= Q16_ZERO;
                            row_seen_r[actual_row_idx_w] <= 1'b0;
                        end
                    end else begin
                        rescale_q16_s = q16_mul_rn_sat(alpha_l_old_r, recip_l_new_r);
                        rescale_vec_flat[(actual_row_idx_w * 32) +: 32] <= rescale_q16_s;
                        for (col_i = 0; col_i < 16; col_i = col_i + 1) begin
                            p_q16_s = q16_mul_rn_sat(beta_r[col_i], recip_l_new_r);
                            p_q88_s = q16_to_q88_rn_sat(p_q16_s);
                            word_i = ((actual_row_idx_w * 16) + col_i) >> 1;
                            lane_i = col_i & 1;
                            p_tile_flat[(word_i * 32) + (lane_i * 16) +: 16] <= p_q88_s;
                        end
                        m_state_r[actual_row_idx_w] <= m_new_r;
                        l_state_r[actual_row_idx_w] <= l_new_r;
                        row_seen_r[actual_row_idx_w] <= 1'b1;
                    end

                    if (row_idx_r == row_limit_w) begin
                        resp_valid <= 1'b1;
                    end
                end
                ST_DONE: begin
                end
                default: begin
                end
            endcase
        end
    end

endmodule
