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
    input  wire         rd_data_valid,
    output wire         rd_data_ready,
    input  wire [31:0]  rd_data,
    input  wire         rd_data_last,
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

    localparam [1:0] LOAD_KIND_Q = 2'd0;
    localparam [1:0] LOAD_KIND_K = 2'd1;
    localparam [1:0] LOAD_KIND_V = 2'd2;
    localparam [16383:0] ZERO_TILE_16X64 = {16384{1'b0}};
    localparam [4095:0] ZERO_TILE_16X16 = {4096{1'b0}};

    wire        csr_start_level;
    wire        csr_start_pulse;
    wire        csr_soft_reset_level;
    wire        csr_soft_reset_pulse;
    wire        csr_irq_en;
    wire        csr_causal_en;
    wire [63:0] csr_q_base;
    wire [63:0] csr_k_base;
    wire [63:0] csr_v_base;
    wire [63:0] csr_o_base;
    wire [31:0] csr_stride_bytes;
    wire [31:0] csr_neg_large;
    wire [31:0] csr_scale;

    wire        run_active;
    wire        status_busy;
    wire        status_done;
    wire        status_error;
    wire [31:0] status_cycles;

    wire [3:0] sched_q_blk_idx;
    wire [3:0] sched_kv_blk_idx;
    wire       load_req_valid;
    wire       load_req_ready;
    wire [1:0] load_req_kind;
    wire       load_done_pulse;
    wire       row_init_valid;
    wire       row_init_ready;
    wire       row_init_done_pulse;
    wire       oacc_clear_valid;
    wire       oacc_clear_ready;
    reg        oacc_clear_done_pulse_r;
    wire       qk_req_valid;
    wire       qk_req_ready;
    wire       qk_done_pulse;
    wire       score_req_valid;
    wire       score_req_ready;
    wire       score_done_pulse;
    wire       row_update_valid;
    wire       row_update_ready;
    wire       row_update_done_pulse;
    wire       pv_req_valid;
    wire       pv_req_ready;
    wire       pv_done_pulse;
    wire       oacc_update_valid;
    wire       oacc_update_ready;
    wire       oacc_update_done_pulse;
    wire       store_req_valid;
    wire       store_req_ready;
    wire       store_done_pulse;
    wire       run_complete_pulse;

    wire       qkv_wr_valid;
    wire [1:0] qkv_wr_kind;
    wire [3:0] qkv_wr_row;
    wire [4:0] qkv_wr_lane;
    wire [31:0] qkv_wr_word;
    wire       v_pv_wr_valid;
    wire [4:0] v_pv_wr_addr;
    wire       v_pv_lane0_valid;
    wire [3:0] v_pv_lane0_idx;
    wire       v_pv_lane0_hi;
    wire [15:0] v_pv_lane0_data;
    wire       v_pv_lane1_valid;
    wire [3:0] v_pv_lane1_idx;
    wire       v_pv_lane1_hi;
    wire [15:0] v_pv_lane1_data;
    wire       rd_error_pulse;

    wire [16383:0] q_tile_flat;
    wire [16383:0] k_tile_flat;
    wire [16383:0] v_tile_flat;
    wire [16383:0] v_pv_layout_flat;
    wire [4095:0]  p_tile_flat;
    wire [16383:0] oacc_tile_flat;

    wire         qk_resp_valid;
    wire [8191:0] qk_result_tile_flat;
    wire         score_resp_valid;
    wire [8191:0] score_masked_tile_flat;
    wire         row_resp_valid;
    wire [4095:0] row_p_tile_flat;
    wire [511:0] row_rescale_vec_flat;
    wire         row_proxy_ready_w;
    wire         pv_resp_valid;
    wire [16383:0] pv_result_tile_flat;
    wire         oacc_resp_valid;
    wire [16383:0] oacc_updated_tile_flat;
    wire         oacc_proxy_ready_w;
    wire         p_buf_load_ready;
    wire         p_buf_load_done_pulse;
    wire         oacc_buf_load_ready;
    wire         oacc_buf_load_done_pulse;
    wire         oacc_clear_req_ready_w;
    wire         oacc_clear_done_pulse_w;
    wire         q_qk_rd_en;
    wire [4:0]   q_qk_rd_addr;
    wire         q_qk_rd_valid;
    wire [511:0] q_qk_rd_data;
    wire         k_qk_rd_en;
    wire [4:0]   k_qk_rd_addr;
    wire         k_qk_rd_valid;
    wire [511:0] k_qk_rd_data;
    wire         p_pv_rd_en;
    wire [2:0]   p_pv_rd_addr;
    wire         p_pv_rd_valid;
    wire [511:0] p_pv_rd_data;
    wire         v_pv_rd_en;
    wire [4:0]   v_pv_rd_addr;
    wire         v_pv_rd_valid;
    wire [511:0] v_pv_rd_data;
    wire         oacc_exp_rd_en;
    wire [3:0]   oacc_exp_rd_row;
    wire         oacc_exp_rd_valid;
    wire [1023:0] oacc_exp_rd_data;
    wire         row_proxy_done_pulse;
    wire         oacc_proxy_done_pulse;

    wire runtime_clear = clear || csr_soft_reset_pulse;

    assign status_busy = run_active;
    assign irq = csr_irq_en && (status_done || status_error);

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
        .start_level(csr_start_level),
        .start_pulse(csr_start_pulse),
        .soft_reset_level(csr_soft_reset_level),
        .soft_reset_pulse(csr_soft_reset_pulse),
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

    FA_RUN_CTRL u_run_ctrl (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start_pulse(csr_start_pulse),
        .soft_reset_pulse(csr_soft_reset_pulse),
        .run_complete_pulse(run_complete_pulse),
        .run_error_pulse(rd_error_pulse),
        .run_active(run_active),
        .busy(),
        .done_sticky(status_done),
        .error_sticky(status_error),
        .cycles(status_cycles)
    );

    FA_TILE_SCHED u_sched (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .run_active(run_active),
        .run_start_pulse(csr_start_pulse),
        .q_blk_idx(sched_q_blk_idx),
        .kv_blk_idx(sched_kv_blk_idx),
        .load_req_valid(load_req_valid),
        .load_req_ready(load_req_ready),
        .load_req_kind(load_req_kind),
        .load_done_pulse(load_done_pulse),
        .row_init_valid(row_init_valid),
        .row_init_ready(row_init_ready),
        .row_init_done_pulse(row_init_done_pulse),
        .oacc_clear_valid(oacc_clear_valid),
        .oacc_clear_ready(oacc_clear_ready),
        .oacc_clear_done_pulse(oacc_clear_done_pulse_r),
        .qk_req_valid(qk_req_valid),
        .qk_req_ready(qk_req_ready),
        .qk_done_pulse(qk_done_pulse),
        .score_req_valid(score_req_valid),
        .score_req_ready(score_req_ready),
        .score_done_pulse(score_done_pulse),
        .row_update_valid(row_update_valid),
        .row_update_ready(row_update_ready),
        .row_update_done_pulse(row_update_done_pulse),
        .pv_req_valid(pv_req_valid),
        .pv_req_ready(pv_req_ready),
        .pv_done_pulse(pv_done_pulse),
        .oacc_update_valid(oacc_update_valid),
        .oacc_update_ready(oacc_update_ready),
        .oacc_update_done_pulse(oacc_update_done_pulse),
        .store_req_valid(store_req_valid),
        .store_req_ready(store_req_ready),
        .store_done_pulse(store_done_pulse),
        .run_complete_pulse(run_complete_pulse)
    );

    FA_RD_DMA u_rd_dma (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .req_valid(load_req_valid),
        .req_ready(load_req_ready),
        .req_kind(load_req_kind),
        .req_q_blk(sched_q_blk_idx),
        .req_kv_blk(sched_kv_blk_idx),
        .q_base(csr_q_base),
        .k_base(csr_k_base),
        .v_base(csr_v_base),
        .stride_bytes(csr_stride_bytes),
        .rd_desc_valid(rd_desc_valid),
        .rd_desc_ready(rd_desc_ready),
        .rd_desc_addr(rd_desc_addr),
        .rd_desc_words(rd_desc_words),
        .rd_desc_tag(rd_desc_tag),
        .rd_data_valid(rd_data_valid),
        .rd_data_ready(rd_data_ready),
        .rd_data(rd_data),
        .rd_data_last(rd_data_last),
        .qkv_wr_valid(qkv_wr_valid),
        .qkv_wr_kind(qkv_wr_kind),
        .qkv_wr_row(qkv_wr_row),
        .qkv_wr_lane(qkv_wr_lane),
        .qkv_wr_word(qkv_wr_word),
        .v_pv_wr_valid(v_pv_wr_valid),
        .v_pv_wr_addr(v_pv_wr_addr),
        .v_pv_lane0_valid(v_pv_lane0_valid),
        .v_pv_lane0_idx(v_pv_lane0_idx),
        .v_pv_lane0_hi(v_pv_lane0_hi),
        .v_pv_lane0_data(v_pv_lane0_data),
        .v_pv_lane1_valid(v_pv_lane1_valid),
        .v_pv_lane1_idx(v_pv_lane1_idx),
        .v_pv_lane1_hi(v_pv_lane1_hi),
        .v_pv_lane1_data(v_pv_lane1_data),
        .done_pulse(load_done_pulse),
        .error_pulse(rd_error_pulse)
    );

    FA_Q_BUF_REAL u_q_buf (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .word_write_valid(qkv_wr_valid && (qkv_wr_kind == LOAD_KIND_Q)),
        .word_write_row(qkv_wr_row),
        .word_write_lane(qkv_wr_lane),
        .word_write_data(qkv_wr_word),
        .qk_rd_en(q_qk_rd_en),
        .qk_rd_addr(q_qk_rd_addr),
        .qk_rd_valid(q_qk_rd_valid),
        .qk_rd_data(q_qk_rd_data),
        .tile_flat(q_tile_flat)
    );

    FA_K_BUF_REAL u_k_buf (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .word_write_valid(qkv_wr_valid && (qkv_wr_kind == LOAD_KIND_K)),
        .word_write_row(qkv_wr_row),
        .word_write_lane(qkv_wr_lane),
        .word_write_data(qkv_wr_word),
        .qk_rd_en(k_qk_rd_en),
        .qk_rd_addr(k_qk_rd_addr),
        .qk_rd_valid(k_qk_rd_valid),
        .qk_rd_data(k_qk_rd_data),
        .tile_flat(k_tile_flat)
    );

    FA_V_BUF_REAL u_v_buf (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .word_write_valid(qkv_wr_valid && (qkv_wr_kind == LOAD_KIND_V)),
        .word_write_row(qkv_wr_row),
        .word_write_lane(qkv_wr_lane),
        .word_write_data(qkv_wr_word),
        .tile_flat(v_tile_flat)
    );

    FA_V_BUF_PV_REAL u_v_buf_pv (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .wr_valid(v_pv_wr_valid),
        .wr_addr(v_pv_wr_addr),
        .wr_lane0_valid(v_pv_lane0_valid),
        .wr_lane0_idx(v_pv_lane0_idx),
        .wr_lane0_hi(v_pv_lane0_hi),
        .wr_lane0_data(v_pv_lane0_data),
        .wr_lane1_valid(v_pv_lane1_valid),
        .wr_lane1_idx(v_pv_lane1_idx),
        .wr_lane1_hi(v_pv_lane1_hi),
        .wr_lane1_data(v_pv_lane1_data),
        .rd_en(v_pv_rd_en),
        .rd_addr(v_pv_rd_addr),
        .rd_valid(v_pv_rd_valid),
        .rd_data(v_pv_rd_data),
        .layout_flat(v_pv_layout_flat)
    );

    FA_P_BUF_REAL u_p_buf (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .load_valid(row_proxy_done_pulse),
        .load_ready(p_buf_load_ready),
        .tile_load_data(row_p_tile_flat),
        .load_done_pulse(p_buf_load_done_pulse),
        .pv_rd_en(p_pv_rd_en),
        .pv_rd_addr(p_pv_rd_addr),
        .pv_rd_valid(p_pv_rd_valid),
        .pv_rd_data(p_pv_rd_data),
        .tile_flat(p_tile_flat)
    );

    FA_OACC_BUF_REAL u_oacc_buf (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .clear_req_valid(oacc_clear_valid),
        .clear_req_ready(oacc_clear_req_ready_w),
        .clear_done_pulse(oacc_clear_done_pulse_w),
        .load_valid(oacc_proxy_done_pulse),
        .load_ready(oacc_buf_load_ready),
        .tile_load_data(oacc_updated_tile_flat),
        .load_done_pulse(oacc_buf_load_done_pulse),
        .row_rd_en(1'b0),
        .row_rd_addr(4'd0),
        .row_rd_valid(),
        .row_rd_data(),
        .exp_rd_en(oacc_exp_rd_en),
        .exp_rd_addr(oacc_exp_rd_row),
        .exp_rd_valid(oacc_exp_rd_valid),
        .exp_rd_data(oacc_exp_rd_data),
        .tile_flat(oacc_tile_flat)
    );

    assign oacc_clear_ready = oacc_clear_req_ready_w;
    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            oacc_clear_done_pulse_r <= 1'b0;
        end else if (runtime_clear) begin
            oacc_clear_done_pulse_r <= 1'b0;
        end else begin
            oacc_clear_done_pulse_r <= oacc_clear_done_pulse_w;
        end
    end

    FA_QK_CORE_REAL u_qk_core (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .req_valid(qk_req_valid),
        .req_ready(qk_req_ready),
        .q_rd_en(q_qk_rd_en),
        .q_rd_addr(q_qk_rd_addr),
        .q_rd_valid(q_qk_rd_valid),
        .q_rd_data(q_qk_rd_data),
        .k_rd_en(k_qk_rd_en),
        .k_rd_addr(k_qk_rd_addr),
        .k_rd_valid(k_qk_rd_valid),
        .k_rd_data(k_qk_rd_data),
        .resp_valid(qk_resp_valid),
        .resp_ready(1'b1),
        .result_tile_flat(qk_result_tile_flat),
        .done_pulse(qk_done_pulse)
    );

    FA_SCORE_POST_PROXY #(
        .LATENCY(4)
    ) u_score_post (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .req_valid(score_req_valid),
        .req_ready(score_req_ready),
        .q_blk_idx(sched_q_blk_idx),
        .kv_blk_idx(sched_kv_blk_idx),
        .causal_en(csr_causal_en),
        .scale_word(csr_scale),
        .neg_large_word(csr_neg_large),
        .score_tile_flat(qk_result_tile_flat),
        .resp_valid(score_resp_valid),
        .resp_ready(1'b1),
        .masked_score_tile_flat(score_masked_tile_flat),
        .done_pulse(score_done_pulse)
    );

    FA_ROW_STATE_PROXY #(
        .LATENCY(2)
    ) u_row_state (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .init_valid(row_init_valid),
        .init_ready(row_init_ready),
        .init_done_pulse(row_init_done_pulse),
        .update_valid(row_update_valid),
        .update_ready(row_proxy_ready_w),
        .neg_large_word(csr_neg_large),
        .masked_score_tile_flat(score_masked_tile_flat),
        .resp_valid(row_resp_valid),
        .resp_ready(1'b1),
        .p_tile_flat(row_p_tile_flat),
        .rescale_vec_flat(row_rescale_vec_flat),
        .done_pulse(row_proxy_done_pulse)
    );

    assign row_update_ready = row_proxy_ready_w && p_buf_load_ready;
    assign row_update_done_pulse = p_buf_load_done_pulse;

    FA_PV_CORE_REAL u_pv_core (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .req_valid(pv_req_valid),
        .req_ready(pv_req_ready),
        .p_rd_en(p_pv_rd_en),
        .p_rd_addr(p_pv_rd_addr),
        .p_rd_valid(p_pv_rd_valid),
        .p_rd_data(p_pv_rd_data),
        .v_rd_en(v_pv_rd_en),
        .v_rd_addr(v_pv_rd_addr),
        .v_rd_valid(v_pv_rd_valid),
        .v_rd_data(v_pv_rd_data),
        .resp_valid(pv_resp_valid),
        .resp_ready(1'b1),
        .result_tile_flat(pv_result_tile_flat),
        .done_pulse(pv_done_pulse)
    );

    FA_OACC_UPDATE_PROXY #(
        .LATENCY(4)
    ) u_oacc_update (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .req_valid(oacc_update_valid),
        .req_ready(oacc_proxy_ready_w),
        .rescale_vec_flat(row_rescale_vec_flat),
        .old_oacc_tile_flat(oacc_tile_flat),
        .partial_o_tile_flat(pv_result_tile_flat),
        .resp_valid(oacc_resp_valid),
        .resp_ready(1'b1),
        .updated_oacc_tile_flat(oacc_updated_tile_flat),
        .done_pulse(oacc_proxy_done_pulse)
    );

    assign oacc_update_ready = oacc_proxy_ready_w && oacc_buf_load_ready;
    assign oacc_update_done_pulse = oacc_buf_load_done_pulse;

    FA_WR_DMA u_wr_dma (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .req_valid(store_req_valid),
        .req_ready(store_req_ready),
        .req_q_blk(sched_q_blk_idx),
        .o_base(csr_o_base),
        .stride_bytes(csr_stride_bytes),
        .oacc_exp_rd_en(oacc_exp_rd_en),
        .oacc_exp_rd_row(oacc_exp_rd_row),
        .oacc_exp_rd_valid(oacc_exp_rd_valid),
        .oacc_exp_rd_data(oacc_exp_rd_data),
        .wr_desc_valid(wr_desc_valid),
        .wr_desc_ready(wr_desc_ready),
        .wr_desc_addr(wr_desc_addr),
        .wr_desc_words(wr_desc_words),
        .wr_data_valid(wr_data_valid),
        .wr_data_ready(wr_data_ready),
        .wr_data(wr_data),
        .wr_data_last(wr_data_last),
        .done_pulse(store_done_pulse),
        .error_pulse()
    );

endmodule
