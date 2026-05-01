module FA_TOP_BASELINE #(
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
    wire [2:0]  s_axil_awprot_tieoff = 3'b000;
    wire [2:0]  s_axil_arprot_tieoff = 3'b000;

    wire        core_busy;
    wire        core_done;
    wire        core_error;
    wire [31:0] core_cycles;
    wire [31:0] core_rd_bytes;
    wire [31:0] core_wr_bytes;
    wire        core_irq;

    wire        rd_desc_valid;
    wire        rd_desc_ready;
    wire [63:0] rd_desc_addr;
    wire [15:0] rd_desc_words;
    wire [3:0]  rd_desc_tag;
    wire        rd_beat_valid;
    wire        rd_beat_ready;
    wire [127:0] rd_beat_data;
    wire [2:0]  rd_beat_word_count;
    wire        rd_beat_last;
    wire        wr_desc_valid;
    wire        wr_desc_ready;
    wire [63:0] wr_desc_addr;
    wire [15:0] wr_desc_words;
    wire        wr_data_valid;
    wire        wr_data_ready;
    wire [31:0] wr_data;
    wire        wr_data_last;
    wire        rd_axi_error_pulse;
    wire        wr_axi_error_pulse;
    wire        csr_level_unused_zero_w = (csr_start_level & 1'b0)
                                        | (csr_soft_reset_level & 1'b0);
`ifndef SYNTHESIS
    //debug
    wire [16383:0] q_tile_flat_unused;
    wire [16383:0] k_tile_flat_unused;
    wire [16383:0] v_tile_flat_unused;
    wire [16383:0] v_pv_layout_flat_unused;
    wire [4095:0]  p_tile_flat_unused;
    wire [16383:0] oacc_tile_flat_unused;
    wire [8191:0]  qk_result_tile_flat_unused;
    wire [8191:0]  score_masked_tile_flat_unused;
    wire [16383:0] pv_result_tile_flat_unused;
    wire [511:0]   row_debug_m_state_flat_unused;
    wire [511:0]   row_debug_l_state_flat_unused;
    wire [15:0]    row_debug_seen_flat_unused;
    wire           debug_store_req_valid_unused;
    wire           debug_store_done_pulse_unused;
    wire           top_debug_unused_zero_w = (q_tile_flat_unused[0] & 1'b0)
                                           | (k_tile_flat_unused[0] & 1'b0)
                                           | (v_tile_flat_unused[0] & 1'b0)
                                           | (v_pv_layout_flat_unused[0] & 1'b0)
                                           | (p_tile_flat_unused[0] & 1'b0)
                                           | (oacc_tile_flat_unused[0] & 1'b0)
                                           | (qk_result_tile_flat_unused[0] & 1'b0)
                                           | (score_masked_tile_flat_unused[0] & 1'b0)
                                           | (pv_result_tile_flat_unused[0] & 1'b0)
                                           | (row_debug_m_state_flat_unused[0] & 1'b0)
                                           | (row_debug_l_state_flat_unused[0] & 1'b0)
                                           | (row_debug_seen_flat_unused[0] & 1'b0)
                                           | (debug_store_req_valid_unused & 1'b0)
                                           | (debug_store_done_pulse_unused & 1'b0);
`else
    wire           top_debug_unused_zero_w = 1'b0;
`endif
    wire           top_unused_zero_w = csr_level_unused_zero_w | top_debug_unused_zero_w;

    reg axi_error_sticky_r;
    wire status_error = core_error | axi_error_sticky_r | csr_config_error | top_unused_zero_w;

    FA_CSR u_fa_csr (
        .aclk(clk),
        .aresetn(rstn),
        .clear(clear),
        .s_axi_awaddr(s_axil_awaddr),
        .s_axi_awprot(s_axil_awprot_tieoff),
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
        .s_axi_arprot(s_axil_arprot_tieoff),
        .s_axi_arvalid(s_axil_arvalid),
        .s_axi_arready(s_axil_arready),
        .s_axi_rdata(s_axil_rdata),
        .s_axi_rresp(s_axil_rresp),
        .s_axi_rvalid(s_axil_rvalid),
        .s_axi_rready(s_axil_rready),
        .status_busy(core_busy),
        .status_done(core_done),
        .status_error(status_error),
        .status_cycles(core_cycles),
        .status_rd_bytes(core_rd_bytes),
        .status_wr_bytes(core_wr_bytes),
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
        .ext_error_pulse(rd_axi_error_pulse | wr_axi_error_pulse),
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
        .busy(core_busy),
        .done(core_done),
        .error(core_error),
        .cycles(core_cycles),
        .rd_bytes(core_rd_bytes),
        .wr_bytes(core_wr_bytes),
        .irq(core_irq)
`ifndef SYNTHESIS
        ,
        //debug
        .q_tile_flat(q_tile_flat_unused),
        .k_tile_flat(k_tile_flat_unused),
        .v_tile_flat(v_tile_flat_unused),
        .v_pv_layout_flat(v_pv_layout_flat_unused),
        .p_tile_flat(p_tile_flat_unused),
        .oacc_tile_flat(oacc_tile_flat_unused),
        .qk_result_tile_flat(qk_result_tile_flat_unused),
        .score_masked_tile_flat(score_masked_tile_flat_unused),
        .pv_result_tile_flat(pv_result_tile_flat_unused),
        .row_debug_m_state_flat(row_debug_m_state_flat_unused),
        .row_debug_l_state_flat(row_debug_l_state_flat_unused),
        .row_debug_seen_flat(row_debug_seen_flat_unused),
        .debug_store_req_valid(debug_store_req_valid_unused),
        .debug_store_done_pulse(debug_store_done_pulse_unused)
`endif
    );

    FA_AXI_RD_MASTER u_axi_rd (
        .clk(clk),
        .rstn(rstn),
        .clear(clear | csr_soft_reset_pulse),
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
        .axi_arvalid(m_axi_arvalid),
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
        .error_pulse(rd_axi_error_pulse)
    );

    FA_AXI_WR_MASTER u_axi_wr (
        .clk(clk),
        .rstn(rstn),
        .clear(clear | csr_soft_reset_pulse),
        .wr_desc_valid(wr_desc_valid),
        .wr_desc_ready(wr_desc_ready),
        .wr_desc_addr(wr_desc_addr),
        .wr_desc_words(wr_desc_words),
        .wr_data_valid(wr_data_valid),
        .wr_data_ready(wr_data_ready),
        .wr_data(wr_data),
        .wr_data_last(wr_data_last),
        .axi_awvalid(m_axi_awvalid),
        .axi_awready(m_axi_awready),
        .axi_awaddr(m_axi_awaddr),
        .axi_awlen(m_axi_awlen),
        .axi_awsize(m_axi_awsize),
        .axi_awburst(m_axi_awburst),
        .axi_wvalid(m_axi_wvalid),
        .axi_wready(m_axi_wready),
        .axi_wdata(m_axi_wdata),
        .axi_wstrb(m_axi_wstrb),
        .axi_wlast(m_axi_wlast),
        .axi_bresp(m_axi_bresp),
        .axi_bvalid(m_axi_bvalid),
        .axi_bready(m_axi_bready),
        .error_pulse(wr_axi_error_pulse)
    );

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            axi_error_sticky_r <= 1'b0;
        end else if (clear || csr_soft_reset_pulse || csr_start_pulse) begin
            axi_error_sticky_r <= 1'b0;
        end else if (rd_axi_error_pulse || wr_axi_error_pulse) begin
            axi_error_sticky_r <= 1'b1;
        end
    end

    assign irq = core_irq;

endmodule
