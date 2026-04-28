module FA_RD_DMA (
    input  wire         clk,
    input  wire         rstn,
    input  wire         clear,
    input  wire         req_valid,
    output wire         req_ready,
    input  wire [1:0]   req_kind,
    input  wire [3:0]   req_q_blk,
    input  wire [3:0]   req_kv_blk,
    input  wire [63:0]  q_base,
    input  wire [63:0]  k_base,
    input  wire [63:0]  v_base,
    input  wire [31:0]  stride_bytes,
    output wire         rd_desc_valid,
    input  wire         rd_desc_ready,
    output wire [63:0]  rd_desc_addr,
    output wire [15:0]  rd_desc_words,
    output wire [3:0]   rd_desc_tag,
    input  wire         rd_beat_valid,
    output wire         rd_beat_ready,
    input  wire [127:0] rd_beat_data,
    input  wire [2:0]   rd_beat_word_count,
    input  wire         rd_beat_last,
    output reg          qkv_wr_valid,
    output reg  [1:0]   qkv_wr_kind,
    output reg  [3:0]   qkv_wr_row_idx,
    output reg  [2:0]   qkv_wr_local_addr,
    output reg  [3:0]   qkv_wr_word_mask,
    output reg  [127:0] qkv_wr_data,
    output reg          v_pv_src_valid,
    output reg  [8:0]   v_pv_src_word_idx_base,
    output reg  [3:0]   v_pv_src_word_mask,
    output reg  [127:0] v_pv_src_data,
    output reg          done_pulse,
    output reg          error_pulse
);

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_DESC = 2'd1;
    localparam [1:0] ST_DATA = 2'd2;

    localparam [1:0] LOAD_KIND_Q = 2'd0;
    localparam [1:0] LOAD_KIND_K = 2'd1;
    localparam [1:0] LOAD_KIND_V = 2'd2;

    reg [1:0]  state_r;
    reg [1:0]  state_n;
    reg [1:0]  active_kind_r;
    reg [8:0]  word_idx_r;
    reg [63:0] desc_addr_r;
    reg        desc_misaligned_r;
    reg [9:0]  next_word_idx_s;
    reg [3:0]  beat_mask_s;
    reg        beat_protocol_error_s;
    reg        beat_done_s;

    wire [63:0] q_block_addr = q_base + ({56'd0, req_q_blk} * 64'd16 * {32'd0, stride_bytes});
    wire [63:0] k_block_addr = k_base + ({56'd0, req_kv_blk} * 64'd16 * {32'd0, stride_bytes});
    wire [63:0] v_block_addr = v_base + ({56'd0, req_kv_blk} * 64'd16 * {32'd0, stride_bytes});

    assign req_ready = (state_r == ST_IDLE);
    assign rd_desc_valid = (state_r == ST_DESC);
    assign rd_desc_addr = desc_addr_r;
    assign rd_desc_words = 16'd512;
    assign rd_desc_tag = (active_kind_r == LOAD_KIND_Q) ? 4'h1 :
                         (active_kind_r == LOAD_KIND_K) ? 4'h2 :
                         4'h3;
    assign rd_beat_ready = (state_r == ST_DATA);

    always @(*) begin
        state_n = state_r;
        case (state_r)
            ST_IDLE: begin
                if (req_valid) begin
                    state_n = ST_DESC;
                end
            end
            ST_DESC: begin
                if (rd_desc_ready) begin
                    state_n = ST_DATA;
                end
            end
            ST_DATA: begin
                if (rd_beat_valid && (beat_protocol_error_s || beat_done_s || rd_beat_last)) begin
                    state_n = ST_IDLE;
                end
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

    always @(*) begin
        beat_mask_s = 4'd0;
        case (rd_beat_word_count)
            3'd1: beat_mask_s = 4'b0001;
            3'd2: beat_mask_s = 4'b0011;
            3'd3: beat_mask_s = 4'b0111;
            3'd4: beat_mask_s = 4'b1111;
            default: beat_mask_s = 4'd0;
        endcase
        next_word_idx_s = {1'b0, word_idx_r} + {7'd0, rd_beat_word_count};
        beat_done_s = (next_word_idx_s == 10'd512);
        beat_protocol_error_s = desc_misaligned_r ||
                                (rd_beat_word_count == 3'd0) ||
                                (rd_beat_word_count > 3'd4) ||
                                (word_idx_r[1:0] != 2'b00) ||
                                (next_word_idx_s > 10'd512) ||
                                ({1'b0, word_idx_r[4:0]} + {2'd0, rd_beat_word_count} > 6'd32);
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            active_kind_r <= LOAD_KIND_Q;
            word_idx_r <= 9'd0;
            desc_addr_r <= 64'd0;
            desc_misaligned_r <= 1'b0;
            qkv_wr_valid <= 1'b0;
            qkv_wr_kind <= LOAD_KIND_Q;
            qkv_wr_row_idx <= 4'd0;
            qkv_wr_local_addr <= 3'd0;
            qkv_wr_word_mask <= 4'd0;
            qkv_wr_data <= 128'd0;
            v_pv_src_valid <= 1'b0;
            v_pv_src_word_idx_base <= 9'd0;
            v_pv_src_word_mask <= 4'd0;
            v_pv_src_data <= 128'd0;
            done_pulse <= 1'b0;
            error_pulse <= 1'b0;
        end else if (clear) begin
            active_kind_r <= LOAD_KIND_Q;
            word_idx_r <= 9'd0;
            desc_addr_r <= 64'd0;
            desc_misaligned_r <= 1'b0;
            qkv_wr_valid <= 1'b0;
            qkv_wr_kind <= LOAD_KIND_Q;
            qkv_wr_row_idx <= 4'd0;
            qkv_wr_local_addr <= 3'd0;
            qkv_wr_word_mask <= 4'd0;
            qkv_wr_data <= 128'd0;
            v_pv_src_valid <= 1'b0;
            v_pv_src_word_idx_base <= 9'd0;
            v_pv_src_word_mask <= 4'd0;
            v_pv_src_data <= 128'd0;
            done_pulse <= 1'b0;
            error_pulse <= 1'b0;
        end else begin
            qkv_wr_valid <= 1'b0;
            qkv_wr_word_mask <= 4'd0;
            qkv_wr_data <= 128'd0;
            v_pv_src_valid <= 1'b0;
            v_pv_src_word_mask <= 4'd0;
            v_pv_src_data <= 128'd0;
            done_pulse <= 1'b0;
            error_pulse <= 1'b0;

            case (state_r)
                ST_IDLE: begin
                    if (req_valid) begin
                        active_kind_r <= req_kind;
                        word_idx_r <= 9'd0;
                        case (req_kind)
                            LOAD_KIND_Q: begin
                                desc_addr_r <= q_block_addr;
                                desc_misaligned_r <= |q_block_addr[3:2];
                            end
                            LOAD_KIND_K: begin
                                desc_addr_r <= k_block_addr;
                                desc_misaligned_r <= |k_block_addr[3:2];
                            end
                            default: begin
                                desc_addr_r <= v_block_addr;
                                desc_misaligned_r <= |v_block_addr[3:2];
                            end
                        endcase
                    end
                end
                ST_DESC: begin
                end
                ST_DATA: begin
                    if (rd_beat_valid) begin
                        if (beat_protocol_error_s) begin
                            error_pulse <= 1'b1;
                        end else begin
                            qkv_wr_valid <= 1'b1;
                            qkv_wr_kind <= active_kind_r;
                            qkv_wr_row_idx <= word_idx_r[8:5];
                            qkv_wr_local_addr <= word_idx_r[4:2];
                            qkv_wr_word_mask <= beat_mask_s;
                            qkv_wr_data <= rd_beat_data;
                            if (active_kind_r == LOAD_KIND_V) begin
                                v_pv_src_valid <= 1'b1;
                                v_pv_src_word_idx_base <= word_idx_r;
                                v_pv_src_word_mask <= beat_mask_s;
                                v_pv_src_data <= rd_beat_data;
                            end
                            if (beat_done_s) begin
                                if (!rd_beat_last) begin
                                    error_pulse <= 1'b1;
                                end else begin
                                    done_pulse <= 1'b1;
                                end
                            end else if (rd_beat_last) begin
                                error_pulse <= 1'b1;
                            end else begin
                                word_idx_r <= next_word_idx_s[8:0];
                            end
                        end
                    end
                end
                default: begin
                end
            endcase
        end
    end

endmodule

module FA_WR_DMA (
    input  wire         clk,
    input  wire         rstn,
    input  wire         clear,
    input  wire         req_valid,
    output wire         req_ready,
    input  wire [3:0]   req_q_blk,
    input  wire [63:0]  o_base,
    input  wire [31:0]  stride_bytes,
    output reg          oacc_exp_rd_en,
    output reg  [3:0]   oacc_exp_rd_row,
    input  wire         oacc_exp_rd_valid,
    input  wire [1023:0] oacc_exp_rd_data,
    output wire         wr_desc_valid,
    input  wire         wr_desc_ready,
    output wire [63:0]  wr_desc_addr,
    output wire [15:0]  wr_desc_words,
    output wire         wr_data_valid,
    input  wire         wr_data_ready,
    output wire [31:0]  wr_data,
    output wire         wr_data_last,
    output reg          done_pulse,
    output reg          error_pulse
);

    localparam [2:0] ST_IDLE = 3'd0;
    localparam [2:0] ST_DESC = 3'd1;
    localparam [2:0] ST_REQ_ROW = 3'd2;
    localparam [2:0] ST_WAIT_ROW = 3'd3;
    localparam [2:0] ST_DATA = 3'd4;

    reg [2:0] state_r;
    reg [2:0] state_n;
    reg [4:0] row_idx_r;
    reg [4:0] row_idx_n;
    reg [4:0] word_idx_r;
    reg [4:0] word_idx_n;
    reg [63:0] desc_addr_r;
    reg [1023:0] row_data_r;

    assign req_ready = (state_r == ST_IDLE);
    assign wr_desc_valid = (state_r == ST_DESC);
    assign wr_desc_addr = desc_addr_r;
    assign wr_desc_words = 16'd512;
    assign wr_data_valid = (state_r == ST_DATA);
    assign wr_data = row_data_r[(word_idx_r * 32) +: 32];
    assign wr_data_last = (state_r == ST_DATA) && (row_idx_r == 5'd15) && (word_idx_r == 5'd31);

    always @(*) begin
        state_n = state_r;
        row_idx_n = row_idx_r;
        word_idx_n = word_idx_r;
        case (state_r)
            ST_IDLE: begin
                if (req_valid) begin
                    state_n = ST_DESC;
                    row_idx_n = 5'd0;
                    word_idx_n = 5'd0;
                end
            end
            ST_DESC: begin
                if (wr_desc_ready) begin
                    state_n = ST_REQ_ROW;
                end
            end
            ST_REQ_ROW: begin
                state_n = ST_WAIT_ROW;
            end
            ST_WAIT_ROW: begin
                if (oacc_exp_rd_valid) begin
                    state_n = ST_DATA;
                    word_idx_n = 5'd0;
                end
            end
            ST_DATA: begin
                if (wr_data_ready) begin
                    if (word_idx_r == 5'd31) begin
                        if (row_idx_r == 5'd15) begin
                            state_n = ST_IDLE;
                        end else begin
                            row_idx_n = row_idx_r + 1'b1;
                            state_n = ST_REQ_ROW;
                        end
                    end else begin
                        word_idx_n = word_idx_r + 1'b1;
                    end
                end
            end
            default: begin
                state_n = ST_IDLE;
                row_idx_n = 5'd0;
                word_idx_n = 5'd0;
            end
        endcase
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            row_idx_r <= 5'd0;
            word_idx_r <= 5'd0;
        end else if (clear) begin
            state_r <= ST_IDLE;
            row_idx_r <= 5'd0;
            word_idx_r <= 5'd0;
        end else begin
            state_r <= state_n;
            row_idx_r <= row_idx_n;
            word_idx_r <= word_idx_n;
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            desc_addr_r <= 64'd0;
            row_data_r <= 1024'd0;
            oacc_exp_rd_en <= 1'b0;
            oacc_exp_rd_row <= 4'd0;
            done_pulse <= 1'b0;
            error_pulse <= 1'b0;
        end else if (clear) begin
            desc_addr_r <= 64'd0;
            row_data_r <= 1024'd0;
            oacc_exp_rd_en <= 1'b0;
            oacc_exp_rd_row <= 4'd0;
            done_pulse <= 1'b0;
            error_pulse <= 1'b0;
        end else begin
            oacc_exp_rd_en <= 1'b0;
            done_pulse <= 1'b0;
            error_pulse <= 1'b0;
            case (state_r)
                ST_IDLE: begin
                    if (req_valid) begin
                        desc_addr_r <= o_base + ({56'd0, req_q_blk} * 64'd16 * {32'd0, stride_bytes});
                    end
                end
                ST_DESC: begin
                end
                ST_REQ_ROW: begin
                    oacc_exp_rd_en <= 1'b1;
                    oacc_exp_rd_row <= row_idx_r[3:0];
                end
                ST_WAIT_ROW: begin
                    if (oacc_exp_rd_valid) begin
                        row_data_r <= oacc_exp_rd_data;
                    end
                end
                ST_DATA: begin
                    if (wr_data_ready) begin
                        if (word_idx_r == 5'd31) begin
                            if (row_idx_r == 5'd15) begin
                                done_pulse <= 1'b1;
                            end
                        end
                    end
                end
                default: begin
                end
            endcase
        end
    end

endmodule
