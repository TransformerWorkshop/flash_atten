`ifndef SYNTHESIS
module FA_OACC_UPDATE_SIM #(
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
    input  wire           clk,
    input  wire           rstn,
    input  wire           clear,
    input  wire           req_valid,
    output wire           req_ready,
    input  wire [511:0]   rescale_vec_flat,
    input  wire [16383:0] partial_o_tile_flat,
    output wire           oacc_row_rd_en,
    output wire [3:0]     oacc_row_rd_addr,
    input  wire           oacc_row_rd_valid,
    input  wire [1023:0]  oacc_row_rd_data,
    output wire           oacc_row_wr_en,
    output wire [3:0]     oacc_row_wr_addr,
    output wire [1023:0]  oacc_row_wr_data,
    output wire           resp_valid,
    input  wire           resp_ready,
    output wire           done_pulse
);

    wire unused_partial_row_rd_en_w;
    wire [3:0] unused_partial_row_rd_addr_w;
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

    FA_OACC_UPDATE_REAL u_update (
        .clk(clk),
        .rstn(rstn),
        .clear(clear | (unused_params_w & 1'b0)),
        .req_valid(req_valid),
        .req_ready(req_ready),
        .rescale_vec_flat(rescale_vec_flat),
        .partial_o_tile_flat(partial_o_tile_flat),
        .partial_row_rd_en(unused_partial_row_rd_en_w),
        .partial_row_rd_addr(unused_partial_row_rd_addr_w),
        .partial_row_rd_valid(1'b0),
        .partial_row_rd_data(1024'd0),
        .oacc_row_rd_en(oacc_row_rd_en),
        .oacc_row_rd_addr(oacc_row_rd_addr),
        .oacc_row_rd_valid(oacc_row_rd_valid),
        .oacc_row_rd_data(oacc_row_rd_data),
        .oacc_row_wr_en(oacc_row_wr_en),
        .oacc_row_wr_addr(oacc_row_wr_addr),
        .oacc_row_wr_data(oacc_row_wr_data),
        .resp_valid(resp_valid),
        .resp_ready(resp_ready),
        .done_pulse(done_pulse)
    );

endmodule
`endif
