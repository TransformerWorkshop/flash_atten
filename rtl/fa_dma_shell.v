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
    input  wire         rd_data_valid,
    output wire         rd_data_ready,
    input  wire [31:0]  rd_data,
    input  wire         rd_data_last,
    output reg          qkv_wr_valid,
    output reg  [1:0]   qkv_wr_kind,
    output reg  [3:0]   qkv_wr_row,
    output reg  [4:0]   qkv_wr_lane,
    output reg  [31:0]  qkv_wr_word,
    output reg          v_pv_wr_valid,
    output reg  [4:0]   v_pv_wr_addr,
    output reg          v_pv_lane0_valid,
    output reg  [3:0]   v_pv_lane0_idx,
    output reg          v_pv_lane0_hi,
    output reg  [15:0]  v_pv_lane0_data,
    output reg          v_pv_lane1_valid,
    output reg  [3:0]   v_pv_lane1_idx,
    output reg          v_pv_lane1_hi,
    output reg  [15:0]  v_pv_lane1_data,
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
    reg [1:0]  active_kind_r;
    reg [8:0]  word_idx_r;
    reg [63:0] desc_addr_r;

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
    assign rd_data_ready = (state_r == ST_DATA);

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            active_kind_r <= LOAD_KIND_Q;
            word_idx_r <= 9'd0;
            desc_addr_r <= 64'd0;
            qkv_wr_valid <= 1'b0;
            qkv_wr_kind <= LOAD_KIND_Q;
            qkv_wr_row <= 4'd0;
            qkv_wr_lane <= 5'd0;
            qkv_wr_word <= 32'd0;
            v_pv_wr_valid <= 1'b0;
            v_pv_wr_addr <= 5'd0;
            v_pv_lane0_valid <= 1'b0;
            v_pv_lane0_idx <= 4'd0;
            v_pv_lane0_hi <= 1'b0;
            v_pv_lane0_data <= 16'd0;
            v_pv_lane1_valid <= 1'b0;
            v_pv_lane1_idx <= 4'd0;
            v_pv_lane1_hi <= 1'b0;
            v_pv_lane1_data <= 16'd0;
            done_pulse <= 1'b0;
            error_pulse <= 1'b0;
        end else if (clear) begin
            state_r <= ST_IDLE;
            active_kind_r <= LOAD_KIND_Q;
            word_idx_r <= 9'd0;
            desc_addr_r <= 64'd0;
            qkv_wr_valid <= 1'b0;
            qkv_wr_kind <= LOAD_KIND_Q;
            qkv_wr_row <= 4'd0;
            qkv_wr_lane <= 5'd0;
            qkv_wr_word <= 32'd0;
            v_pv_wr_valid <= 1'b0;
            v_pv_wr_addr <= 5'd0;
            v_pv_lane0_valid <= 1'b0;
            v_pv_lane0_idx <= 4'd0;
            v_pv_lane0_hi <= 1'b0;
            v_pv_lane0_data <= 16'd0;
            v_pv_lane1_valid <= 1'b0;
            v_pv_lane1_idx <= 4'd0;
            v_pv_lane1_hi <= 1'b0;
            v_pv_lane1_data <= 16'd0;
            done_pulse <= 1'b0;
            error_pulse <= 1'b0;
        end else begin
            qkv_wr_valid <= 1'b0;
            v_pv_wr_valid <= 1'b0;
            v_pv_lane0_valid <= 1'b0;
            v_pv_lane1_valid <= 1'b0;
            done_pulse <= 1'b0;
            error_pulse <= 1'b0;

            case (state_r)
                ST_IDLE: begin
                    if (req_valid) begin
                        active_kind_r <= req_kind;
                        word_idx_r <= 9'd0;
                        case (req_kind)
                            LOAD_KIND_Q: desc_addr_r <= q_block_addr;
                            LOAD_KIND_K: desc_addr_r <= k_block_addr;
                            default:     desc_addr_r <= v_block_addr;
                        endcase
                        state_r <= ST_DESC;
                    end
                end
                ST_DESC: begin
                    if (rd_desc_ready) begin
                        state_r <= ST_DATA;
                    end
                end
                ST_DATA: begin
                    if (rd_data_valid) begin
                        qkv_wr_valid <= 1'b1;
                        qkv_wr_kind <= active_kind_r;
                        qkv_wr_row <= word_idx_r[8:5];
                        qkv_wr_lane <= word_idx_r[4:0];
                        qkv_wr_word <= rd_data;
                        if (active_kind_r == LOAD_KIND_V) begin
                            v_pv_wr_valid <= 1'b1;
                            v_pv_wr_addr <= {word_idx_r[4:3], word_idx_r[8:6]};
                            v_pv_lane0_valid <= 1'b1;
                            v_pv_lane0_idx <= {word_idx_r[2:0], 1'b0};
                            v_pv_lane0_hi <= word_idx_r[5];
                            v_pv_lane0_data <= rd_data[15:0];
                            v_pv_lane1_valid <= 1'b1;
                            v_pv_lane1_idx <= {word_idx_r[2:0], 1'b1};
                            v_pv_lane1_hi <= word_idx_r[5];
                            v_pv_lane1_data <= rd_data[31:16];
                        end
                        if (word_idx_r == 9'd511) begin
                            if (!rd_data_last) begin
                                error_pulse <= 1'b1;
                            end
                            done_pulse <= 1'b1;
                            state_r <= ST_IDLE;
                        end else begin
                            if (rd_data_last) begin
                                error_pulse <= 1'b1;
                                state_r <= ST_IDLE;
                            end else begin
                                word_idx_r <= word_idx_r + 1'b1;
                            end
                        end
                    end
                end
                default: state_r <= ST_IDLE;
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
    reg [4:0] row_idx_r;
    reg [4:0] word_idx_r;
    reg [63:0] desc_addr_r;
    reg [1023:0] row_data_r;

    assign req_ready = (state_r == ST_IDLE);
    assign wr_desc_valid = (state_r == ST_DESC);
    assign wr_desc_addr = desc_addr_r;
    assign wr_desc_words = 16'd512;
    assign wr_data_valid = (state_r == ST_DATA);
    assign wr_data = row_data_r[(word_idx_r * 32) +: 32];
    assign wr_data_last = (state_r == ST_DATA) && (row_idx_r == 5'd15) && (word_idx_r == 5'd31);

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            row_idx_r <= 5'd0;
            word_idx_r <= 5'd0;
            desc_addr_r <= 64'd0;
            row_data_r <= 1024'd0;
            oacc_exp_rd_en <= 1'b0;
            oacc_exp_rd_row <= 4'd0;
            done_pulse <= 1'b0;
            error_pulse <= 1'b0;
        end else if (clear) begin
            state_r <= ST_IDLE;
            row_idx_r <= 5'd0;
            word_idx_r <= 5'd0;
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
                        row_idx_r <= 5'd0;
                        word_idx_r <= 5'd0;
                        state_r <= ST_DESC;
                    end
                end
                ST_DESC: begin
                    if (wr_desc_ready) begin
                        state_r <= ST_REQ_ROW;
                    end
                end
                ST_REQ_ROW: begin
                    oacc_exp_rd_en <= 1'b1;
                    oacc_exp_rd_row <= row_idx_r[3:0];
                    state_r <= ST_WAIT_ROW;
                end
                ST_WAIT_ROW: begin
                    if (oacc_exp_rd_valid) begin
                        row_data_r <= oacc_exp_rd_data;
                        word_idx_r <= 5'd0;
                        state_r <= ST_DATA;
                    end
                end
                ST_DATA: begin
                    if (wr_data_ready) begin
                        if (word_idx_r == 5'd31) begin
                            if (row_idx_r == 5'd15) begin
                                done_pulse <= 1'b1;
                                state_r <= ST_IDLE;
                            end else begin
                                row_idx_r <= row_idx_r + 1'b1;
                                state_r <= ST_REQ_ROW;
                            end
                        end else begin
                            word_idx_r <= word_idx_r + 1'b1;
                        end
                    end
                end
                default: state_r <= ST_IDLE;
            endcase
        end
    end

endmodule
