module FA_QK_CORE_REAL (
    input  wire         clk,
    input  wire         rstn,
    input  wire         clear,
    input  wire         req_valid,
    output wire         req_ready,
    output wire         q_rd_en,
    output wire [4:0]   q_rd_addr,
    input  wire         q_rd_valid,
    input  wire [511:0] q_rd_data,
    output wire         k_rd_en,
    output wire [4:0]   k_rd_addr,
    input  wire         k_rd_valid,
    input  wire [511:0] k_rd_data,
    output reg          resp_valid,
    input  wire         resp_ready,
    output wire [8191:0] result_tile_flat,
    output reg          done_pulse
);

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_STREAM = 2'd1;
    localparam [1:0] ST_COLLECT = 2'd2;

    reg [1:0] state_r;
    reg [5:0] issue_count_r;
    reg [5:0] feed_count_r;
    reg [31:0] result_words_r [0:255];
    wire         gemm_a_ready_w;
    wire         gemm_b_ready_w;
    wire         gemm_start_ready_w;
    wire [2047:0] gemm_group_data_w;
    wire         gemm_group_valid_w;
    wire [31:0]  gemm_group_idx_w;
    wire         gemm_last_w;
    wire         gemm_stream_fire_w;
    wire         first_feed_w;
    wire         rd_feed_valid_w;
    wire         gemm_feed_ready_w;
    wire         gemm_feed_fire_w;
    wire         issue_more_w;
    wire         read_issue_w;
    wire [4:0]   issue_addr_w;

    integer wi;
    integer col_idx;
    reg signed [127:0] accum_word_s;

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

    generate
        genvar gi;
        for (gi = 0; gi < 256; gi = gi + 1) begin : gen_result_flat
            assign result_tile_flat[(gi * 32) +: 32] = result_words_r[gi];
        end
    endgenerate

    assign req_ready = (state_r == ST_IDLE) && !resp_valid;
    assign gemm_stream_fire_w = gemm_group_valid_w;
    assign first_feed_w = (feed_count_r == 6'd0);
    assign rd_feed_valid_w = (state_r == ST_STREAM) && q_rd_valid && k_rd_valid;
    assign gemm_feed_ready_w = gemm_a_ready_w && gemm_b_ready_w && (!first_feed_w || gemm_start_ready_w);
    assign gemm_feed_fire_w = rd_feed_valid_w && gemm_feed_ready_w;
    assign issue_more_w = (issue_count_r < 6'd32);
    assign read_issue_w = (state_r == ST_STREAM) && issue_more_w && (issue_count_r <= (feed_count_r + 6'd1));
    assign issue_addr_w = issue_count_r[4:0];
    assign q_rd_en = read_issue_w;
    assign q_rd_addr = issue_addr_w;
    assign k_rd_en = read_issue_w;
    assign k_rd_addr = issue_addr_w;

    GEMM_V3 #(
        .WIDTH(32),
        .ELEM_WIDTH(16),
        .PACK_LANES(2),
        .X_DIM(16),
        .Y_DIM(16),
        .OUTPUT_BY_ROW(1)
    ) u_gemm (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(gemm_feed_fire_w && first_feed_w),
        .num_acc(32),
        .a_valid(gemm_feed_fire_w),
        .a_ready(gemm_a_ready_w),
        .a(q_rd_data),
        .b_valid(gemm_feed_fire_w),
        .b_ready(gemm_b_ready_w),
        .b(k_rd_data),
        .start_ready(gemm_start_ready_w),
        .m_group_data(gemm_group_data_w),
        .m_group_valid(gemm_group_valid_w),
        .m_group_ready(1'b1),
        .m_group_idx(gemm_group_idx_w),
        .m_last(gemm_last_w)
    );

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            issue_count_r <= 6'd0;
            feed_count_r <= 6'd0;
            resp_valid <= 1'b0;
            done_pulse <= 1'b0;
            for (wi = 0; wi < 256; wi = wi + 1) begin
                result_words_r[wi] <= 32'd0;
            end
        end else if (clear) begin
            state_r <= ST_IDLE;
            issue_count_r <= 6'd0;
            feed_count_r <= 6'd0;
            resp_valid <= 1'b0;
            done_pulse <= 1'b0;
            for (wi = 0; wi < 256; wi = wi + 1) begin
                result_words_r[wi] <= 32'd0;
            end
        end else begin
            done_pulse <= 1'b0;

            if (resp_valid && resp_ready) begin
                resp_valid <= 1'b0;
                done_pulse <= 1'b1;
            end

            if (gemm_stream_fire_w) begin
                for (col_idx = 0; col_idx < 16; col_idx = col_idx + 1) begin
                    accum_word_s = gemm_group_data_w[(col_idx * 128) +: 128];
                    result_words_r[(gemm_group_idx_w * 16) + col_idx] <= clamp_q16_16_from_acc128(accum_word_s);
                end
                if (gemm_last_w) begin
                    resp_valid <= 1'b1;
                    state_r <= ST_IDLE;
                end
            end

            case (state_r)
                ST_IDLE: begin
                    if (req_valid && req_ready) begin
                        issue_count_r <= 6'd0;
                        feed_count_r <= 6'd0;
                        for (wi = 0; wi < 256; wi = wi + 1) begin
                            result_words_r[wi] <= 32'd0;
                        end
                        state_r <= ST_STREAM;
                    end
                end
                ST_STREAM: begin
                    if (read_issue_w) begin
                        issue_count_r <= issue_count_r + 6'd1;
                    end
                    if (gemm_feed_fire_w) begin
                        if (feed_count_r == 6'd31) begin
                            feed_count_r <= 6'd32;
                            state_r <= ST_COLLECT;
                        end else begin
                            feed_count_r <= feed_count_r + 6'd1;
                        end
                    end
                end
                ST_COLLECT: begin
                end
                default: state_r <= ST_IDLE;
            endcase
        end
    end

endmodule

module FA_PV_CORE_REAL (
    input  wire          clk,
    input  wire          rstn,
    input  wire          clear,
    input  wire          req_valid,
    output wire          req_ready,
    output wire          p_rd_en,
    output wire [2:0]    p_rd_addr,
    input  wire          p_rd_valid,
    input  wire [511:0]  p_rd_data,
    output wire          v_rd_en,
    output wire [4:0]    v_rd_addr,
    input  wire          v_rd_valid,
    input  wire [511:0]  v_rd_data,
    output reg           resp_valid,
    input  wire          resp_ready,
    output wire [16383:0] result_tile_flat,
    output reg           done_pulse
);

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_STREAM = 2'd1;
    localparam [1:0] ST_COLLECT = 2'd2;

    reg [1:0] state_r;
    reg [3:0] issue_count_r;
    reg [3:0] feed_count_r;
    reg [1:0] col_blk_r;
    reg [31:0] result_words_r [0:511];
    wire         gemm_a_ready_w;
    wire         gemm_b_ready_w;
    wire         gemm_start_ready_w;
    wire [2047:0] gemm_group_data_w;
    wire         gemm_group_valid_w;
    wire [31:0]  gemm_group_idx_w;
    wire         gemm_last_w;
    wire         gemm_stream_fire_w;
    wire         first_feed_w;
    wire         rd_feed_valid_w;
    wire         gemm_feed_ready_w;
    wire         gemm_feed_fire_w;
    wire         issue_more_w;
    wire         read_issue_w;
    wire [2:0]   issue_addr_w;

    integer wi;
    integer col_idx;
    integer global_col_idx;
    reg signed [127:0] accum_word_s;

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

    generate
        genvar gi;
        for (gi = 0; gi < 512; gi = gi + 1) begin : gen_result_flat
            assign result_tile_flat[(gi * 32) +: 32] = result_words_r[gi];
        end
    endgenerate

    assign req_ready = (state_r == ST_IDLE) && !resp_valid;
    assign gemm_stream_fire_w = gemm_group_valid_w;
    assign first_feed_w = (feed_count_r == 4'd0);
    assign rd_feed_valid_w = (state_r == ST_STREAM) && p_rd_valid && v_rd_valid;
    assign gemm_feed_ready_w = gemm_a_ready_w && gemm_b_ready_w && (!first_feed_w || gemm_start_ready_w);
    assign gemm_feed_fire_w = rd_feed_valid_w && gemm_feed_ready_w;
    assign issue_more_w = (issue_count_r < 4'd8);
    assign read_issue_w = (state_r == ST_STREAM) && issue_more_w && (issue_count_r <= (feed_count_r + 4'd1));
    assign issue_addr_w = issue_count_r[2:0];
    assign p_rd_en = read_issue_w;
    assign p_rd_addr = issue_addr_w;
    assign v_rd_en = read_issue_w;
    assign v_rd_addr = {col_blk_r, issue_addr_w};

    GEMM_V3 #(
        .WIDTH(32),
        .ELEM_WIDTH(16),
        .PACK_LANES(2),
        .X_DIM(16),
        .Y_DIM(16),
        .OUTPUT_BY_ROW(1)
    ) u_gemm (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(gemm_feed_fire_w && first_feed_w),
        .num_acc(8),
        .a_valid(gemm_feed_fire_w),
        .a_ready(gemm_a_ready_w),
        .a(p_rd_data),
        .b_valid(gemm_feed_fire_w),
        .b_ready(gemm_b_ready_w),
        .b(v_rd_data),
        .start_ready(gemm_start_ready_w),
        .m_group_data(gemm_group_data_w),
        .m_group_valid(gemm_group_valid_w),
        .m_group_ready(1'b1),
        .m_group_idx(gemm_group_idx_w),
        .m_last(gemm_last_w)
    );

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            issue_count_r <= 4'd0;
            feed_count_r <= 4'd0;
            col_blk_r <= 2'd0;
            resp_valid <= 1'b0;
            done_pulse <= 1'b0;
            for (wi = 0; wi < 512; wi = wi + 1) begin
                result_words_r[wi] <= 32'd0;
            end
        end else if (clear) begin
            state_r <= ST_IDLE;
            issue_count_r <= 4'd0;
            feed_count_r <= 4'd0;
            col_blk_r <= 2'd0;
            resp_valid <= 1'b0;
            done_pulse <= 1'b0;
            for (wi = 0; wi < 512; wi = wi + 1) begin
                result_words_r[wi] <= 32'd0;
            end
        end else begin
            done_pulse <= 1'b0;

            if (resp_valid && resp_ready) begin
                resp_valid <= 1'b0;
                done_pulse <= 1'b1;
            end

            if (gemm_stream_fire_w) begin
                for (col_idx = 0; col_idx < 16; col_idx = col_idx + 1) begin
                    global_col_idx = (col_blk_r * 16) + col_idx;
                    accum_word_s = gemm_group_data_w[(col_idx * 128) +: 128];
                    result_words_r[(gemm_group_idx_w * 32) + (global_col_idx >> 1)][((global_col_idx & 1) * 16) +: 16] <= q16_16_to_q88_sat128(accum_word_s);
                end
                if (gemm_last_w) begin
                    if (col_blk_r == 2'd3) begin
                        resp_valid <= 1'b1;
                        state_r <= ST_IDLE;
                    end else begin
                        col_blk_r <= col_blk_r + 1'b1;
                        issue_count_r <= 4'd0;
                        feed_count_r <= 4'd0;
                        state_r <= ST_STREAM;
                    end
                end
            end

            case (state_r)
                ST_IDLE: begin
                    if (req_valid && req_ready) begin
                        col_blk_r <= 2'd0;
                        issue_count_r <= 4'd0;
                        feed_count_r <= 4'd0;
                        for (wi = 0; wi < 512; wi = wi + 1) begin
                            result_words_r[wi] <= 32'd0;
                        end
                        state_r <= ST_STREAM;
                    end
                end
                ST_STREAM: begin
                    if (read_issue_w) begin
                        issue_count_r <= issue_count_r + 4'd1;
                    end
                    if (gemm_feed_fire_w) begin
                        if (feed_count_r == 4'd7) begin
                            feed_count_r <= 4'd8;
                            state_r <= ST_COLLECT;
                        end else begin
                            feed_count_r <= feed_count_r + 4'd1;
                        end
                    end
                end
                ST_COLLECT: begin
                end
                default: state_r <= ST_IDLE;
            endcase
        end
    end

endmodule
