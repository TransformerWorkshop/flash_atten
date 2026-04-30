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

    reg [1:0] block_idx_r;
    reg       active_r;
    reg       issue_block_r;
    reg       resp_valid_r;
    reg       done_pulse_r;

    wire         real_req_ready_w;
    wire         real_done_pulse_w;
    wire         real_req_valid_w;
    wire [4095:0] partial_o_block_flat_w;
    wire         unused_params_w = (DATA_WIDTH == 0)
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

    assign req_ready = real_req_ready_w && !active_r && !resp_valid_r;
    assign real_req_valid_w = (req_valid && req_ready) || issue_block_r;
    assign partial_o_block_flat_w = partial_o_tile_flat[(block_idx_r * 4096) +: 4096];
    assign resp_valid = resp_valid_r;
    assign done_pulse = done_pulse_r;

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

            if (req_valid && req_ready) begin
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

    FA_OACC_UPDATE_REAL u_update (
        .clk(clk),
        .rstn(rstn),
        .clear(clear | (unused_params_w & 1'b0)),
        .req_valid(real_req_valid_w),
        .req_ready(real_req_ready_w),
        .rescale_vec_flat(rescale_vec_flat),
        .req_row_base({block_idx_r, 2'b00}),
        .partial_o_block_flat(partial_o_block_flat_w),
        .oacc_row_rd_en(oacc_row_rd_en),
        .oacc_row_rd_addr(oacc_row_rd_addr),
        .oacc_row_rd_valid(oacc_row_rd_valid),
        .oacc_row_rd_data(oacc_row_rd_data),
        .oacc_row_wr_en(oacc_row_wr_en),
        .oacc_row_wr_addr(oacc_row_wr_addr),
        .oacc_row_wr_data(oacc_row_wr_data),
        .done_pulse(real_done_pulse_w)
    );

endmodule
`endif
