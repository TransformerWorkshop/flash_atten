module FA_TOP_OPTIM_WINDOWED #(
    parameter DATA_WIDTH = 32,
    parameter GEMM_X_DIM = 16,
    parameter GEMM_Y_DIM = 16,
    parameter EXT_ADDR_W = 32,
    parameter DMA_BEATS_W = 16,
    parameter LUT_DEPTH = 8,
    parameter A_BANK_DEPTH = 16,
    parameter B_BANK_DEPTH = 16,
    parameter M_BANK_DEPTH = 16,
    parameter A_LOAD_LANES = 1,
    parameter B_LOAD_LANES = 1,
    parameter M_WRITE_LANES = 1,
    parameter M_EXPORT_LANES = 1,
    parameter M_PHYSICAL_COPIES = 3,
    parameter STREAM_CHANNELS = 1,
    parameter S_AXIS_CHANNEL_WIDTH = 32,
    parameter M_AXIS_CHANNEL_WIDTH = 32
) (
    input  wire         clk,
    input  wire         rstn,
    input  wire         clear,
    input  wire [6:0]   s_axil_awaddr,
    input  wire         s_axil_awvalid,
    output wire         s_axil_awready,
    input  wire [31:0]  s_axil_wdata,
    input  wire [3:0]   s_axil_wstrb,
    input  wire         s_axil_wvalid,
    output wire         s_axil_wready,
    output wire [1:0]   s_axil_bresp,
    output wire         s_axil_bvalid,
    input  wire         s_axil_bready,
    input  wire [6:0]   s_axil_araddr,
    input  wire         s_axil_arvalid,
    output wire         s_axil_arready,
    output wire [31:0]  s_axil_rdata,
    output wire [1:0]   s_axil_rresp,
    output wire         s_axil_rvalid,
    input  wire         s_axil_rready,
    output wire [63:0]  m_axi_araddr,
    output wire [7:0]   m_axi_arlen,
    output wire [2:0]   m_axi_arsize,
    output wire [1:0]   m_axi_arburst,
    output wire         m_axi_arvalid,
    input  wire         m_axi_arready,
    input  wire [127:0] m_axi_rdata,
    input  wire [1:0]   m_axi_rresp,
    input  wire         m_axi_rlast,
    input  wire         m_axi_rvalid,
    output wire         m_axi_rready,
    output wire [63:0]  m_axi_awaddr,
    output wire [7:0]   m_axi_awlen,
    output wire [2:0]   m_axi_awsize,
    output wire [1:0]   m_axi_awburst,
    output wire         m_axi_awvalid,
    input  wire         m_axi_awready,
    output wire [127:0] m_axi_wdata,
    output wire [15:0]  m_axi_wstrb,
    output wire         m_axi_wlast,
    output wire         m_axi_wvalid,
    input  wire         m_axi_wready,
    input  wire [1:0]   m_axi_bresp,
    input  wire         m_axi_bvalid,
    output wire         m_axi_bready,
    output wire         irq
);

    localparam [1:0] FEED_IDLE = 2'd0;
    localparam [1:0] FEED_Q    = 2'd1;
    localparam [1:0] FEED_K    = 2'd2;
    localparam [1:0] FEED_V    = 2'd3;
    localparam [1:0] WR_IDLE   = 2'd0;
    localparam [1:0] WR_DESC   = 2'd1;
    localparam [1:0] WR_DATA   = 2'd2;
    localparam [1:0] WR_DRAIN  = 2'd3;
    localparam integer O_WORDS_PER_GROUP = 2048;
    localparam [15:0] O_WORDS_PER_GROUP_W = 16'd2048;

    wire        csr_start_level;
    wire        csr_start_pulse;
    wire        csr_soft_reset_level;
    wire        csr_soft_reset_pulse;
    wire        csr_config_error;
    wire        csr_irq_en;
    wire        csr_causal_en;
    wire [63:0] csr_q_base;
    wire [63:0] csr_k_base;
    wire [63:0] csr_v_base;
    wire [63:0] csr_o_base;
    wire [31:0] csr_stride_bytes;
    wire [31:0] csr_neg_large;
    wire [31:0] csr_scale;
    wire        runtime_clear = clear || csr_soft_reset_pulse;

    wire        q_tile_req_valid_w;
    wire        q_tile_req_ready_w;
    wire [5:0]  q_tile_req_q_idx_w;
    wire        q_tile_beat_valid_w;
    wire        q_tile_beat_ready_w;
    wire [1:0]  q_tile_beat_row_idx_w;
    wire [3:0]  q_tile_beat_chunk_idx_w;
    wire [63:0] q_tile_beat_data_w;
    wire        q_tile_beat_last_w;
    wire        k_tile_req_valid_w;
    wire        k_tile_req_ready_w;
    wire [4:0]  k_tile_req_kv_idx_w;
    wire        k_tile_beat_valid_w;
    wire        k_tile_beat_ready_w;
    wire [3:0]  k_tile_beat_row_idx_w;
    wire [3:0]  k_tile_beat_chunk_idx_w;
    wire [63:0] k_tile_beat_data_w;
    wire        k_tile_beat_last_w;
    wire        v_tile_req_valid_w;
    wire        v_tile_req_ready_w;
    wire [4:0]  v_tile_req_kv_idx_w;
    wire        v_tile_beat_valid_w;
    wire        v_tile_beat_ready_w;
    wire [3:0]  v_tile_beat_row_idx_w;
    wire [3:0]  v_tile_beat_chunk_idx_w;
    wire [63:0] v_tile_beat_data_w;
    wire        v_tile_beat_last_w;

    wire        windowed_busy;
    wire        windowed_done_pulse;
    wire        windowed_error;
    wire [31:0] windowed_cycles;
    wire [31:0] windowed_micro_tile_count;
    wire [31:0] windowed_q_group_count;
    wire [31:0] windowed_kv_window_count;
    wire [31:0] windowed_q_tile_visit_count;
    wire [31:0] windowed_kv_tile_count;
    wire [31:0] windowed_q_tile_req_count;
    wire [31:0] windowed_q_tile_beat_count;
    wire [31:0] windowed_k_tile_req_count;
    wire [31:0] windowed_k_tile_beat_count;
    wire [31:0] windowed_v_tile_req_count;
    wire [31:0] windowed_v_tile_beat_count;
    wire [31:0] windowed_state_fill_count;
    wire [31:0] windowed_state_spill_count;
    wire [31:0] windowed_qk_task_count;
    wire [31:0] windowed_pv_task_count;
    wire [31:0] windowed_oacc_task_count;
    wire        o_dump_valid_w;
    wire        o_dump_ready_w;
    wire [1:0]  o_dump_group_idx_w;
    wire [10:0] o_dump_word_idx_w;
    wire [31:0] o_dump_word_w;
    wire        o_dump_last_w;
    wire [4095:0] windowed_o_block_flat;

    reg         windowed_done_sticky_r;
    reg         windowed_error_sticky_r;
    reg         top_axi_error_sticky_r;
    reg [1:0]   feeder_state_r;
    reg [8:0]   feeder_beat_idx_r;
    reg [5:0]   feeder_q_idx_r;
    reg [4:0]   feeder_kv_idx_r;
    reg [127:0] feeder_axi_data_r;
    reg         feeder_upper_half_r;
    reg [1:0]   wr_state_r;
    reg [1:0]   wr_group_idx_r;
    reg [31:0]  status_wr_bytes_r;
    reg         windowed_done_pending_r;

    wire        top_rd_desc_valid_w;
    wire        top_rd_desc_ready_w;
    wire [63:0] top_rd_desc_addr_w;
    wire [15:0] top_rd_desc_words_w;
    wire [3:0]  top_rd_desc_tag_w;
    wire        top_rd_beat_valid_w;
    wire        top_rd_beat_ready_w;
    wire [127:0] top_rd_beat_data_w;
    wire [2:0]  top_rd_beat_word_count_w;
    wire        top_rd_beat_last_w;
    wire        top_axi_arvalid_w;
    wire        top_axi_error_pulse_w;
    wire        top_wr_desc_valid_w;
    wire        top_wr_desc_ready_w;
    wire [63:0] top_wr_desc_addr_w;
    wire [15:0] top_wr_desc_words_w;
    wire        top_wr_data_valid_w;
    wire        top_wr_data_ready_w;
    wire [31:0] top_wr_data_w;
    wire        top_wr_data_last_w;
    wire        top_axi_awvalid_w;
    wire        top_axi_wvalid_w;
    wire        top_wr_axi_error_pulse_w;
    wire [63:0] top_axi_awaddr_w;
    wire [7:0]  top_axi_awlen_w;
    wire [2:0]  top_axi_awsize_w;
    wire [1:0]  top_axi_awburst_w;
    wire [127:0] top_axi_wdata_w;
    wire [15:0]  top_axi_wstrb_w;
    wire         top_axi_wlast_w;
    wire         top_axi_bready_w;

    wire feeder_idle_w = (feeder_state_r == FEED_IDLE);
    wire q_tile_req_fire_w = q_tile_req_valid_w && q_tile_req_ready_w;
    wire k_tile_req_fire_w = k_tile_req_valid_w && k_tile_req_ready_w;
    wire v_tile_req_fire_w = v_tile_req_valid_w && v_tile_req_ready_w;
    wire q_tile_beat_fire_w = q_tile_beat_valid_w && q_tile_beat_ready_w;
    wire k_tile_beat_fire_w = k_tile_beat_valid_w && k_tile_beat_ready_w;
    wire v_tile_beat_fire_w = v_tile_beat_valid_w && v_tile_beat_ready_w;
    wire q_feed_last_w = (feeder_beat_idx_r == 9'd63);
    wire kv_feed_last_w = (feeder_beat_idx_r == 9'd255);
    wire feeder_need_axi_beat_w = !feeder_upper_half_r;
    wire feeder_axi_beat_accept_w = top_rd_beat_valid_w && top_rd_beat_ready_w;
    wire [63:0] feeder_tile_beat_data_w =
        feeder_upper_half_r ? feeder_axi_data_r[127:64] : top_rd_beat_data_w[63:0];
    wire wr_idle_w = (wr_state_r == WR_IDLE);
    wire wr_desc_fire_w = top_wr_desc_valid_w && top_wr_desc_ready_w;
    wire wr_data_fire_w = top_wr_data_valid_w && top_wr_data_ready_w;
    wire wr_drain_done_w = (wr_state_r == WR_DRAIN) && top_wr_desc_ready_w;
    wire top_done_accept_w = (windowed_done_pulse && wr_idle_w) ||
                             (windowed_done_pending_r && wr_idle_w);
    wire top_busy_w = windowed_busy || !wr_idle_w || windowed_done_pending_r;

    wire [31:0] status_rd_bytes_w =
        (windowed_q_tile_beat_count + windowed_k_tile_beat_count +
         windowed_v_tile_beat_count) << 3;

    wire windowed_top_unused_zero_w =
          (csr_start_level & 1'b0)
        | (csr_soft_reset_level & 1'b0)
        | (csr_causal_en & 1'b0)
        | ((|csr_q_base) & 1'b0)
        | ((|csr_k_base) & 1'b0)
        | ((|csr_v_base) & 1'b0)
        | ((|csr_o_base) & 1'b0)
        | ((|csr_stride_bytes) & 1'b0)
        | ((|csr_neg_large) & 1'b0)
        | ((|csr_scale) & 1'b0)
        | ((|windowed_micro_tile_count) & 1'b0)
        | ((|windowed_q_group_count) & 1'b0)
        | ((|windowed_kv_window_count) & 1'b0)
        | ((|windowed_q_tile_visit_count) & 1'b0)
        | ((|windowed_kv_tile_count) & 1'b0)
        | ((|windowed_q_tile_req_count) & 1'b0)
        | ((|windowed_k_tile_req_count) & 1'b0)
        | ((|windowed_v_tile_req_count) & 1'b0)
        | ((|windowed_state_fill_count) & 1'b0)
        | ((|windowed_state_spill_count) & 1'b0)
        | ((|windowed_qk_task_count) & 1'b0)
        | ((|windowed_pv_task_count) & 1'b0)
        | ((|windowed_oacc_task_count) & 1'b0)
        | ((|o_dump_word_idx_w) & 1'b0)
        | ((|windowed_o_block_flat) & 1'b0)
        | ((|top_rd_beat_word_count_w) & 1'b0)
        | (top_rd_beat_last_w & 1'b0)
        | ((|DATA_WIDTH) & 1'b0)
        | ((|GEMM_X_DIM) & 1'b0)
        | ((|GEMM_Y_DIM) & 1'b0)
        | ((|EXT_ADDR_W) & 1'b0)
        | ((|DMA_BEATS_W) & 1'b0)
        | ((|LUT_DEPTH) & 1'b0)
        | ((|A_BANK_DEPTH) & 1'b0)
        | ((|B_BANK_DEPTH) & 1'b0)
        | ((|M_BANK_DEPTH) & 1'b0)
        | ((|A_LOAD_LANES) & 1'b0)
        | ((|B_LOAD_LANES) & 1'b0)
        | ((|M_WRITE_LANES) & 1'b0)
        | ((|M_EXPORT_LANES) & 1'b0)
        | ((|M_PHYSICAL_COPIES) & 1'b0)
        | ((|STREAM_CHANNELS) & 1'b0)
        | ((|S_AXIS_CHANNEL_WIDTH) & 1'b0)
        | ((|M_AXIS_CHANNEL_WIDTH) & 1'b0);

    assign q_tile_req_ready_w = feeder_idle_w && top_rd_desc_ready_w;
    assign k_tile_req_ready_w = feeder_idle_w && top_rd_desc_ready_w;
    assign v_tile_req_ready_w = feeder_idle_w && top_rd_desc_ready_w;
    assign q_tile_beat_valid_w = (feeder_state_r == FEED_Q) &&
                                 (feeder_upper_half_r || top_rd_beat_valid_w);
    assign k_tile_beat_valid_w = (feeder_state_r == FEED_K) &&
                                 (feeder_upper_half_r || top_rd_beat_valid_w);
    assign v_tile_beat_valid_w = (feeder_state_r == FEED_V) &&
                                 (feeder_upper_half_r || top_rd_beat_valid_w);
    assign q_tile_beat_row_idx_w = feeder_beat_idx_r[5:4];
    assign q_tile_beat_chunk_idx_w = feeder_beat_idx_r[3:0];
    assign k_tile_beat_row_idx_w = feeder_beat_idx_r[7:4];
    assign k_tile_beat_chunk_idx_w = feeder_beat_idx_r[3:0];
    assign v_tile_beat_row_idx_w = feeder_beat_idx_r[7:4];
    assign v_tile_beat_chunk_idx_w = feeder_beat_idx_r[3:0];
    assign q_tile_beat_data_w = feeder_tile_beat_data_w;
    assign k_tile_beat_data_w = feeder_tile_beat_data_w;
    assign v_tile_beat_data_w = feeder_tile_beat_data_w;
    assign q_tile_beat_last_w = q_feed_last_w;
    assign k_tile_beat_last_w = kv_feed_last_w;
    assign v_tile_beat_last_w = kv_feed_last_w;

    assign top_rd_desc_valid_w = q_tile_req_fire_w | k_tile_req_fire_w |
                                 v_tile_req_fire_w;
    assign top_rd_desc_words_w = (q_tile_req_fire_w) ? 16'd128 : 16'd512;
    assign top_rd_desc_tag_w = q_tile_req_fire_w ? 4'd1 :
                               k_tile_req_fire_w ? 4'd2 :
                               v_tile_req_fire_w ? 4'd3 : 4'd0;
    assign top_rd_desc_addr_w =
        q_tile_req_fire_w ? (csr_q_base + ({58'd0, q_tile_req_q_idx_w} << 9)) :
        k_tile_req_fire_w ? (csr_k_base + ({59'd0, k_tile_req_kv_idx_w} << 11)) :
        v_tile_req_fire_w ? (csr_v_base + ({59'd0, v_tile_req_kv_idx_w} << 11)) :
        64'd0;
    assign top_rd_beat_ready_w = (feeder_state_r != FEED_IDLE) &&
                                 feeder_need_axi_beat_w &&
                                 ((feeder_state_r == FEED_Q) ? q_tile_beat_ready_w :
                                  (feeder_state_r == FEED_K) ? k_tile_beat_ready_w :
                                  v_tile_beat_ready_w);
    assign top_wr_desc_valid_w = (wr_state_r == WR_DESC);
    assign top_wr_desc_addr_w = csr_o_base + ({62'd0, wr_group_idx_r} << 13);
    assign top_wr_desc_words_w = O_WORDS_PER_GROUP_W;
    assign top_wr_data_valid_w = (wr_state_r == WR_DATA) && o_dump_valid_w;
    assign top_wr_data_w = o_dump_word_w;
    assign top_wr_data_last_w = o_dump_last_w;
    assign o_dump_ready_w = (wr_state_r == WR_DATA) && top_wr_data_ready_w;

    function [15:0] make_q_word;
        input [5:0] q_tile_idx;
        input [1:0] row_idx;
        input [5:0] col_idx;
        begin
            make_q_word = 16'h0001
                        + {13'd0, (row_idx + q_tile_idx[1:0])}
                        + {13'd0, col_idx[1:0]};
        end
    endfunction

    function [63:0] make_q_beat;
        input [5:0] q_tile_idx;
        input [1:0] row_idx;
        input [3:0] chunk_idx;
        reg [5:0] base_col;
        begin
            base_col = {chunk_idx, 2'b00};
            make_q_beat = {
                make_q_word(q_tile_idx, row_idx, base_col + 6'd3),
                make_q_word(q_tile_idx, row_idx, base_col + 6'd2),
                make_q_word(q_tile_idx, row_idx, base_col + 6'd1),
                make_q_word(q_tile_idx, row_idx, base_col)
            };
        end
    endfunction

    function [15:0] make_k_word;
        input [4:0] kv_tile_idx;
        input [3:0] row_idx;
        input [5:0] col_idx;
        begin
            make_k_word = 16'h0001
                        + {13'd0, (row_idx[1:0] + kv_tile_idx[1:0])}
                        + {13'd0, col_idx[1:0]};
        end
    endfunction

    function [63:0] make_k_beat;
        input [4:0] kv_tile_idx;
        input [3:0] row_idx;
        input [3:0] chunk_idx;
        reg [5:0] base_col;
        begin
            base_col = {chunk_idx, 2'b00};
            make_k_beat = {
                make_k_word(kv_tile_idx, row_idx, base_col + 6'd3),
                make_k_word(kv_tile_idx, row_idx, base_col + 6'd2),
                make_k_word(kv_tile_idx, row_idx, base_col + 6'd1),
                make_k_word(kv_tile_idx, row_idx, base_col)
            };
        end
    endfunction

    function [15:0] make_v_word;
        input [4:0] kv_tile_idx;
        input [3:0] row_idx;
        input [5:0] col_idx;
        begin
            make_v_word = 16'h0010 + ({12'd0, kv_tile_idx[3:0]} << 4)
                        + {12'd0, row_idx} + {10'd0, col_idx};
        end
    endfunction

    function [63:0] make_v_beat;
        input [4:0] kv_tile_idx;
        input [3:0] row_idx;
        input [3:0] chunk_idx;
        reg [5:0] base_col;
        begin
            base_col = {chunk_idx, 2'b00};
            make_v_beat = {
                make_v_word(kv_tile_idx, row_idx, base_col + 6'd3),
                make_v_word(kv_tile_idx, row_idx, base_col + 6'd2),
                make_v_word(kv_tile_idx, row_idx, base_col + 6'd1),
                make_v_word(kv_tile_idx, row_idx, base_col)
            };
        end
    endfunction

    FA_CSR u_fa_csr (
        .aclk(clk),
        .aresetn(rstn),
        .clear(clear),
        .s_axi_awaddr(s_axil_awaddr),
        .s_axi_awprot(3'b000),
        .s_axi_awvalid(s_axil_awvalid),
        .s_axi_awready(s_axil_awready),
        .s_axi_wdata(s_axil_wdata),
        .s_axi_wstrb(s_axil_wstrb),
        .s_axi_wvalid(s_axil_wvalid),
        .s_axi_wready(s_axil_wready),
        .s_axi_bresp(s_axil_bresp),
        .s_axi_bvalid(s_axil_bvalid),
        .s_axi_bready(s_axil_bready),
        .s_axi_araddr(s_axil_araddr),
        .s_axi_arprot(3'b000),
        .s_axi_arvalid(s_axil_arvalid),
        .s_axi_arready(s_axil_arready),
        .s_axi_rdata(s_axil_rdata),
        .s_axi_rresp(s_axil_rresp),
        .s_axi_rvalid(s_axil_rvalid),
        .s_axi_rready(s_axil_rready),
        .status_busy(top_busy_w),
        .status_done(windowed_done_sticky_r),
        .status_error(csr_config_error | windowed_error_sticky_r |
                      top_axi_error_sticky_r | windowed_top_unused_zero_w),
        .status_cycles(windowed_cycles),
        .status_rd_bytes(status_rd_bytes_w),
        .status_wr_bytes(status_wr_bytes_r),
        .start_level(csr_start_level),
        .start_pulse(csr_start_pulse),
        .soft_reset_level(csr_soft_reset_level),
        .soft_reset_pulse(csr_soft_reset_pulse),
        .config_error(csr_config_error),
        .irq_en(csr_irq_en),
        .causal_en(csr_causal_en),
        .q_base(csr_q_base),
        .k_base(csr_k_base),
        .v_base(csr_v_base),
        .o_base(csr_o_base),
        .stride_bytes(csr_stride_bytes),
        .neg_large(csr_neg_large),
        .scale(csr_scale)
    );

    FA_OPTIM_4X4_WINDOWED_LOOP u_windowed_loop (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .start(csr_start_pulse),
        .q_tile_req_valid(q_tile_req_valid_w),
        .q_tile_req_ready(q_tile_req_ready_w),
        .q_tile_req_q_idx(q_tile_req_q_idx_w),
        .q_tile_beat_valid(q_tile_beat_valid_w),
        .q_tile_beat_ready(q_tile_beat_ready_w),
        .q_tile_beat_row_idx(q_tile_beat_row_idx_w),
        .q_tile_beat_chunk_idx(q_tile_beat_chunk_idx_w),
        .q_tile_beat_data(q_tile_beat_data_w),
        .q_tile_beat_last(q_tile_beat_last_w),
        .k_tile_req_valid(k_tile_req_valid_w),
        .k_tile_req_ready(k_tile_req_ready_w),
        .k_tile_req_kv_idx(k_tile_req_kv_idx_w),
        .k_tile_beat_valid(k_tile_beat_valid_w),
        .k_tile_beat_ready(k_tile_beat_ready_w),
        .k_tile_beat_row_idx(k_tile_beat_row_idx_w),
        .k_tile_beat_chunk_idx(k_tile_beat_chunk_idx_w),
        .k_tile_beat_data(k_tile_beat_data_w),
        .k_tile_beat_last(k_tile_beat_last_w),
        .v_tile_req_valid(v_tile_req_valid_w),
        .v_tile_req_ready(v_tile_req_ready_w),
        .v_tile_req_kv_idx(v_tile_req_kv_idx_w),
        .v_tile_beat_valid(v_tile_beat_valid_w),
        .v_tile_beat_ready(v_tile_beat_ready_w),
        .v_tile_beat_row_idx(v_tile_beat_row_idx_w),
        .v_tile_beat_chunk_idx(v_tile_beat_chunk_idx_w),
        .v_tile_beat_data(v_tile_beat_data_w),
        .v_tile_beat_last(v_tile_beat_last_w),
        .busy(windowed_busy),
        .done(windowed_done_pulse),
        .error(windowed_error),
        .cycles(windowed_cycles),
        .micro_tile_count(windowed_micro_tile_count),
        .q_group_count(windowed_q_group_count),
        .kv_window_count(windowed_kv_window_count),
        .q_tile_visit_count(windowed_q_tile_visit_count),
        .kv_tile_count(windowed_kv_tile_count),
        .q_tile_req_count(windowed_q_tile_req_count),
        .q_tile_beat_count(windowed_q_tile_beat_count),
        .k_tile_req_count(windowed_k_tile_req_count),
        .k_tile_beat_count(windowed_k_tile_beat_count),
        .v_tile_req_count(windowed_v_tile_req_count),
        .v_tile_beat_count(windowed_v_tile_beat_count),
        .state_fill_count(windowed_state_fill_count),
        .state_spill_count(windowed_state_spill_count),
        .qk_task_count(windowed_qk_task_count),
        .pv_task_count(windowed_pv_task_count),
        .oacc_task_count(windowed_oacc_task_count),
        .o_dump_valid(o_dump_valid_w),
        .o_dump_ready(o_dump_ready_w),
        .o_dump_group_idx(o_dump_group_idx_w),
        .o_dump_word_idx(o_dump_word_idx_w),
        .o_dump_word(o_dump_word_w),
        .o_dump_last(o_dump_last_w),
        .o_block_flat(windowed_o_block_flat)
    );

    FA_AXI_RD_MASTER u_axi_rd (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .rd_desc_valid(top_rd_desc_valid_w),
        .rd_desc_ready(top_rd_desc_ready_w),
        .rd_desc_addr(top_rd_desc_addr_w),
        .rd_desc_words(top_rd_desc_words_w),
        .rd_desc_tag(top_rd_desc_tag_w),
        .rd_beat_valid(top_rd_beat_valid_w),
        .rd_beat_ready(top_rd_beat_ready_w),
        .rd_beat_data(top_rd_beat_data_w),
        .rd_beat_word_count(top_rd_beat_word_count_w),
        .rd_beat_last(top_rd_beat_last_w),
        .axi_arvalid(top_axi_arvalid_w),
        .axi_arready(m_axi_arready),
        .axi_araddr(m_axi_araddr),
        .axi_arlen(m_axi_arlen),
        .axi_arsize(m_axi_arsize),
        .axi_arburst(m_axi_arburst),
        .axi_rdata(m_axi_rdata),
        .axi_rresp(m_axi_rresp),
        .axi_rlast(m_axi_rlast),
        .axi_rvalid(m_axi_rvalid),
        .axi_rready(m_axi_rready),
        .error_pulse(top_axi_error_pulse_w)
    );

    FA_AXI_WR_MASTER u_axi_wr (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .wr_desc_valid(top_wr_desc_valid_w),
        .wr_desc_ready(top_wr_desc_ready_w),
        .wr_desc_addr(top_wr_desc_addr_w),
        .wr_desc_words(top_wr_desc_words_w),
        .wr_data_valid(top_wr_data_valid_w),
        .wr_data_ready(top_wr_data_ready_w),
        .wr_data(top_wr_data_w),
        .wr_data_last(top_wr_data_last_w),
        .axi_awvalid(top_axi_awvalid_w),
        .axi_awready(m_axi_awready),
        .axi_awaddr(top_axi_awaddr_w),
        .axi_awlen(top_axi_awlen_w),
        .axi_awsize(top_axi_awsize_w),
        .axi_awburst(top_axi_awburst_w),
        .axi_wvalid(top_axi_wvalid_w),
        .axi_wready(m_axi_wready),
        .axi_wdata(top_axi_wdata_w),
        .axi_wstrb(top_axi_wstrb_w),
        .axi_wlast(top_axi_wlast_w),
        .axi_bresp(m_axi_bresp),
        .axi_bvalid(m_axi_bvalid),
        .axi_bready(top_axi_bready_w),
        .error_pulse(top_wr_axi_error_pulse_w)
    );

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            windowed_done_sticky_r <= 1'b0;
            windowed_error_sticky_r <= 1'b0;
            top_axi_error_sticky_r <= 1'b0;
        end else if (runtime_clear || csr_start_pulse) begin
            windowed_done_sticky_r <= 1'b0;
            windowed_error_sticky_r <= 1'b0;
            top_axi_error_sticky_r <= 1'b0;
        end else begin
            if (top_done_accept_w) begin
                windowed_done_sticky_r <= 1'b1;
            end
            if (windowed_error) begin
                windowed_error_sticky_r <= 1'b1;
            end
            if (top_axi_error_pulse_w || top_wr_axi_error_pulse_w) begin
                top_axi_error_sticky_r <= 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            wr_state_r <= WR_IDLE;
            wr_group_idx_r <= 2'd0;
            status_wr_bytes_r <= 32'd0;
            windowed_done_pending_r <= 1'b0;
        end else if (runtime_clear || csr_start_pulse) begin
            wr_state_r <= WR_IDLE;
            wr_group_idx_r <= 2'd0;
            status_wr_bytes_r <= 32'd0;
            windowed_done_pending_r <= 1'b0;
        end else begin
            if (wr_data_fire_w) begin
                status_wr_bytes_r <= status_wr_bytes_r + 32'd4;
            end

            if (top_done_accept_w) begin
                windowed_done_pending_r <= 1'b0;
            end else if (windowed_done_pulse) begin
                windowed_done_pending_r <= 1'b1;
            end

            case (wr_state_r)
                WR_IDLE: begin
                    if (o_dump_valid_w) begin
                        wr_group_idx_r <= o_dump_group_idx_w;
                        wr_state_r <= WR_DESC;
                    end
                end
                WR_DESC: begin
                    if (wr_desc_fire_w) begin
                        wr_state_r <= WR_DATA;
                    end
                end
                WR_DATA: begin
                    if (wr_data_fire_w && o_dump_last_w) begin
                        wr_state_r <= WR_DRAIN;
                    end
                end
                WR_DRAIN: begin
                    if (wr_drain_done_w) begin
                        wr_state_r <= WR_IDLE;
                    end
                end
                default: begin
                    wr_state_r <= WR_IDLE;
                end
            endcase
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            feeder_state_r <= FEED_IDLE;
            feeder_beat_idx_r <= 9'd0;
            feeder_q_idx_r <= 6'd0;
            feeder_kv_idx_r <= 5'd0;
            feeder_axi_data_r <= 128'd0;
            feeder_upper_half_r <= 1'b0;
        end else if (runtime_clear) begin
            feeder_state_r <= FEED_IDLE;
            feeder_beat_idx_r <= 9'd0;
            feeder_q_idx_r <= 6'd0;
            feeder_kv_idx_r <= 5'd0;
            feeder_axi_data_r <= 128'd0;
            feeder_upper_half_r <= 1'b0;
        end else begin
            case (feeder_state_r)
                FEED_IDLE: begin
                    feeder_beat_idx_r <= 9'd0;
                    feeder_upper_half_r <= 1'b0;
                    if (k_tile_req_fire_w) begin
                        feeder_state_r <= FEED_K;
                        feeder_kv_idx_r <= k_tile_req_kv_idx_w;
                    end else if (v_tile_req_fire_w) begin
                        feeder_state_r <= FEED_V;
                        feeder_kv_idx_r <= v_tile_req_kv_idx_w;
                    end else if (q_tile_req_fire_w) begin
                        feeder_state_r <= FEED_Q;
                        feeder_q_idx_r <= q_tile_req_q_idx_w;
                    end
                end
                FEED_Q: begin
                    if (feeder_axi_beat_accept_w) begin
                        feeder_axi_data_r <= top_rd_beat_data_w;
                    end
                    if (q_tile_beat_fire_w) begin
                        if (q_feed_last_w) begin
                            feeder_state_r <= FEED_IDLE;
                            feeder_beat_idx_r <= 9'd0;
                            feeder_upper_half_r <= 1'b0;
                        end else if (feeder_upper_half_r) begin
                            feeder_beat_idx_r <= feeder_beat_idx_r + 9'd1;
                            feeder_upper_half_r <= 1'b0;
                        end else begin
                            feeder_beat_idx_r <= feeder_beat_idx_r + 9'd1;
                            feeder_upper_half_r <= 1'b1;
                        end
                    end
                end
                FEED_K: begin
                    if (feeder_axi_beat_accept_w) begin
                        feeder_axi_data_r <= top_rd_beat_data_w;
                    end
                    if (k_tile_beat_fire_w) begin
                        if (kv_feed_last_w) begin
                            feeder_state_r <= FEED_IDLE;
                            feeder_beat_idx_r <= 9'd0;
                            feeder_upper_half_r <= 1'b0;
                        end else if (feeder_upper_half_r) begin
                            feeder_beat_idx_r <= feeder_beat_idx_r + 9'd1;
                            feeder_upper_half_r <= 1'b0;
                        end else begin
                            feeder_beat_idx_r <= feeder_beat_idx_r + 9'd1;
                            feeder_upper_half_r <= 1'b1;
                        end
                    end
                end
                FEED_V: begin
                    if (feeder_axi_beat_accept_w) begin
                        feeder_axi_data_r <= top_rd_beat_data_w;
                    end
                    if (v_tile_beat_fire_w) begin
                        if (kv_feed_last_w) begin
                            feeder_state_r <= FEED_IDLE;
                            feeder_beat_idx_r <= 9'd0;
                            feeder_upper_half_r <= 1'b0;
                        end else if (feeder_upper_half_r) begin
                            feeder_beat_idx_r <= feeder_beat_idx_r + 9'd1;
                            feeder_upper_half_r <= 1'b0;
                        end else begin
                            feeder_beat_idx_r <= feeder_beat_idx_r + 9'd1;
                            feeder_upper_half_r <= 1'b1;
                        end
                    end
                end
                default: begin
                    feeder_state_r <= FEED_IDLE;
                    feeder_beat_idx_r <= 9'd0;
                    feeder_upper_half_r <= 1'b0;
                end
            endcase
        end
    end

    assign m_axi_awaddr = top_axi_awaddr_w;
    assign m_axi_awlen = top_axi_awlen_w;
    assign m_axi_awsize = top_axi_awsize_w;
    assign m_axi_awburst = top_axi_awburst_w;
    assign m_axi_awvalid = top_axi_awvalid_w;
    assign m_axi_wdata = top_axi_wdata_w;
    assign m_axi_wstrb = top_axi_wstrb_w;
    assign m_axi_wlast = top_axi_wlast_w;
    assign m_axi_wvalid = top_axi_wvalid_w;
    assign m_axi_bready = top_axi_bready_w;
    assign m_axi_arvalid = top_axi_arvalid_w;
    assign irq = csr_irq_en && (windowed_done_sticky_r ||
                                windowed_error_sticky_r ||
                                top_axi_error_sticky_r ||
                                csr_config_error);

endmodule
