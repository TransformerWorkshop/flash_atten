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
    output wire [8191:0] qk_result_tile_flat,
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
    output wire [16383:0] pv_result_tile_flat,
    output wire          pv_done_pulse
);

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
        .qk_resp_valid(qk_resp_valid),
        .qk_resp_ready(qk_resp_ready),
        .qk_result_tile_flat(qk_result_tile_flat),
        .qk_done_pulse(qk_done_pulse),
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
        .pv_resp_valid(pv_resp_valid),
        .pv_resp_ready(pv_resp_ready),
        .pv_result_tile_flat(pv_result_tile_flat),
        .pv_done_pulse(pv_done_pulse)
    );

endmodule
`endif
