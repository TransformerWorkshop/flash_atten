`ifndef SYNTHESIS
module FA_QK_PV_SHARED_CORE_SIM #(
    parameter integer DATA_WIDTH = 32,
    parameter integer GEMM_X_DIM = 16,
    parameter integer GEMM_Y_DIM = 16,
    parameter integer EXT_ADDR_W = 32,
    parameter integer DMA_BEATS_W = 16,
    parameter integer LUT_DEPTH = 8,
    parameter integer A_BANK_DEPTH = 16,
    parameter integer B_BANK_DEPTH = 16,
    parameter integer M_BANK_DEPTH = 16,
    parameter integer A_LOAD_LANES = 1,
    parameter integer B_LOAD_LANES = 1,
    parameter integer M_WRITE_LANES = 1,
    parameter integer M_EXPORT_LANES = 1,
    parameter integer M_PHYSICAL_COPIES = 3
) (
    input  wire          clk,
    input  wire          rstn,
    input  wire          clear,
    input  wire          qk_req_valid,
    output wire          qk_req_ready,
    output wire          q_rd_en,
    output wire [4:0]    q_rd_addr,
    input  wire          q_rd_valid,
    input  wire [511:0]  q_rd_data,
    output wire          k_rd_en,
    output wire [4:0]    k_rd_addr,
    input  wire          k_rd_valid,
    input  wire [511:0]  k_rd_data,
    output wire          qk_resp_valid,
    input  wire          qk_resp_ready,
    output wire          qk_done_pulse,
    input  wire          pv_req_valid,
    output wire          pv_req_ready,
    output wire          p_rd_en,
    output wire [2:0]    p_rd_addr,
    input  wire          p_rd_valid,
    input  wire [511:0]  p_rd_data,
    output wire          v_rd_en,
    output wire [4:0]    v_rd_addr,
    input  wire          v_rd_valid,
    input  wire [511:0]  v_rd_data,
    output wire          pv_resp_valid,
    input  wire          pv_resp_ready,
    output wire          pv_done_pulse,
    //debug
    output wire [8191:0] qk_result_tile_flat,
    output wire [16383:0] pv_result_tile_flat
);

    wire unused_qk_block_valid_w;
    wire [3:0] unused_qk_block_row_base_w;
    wire [2047:0] unused_qk_block_data_w;
    wire unused_pv_block_valid_w;
    wire [3:0] unused_pv_block_row_base_w;
    wire [4095:0] unused_pv_block_data_w;
    wire qk_done_pulse_w;
    wire pv_done_pulse_w;
    reg  qk_resp_valid_r;
    reg  pv_resp_valid_r;
    reg  qk_done_pulse_r;
    reg  pv_done_pulse_r;
    wire unused_params_w = (DATA_WIDTH == 0)
                         | (GEMM_X_DIM == 0)
                         | (GEMM_Y_DIM == 0)
                         | (EXT_ADDR_W == 0)
                         | (DMA_BEATS_W == 0)
                         | (LUT_DEPTH == 0)
                         | (A_BANK_DEPTH == 0)
                         | (B_BANK_DEPTH == 0)
                         | (M_BANK_DEPTH == 0)
                         | (A_LOAD_LANES == 0)
                         | (B_LOAD_LANES == 0)
                         | (M_WRITE_LANES == 0)
	                         | (M_EXPORT_LANES == 0)
	                         | (M_PHYSICAL_COPIES == 0);

    assign qk_done_pulse = qk_done_pulse_r;
    assign pv_done_pulse = pv_done_pulse_r;
    assign qk_resp_valid = qk_resp_valid_r;
    assign pv_resp_valid = pv_resp_valid_r;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            qk_resp_valid_r <= 1'b0;
            pv_resp_valid_r <= 1'b0;
            qk_done_pulse_r <= 1'b0;
            pv_done_pulse_r <= 1'b0;
        end else if (clear) begin
            qk_resp_valid_r <= 1'b0;
            pv_resp_valid_r <= 1'b0;
            qk_done_pulse_r <= 1'b0;
            pv_done_pulse_r <= 1'b0;
        end else begin
            qk_done_pulse_r <= 1'b0;
            pv_done_pulse_r <= 1'b0;
            if (qk_resp_valid_r && qk_resp_ready) begin
                qk_resp_valid_r <= 1'b0;
                qk_done_pulse_r <= 1'b1;
            end
            if (pv_resp_valid_r && pv_resp_ready) begin
                pv_resp_valid_r <= 1'b0;
                pv_done_pulse_r <= 1'b1;
            end
            if (qk_done_pulse_w) begin
                qk_resp_valid_r <= 1'b1;
            end
            if (pv_done_pulse_w) begin
                pv_resp_valid_r <= 1'b1;
            end
        end
    end

    FA_QK_PV_SHARED_CORE_REAL u_core (
        .clk(clk),
        .rstn(rstn),
        .clear(clear | (unused_params_w & 1'b0)),
        .qk_req_valid(qk_req_valid),
        .qk_req_ready(qk_req_ready),
        .q_rd_en(q_rd_en),
        .q_rd_addr(q_rd_addr),
        .q_rd_valid(q_rd_valid),
        .q_rd_data(q_rd_data),
        .k_rd_en(k_rd_en),
        .k_rd_addr(k_rd_addr),
        .k_rd_valid(k_rd_valid),
        .k_rd_data(k_rd_data),
        .qk_block_valid(unused_qk_block_valid_w),
        .qk_block_ready(1'b1),
        .qk_block_row_base(unused_qk_block_row_base_w),
        .qk_block_data(unused_qk_block_data_w),
        .qk_done_pulse(qk_done_pulse_w),
        .pv_req_valid(pv_req_valid),
        .pv_req_ready(pv_req_ready),
        .p_rd_en(p_rd_en),
        .p_rd_addr(p_rd_addr),
        .p_rd_valid(p_rd_valid),
        .p_rd_data(p_rd_data),
        .v_rd_en(v_rd_en),
        .v_rd_addr(v_rd_addr),
        .v_rd_valid(v_rd_valid),
        .v_rd_data(v_rd_data),
        .pv_block_valid(unused_pv_block_valid_w),
        .pv_block_ready(1'b1),
        .pv_block_row_base(unused_pv_block_row_base_w),
        .pv_block_data(unused_pv_block_data_w),
        .pv_done_pulse(pv_done_pulse_w),
        //debug
        .qk_result_tile_flat(qk_result_tile_flat),
        .pv_result_tile_flat(pv_result_tile_flat)
    );

endmodule
`endif
