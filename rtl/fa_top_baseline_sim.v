module FA_TOP_BASELINE_SIM #(
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
    output wire         wr_desc_valid,
    input  wire         wr_desc_ready,
    output wire [63:0]  wr_desc_addr,
    output wire [15:0]  wr_desc_words,
    output wire         wr_data_valid,
    input  wire         wr_data_ready,
    output wire [31:0]  wr_data,
    output wire         wr_data_last,
    output wire         irq
);

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

    wire        status_busy;
    wire        status_done;
    wire        status_error_core;
    wire [31:0] status_cycles;
    wire [31:0] status_rd_bytes;
    wire [31:0] status_wr_bytes;

    wire [16383:0] q_tile_flat;
    wire [16383:0] k_tile_flat;
    wire [16383:0] v_tile_flat;
    wire [16383:0] v_pv_layout_flat;
    wire [4095:0]  p_tile_flat;
    wire [16383:0] oacc_tile_flat;
    wire [8191:0]  qk_result_tile_flat;
    wire [8191:0]  score_masked_tile_flat;
    wire [16383:0] pv_result_tile_flat;
    wire [511:0]   row_debug_m_state_flat;
    wire [511:0]   row_debug_l_state_flat;
    wire [15:0]    row_debug_seen_flat;
    wire           store_req_valid;
    wire           store_done_pulse;
    wire           core_irq;

    wire status_error = status_error_core | csr_config_error;

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
        .status_busy(status_busy),
        .status_done(status_done),
        .status_error(status_error),
        .status_cycles(status_cycles),
        .status_rd_bytes(status_rd_bytes),
        .status_wr_bytes(status_wr_bytes),
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

    FA_CORE_BASELINE #(
        .DATA_WIDTH(DATA_WIDTH),
        .GEMM_X_DIM(GEMM_X_DIM),
        .GEMM_Y_DIM(GEMM_Y_DIM),
        .EXT_ADDR_W(EXT_ADDR_W),
        .DMA_BEATS_W(DMA_BEATS_W),
        .LUT_DEPTH(LUT_DEPTH),
        .A_BANK_DEPTH(A_BANK_DEPTH),
        .B_BANK_DEPTH(B_BANK_DEPTH),
        .M_BANK_DEPTH(M_BANK_DEPTH),
        .A_LOAD_LANES(A_LOAD_LANES),
        .B_LOAD_LANES(B_LOAD_LANES),
        .M_WRITE_LANES(M_WRITE_LANES),
        .M_EXPORT_LANES(M_EXPORT_LANES),
        .M_PHYSICAL_COPIES(M_PHYSICAL_COPIES),
        .STREAM_CHANNELS(STREAM_CHANNELS),
        .S_AXIS_CHANNEL_WIDTH(S_AXIS_CHANNEL_WIDTH),
        .M_AXIS_CHANNEL_WIDTH(M_AXIS_CHANNEL_WIDTH)
    ) u_core (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start_pulse(csr_start_pulse),
        .soft_reset_pulse(csr_soft_reset_pulse),
        .irq_en(csr_irq_en),
        .causal_en(csr_causal_en),
        .q_base(csr_q_base),
        .k_base(csr_k_base),
        .v_base(csr_v_base),
        .o_base(csr_o_base),
        .stride_bytes(csr_stride_bytes),
        .neg_large(csr_neg_large),
        .scale(csr_scale),
        .ext_error_pulse(1'b0),
        .rd_desc_valid(rd_desc_valid),
        .rd_desc_ready(rd_desc_ready),
        .rd_desc_addr(rd_desc_addr),
        .rd_desc_words(rd_desc_words),
        .rd_desc_tag(rd_desc_tag),
        .rd_beat_valid(rd_beat_valid),
        .rd_beat_ready(rd_beat_ready),
        .rd_beat_data(rd_beat_data),
        .rd_beat_word_count(rd_beat_word_count),
        .rd_beat_last(rd_beat_last),
        .wr_desc_valid(wr_desc_valid),
        .wr_desc_ready(wr_desc_ready),
        .wr_desc_addr(wr_desc_addr),
        .wr_desc_words(wr_desc_words),
        .wr_data_valid(wr_data_valid),
        .wr_data_ready(wr_data_ready),
        .wr_data(wr_data),
        .wr_data_last(wr_data_last),
        .busy(status_busy),
        .done(status_done),
        .error(status_error_core),
        .cycles(status_cycles),
        .rd_bytes(status_rd_bytes),
        .wr_bytes(status_wr_bytes),
        .irq(core_irq),
        .q_tile_flat(q_tile_flat),
        .k_tile_flat(k_tile_flat),
        .v_tile_flat(v_tile_flat),
        .v_pv_layout_flat(v_pv_layout_flat),
        .p_tile_flat(p_tile_flat),
        .oacc_tile_flat(oacc_tile_flat),
        .qk_result_tile_flat(qk_result_tile_flat),
        .score_masked_tile_flat(score_masked_tile_flat),
        .pv_result_tile_flat(pv_result_tile_flat),
        .row_debug_m_state_flat(row_debug_m_state_flat),
        .row_debug_l_state_flat(row_debug_l_state_flat),
        .row_debug_seen_flat(row_debug_seen_flat),
        .debug_store_req_valid(store_req_valid),
        .debug_store_done_pulse(store_done_pulse)
    );

    assign irq = core_irq;

endmodule
