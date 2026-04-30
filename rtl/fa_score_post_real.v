module FA_SCORE_POST_REAL (
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
    input  wire [3:0]    score_block_row_base,
    input  wire [2047:0] score_block_flat,
    output reg           resp_valid,
    input  wire          resp_ready,
    output reg  [3:0]    masked_block_row_base,
    output reg  [63:0]   masked_score_block_valid,
    output reg  [2047:0] masked_score_block_flat,
    output reg           done_pulse,
    //debug
    output wire [8191:0] masked_score_tile_flat
);

    localparam [2:0] ST_IDLE     = 3'd0;
    localparam [2:0] ST_RUN      = 3'd1;
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
    wire [3:0] actual_row_idx_w;
    wire [7:0] global_q_idx_w;
    wire [7:0] kv_global_base_w;
    (* keep = "true" *) wire signed [31:0] scale_word_g0_w;
    (* keep = "true" *) wire signed [31:0] scale_word_g1_w;
    (* keep = "true" *) wire signed [31:0] scale_word_g2_w;
    (* keep = "true" *) wire signed [31:0] scale_word_g3_w;
    (* keep = "true" *) wire causal_g0_w;
    (* keep = "true" *) wire causal_g1_w;
    (* keep = "true" *) wire causal_g2_w;
    (* keep = "true" *) wire causal_g3_w;
    (* keep = "true" *) wire [7:0] global_q_idx_g0_w;
    (* keep = "true" *) wire [7:0] global_q_idx_g1_w;
    (* keep = "true" *) wire [7:0] global_q_idx_g2_w;
    (* keep = "true" *) wire [7:0] global_q_idx_g3_w;
    (* keep = "true" *) wire [7:0] kv_global_base_g0_w;
    (* keep = "true" *) wire [7:0] kv_global_base_g1_w;
    (* keep = "true" *) wire [7:0] kv_global_base_g2_w;
    (* keep = "true" *) wire [7:0] kv_global_base_g3_w;

    integer col_idx;
    integer global_k_idx;
    reg signed [31:0] score_word_s;
    reg signed [31:0] scaled_q16_16;
`ifndef SYNTHESIS
    reg [8191:0] masked_score_tile_flat_r;
`endif

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

    assign actual_row_idx_w = score_block_row_base_r + row_idx_r;
    assign global_q_idx_w = {q_blk_r, 4'b0000} + {4'b0000, actual_row_idx_w};
    assign kv_global_base_w = {kv_blk_r, 4'b0000};
    assign scale_word_g0_w = scale_word_r;
    assign scale_word_g1_w = scale_word_r;
    assign scale_word_g2_w = scale_word_r;
    assign scale_word_g3_w = scale_word_r;
    assign causal_g0_w = causal_r;
    assign causal_g1_w = causal_r;
    assign causal_g2_w = causal_r;
    assign causal_g3_w = causal_r;
    assign global_q_idx_g0_w = global_q_idx_w;
    assign global_q_idx_g1_w = global_q_idx_w;
    assign global_q_idx_g2_w = global_q_idx_w;
    assign global_q_idx_g3_w = global_q_idx_w;
    assign kv_global_base_g0_w = kv_global_base_w;
    assign kv_global_base_g1_w = kv_global_base_w;
    assign kv_global_base_g2_w = kv_global_base_w;
    assign kv_global_base_g3_w = kv_global_base_w;
    assign req_ready = (state_r == ST_IDLE) && !resp_valid;
`ifndef SYNTHESIS
    assign masked_score_tile_flat = masked_score_tile_flat_r;
`else
    wire score_post_debug_zero_w = (clk & 1'b0)
                                 | (rstn & 1'b0)
                                 | (clear & 1'b0)
                                 | (req_valid & 1'b0)
                                 | ((|q_blk_idx) & 1'b0)
                                 | ((|kv_blk_idx) & 1'b0)
                                 | (causal_en & 1'b0)
                                 | ((|scale_word) & 1'b0)
                                 | ((|neg_large_word) & 1'b0)
                                 | ((|score_block_row_base) & 1'b0)
                                 | ((|score_block_flat) & 1'b0);
    assign masked_score_tile_flat = {8192{score_post_debug_zero_w}};
`endif

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
                    row_idx_n = 4'd0;
                end
            end
            ST_RUN: begin
                if (row_idx_r == 4'd3) begin
                    state_n = ST_DONE;
                end else begin
                    row_idx_n = row_idx_r + 1'b1;
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
            resp_valid <= 1'b0;
            masked_block_row_base <= 4'd0;
            masked_score_block_valid <= 64'd0;
            masked_score_block_flat <= 2048'd0;
`ifndef SYNTHESIS
            masked_score_tile_flat_r <= 8192'd0;
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
            resp_valid <= 1'b0;
            masked_block_row_base <= 4'd0;
            masked_score_block_valid <= 64'd0;
            masked_score_block_flat <= 2048'd0;
`ifndef SYNTHESIS
            masked_score_tile_flat_r <= 8192'd0;
`endif
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
                        scale_word_r <= scale_word;
                        neg_large_word_r <= neg_large_word;
                        score_block_row_base_r <= score_block_row_base;
                        score_block_flat_r <= score_block_flat;
                        masked_block_row_base <= score_block_row_base;
                        masked_score_block_valid <= 64'd0;
                        masked_score_block_flat <= 2048'd0;
`ifndef SYNTHESIS
                        if (score_block_row_base == 4'd0) begin
                            masked_score_tile_flat_r <= 8192'd0;
                        end
`endif
                    end
                end
                ST_RUN: begin
                    for (col_idx = 0; col_idx < 4; col_idx = col_idx + 1) begin
                        global_k_idx = kv_global_base_g0_w + col_idx;
                        score_word_s = score_block_flat_r[((row_idx_r * 16) + col_idx) * 32 +: 32];
                        scaled_q16_16 = q16_mul_rn_sat(score_word_s, scale_word_g0_w);
                        if (causal_g0_w && (global_k_idx > global_q_idx_g0_w)) begin
                            masked_score_block_valid[(row_idx_r * 16) + col_idx] <= 1'b0;
                            masked_score_block_flat[((row_idx_r * 16) + col_idx) * 32 +: 32] <= neg_large_word_r;
`ifndef SYNTHESIS
                            masked_score_tile_flat_r[((actual_row_idx_w * 16) + col_idx) * 32 +: 32] <= neg_large_word_r;
`endif
                        end else begin
                            masked_score_block_valid[(row_idx_r * 16) + col_idx] <= 1'b1;
                            masked_score_block_flat[((row_idx_r * 16) + col_idx) * 32 +: 32] <= scaled_q16_16;
`ifndef SYNTHESIS
                            masked_score_tile_flat_r[((actual_row_idx_w * 16) + col_idx) * 32 +: 32] <= scaled_q16_16;
`endif
                        end
                    end
                    for (col_idx = 4; col_idx < 8; col_idx = col_idx + 1) begin
                        global_k_idx = kv_global_base_g1_w + col_idx;
                        score_word_s = score_block_flat_r[((row_idx_r * 16) + col_idx) * 32 +: 32];
                        scaled_q16_16 = q16_mul_rn_sat(score_word_s, scale_word_g1_w);
                        if (causal_g1_w && (global_k_idx > global_q_idx_g1_w)) begin
                            masked_score_block_valid[(row_idx_r * 16) + col_idx] <= 1'b0;
                            masked_score_block_flat[((row_idx_r * 16) + col_idx) * 32 +: 32] <= neg_large_word_r;
`ifndef SYNTHESIS
                            masked_score_tile_flat_r[((actual_row_idx_w * 16) + col_idx) * 32 +: 32] <= neg_large_word_r;
`endif
                        end else begin
                            masked_score_block_valid[(row_idx_r * 16) + col_idx] <= 1'b1;
                            masked_score_block_flat[((row_idx_r * 16) + col_idx) * 32 +: 32] <= scaled_q16_16;
`ifndef SYNTHESIS
                            masked_score_tile_flat_r[((actual_row_idx_w * 16) + col_idx) * 32 +: 32] <= scaled_q16_16;
`endif
                        end
                    end
                    for (col_idx = 8; col_idx < 12; col_idx = col_idx + 1) begin
                        global_k_idx = kv_global_base_g2_w + col_idx;
                        score_word_s = score_block_flat_r[((row_idx_r * 16) + col_idx) * 32 +: 32];
                        scaled_q16_16 = q16_mul_rn_sat(score_word_s, scale_word_g2_w);
                        if (causal_g2_w && (global_k_idx > global_q_idx_g2_w)) begin
                            masked_score_block_valid[(row_idx_r * 16) + col_idx] <= 1'b0;
                            masked_score_block_flat[((row_idx_r * 16) + col_idx) * 32 +: 32] <= neg_large_word_r;
`ifndef SYNTHESIS
                            masked_score_tile_flat_r[((actual_row_idx_w * 16) + col_idx) * 32 +: 32] <= neg_large_word_r;
`endif
                        end else begin
                            masked_score_block_valid[(row_idx_r * 16) + col_idx] <= 1'b1;
                            masked_score_block_flat[((row_idx_r * 16) + col_idx) * 32 +: 32] <= scaled_q16_16;
`ifndef SYNTHESIS
                            masked_score_tile_flat_r[((actual_row_idx_w * 16) + col_idx) * 32 +: 32] <= scaled_q16_16;
`endif
                        end
                    end
                    for (col_idx = 12; col_idx < 16; col_idx = col_idx + 1) begin
                        global_k_idx = kv_global_base_g3_w + col_idx;
                        score_word_s = score_block_flat_r[((row_idx_r * 16) + col_idx) * 32 +: 32];
                        scaled_q16_16 = q16_mul_rn_sat(score_word_s, scale_word_g3_w);
                        if (causal_g3_w && (global_k_idx > global_q_idx_g3_w)) begin
                            masked_score_block_valid[(row_idx_r * 16) + col_idx] <= 1'b0;
                            masked_score_block_flat[((row_idx_r * 16) + col_idx) * 32 +: 32] <= neg_large_word_r;
`ifndef SYNTHESIS
                            masked_score_tile_flat_r[((actual_row_idx_w * 16) + col_idx) * 32 +: 32] <= neg_large_word_r;
`endif
                        end else begin
                            masked_score_block_valid[(row_idx_r * 16) + col_idx] <= 1'b1;
                            masked_score_block_flat[((row_idx_r * 16) + col_idx) * 32 +: 32] <= scaled_q16_16;
`ifndef SYNTHESIS
                            masked_score_tile_flat_r[((actual_row_idx_w * 16) + col_idx) * 32 +: 32] <= scaled_q16_16;
`endif
                        end
                    end
                    if (row_idx_r == 4'd3) begin
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
