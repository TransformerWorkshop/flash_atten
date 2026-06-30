module FA_SCORE_POST_REAL #(
    parameter USE_SCORE_ROW_INPUT = 0,
    parameter USE_SCORE_BLOCK_INPUT = 0
) (
    input  wire          clk,
    input  wire          rstn,
    input  wire          clear,
    input  wire          req_valid,
    output wire          req_ready,
    input  wire [3:0]    q_blk_idx,
    input  wire [3:0]    kv_blk_idx,
    input  wire          causal_en,
    input  wire [31:0]   scale_word,
    input  wire [31:0]   neg_large_word,
    input  wire [8191:0] score_tile_flat,
    input  wire [3:0]    score_block_row_base,
    input  wire [2047:0] score_block_flat,
    output reg           score_row_rd_en,
    output reg  [3:0]    score_row_rd_addr,
    input  wire          score_row_rd_valid,
    input  wire [511:0]  score_row_rd_data,
    output reg           resp_valid,
    input  wire          resp_ready,
    output reg  [3:0]    masked_block_row_base,
    output reg  [63:0]   masked_score_block_valid,
    output reg  [2047:0] masked_score_block_flat,
    output reg           done_pulse,
    //debug
    output reg  [8191:0] masked_score_tile_flat
);

    localparam [2:0] ST_IDLE     = 3'd0;
    localparam [2:0] ST_RUN      = 3'd1;
    localparam [2:0] ST_ROW_REQ  = 3'd2;
    localparam [2:0] ST_ROW_WAIT = 3'd3;
    localparam [2:0] ST_DONE     = 3'd4;

    reg [2:0] state_r;
    reg [2:0] state_n;
    reg [3:0] q_blk_r;
    reg [3:0] kv_blk_r;
    reg       causal_r;
    reg [31:0] scale_word_r;
    reg [31:0] neg_large_word_r;
    reg [3:0] score_block_row_base_r;
    reg [2047:0] score_block_flat_r;
    reg [3:0] row_idx_r;
    reg [3:0] row_idx_n;
    wire [3:0] row_limit_w;
    wire [3:0] actual_row_idx_w;

    integer col_idx;
    integer global_q_idx;
    integer global_k_idx;
    reg signed [31:0] score_word_s;
    reg signed [31:0] scale_word_s;
    reg signed [63:0] mult_q32_32;
    reg signed [63:0] rounded_q32_32;
    reg signed [31:0] scaled_q16_16;

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

    assign row_limit_w = (USE_SCORE_BLOCK_INPUT != 0) ? 4'd3 : 4'd15;
    assign actual_row_idx_w = (USE_SCORE_BLOCK_INPUT != 0) ? (score_block_row_base_r + row_idx_r) : row_idx_r;
    assign req_ready = (state_r == ST_IDLE) && !resp_valid;

    always @(*) begin
        state_n = state_r;
        row_idx_n = row_idx_r;

        if ((state_r == ST_DONE) && resp_valid && resp_ready) begin
            state_n = ST_IDLE;
        end

        case (state_r)
            ST_IDLE: begin
                if (req_valid && req_ready) begin
                    state_n = (USE_SCORE_ROW_INPUT != 0) ? ST_ROW_REQ : ST_RUN;
                    row_idx_n = 4'd0;
                end
            end
            ST_RUN: begin
                if (row_idx_r == row_limit_w) begin
                    state_n = ST_DONE;
                end else begin
                    row_idx_n = row_idx_r + 1'b1;
                end
            end
            ST_ROW_REQ: begin
                state_n = ST_ROW_WAIT;
            end
            ST_ROW_WAIT: begin
                if (score_row_rd_valid) begin
                    if (row_idx_r == row_limit_w) begin
                        state_n = ST_DONE;
                    end else begin
                        row_idx_n = row_idx_r + 1'b1;
                        state_n = ST_ROW_REQ;
                    end
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

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            q_blk_r <= 4'd0;
            kv_blk_r <= 4'd0;
            causal_r <= 1'b0;
            scale_word_r <= 32'd0;
            neg_large_word_r <= 32'd0;
            score_block_row_base_r <= 4'd0;
            score_block_flat_r <= 2048'd0;
            score_row_rd_en <= 1'b0;
            score_row_rd_addr <= 4'd0;
            resp_valid <= 1'b0;
            masked_block_row_base <= 4'd0;
            masked_score_block_valid <= 64'd0;
            masked_score_block_flat <= 2048'd0;
`ifndef SYNTHESIS
            masked_score_tile_flat <= 8192'd0;
`endif
            done_pulse <= 1'b0;
        end else if (clear) begin
            q_blk_r <= 4'd0;
            kv_blk_r <= 4'd0;
            causal_r <= 1'b0;
            scale_word_r <= 32'd0;
            neg_large_word_r <= 32'd0;
            score_block_row_base_r <= 4'd0;
            score_block_flat_r <= 2048'd0;
            score_row_rd_en <= 1'b0;
            score_row_rd_addr <= 4'd0;
            resp_valid <= 1'b0;
            masked_block_row_base <= 4'd0;
            masked_score_block_valid <= 64'd0;
            masked_score_block_flat <= 2048'd0;
`ifndef SYNTHESIS
            masked_score_tile_flat <= 8192'd0;
`endif
            done_pulse <= 1'b0;
        end else begin
            done_pulse <= 1'b0;
            score_row_rd_en <= 1'b0;

            if (resp_valid && resp_ready) begin
                resp_valid <= 1'b0;
                done_pulse <= 1'b1;
            end

            case (state_r)
                ST_IDLE: begin
                    if (req_valid && req_ready) begin
                        q_blk_r <= q_blk_idx;
                        kv_blk_r <= kv_blk_idx;
                        causal_r <= causal_en;
                        scale_word_r <= scale_word;
                        neg_large_word_r <= neg_large_word;
                        score_block_row_base_r <= score_block_row_base;
                        score_block_flat_r <= score_block_flat;
                        masked_block_row_base <= score_block_row_base;
                        masked_score_block_valid <= 64'd0;
                        masked_score_block_flat <= 2048'd0;
`ifndef SYNTHESIS
                        if ((USE_SCORE_BLOCK_INPUT == 0) || (score_block_row_base == 4'd0)) begin
                            masked_score_tile_flat <= 8192'd0;
                        end
`endif
                    end
                end
                ST_RUN: begin
                    global_q_idx = (q_blk_r * 16) + actual_row_idx_w;
                    for (col_idx = 0; col_idx < 16; col_idx = col_idx + 1) begin
                        global_k_idx = (kv_blk_r * 16) + col_idx;
                        if (USE_SCORE_BLOCK_INPUT != 0) begin
                            score_word_s = score_block_flat_r[((row_idx_r * 16) + col_idx) * 32 +: 32];
                        end else begin
                            score_word_s = score_tile_flat[((row_idx_r * 16) + col_idx) * 32 +: 32];
                        end
                        if (causal_r && (global_k_idx > global_q_idx)) begin
                            masked_score_block_valid[(row_idx_r * 16) + col_idx] <= 1'b0;
                            masked_score_block_flat[((row_idx_r * 16) + col_idx) * 32 +: 32] <= neg_large_word_r;
                            masked_score_tile_flat[((actual_row_idx_w * 16) + col_idx) * 32 +: 32] <= neg_large_word_r;
                        end else begin
                            masked_score_block_valid[(row_idx_r * 16) + col_idx] <= 1'b1;
                            masked_score_block_flat[((row_idx_r * 16) + col_idx) * 32 +: 32] <= q16_mul_rn_sat(score_word_s, scale_word_r);
                            masked_score_tile_flat[((actual_row_idx_w * 16) + col_idx) * 32 +: 32] <= q16_mul_rn_sat(score_word_s, scale_word_r);
                        end
                    end
                    if (row_idx_r == row_limit_w) begin
                        resp_valid <= 1'b1;
                    end
                end
                ST_ROW_REQ: begin
                    score_row_rd_en <= 1'b1;
                    score_row_rd_addr <= row_idx_r;
                end
                ST_ROW_WAIT: begin
                    if (score_row_rd_valid) begin
                        global_q_idx = (q_blk_r * 16) + actual_row_idx_w;
                        for (col_idx = 0; col_idx < 16; col_idx = col_idx + 1) begin
                            global_k_idx = (kv_blk_r * 16) + col_idx;
                            score_word_s = score_row_rd_data[(col_idx * 32) +: 32];
                            if (causal_r && (global_k_idx > global_q_idx)) begin
                                if (row_idx_r < 4) begin
                                    masked_score_block_valid[(row_idx_r * 16) + col_idx] <= 1'b0;
                                end
                                masked_score_block_flat[((row_idx_r * 16) + col_idx) * 32 +: 32] <= neg_large_word_r;
                                masked_score_tile_flat[((row_idx_r * 16) + col_idx) * 32 +: 32] <= neg_large_word_r;
                            end else begin
                                if (row_idx_r < 4) begin
                                    masked_score_block_valid[(row_idx_r * 16) + col_idx] <= 1'b1;
                                end
                                masked_score_block_flat[((row_idx_r * 16) + col_idx) * 32 +: 32] <= q16_mul_rn_sat(score_word_s, scale_word_r);
                                masked_score_tile_flat[((row_idx_r * 16) + col_idx) * 32 +: 32] <= q16_mul_rn_sat(score_word_s, scale_word_r);
                            end
                        end
                        if (row_idx_r == row_limit_w) begin
                            resp_valid <= 1'b1;
                        end
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

module FA_SCORE_POST_Q4_BLOCK_REAL (
    input  wire          clk,
    input  wire          rstn,
    input  wire          clear,
    input  wire          req_valid,
    output wire          req_ready,
    input  wire [3:0]    q_blk_idx,
    input  wire [3:0]    kv_blk_idx,
    input  wire          causal_en,
    input  wire [3:0]    score_block_row_base,
    input  wire [2047:0] score_block_flat,
    output reg           resp_valid,
    input  wire          resp_ready,
    output reg  [63:0]   masked_score_block_valid,
    output reg  [2047:0] masked_score_block_flat,
    output reg           done_pulse
);

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_RUN  = 2'd1;
    localparam [1:0] ST_DONE = 2'd2;

    reg [1:0] state_r;
    reg [1:0] state_n;
    reg [1:0] row_idx_r;
    reg [1:0] row_idx_n;
    reg [3:0] q_blk_r;
    reg [3:0] kv_blk_r;
    reg       causal_r;
    reg [3:0] score_block_row_base_r;
    reg [2047:0] score_block_flat_r;

    integer col_idx;
    integer global_q_idx;
    integer global_k_idx;
    reg signed [31:0] score_word_s;

    assign req_ready = (state_r == ST_IDLE) && !resp_valid;

    always @(*) begin
        state_n = state_r;
        row_idx_n = row_idx_r;

        if ((state_r == ST_DONE) && resp_valid && resp_ready) begin
            state_n = ST_IDLE;
        end

        case (state_r)
            ST_IDLE: begin
                if (req_valid && req_ready) begin
                    state_n = ST_RUN;
                    row_idx_n = 2'd0;
                end
            end
            ST_RUN: begin
                if (row_idx_r == 2'd3) begin
                    state_n = ST_DONE;
                end else begin
                    row_idx_n = row_idx_r + 1'b1;
                end
            end
            ST_DONE: begin
            end
            default: begin
                state_n = ST_IDLE;
                row_idx_n = 2'd0;
            end
        endcase
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            row_idx_r <= 2'd0;
        end else if (clear) begin
            state_r <= ST_IDLE;
            row_idx_r <= 2'd0;
        end else begin
            state_r <= state_n;
            row_idx_r <= row_idx_n;
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            q_blk_r <= 4'd0;
            kv_blk_r <= 4'd0;
            causal_r <= 1'b0;
            score_block_row_base_r <= 4'd0;
            score_block_flat_r <= 2048'd0;
            resp_valid <= 1'b0;
            masked_score_block_valid <= 64'd0;
            masked_score_block_flat <= 2048'd0;
            done_pulse <= 1'b0;
        end else if (clear) begin
            q_blk_r <= 4'd0;
            kv_blk_r <= 4'd0;
            causal_r <= 1'b0;
            score_block_row_base_r <= 4'd0;
            score_block_flat_r <= 2048'd0;
            resp_valid <= 1'b0;
            masked_score_block_valid <= 64'd0;
            masked_score_block_flat <= 2048'd0;
            done_pulse <= 1'b0;
        end else begin
            done_pulse <= 1'b0;

            if (resp_valid && resp_ready) begin
                resp_valid <= 1'b0;
                done_pulse <= 1'b1;
            end

            case (state_r)
                ST_IDLE: begin
                    if (req_valid && req_ready) begin
                        q_blk_r <= q_blk_idx;
                        kv_blk_r <= kv_blk_idx;
                        causal_r <= causal_en;
                        score_block_row_base_r <= score_block_row_base;
                        score_block_flat_r <= score_block_flat;
                        masked_score_block_valid <= 64'd0;
                        masked_score_block_flat <= 2048'd0;
                    end
                end
                ST_RUN: begin
                    global_q_idx = (q_blk_r * 16) + score_block_row_base_r + row_idx_r;
                    for (col_idx = 0; col_idx < 16; col_idx = col_idx + 1) begin
                        global_k_idx = (kv_blk_r * 16) + col_idx;
                        score_word_s = score_block_flat_r[(((row_idx_r * 16) + col_idx) * 32) +: 32];
                        if (causal_r && (global_k_idx > global_q_idx)) begin
                            masked_score_block_valid[(row_idx_r * 16) + col_idx] <= 1'b0;
                            masked_score_block_flat[(((row_idx_r * 16) + col_idx) * 32) +: 32] <= 32'hffc0_0000;
                        end else begin
                            masked_score_block_valid[(row_idx_r * 16) + col_idx] <= 1'b1;
                            masked_score_block_flat[(((row_idx_r * 16) + col_idx) * 32) +: 32] <= score_word_s;
                        end
                    end
                    if (row_idx_r == 2'd3) begin
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
