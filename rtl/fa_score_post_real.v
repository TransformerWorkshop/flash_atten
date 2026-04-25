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
    input  wire [8191:0] score_tile_flat,
    output reg           resp_valid,
    input  wire          resp_ready,
    output reg  [8191:0] masked_score_tile_flat,
    output reg           done_pulse
);

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_RUN  = 2'd1;
    localparam [1:0] ST_DONE = 2'd2;

    reg [1:0] state_r;
    reg [3:0] q_blk_r;
    reg [3:0] kv_blk_r;
    reg       causal_r;
    reg [31:0] scale_word_r;
    reg [31:0] neg_large_word_r;
    reg [8191:0] score_tile_r;
    reg [3:0] row_idx_r;

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
        begin
            prod = lhs * rhs;
            if (prod >= 0) begin
                rounded = prod + 64'sd32768;
            end else begin
                rounded = prod - 64'sd32768;
            end
            if ((rounded >>> 16) > 64'sh7FFF_FFFF) begin
                q16_mul_rn_sat = 32'sh7FFF_FFFF;
            end else if ((rounded >>> 16) < -64'sh8000_0000) begin
                q16_mul_rn_sat = -32'sh8000_0000;
            end else begin
                q16_mul_rn_sat = rounded >>> 16;
            end
        end
    endfunction

    assign req_ready = (state_r == ST_IDLE) && !resp_valid;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            q_blk_r <= 4'd0;
            kv_blk_r <= 4'd0;
            causal_r <= 1'b0;
            scale_word_r <= 32'd0;
            neg_large_word_r <= 32'd0;
            score_tile_r <= 8192'd0;
            row_idx_r <= 4'd0;
            resp_valid <= 1'b0;
            masked_score_tile_flat <= 8192'd0;
            done_pulse <= 1'b0;
        end else if (clear) begin
            state_r <= ST_IDLE;
            q_blk_r <= 4'd0;
            kv_blk_r <= 4'd0;
            causal_r <= 1'b0;
            scale_word_r <= 32'd0;
            neg_large_word_r <= 32'd0;
            score_tile_r <= 8192'd0;
            row_idx_r <= 4'd0;
            resp_valid <= 1'b0;
            masked_score_tile_flat <= 8192'd0;
            done_pulse <= 1'b0;
        end else begin
            done_pulse <= 1'b0;

            if (resp_valid && resp_ready) begin
                resp_valid <= 1'b0;
                done_pulse <= 1'b1;
                if (state_r == ST_DONE) begin
                    state_r <= ST_IDLE;
                end
            end

            case (state_r)
                ST_IDLE: begin
                    if (req_valid && req_ready) begin
                        q_blk_r <= q_blk_idx;
                        kv_blk_r <= kv_blk_idx;
                        causal_r <= causal_en;
                        scale_word_r <= scale_word;
                        neg_large_word_r <= neg_large_word;
                        score_tile_r <= score_tile_flat;
                        masked_score_tile_flat <= 8192'd0;
                        row_idx_r <= 4'd0;
                        state_r <= ST_RUN;
                    end
                end
                ST_RUN: begin
                    global_q_idx = (q_blk_r * 16) + row_idx_r;
                    for (col_idx = 0; col_idx < 16; col_idx = col_idx + 1) begin
                        global_k_idx = (kv_blk_r * 16) + col_idx;
                        score_word_s = score_tile_r[((row_idx_r * 16) + col_idx) * 32 +: 32];
                        if (causal_r && (global_k_idx > global_q_idx)) begin
                            masked_score_tile_flat[((row_idx_r * 16) + col_idx) * 32 +: 32] <= neg_large_word_r;
                        end else begin
                            masked_score_tile_flat[((row_idx_r * 16) + col_idx) * 32 +: 32] <= q16_mul_rn_sat(score_word_s, scale_word_r);
                        end
                    end
                    if (row_idx_r == 4'd15) begin
                        resp_valid <= 1'b1;
                        state_r <= ST_DONE;
                    end else begin
                        row_idx_r <= row_idx_r + 1'b1;
                    end
                end
                ST_DONE: begin
                end
                default: begin
                    state_r <= ST_IDLE;
                end
            endcase
        end
    end

endmodule
