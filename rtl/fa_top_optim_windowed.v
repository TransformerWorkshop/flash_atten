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
    wire [4095:0] windowed_o_block_flat;

    reg         windowed_done_sticky_r;
    reg         windowed_error_sticky_r;
    reg [1:0]   feeder_state_r;
    reg [8:0]   feeder_beat_idx_r;
    reg [5:0]   feeder_q_idx_r;
    reg [4:0]   feeder_kv_idx_r;

    wire feeder_idle_w = (feeder_state_r == FEED_IDLE);
    wire q_tile_req_fire_w = q_tile_req_valid_w && q_tile_req_ready_w;
    wire k_tile_req_fire_w = k_tile_req_valid_w && k_tile_req_ready_w;
    wire v_tile_req_fire_w = v_tile_req_valid_w && v_tile_req_ready_w;
    wire q_tile_beat_fire_w = q_tile_beat_valid_w && q_tile_beat_ready_w;
    wire k_tile_beat_fire_w = k_tile_beat_valid_w && k_tile_beat_ready_w;
    wire v_tile_beat_fire_w = v_tile_beat_valid_w && v_tile_beat_ready_w;
    wire q_feed_last_w = (feeder_beat_idx_r == 9'd63);
    wire kv_feed_last_w = (feeder_beat_idx_r == 9'd255);

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
        | ((|windowed_o_block_flat) & 1'b0)
        | (m_axi_arready & 1'b0)
        | ((|m_axi_rdata) & 1'b0)
        | ((|m_axi_rresp) & 1'b0)
        | (m_axi_rlast & 1'b0)
        | (m_axi_rvalid & 1'b0)
        | (m_axi_awready & 1'b0)
        | (m_axi_wready & 1'b0)
        | ((|m_axi_bresp) & 1'b0)
        | (m_axi_bvalid & 1'b0)
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

    assign q_tile_req_ready_w = feeder_idle_w;
    assign k_tile_req_ready_w = feeder_idle_w;
    assign v_tile_req_ready_w = feeder_idle_w;
    assign q_tile_beat_valid_w = (feeder_state_r == FEED_Q);
    assign k_tile_beat_valid_w = (feeder_state_r == FEED_K);
    assign v_tile_beat_valid_w = (feeder_state_r == FEED_V);
    assign q_tile_beat_row_idx_w = feeder_beat_idx_r[5:4];
    assign q_tile_beat_chunk_idx_w = feeder_beat_idx_r[3:0];
    assign k_tile_beat_row_idx_w = feeder_beat_idx_r[7:4];
    assign k_tile_beat_chunk_idx_w = feeder_beat_idx_r[3:0];
    assign v_tile_beat_row_idx_w = feeder_beat_idx_r[7:4];
    assign v_tile_beat_chunk_idx_w = feeder_beat_idx_r[3:0];
    assign q_tile_beat_data_w = make_q_beat(feeder_q_idx_r, q_tile_beat_row_idx_w,
                                            q_tile_beat_chunk_idx_w);
    assign k_tile_beat_data_w = make_k_beat(feeder_kv_idx_r, k_tile_beat_row_idx_w,
                                            k_tile_beat_chunk_idx_w);
    assign v_tile_beat_data_w = make_v_beat(feeder_kv_idx_r, v_tile_beat_row_idx_w,
                                            v_tile_beat_chunk_idx_w);
    assign q_tile_beat_last_w = q_feed_last_w;
    assign k_tile_beat_last_w = kv_feed_last_w;
    assign v_tile_beat_last_w = kv_feed_last_w;

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
        .status_busy(windowed_busy),
        .status_done(windowed_done_sticky_r),
        .status_error(csr_config_error | windowed_error_sticky_r |
                      windowed_top_unused_zero_w),
        .status_cycles(windowed_cycles),
        .status_rd_bytes(status_rd_bytes_w),
        .status_wr_bytes(32'd0),
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
        .o_block_flat(windowed_o_block_flat)
    );

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            windowed_done_sticky_r <= 1'b0;
            windowed_error_sticky_r <= 1'b0;
        end else if (runtime_clear || csr_start_pulse) begin
            windowed_done_sticky_r <= 1'b0;
            windowed_error_sticky_r <= 1'b0;
        end else begin
            if (windowed_done_pulse) begin
                windowed_done_sticky_r <= 1'b1;
            end
            if (windowed_error) begin
                windowed_error_sticky_r <= 1'b1;
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            feeder_state_r <= FEED_IDLE;
            feeder_beat_idx_r <= 9'd0;
            feeder_q_idx_r <= 6'd0;
            feeder_kv_idx_r <= 5'd0;
        end else if (runtime_clear) begin
            feeder_state_r <= FEED_IDLE;
            feeder_beat_idx_r <= 9'd0;
            feeder_q_idx_r <= 6'd0;
            feeder_kv_idx_r <= 5'd0;
        end else begin
            case (feeder_state_r)
                FEED_IDLE: begin
                    feeder_beat_idx_r <= 9'd0;
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
                    if (q_tile_beat_fire_w) begin
                        if (q_feed_last_w) begin
                            feeder_state_r <= FEED_IDLE;
                            feeder_beat_idx_r <= 9'd0;
                        end else begin
                            feeder_beat_idx_r <= feeder_beat_idx_r + 9'd1;
                        end
                    end
                end
                FEED_K: begin
                    if (k_tile_beat_fire_w) begin
                        if (kv_feed_last_w) begin
                            feeder_state_r <= FEED_IDLE;
                            feeder_beat_idx_r <= 9'd0;
                        end else begin
                            feeder_beat_idx_r <= feeder_beat_idx_r + 9'd1;
                        end
                    end
                end
                FEED_V: begin
                    if (v_tile_beat_fire_w) begin
                        if (kv_feed_last_w) begin
                            feeder_state_r <= FEED_IDLE;
                            feeder_beat_idx_r <= 9'd0;
                        end else begin
                            feeder_beat_idx_r <= feeder_beat_idx_r + 9'd1;
                        end
                    end
                end
                default: begin
                    feeder_state_r <= FEED_IDLE;
                    feeder_beat_idx_r <= 9'd0;
                end
            endcase
        end
    end

    assign m_axi_araddr = 64'd0;
    assign m_axi_arlen = 8'd0;
    assign m_axi_arsize = 3'd4;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arvalid = 1'b0;
    assign m_axi_rready = 1'b0;
    assign m_axi_awaddr = 64'd0;
    assign m_axi_awlen = 8'd0;
    assign m_axi_awsize = 3'd4;
    assign m_axi_awburst = 2'b01;
    assign m_axi_awvalid = 1'b0;
    assign m_axi_wdata = 128'd0;
    assign m_axi_wstrb = 16'd0;
    assign m_axi_wlast = 1'b0;
    assign m_axi_wvalid = 1'b0;
    assign m_axi_bready = 1'b0;
    assign irq = csr_irq_en && (windowed_done_sticky_r ||
                                windowed_error_sticky_r ||
                                csr_config_error);

endmodule
