module FA_LOCAL_TILE_SRAM_16X64X16 (
    input  wire        clk,
    input  wire        rstn,
    input  wire        clear,
    input  wire        wr_en,
    input  wire [3:0]  wr_row_idx,
    input  wire [3:0]  wr_chunk_idx,
    input  wire [63:0] wr_data,
    input  wire [63:0] wr_mask,
    input  wire        rd_en,
    input  wire [3:0]  rd_row_idx,
    input  wire [3:0]  rd_chunk_idx,
    output reg         rd_valid,
    output wire [63:0] rd_data
);

    wire [7:0] wr_addr_w = {wr_row_idx, wr_chunk_idx};
    wire [7:0] rd_addr_w = {rd_row_idx, rd_chunk_idx};
    wire       sram_wr_en_w = wr_en && |wr_mask;
    wire       sram_en_w = sram_wr_en_w || rd_en;
    wire [7:0] sram_addr_w = sram_wr_en_w ? wr_addr_w : rd_addr_w;

    FA_SKY130_SRAM_256X64_1RW u_sram (
        .clk(clk),
        .en(sram_en_w),
        .we(sram_wr_en_w),
        .addr(sram_addr_w),
        .din(wr_data),
        .bweb(~wr_mask),
        .dout(rd_data)
    );

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (wr_en && rd_en) begin
            $fatal(1, "FA_LOCAL_TILE_SRAM_16X64X16 saw simultaneous read/write on single 1RW macro");
        end
    end
`endif

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rd_valid <= 1'b0;
        end else if (clear) begin
            rd_valid <= 1'b0;
        end else begin
            rd_valid <= rd_en;
        end
    end

endmodule
