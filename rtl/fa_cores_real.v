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
    reg [1:0] state_n;
    reg [5:0] issue_count_r;
    reg [5:0] issue_count_n;
    reg [5:0] feed_count_r;
    reg [5:0] feed_count_n;
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

    always @(*) begin
        state_n = state_r;
        issue_count_n = issue_count_r;
        feed_count_n = feed_count_r;

        if (gemm_stream_fire_w && gemm_last_w) begin
            state_n = ST_IDLE;
        end

        case (state_r)
            ST_IDLE: begin
                if (req_valid && req_ready) begin
                    issue_count_n = 6'd0;
                    feed_count_n = 6'd0;
                    state_n = ST_STREAM;
                end
            end
            ST_STREAM: begin
                if (read_issue_w) begin
                    issue_count_n = issue_count_r + 6'd1;
                end
                if (gemm_feed_fire_w) begin
                    if (feed_count_r == 6'd31) begin
                        feed_count_n = 6'd32;
                        state_n = ST_COLLECT;
                    end else begin
                        feed_count_n = feed_count_r + 6'd1;
                    end
                end
            end
            ST_COLLECT: begin
            end
            default: begin
                state_n = ST_IDLE;
                issue_count_n = 6'd0;
                feed_count_n = 6'd0;
            end
        endcase
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            issue_count_r <= 6'd0;
            feed_count_r <= 6'd0;
        end else if (clear) begin
            state_r <= ST_IDLE;
            issue_count_r <= 6'd0;
            feed_count_r <= 6'd0;
        end else begin
            state_r <= state_n;
            issue_count_r <= issue_count_n;
            feed_count_r <= feed_count_n;
        end
    end

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
        .num_acc(32'd32),
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
            resp_valid <= 1'b0;
            done_pulse <= 1'b0;
            for (wi = 0; wi < 256; wi = wi + 1) begin
                result_words_r[wi] <= 32'd0;
            end
        end else if (clear) begin
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
                end
            end

            case (state_r)
                ST_IDLE: begin
                    if (req_valid && req_ready) begin
                        for (wi = 0; wi < 256; wi = wi + 1) begin
                            result_words_r[wi] <= 32'd0;
                        end
                    end
                end
                ST_STREAM: begin
                end
                ST_COLLECT: begin
                end
                default: begin
                end
            endcase
        end
    end

endmodule

module FA_QK_PV_SHARED_CORE_REAL (
    input  wire          clk,
    input  wire          rstn,
    input  wire          clear,
    input  wire          qk_req_valid,
    output wire          qk_req_ready,
    output wire          q_rd_en,
    output wire [4:0]    q_rd_addr,
    input  wire          q_rd_valid,
    input  wire [511:0]  q_rd_data,
    output wire          k_rd_en,
    output wire [4:0]    k_rd_addr,
    input  wire          k_rd_valid,
    input  wire [511:0]  k_rd_data,
    output reg           qk_resp_valid,
    input  wire          qk_resp_ready,
    output wire [8191:0] qk_result_tile_flat,
    input  wire          qk_result_row_rd_en,
    input  wire [3:0]    qk_result_row_rd_addr,
    output reg           qk_result_row_rd_valid,
    output wire [511:0]  qk_result_row_rd_data,
    output reg           qk_done_pulse,
    input  wire          pv_req_valid,
    output wire          pv_req_ready,
    output wire          p_rd_en,
    output wire [2:0]    p_rd_addr,
    input  wire          p_rd_valid,
    input  wire [511:0]  p_rd_data,
    output wire          v_rd_en,
    output wire [4:0]    v_rd_addr,
    input  wire          v_rd_valid,
    input  wire [511:0]  v_rd_data,
    output reg           pv_resp_valid,
    input  wire          pv_resp_ready,
    output wire [16383:0] pv_result_tile_flat,
    input  wire          pv_result_row_rd_en,
    input  wire [3:0]    pv_result_row_rd_addr,
    output reg           pv_result_row_rd_valid,
    output wire [1023:0] pv_result_row_rd_data,
    output reg           pv_done_pulse
);

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_STREAM = 2'd1;
    localparam [1:0] ST_COLLECT = 2'd2;
    localparam       MODE_QK = 1'b0;
    localparam       MODE_PV = 1'b1;

    reg [1:0] state_r;
    reg [1:0] state_n;
    reg       mode_r;
    reg       mode_n;
    reg [5:0] issue_count_r;
    reg [5:0] issue_count_n;
    reg [5:0] feed_count_r;
    reg [5:0] feed_count_n;
    reg [1:0] row_blk_r;
    reg [1:0] row_blk_n;
    reg [1:0] col_blk_r;
    reg [1:0] col_blk_n;
`ifndef SYNTHESIS
    reg [31:0] qk_result_words_r [0:255];
    reg [31:0] pv_result_words_r [0:511];
`endif
    reg [511:0]  qk_result_wr_data_r;
    reg [1023:0] pv_result_wr_data_r;
    reg [1023:0] pv_result_wr_mask_r;

    wire         idle_ready_w;
    wire         qk_req_fire_w;
    wire         pv_req_fire_w;
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
    wire [5:0]   feed_last_w;
    wire [4:0]   qk_issue_addr_w;
    wire [2:0]   pv_issue_addr_w;
    wire [127:0] gemm_a_data_w;
    wire [511:0] gemm_b_data_w;
    wire [31:0]  gemm_num_acc_w;
    wire [3:0]   result_row_idx_w;
    wire [511:0] gemm_a_full_data_w;
    reg  [127:0] gemm_a_data_r;

    integer col_idx;
    integer global_col_idx;
    integer pv_global_col_idx;
`ifndef SYNTHESIS
    integer wi;
`endif

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

`ifndef SYNTHESIS
    generate
        genvar qgi;
        for (qgi = 0; qgi < 256; qgi = qgi + 1) begin : gen_qk_result_flat
            assign qk_result_tile_flat[(qgi * 32) +: 32] = qk_result_words_r[qgi];
        end
    endgenerate

    generate
        genvar pgi;
        for (pgi = 0; pgi < 512; pgi = pgi + 1) begin : gen_pv_result_flat
            assign pv_result_tile_flat[(pgi * 32) +: 32] = pv_result_words_r[pgi];
        end
    endgenerate
`else
    wire unused_qk_result_flat_zero_w = (clk & 1'b0)
                                      | (rstn & 1'b0)
                                      | (clear & 1'b0)
                                      | (qk_result_row_rd_en & 1'b0)
                                      | ((|qk_result_row_rd_addr) & 1'b0);
    wire unused_pv_result_flat_zero_w = (clk & 1'b0)
                                      | (rstn & 1'b0)
                                      | (clear & 1'b0)
                                      | (pv_result_row_rd_en & 1'b0)
                                      | ((|pv_result_row_rd_addr) & 1'b0);
    assign qk_result_tile_flat = {8192{unused_qk_result_flat_zero_w}};
    assign pv_result_tile_flat = {16384{unused_pv_result_flat_zero_w}};
`endif

    always @(*) begin
        qk_result_wr_data_r = 512'd0;
        for (col_idx = 0; col_idx < 16; col_idx = col_idx + 1) begin
            qk_result_wr_data_r[(col_idx * 32) +: 32] =
                clamp_q16_16_from_acc128(gemm_group_data_w[(col_idx * 128) +: 128]);
        end
    end

    always @(*) begin
        pv_result_wr_data_r = 1024'd0;
        pv_result_wr_mask_r = 1024'd0;
        for (col_idx = 0; col_idx < 16; col_idx = col_idx + 1) begin
            pv_global_col_idx = (col_blk_r * 16) + col_idx;
            pv_result_wr_data_r[(pv_global_col_idx * 16) +: 16] =
                q16_16_to_q88_sat128(gemm_group_data_w[(col_idx * 128) +: 128]);
            pv_result_wr_mask_r[(pv_global_col_idx * 16) +: 16] = 16'hFFFF;
        end
    end

    assign result_row_idx_w = {row_blk_r, gemm_group_idx_w[1:0]};

    FA_MASKED_ROWBUF_REG_REAL #(
        .ROW_WIDTH(512),
        .DEPTH(16)
    ) u_qk_result_rows (
        .clk(clk),
        .wr_en(gemm_stream_fire_w && (mode_r == MODE_QK)),
        .wr_addr(result_row_idx_w),
        .wr_data(qk_result_wr_data_r),
        .wr_mask({512{1'b1}}),
        .rd_en(qk_result_row_rd_en),
        .rd_addr(qk_result_row_rd_addr),
        .rd_data(qk_result_row_rd_data)
    );

    FA_MASKED_ROWBUF_REG_REAL #(
        .ROW_WIDTH(1024),
        .DEPTH(16)
    ) u_pv_result_rows (
        .clk(clk),
        .wr_en(gemm_stream_fire_w && (mode_r == MODE_PV)),
        .wr_addr(result_row_idx_w),
        .wr_data(pv_result_wr_data_r),
        .wr_mask(pv_result_wr_mask_r),
        .rd_en(pv_result_row_rd_en),
        .rd_addr(pv_result_row_rd_addr),
        .rd_data(pv_result_row_rd_data)
    );

    assign idle_ready_w = (state_r == ST_IDLE) && !qk_resp_valid && !pv_resp_valid;
    assign qk_req_ready = idle_ready_w;
    assign pv_req_ready = idle_ready_w && !qk_req_valid;
    assign qk_req_fire_w = qk_req_valid && qk_req_ready;
    assign pv_req_fire_w = pv_req_valid && pv_req_ready;

    assign gemm_stream_fire_w = gemm_group_valid_w;
    assign first_feed_w = (feed_count_r == 6'd0);
    assign rd_feed_valid_w = (state_r == ST_STREAM) &&
                             ((mode_r == MODE_QK) ? (q_rd_valid && k_rd_valid) : (p_rd_valid && v_rd_valid));
    assign gemm_feed_ready_w = gemm_a_ready_w && gemm_b_ready_w && (!first_feed_w || gemm_start_ready_w);
    assign gemm_feed_fire_w = rd_feed_valid_w && gemm_feed_ready_w;
    assign issue_more_w = (mode_r == MODE_QK) ? (issue_count_r < 6'd32) : (issue_count_r < 6'd8);
    assign read_issue_w = (state_r == ST_STREAM) && issue_more_w && (issue_count_r <= (feed_count_r + 6'd1));
    assign feed_last_w = (mode_r == MODE_QK) ? 6'd31 : 6'd7;
    assign qk_issue_addr_w = issue_count_r[4:0];
    assign pv_issue_addr_w = issue_count_r[2:0];

    assign q_rd_en = read_issue_w && (mode_r == MODE_QK);
    assign q_rd_addr = qk_issue_addr_w;
    assign k_rd_en = read_issue_w && (mode_r == MODE_QK);
    assign k_rd_addr = qk_issue_addr_w;
    assign p_rd_en = read_issue_w && (mode_r == MODE_PV);
    assign p_rd_addr = pv_issue_addr_w;
    assign v_rd_en = read_issue_w && (mode_r == MODE_PV);
    assign v_rd_addr = {col_blk_r, pv_issue_addr_w};

    assign gemm_a_full_data_w = (mode_r == MODE_QK) ? q_rd_data : p_rd_data;
    assign gemm_a_data_w = gemm_a_data_r;
    assign gemm_b_data_w = (mode_r == MODE_QK) ? k_rd_data : v_rd_data;
    assign gemm_num_acc_w = (mode_r == MODE_QK) ? 32'd32 : 32'd8;

    always @(*) begin
        case (row_blk_r)
            2'd0: gemm_a_data_r = gemm_a_full_data_w[127:0];
            2'd1: gemm_a_data_r = gemm_a_full_data_w[255:128];
            2'd2: gemm_a_data_r = gemm_a_full_data_w[383:256];
            default: gemm_a_data_r = gemm_a_full_data_w[511:384];
        endcase
    end

    always @(*) begin
        state_n = state_r;
        mode_n = mode_r;
        issue_count_n = issue_count_r;
        feed_count_n = feed_count_r;
        row_blk_n = row_blk_r;
        col_blk_n = col_blk_r;

        if (gemm_stream_fire_w && gemm_last_w) begin
            if (mode_r == MODE_QK) begin
                if (row_blk_r != 2'd3) begin
                    row_blk_n = row_blk_r + 1'b1;
                    issue_count_n = 6'd0;
                    feed_count_n = 6'd0;
                    state_n = ST_STREAM;
                end else begin
                    state_n = ST_IDLE;
                end
            end else if (row_blk_r != 2'd3) begin
                row_blk_n = row_blk_r + 1'b1;
                issue_count_n = 6'd0;
                feed_count_n = 6'd0;
                state_n = ST_STREAM;
            end else if (col_blk_r == 2'd3) begin
                state_n = ST_IDLE;
            end else begin
                row_blk_n = 2'd0;
                col_blk_n = col_blk_r + 1'b1;
                issue_count_n = 6'd0;
                feed_count_n = 6'd0;
                state_n = ST_STREAM;
            end
        end

        case (state_r)
            ST_IDLE: begin
                if (qk_req_fire_w) begin
                    mode_n = MODE_QK;
                    issue_count_n = 6'd0;
                    feed_count_n = 6'd0;
                    row_blk_n = 2'd0;
                    col_blk_n = 2'd0;
                    state_n = ST_STREAM;
                end else if (pv_req_fire_w) begin
                    mode_n = MODE_PV;
                    issue_count_n = 6'd0;
                    feed_count_n = 6'd0;
                    row_blk_n = 2'd0;
                    col_blk_n = 2'd0;
                    state_n = ST_STREAM;
                end
            end
            ST_STREAM: begin
                if (read_issue_w) begin
                    issue_count_n = issue_count_r + 6'd1;
                end
                if (gemm_feed_fire_w) begin
                    if (feed_count_r == feed_last_w) begin
                        feed_count_n = feed_count_r + 6'd1;
                        state_n = ST_COLLECT;
                    end else begin
                        feed_count_n = feed_count_r + 6'd1;
                    end
                end
            end
            ST_COLLECT: begin
            end
            default: begin
                state_n = ST_IDLE;
                mode_n = MODE_QK;
                issue_count_n = 6'd0;
                feed_count_n = 6'd0;
                row_blk_n = 2'd0;
                col_blk_n = 2'd0;
            end
        endcase
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            mode_r <= MODE_QK;
            issue_count_r <= 6'd0;
            feed_count_r <= 6'd0;
            row_blk_r <= 2'd0;
            col_blk_r <= 2'd0;
        end else if (clear) begin
            state_r <= ST_IDLE;
            mode_r <= MODE_QK;
            issue_count_r <= 6'd0;
            feed_count_r <= 6'd0;
            row_blk_r <= 2'd0;
            col_blk_r <= 2'd0;
        end else begin
            state_r <= state_n;
            mode_r <= mode_n;
            issue_count_r <= issue_count_n;
            feed_count_r <= feed_count_n;
            row_blk_r <= row_blk_n;
            col_blk_r <= col_blk_n;
        end
    end

    GEMM_V3 #(
        .WIDTH(32),
        .ELEM_WIDTH(16),
        .PACK_LANES(2),
        .X_DIM(4),
        .Y_DIM(16),
        .OUTPUT_BY_ROW(1)
    ) u_gemm (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start(gemm_feed_fire_w && first_feed_w),
        .num_acc(gemm_num_acc_w),
        .a_valid(gemm_feed_fire_w),
        .a_ready(gemm_a_ready_w),
        .a(gemm_a_data_w),
        .b_valid(gemm_feed_fire_w),
        .b_ready(gemm_b_ready_w),
        .b(gemm_b_data_w),
        .start_ready(gemm_start_ready_w),
        .m_group_data(gemm_group_data_w),
        .m_group_valid(gemm_group_valid_w),
        .m_group_ready(1'b1),
        .m_group_idx(gemm_group_idx_w),
        .m_last(gemm_last_w)
    );

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            qk_resp_valid <= 1'b0;
            pv_resp_valid <= 1'b0;
            qk_done_pulse <= 1'b0;
            pv_done_pulse <= 1'b0;
            qk_result_row_rd_valid <= 1'b0;
            pv_result_row_rd_valid <= 1'b0;
`ifndef SYNTHESIS
            for (wi = 0; wi < 256; wi = wi + 1) begin
                qk_result_words_r[wi] <= 32'd0;
            end
            for (wi = 0; wi < 512; wi = wi + 1) begin
                pv_result_words_r[wi] <= 32'd0;
            end
`endif
        end else if (clear) begin
            qk_resp_valid <= 1'b0;
            pv_resp_valid <= 1'b0;
            qk_done_pulse <= 1'b0;
            pv_done_pulse <= 1'b0;
            qk_result_row_rd_valid <= 1'b0;
            pv_result_row_rd_valid <= 1'b0;
`ifndef SYNTHESIS
            for (wi = 0; wi < 256; wi = wi + 1) begin
                qk_result_words_r[wi] <= 32'd0;
            end
            for (wi = 0; wi < 512; wi = wi + 1) begin
                pv_result_words_r[wi] <= 32'd0;
            end
`endif
        end else begin
            qk_done_pulse <= 1'b0;
            pv_done_pulse <= 1'b0;
            qk_result_row_rd_valid <= qk_result_row_rd_en;
            pv_result_row_rd_valid <= pv_result_row_rd_en;

            if (qk_resp_valid && qk_resp_ready) begin
                qk_resp_valid <= 1'b0;
                qk_done_pulse <= 1'b1;
            end
            if (pv_resp_valid && pv_resp_ready) begin
                pv_resp_valid <= 1'b0;
                pv_done_pulse <= 1'b1;
            end

            if (qk_req_fire_w) begin
`ifndef SYNTHESIS
                for (wi = 0; wi < 256; wi = wi + 1) begin
                    qk_result_words_r[wi] <= 32'd0;
                end
`endif
            end
            if (pv_req_fire_w) begin
`ifndef SYNTHESIS
                for (wi = 0; wi < 512; wi = wi + 1) begin
                    pv_result_words_r[wi] <= 32'd0;
                end
`endif
            end

            if (gemm_stream_fire_w) begin
                if (mode_r == MODE_QK) begin
`ifndef SYNTHESIS
                    for (col_idx = 0; col_idx < 16; col_idx = col_idx + 1) begin
                        qk_result_words_r[(result_row_idx_w * 16) + col_idx] <= qk_result_wr_data_r[(col_idx * 32) +: 32];
                    end
`endif
                    if (gemm_last_w && (row_blk_r == 2'd3)) begin
                        qk_resp_valid <= 1'b1;
                    end
                end else begin
`ifndef SYNTHESIS
                    for (col_idx = 0; col_idx < 16; col_idx = col_idx + 1) begin
                        global_col_idx = (col_blk_r * 16) + col_idx;
                        pv_result_words_r[(result_row_idx_w * 32) + (global_col_idx >> 1)][((global_col_idx & 1) * 16) +: 16] <= pv_result_wr_data_r[(global_col_idx * 16) +: 16];
                    end
`endif
                    if (gemm_last_w && (row_blk_r == 2'd3) && (col_blk_r == 2'd3)) begin
                        pv_resp_valid <= 1'b1;
                    end
                end
            end
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
    reg [1:0] state_n;
    reg [3:0] issue_count_r;
    reg [3:0] issue_count_n;
    reg [3:0] feed_count_r;
    reg [3:0] feed_count_n;
    reg [1:0] col_blk_r;
    reg [1:0] col_blk_n;
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

    always @(*) begin
        state_n = state_r;
        issue_count_n = issue_count_r;
        feed_count_n = feed_count_r;
        col_blk_n = col_blk_r;

        if (gemm_stream_fire_w && gemm_last_w) begin
            if (col_blk_r == 2'd3) begin
                state_n = ST_IDLE;
            end else begin
                col_blk_n = col_blk_r + 1'b1;
                issue_count_n = 4'd0;
                feed_count_n = 4'd0;
                state_n = ST_STREAM;
            end
        end

        case (state_r)
            ST_IDLE: begin
                if (req_valid && req_ready) begin
                    col_blk_n = 2'd0;
                    issue_count_n = 4'd0;
                    feed_count_n = 4'd0;
                    state_n = ST_STREAM;
                end
            end
            ST_STREAM: begin
                if (read_issue_w) begin
                    issue_count_n = issue_count_r + 4'd1;
                end
                if (gemm_feed_fire_w) begin
                    if (feed_count_r == 4'd7) begin
                        feed_count_n = 4'd8;
                        state_n = ST_COLLECT;
                    end else begin
                        feed_count_n = feed_count_r + 4'd1;
                    end
                end
            end
            ST_COLLECT: begin
            end
            default: begin
                state_n = ST_IDLE;
                issue_count_n = 4'd0;
                feed_count_n = 4'd0;
                col_blk_n = 2'd0;
            end
        endcase
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            issue_count_r <= 4'd0;
            feed_count_r <= 4'd0;
            col_blk_r <= 2'd0;
        end else if (clear) begin
            state_r <= ST_IDLE;
            issue_count_r <= 4'd0;
            feed_count_r <= 4'd0;
            col_blk_r <= 2'd0;
        end else begin
            state_r <= state_n;
            issue_count_r <= issue_count_n;
            feed_count_r <= feed_count_n;
            col_blk_r <= col_blk_n;
        end
    end

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
        .num_acc(32'd8),
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
            resp_valid <= 1'b0;
            done_pulse <= 1'b0;
            for (wi = 0; wi < 512; wi = wi + 1) begin
                result_words_r[wi] <= 32'd0;
            end
        end else if (clear) begin
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
                if (gemm_last_w && (col_blk_r == 2'd3)) begin
                    resp_valid <= 1'b1;
                end
            end

            case (state_r)
                ST_IDLE: begin
                    if (req_valid && req_ready) begin
                        for (wi = 0; wi < 512; wi = wi + 1) begin
                            result_words_r[wi] <= 32'd0;
                        end
                    end
                end
                ST_STREAM: begin
                end
                ST_COLLECT: begin
                end
                default: begin
                end
            endcase
        end
    end

endmodule
