module FA_TOP_OPTIM_PACKED #(
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

    wire        packed_busy;
    wire        packed_done;
    wire [31:0] packed_cycles;
    wire [31:0] packed_sa_busy_cycles;
    wire [31:0] packed_feeder_busy_cycles;
    wire [31:0] packed_row_state_busy_cycles;
    wire [31:0] packed_qk_task_count;
    wire [31:0] packed_pv_task_count;
    wire [31:0] packed_oacc_task_count;
    wire [31:0] packed_row_update_task_count;
    wire [31:0] packed_qk_feed_count;
    wire [31:0] packed_pv_feed_count;
    wire [31:0] packed_cluster_wait_task_count;
    wire [31:0] packed_feeder_wait_slot_count;
    wire [31:0] packed_pv_wait_row_update_count;
    wire [31:0] packed_active0_count;
    wire [31:0] packed_active1_count;
    wire [31:0] packed_active2_count;
    wire [31:0] packed_active3_count;
    wire [31:0] packed_active4_count;
    wire [63:0] packed_buffer_probe_data;
    wire        runtime_clear = clear || csr_soft_reset_pulse;

    wire optim_unused_zero_w = (csr_start_level & 1'b0)
                             | (csr_soft_reset_level & 1'b0)
                             | (csr_causal_en & 1'b0)
                             | ((|csr_q_base) & 1'b0)
                             | ((|csr_k_base) & 1'b0)
                             | ((|csr_v_base) & 1'b0)
                             | ((|csr_o_base) & 1'b0)
                             | ((|csr_stride_bytes) & 1'b0)
                             | ((|csr_neg_large) & 1'b0)
                             | ((|csr_scale) & 1'b0)
                             | ((|packed_sa_busy_cycles) & 1'b0)
                             | ((|packed_feeder_busy_cycles) & 1'b0)
                             | ((|packed_row_state_busy_cycles) & 1'b0)
                             | ((|packed_qk_task_count) & 1'b0)
                             | ((|packed_pv_task_count) & 1'b0)
                             | ((|packed_oacc_task_count) & 1'b0)
                             | ((|packed_row_update_task_count) & 1'b0)
                             | ((|packed_qk_feed_count) & 1'b0)
                             | ((|packed_pv_feed_count) & 1'b0)
                             | ((|packed_cluster_wait_task_count) & 1'b0)
                             | ((|packed_feeder_wait_slot_count) & 1'b0)
                             | ((|packed_pv_wait_row_update_count) & 1'b0)
                             | ((|packed_active0_count) & 1'b0)
                             | ((|packed_active1_count) & 1'b0)
                             | ((|packed_active2_count) & 1'b0)
                             | ((|packed_active3_count) & 1'b0)
                             | ((|packed_active4_count) & 1'b0)
                             | ((|packed_buffer_probe_data) & 1'b0)
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
        .status_busy(packed_busy),
        .status_done(packed_done),
        .status_error(csr_config_error | optim_unused_zero_w),
        .status_cycles(packed_cycles),
        .status_rd_bytes(32'd0),
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

    FA_OPTIM_SA_PIPELINE_PACKED_PROTOTYPE u_packed_core (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .start(csr_start_pulse),
        .busy(packed_busy),
        .done(packed_done),
        .cycles(packed_cycles),
        .sa_busy_cycles(packed_sa_busy_cycles),
        .feeder_busy_cycles(packed_feeder_busy_cycles),
        .row_state_busy_cycles(packed_row_state_busy_cycles),
        .qk_task_count(packed_qk_task_count),
        .pv_task_count(packed_pv_task_count),
        .oacc_task_count(packed_oacc_task_count),
        .row_update_task_count(packed_row_update_task_count),
        .qk_feed_count(packed_qk_feed_count),
        .pv_feed_count(packed_pv_feed_count),
        .cluster_wait_task_count(packed_cluster_wait_task_count),
        .feeder_wait_slot_count(packed_feeder_wait_slot_count),
        .pv_wait_row_update_count(packed_pv_wait_row_update_count),
        .active0_count(packed_active0_count),
        .active1_count(packed_active1_count),
        .active2_count(packed_active2_count),
        .active3_count(packed_active3_count),
        .active4_count(packed_active4_count),
        .packed_buffer_probe_data(packed_buffer_probe_data)
    );

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
    assign irq = csr_irq_en && (packed_done || csr_config_error);

endmodule
