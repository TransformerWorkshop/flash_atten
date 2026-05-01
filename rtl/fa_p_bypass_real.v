module FA_P_BYPASS_REAL #(
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
    input  wire [4095:0] row_p_tile_flat,
    input  wire          rd_en,
    input  wire [2:0]    rd_addr,
    output reg           rd_valid,
    output reg  [511:0]  rd_data
);

    integer row_i;
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

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rd_valid <= 1'b0;
            rd_data <= 512'd0;
        end else if (clear | (unused_params_w & 1'b0)) begin
            rd_valid <= 1'b0;
            rd_data <= 512'd0;
        end else begin
            rd_valid <= rd_en;
            if (rd_en) begin
                for (row_i = 0; row_i < 16; row_i = row_i + 1) begin
                    rd_data[(row_i * 32) +: 32] <=
                        row_p_tile_flat[(((row_i * 8) + {29'd0, rd_addr}) * 32) +: 32];
                end
            end
        end
    end

endmodule
