module FA_CORE_BASELINE #(
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
    input  wire         start_pulse,
    input  wire         soft_reset_pulse,
    input  wire         irq_en,
    input  wire         causal_en,
    input  wire [63:0]  q_base,
    input  wire [63:0]  k_base,
    input  wire [63:0]  v_base,
    input  wire [63:0]  o_base,
    input  wire [31:0]  stride_bytes,
    input  wire [31:0]  neg_large,
    input  wire [31:0]  scale,
    input  wire         ext_error_pulse,
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
    output wire         busy,
    output wire         done,
    output wire         error,
    output wire [31:0]  cycles,
    output wire [31:0]  rd_bytes,
    output wire [31:0]  wr_bytes,
    output wire         irq,
    output wire [16383:0] q_tile_flat,
    output wire [16383:0] k_tile_flat,
    output wire [16383:0] v_tile_flat,
    output wire [16383:0] v_pv_layout_flat,
    output wire [4095:0]  p_tile_flat,
    output wire [16383:0] oacc_tile_flat,
    output wire [8191:0]  qk_result_tile_flat,
    output wire [8191:0]  score_masked_tile_flat,
    output wire [16383:0] pv_result_tile_flat,
    output wire [511:0]   row_debug_m_state_flat,
    output wire [511:0]   row_debug_l_state_flat,
    output wire [15:0]    row_debug_seen_flat,
    output wire           debug_store_req_valid,
    output wire           debug_store_done_pulse
);

    localparam [1:0] LOAD_KIND_Q = 2'd0;
    localparam [1:0] LOAD_KIND_K = 2'd1;
    localparam [1:0] LOAD_KIND_V = 2'd2;
    localparam [16383:0] ZERO_TILE_16X64 = {16384{1'b0}};

    wire        run_active;
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

    wire         score_resp_valid;
    wire         row_resp_valid;
    wire [4095:0] row_p_tile_flat;
    wire [511:0] row_rescale_vec_flat;
    wire         row_proxy_ready_w;
    wire         pv_resp_valid;
    wire         oacc_real_ready_w;
    wire         p_buf_load_ready;
    wire         p_buf_load_done_pulse;
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
    wire         oacc_real_done_pulse;
    wire         oacc_row_rd_en;
    wire [3:0]   oacc_row_rd_addr;
    wire         oacc_row_rd_valid;
    wire [1023:0] oacc_row_rd_data;
    wire         oacc_row_wr_en;
    wire [3:0]   oacc_row_wr_addr;
    wire [1023:0] oacc_row_wr_data;
    reg [31:0]   rd_bytes_r;
    reg [31:0]   wr_bytes_r;

    wire runtime_clear = clear || soft_reset_pulse;

    assign busy = run_active;
    assign done = status_done;
    assign error = status_error;
    assign cycles = status_cycles;
    assign rd_bytes = rd_bytes_r;
    assign wr_bytes = wr_bytes_r;
    assign irq = irq_en && (status_done || status_error);
    assign debug_store_req_valid = store_req_valid;
    assign debug_store_done_pulse = store_done_pulse;

    FA_RUN_CTRL u_run_ctrl (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .start_pulse(start_pulse),
        .soft_reset_pulse(soft_reset_pulse),
        .run_complete_pulse(run_complete_pulse),
        .run_error_pulse(rd_error_pulse | ext_error_pulse),
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
        .run_start_pulse(start_pulse),
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
        .q_base(q_base),
        .k_base(k_base),
        .v_base(v_base),
        .stride_bytes(stride_bytes),
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
        .load_valid(1'b0),
        .load_ready(),
        .tile_load_data(ZERO_TILE_16X64),
        .load_done_pulse(),
        .row_rd_en(oacc_row_rd_en),
        .row_rd_addr(oacc_row_rd_addr),
        .row_rd_valid(oacc_row_rd_valid),
        .row_rd_data(oacc_row_rd_data),
        .row_wr_en(oacc_row_wr_en),
        .row_wr_addr(oacc_row_wr_addr),
        .row_wr_data(oacc_row_wr_data),
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

    FA_SCORE_POST_REAL u_score_post (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .req_valid(score_req_valid),
        .req_ready(score_req_ready),
        .q_blk_idx(sched_q_blk_idx),
        .kv_blk_idx(sched_kv_blk_idx),
        .causal_en(causal_en),
        .scale_word(scale),
        .neg_large_word(neg_large),
        .score_tile_flat(qk_result_tile_flat),
        .resp_valid(score_resp_valid),
        .resp_ready(1'b1),
        .masked_score_tile_flat(score_masked_tile_flat),
        .done_pulse(score_done_pulse)
    );

    FA_ROW_STATE_REAL u_row_state (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .init_valid(row_init_valid),
        .init_ready(row_init_ready),
        .init_done_pulse(row_init_done_pulse),
        .update_valid(row_update_valid),
        .update_ready(row_proxy_ready_w),
        .neg_large_word(neg_large),
        .masked_score_tile_flat(score_masked_tile_flat),
        .resp_valid(row_resp_valid),
        .resp_ready(1'b1),
        .p_tile_flat(row_p_tile_flat),
        .rescale_vec_flat(row_rescale_vec_flat),
        .done_pulse(row_proxy_done_pulse),
        .debug_m_state_flat(row_debug_m_state_flat),
        .debug_l_state_flat(row_debug_l_state_flat),
        .debug_row_seen(row_debug_seen_flat)
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

    FA_OACC_UPDATE_REAL u_oacc_update (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .req_valid(oacc_update_valid),
        .req_ready(oacc_real_ready_w),
        .rescale_vec_flat(row_rescale_vec_flat),
        .partial_o_tile_flat(pv_result_tile_flat),
        .oacc_row_rd_en(oacc_row_rd_en),
        .oacc_row_rd_addr(oacc_row_rd_addr),
        .oacc_row_rd_valid(oacc_row_rd_valid),
        .oacc_row_rd_data(oacc_row_rd_data),
        .oacc_row_wr_en(oacc_row_wr_en),
        .oacc_row_wr_addr(oacc_row_wr_addr),
        .oacc_row_wr_data(oacc_row_wr_data),
        .resp_valid(),
        .resp_ready(1'b1),
        .done_pulse(oacc_real_done_pulse)
    );

    assign oacc_update_ready = oacc_real_ready_w;
    assign oacc_update_done_pulse = oacc_real_done_pulse;

    FA_WR_DMA u_wr_dma (
        .clk(clk),
        .rstn(rstn),
        .clear(runtime_clear),
        .req_valid(store_req_valid),
        .req_ready(store_req_ready),
        .req_q_blk(sched_q_blk_idx),
        .o_base(o_base),
        .stride_bytes(stride_bytes),
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

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rd_bytes_r <= 32'd0;
            wr_bytes_r <= 32'd0;
        end else if (clear || soft_reset_pulse || start_pulse) begin
            rd_bytes_r <= 32'd0;
            wr_bytes_r <= 32'd0;
        end else begin
            if (rd_data_valid && rd_data_ready) begin
                rd_bytes_r <= rd_bytes_r + 32'd4;
            end
            if (wr_data_valid && wr_data_ready) begin
                wr_bytes_r <= wr_bytes_r + 32'd4;
            end
        end
    end

endmodule
