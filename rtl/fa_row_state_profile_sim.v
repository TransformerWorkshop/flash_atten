`ifndef SYNTHESIS
module FA_ROW_STATE_PROFILE_SIM #(
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
    input  wire          init_valid,
    output wire          init_ready,
    output wire          init_done_pulse,
    input  wire          update_valid,
    output wire          update_ready,
    input  wire [31:0]   neg_large_word,
    input  wire [8191:0] masked_score_tile_flat,
    output wire          resp_valid,
    input  wire          resp_ready,
    output wire [4095:0] p_tile_flat,
    output wire [511:0]  rescale_vec_flat,
    output wire          done_pulse,
    output wire [511:0]  debug_m_state_flat,
    output wire [511:0]  debug_l_state_flat,
    output wire [15:0]   debug_row_seen
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

    FA_ROW_STATE_REAL u_row_state (
        .clk(clk),
        .rstn(rstn),
        .clear(clear | (unused_params_w & 1'b0)),
        .init_valid(init_valid),
        .init_ready(init_ready),
        .init_done_pulse(init_done_pulse),
        .update_valid(update_valid),
        .update_ready(update_ready),
        .neg_large_word(neg_large_word),
        .masked_score_tile_flat(masked_score_tile_flat),
        .update_row_base(4'd0),
        .masked_score_block_valid(64'd0),
        .masked_score_block_flat(2048'd0),
        .resp_valid(resp_valid),
        .resp_ready(resp_ready),
        .p_tile_flat(p_tile_flat),
        .rescale_vec_flat(rescale_vec_flat),
        .done_pulse(done_pulse),
        .debug_m_state_flat(debug_m_state_flat),
        .debug_l_state_flat(debug_l_state_flat),
        .debug_row_seen(debug_row_seen)
    );

endmodule
`endif
