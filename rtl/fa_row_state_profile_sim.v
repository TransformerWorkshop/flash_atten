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
    //debug
    output wire [511:0]  debug_m_state_flat,
    output wire [511:0]  debug_l_state_flat,
    output wire [15:0]   debug_row_seen
);

    reg [1:0] block_idx_r;
    reg       active_r;
    reg       issue_block_r;
    reg       resp_valid_r;
    reg       done_pulse_r;

    wire          real_update_ready_w;
    wire          real_done_pulse_w;
    wire          real_update_valid_w;
    wire [2047:0] masked_score_block_flat_w;
    wire [63:0]   masked_score_block_valid_w;
    wire          unused_params_w = (DATA_WIDTH == 0)
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

    assign update_ready = real_update_ready_w && !active_r && !resp_valid_r;
    assign real_update_valid_w = (update_valid && update_ready) || issue_block_r;
    assign masked_score_block_flat_w = masked_score_tile_flat[(block_idx_r * 2048) +: 2048];
    assign resp_valid = resp_valid_r;
    assign done_pulse = done_pulse_r;

    generate
        genvar gi;
        for (gi = 0; gi < 64; gi = gi + 1) begin : gen_mask_valid
            assign masked_score_block_valid_w[gi] =
                (masked_score_block_flat_w[(gi * 32) +: 32] != neg_large_word);
        end
    endgenerate

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            block_idx_r <= 2'd0;
            active_r <= 1'b0;
            issue_block_r <= 1'b0;
            resp_valid_r <= 1'b0;
            done_pulse_r <= 1'b0;
        end else if (clear) begin
            block_idx_r <= 2'd0;
            active_r <= 1'b0;
            issue_block_r <= 1'b0;
            resp_valid_r <= 1'b0;
            done_pulse_r <= 1'b0;
        end else begin
            issue_block_r <= 1'b0;
            done_pulse_r <= 1'b0;

            if (update_valid && update_ready) begin
                block_idx_r <= 2'd0;
                active_r <= 1'b1;
            end

            if (real_done_pulse_w && active_r) begin
                if (block_idx_r == 2'd3) begin
                    active_r <= 1'b0;
                    resp_valid_r <= 1'b1;
                end else begin
                    block_idx_r <= block_idx_r + 1'b1;
                    issue_block_r <= 1'b1;
                end
            end

            if (resp_valid_r && resp_ready) begin
                resp_valid_r <= 1'b0;
                done_pulse_r <= 1'b1;
            end
        end
    end

    FA_ROW_STATE_REAL u_row_state (
        .clk(clk),
        .rstn(rstn),
        .clear(clear | (unused_params_w & 1'b0)),
        .init_valid(init_valid),
        .init_ready(init_ready),
        .init_done_pulse(init_done_pulse),
        .update_valid(real_update_valid_w),
        .update_ready(real_update_ready_w),
        .neg_large_word(neg_large_word),
        .update_row_base({block_idx_r, 2'b00}),
        .masked_score_block_valid(masked_score_block_valid_w),
        .masked_score_block_flat(masked_score_block_flat_w),
        .p_tile_flat(p_tile_flat),
        .rescale_vec_flat(rescale_vec_flat),
        .done_pulse(real_done_pulse_w),
        //debug
        .debug_m_state_flat(debug_m_state_flat),
        .debug_l_state_flat(debug_l_state_flat),
        .debug_row_seen(debug_row_seen)
    );

endmodule
`endif
