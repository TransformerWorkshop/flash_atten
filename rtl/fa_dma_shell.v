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
    output reg          buf_wr_valid,
    output reg  [1:0]   buf_wr_kind,
    output reg  [8:0]   buf_wr_addr,
    output reg  [31:0]  buf_wr_data,
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
            buf_wr_valid <= 1'b0;
            buf_wr_kind <= LOAD_KIND_Q;
            buf_wr_addr <= 9'd0;
            buf_wr_data <= 32'd0;
            done_pulse <= 1'b0;
            error_pulse <= 1'b0;
        end else if (clear) begin
            state_r <= ST_IDLE;
            active_kind_r <= LOAD_KIND_Q;
            word_idx_r <= 9'd0;
            desc_addr_r <= 64'd0;
            buf_wr_valid <= 1'b0;
            buf_wr_kind <= LOAD_KIND_Q;
            buf_wr_addr <= 9'd0;
            buf_wr_data <= 32'd0;
            done_pulse <= 1'b0;
            error_pulse <= 1'b0;
        end else begin
            buf_wr_valid <= 1'b0;
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
                        buf_wr_valid <= 1'b1;
                        buf_wr_kind <= active_kind_r;
                        buf_wr_addr <= word_idx_r;
                        buf_wr_data <= rd_data;
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
    input  wire [16383:0] oacc_tile_flat,
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

    localparam [1:0] ST_IDLE = 2'd0;
    localparam [1:0] ST_DESC = 2'd1;
    localparam [1:0] ST_DATA = 2'd2;

    reg [1:0] state_r;
    reg [8:0] word_idx_r;
    reg [63:0] desc_addr_r;

    assign req_ready = (state_r == ST_IDLE);
    assign wr_desc_valid = (state_r == ST_DESC);
    assign wr_desc_addr = desc_addr_r;
    assign wr_desc_words = 16'd512;
    assign wr_data_valid = (state_r == ST_DATA);
    assign wr_data = oacc_tile_flat[(word_idx_r * 32) +: 32];
    assign wr_data_last = (state_r == ST_DATA) && (word_idx_r == 9'd511);

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state_r <= ST_IDLE;
            word_idx_r <= 9'd0;
            desc_addr_r <= 64'd0;
            done_pulse <= 1'b0;
            error_pulse <= 1'b0;
        end else if (clear) begin
            state_r <= ST_IDLE;
            word_idx_r <= 9'd0;
            desc_addr_r <= 64'd0;
            done_pulse <= 1'b0;
            error_pulse <= 1'b0;
        end else begin
            done_pulse <= 1'b0;
            error_pulse <= 1'b0;
            case (state_r)
                ST_IDLE: begin
                    if (req_valid) begin
                        desc_addr_r <= o_base + ({56'd0, req_q_blk} * 64'd16 * {32'd0, stride_bytes});
                        word_idx_r <= 9'd0;
                        state_r <= ST_DESC;
                    end
                end
                ST_DESC: begin
                    if (wr_desc_ready) begin
                        state_r <= ST_DATA;
                    end
                end
                ST_DATA: begin
                    if (wr_data_ready) begin
                        if (word_idx_r == 9'd511) begin
                            done_pulse <= 1'b1;
                            state_r <= ST_IDLE;
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
