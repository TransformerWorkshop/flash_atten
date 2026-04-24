module FA_WORD_TILE_BUF #(
    parameter integer WORDS_PER_TILE = 512,
    parameter integer ADDR_W = (WORDS_PER_TILE <= 1) ? 1 : $clog2(WORDS_PER_TILE)
) (
    input  wire                              clk,
    input  wire                              rstn,
    input  wire                              clear,
    input  wire                              word_write_valid,
    input  wire [ADDR_W-1:0]                 word_write_addr,
    input  wire [31:0]                       word_write_data,
    input  wire                              tile_replace_valid,
    input  wire [WORDS_PER_TILE*32-1:0]      tile_replace_data,
    output wire [WORDS_PER_TILE*32-1:0]      tile_flat
);

    wire [31:0] unused_rd_data;
    reg  [31:0] shadow_mem [0:WORDS_PER_TILE-1];
    integer wi;

    PT_MEM_BANK #(
        .DATA_WIDTH(32),
        .LANES(1),
        .DEPTH(WORDS_PER_TILE)
    ) u_mem (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .wr_en(word_write_valid),
        .wr_buf(1'b0),
        .wr_mask(1'b1),
        .wr_addr(word_write_addr),
        .wr_data(word_write_data),
        .rd_en(1'b0),
        .rd_buf(1'b0),
        .rd_addr({ADDR_W{1'b0}}),
        .rd_data(unused_rd_data)
    );

    genvar gi;
    generate
        for (gi = 0; gi < WORDS_PER_TILE; gi = gi + 1) begin : gen_tile_flat
            assign tile_flat[(gi * 32) +: 32] = shadow_mem[gi];
        end
    endgenerate

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (wi = 0; wi < WORDS_PER_TILE; wi = wi + 1) begin
                shadow_mem[wi] <= 32'd0;
            end
        end else if (clear) begin
            for (wi = 0; wi < WORDS_PER_TILE; wi = wi + 1) begin
                shadow_mem[wi] <= 32'd0;
            end
        end else begin
            if (tile_replace_valid) begin
                for (wi = 0; wi < WORDS_PER_TILE; wi = wi + 1) begin
                    shadow_mem[wi] <= tile_replace_data[(wi * 32) +: 32];
                end
            end else if (word_write_valid) begin
                shadow_mem[word_write_addr] <= word_write_data;
            end
        end
    end

endmodule

module FA_WORD_TILE_BUF_M #(
    parameter integer WORDS_PER_TILE = 512,
    parameter integer ADDR_W = (WORDS_PER_TILE <= 1) ? 1 : $clog2(WORDS_PER_TILE)
) (
    input  wire                              clk,
    input  wire                              rstn,
    input  wire                              clear,
    input  wire                              tile_replace_valid,
    input  wire [WORDS_PER_TILE*32-1:0]      tile_replace_data,
    output wire [WORDS_PER_TILE*32-1:0]      tile_flat
);

    wire [31:0] unused_rd_b_data;
    wire [31:0] unused_rd_exp_data;
    reg  [31:0] shadow_mem [0:WORDS_PER_TILE-1];
    integer wi;

    PT_M_MEM #(
        .DATA_WIDTH(32),
        .B_LANES(1),
        .DEPTH(WORDS_PER_TILE),
        .M_PHYSICAL_COPIES(2)
    ) u_mem (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .wr_en(1'b0),
        .wr_buf(1'b0),
        .wr_mask(1'b0),
        .wr_addr({ADDR_W{1'b0}}),
        .wr_data(32'd0),
        .rd_b_en(1'b0),
        .rd_b_buf(1'b0),
        .rd_b_addr({ADDR_W{1'b0}}),
        .rd_b_data(unused_rd_b_data),
        .rd_exp_en(1'b0),
        .rd_exp_buf(1'b0),
        .rd_exp_addr({ADDR_W{1'b0}}),
        .rd_exp_data(unused_rd_exp_data)
    );

    genvar gi;
    generate
        for (gi = 0; gi < WORDS_PER_TILE; gi = gi + 1) begin : gen_tile_flat
            assign tile_flat[(gi * 32) +: 32] = shadow_mem[gi];
        end
    endgenerate

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            for (wi = 0; wi < WORDS_PER_TILE; wi = wi + 1) begin
                shadow_mem[wi] <= 32'd0;
            end
        end else if (clear) begin
            for (wi = 0; wi < WORDS_PER_TILE; wi = wi + 1) begin
                shadow_mem[wi] <= 32'd0;
            end
        end else if (tile_replace_valid) begin
            for (wi = 0; wi < WORDS_PER_TILE; wi = wi + 1) begin
                shadow_mem[wi] <= tile_replace_data[(wi * 32) +: 32];
            end
        end
    end

endmodule

module Q_BUF (
    input  wire                 clk,
    input  wire                 rstn,
    input  wire                 clear,
    input  wire                 word_write_valid,
    input  wire [8:0]           word_write_addr,
    input  wire [31:0]          word_write_data,
    output wire [16383:0]       tile_flat
);
    FA_WORD_TILE_BUF #(
        .WORDS_PER_TILE(512),
        .ADDR_W(9)
    ) u_buf (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .word_write_valid(word_write_valid),
        .word_write_addr(word_write_addr),
        .word_write_data(word_write_data),
        .tile_replace_valid(1'b0),
        .tile_replace_data({512*32{1'b0}}),
        .tile_flat(tile_flat)
    );
endmodule

module K_BUF (
    input  wire                 clk,
    input  wire                 rstn,
    input  wire                 clear,
    input  wire                 word_write_valid,
    input  wire [8:0]           word_write_addr,
    input  wire [31:0]          word_write_data,
    output wire [16383:0]       tile_flat
);
    FA_WORD_TILE_BUF #(
        .WORDS_PER_TILE(512),
        .ADDR_W(9)
    ) u_buf (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .word_write_valid(word_write_valid),
        .word_write_addr(word_write_addr),
        .word_write_data(word_write_data),
        .tile_replace_valid(1'b0),
        .tile_replace_data({512*32{1'b0}}),
        .tile_flat(tile_flat)
    );
endmodule

module V_BUF (
    input  wire                 clk,
    input  wire                 rstn,
    input  wire                 clear,
    input  wire                 word_write_valid,
    input  wire [8:0]           word_write_addr,
    input  wire [31:0]          word_write_data,
    output wire [16383:0]       tile_flat
);
    FA_WORD_TILE_BUF #(
        .WORDS_PER_TILE(512),
        .ADDR_W(9)
    ) u_buf (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .word_write_valid(word_write_valid),
        .word_write_addr(word_write_addr),
        .word_write_data(word_write_data),
        .tile_replace_valid(1'b0),
        .tile_replace_data({512*32{1'b0}}),
        .tile_flat(tile_flat)
    );
endmodule

module P_BUF (
    input  wire                 clk,
    input  wire                 rstn,
    input  wire                 clear,
    input  wire                 tile_replace_valid,
    input  wire [4095:0]        tile_replace_data,
    output wire [4095:0]        tile_flat
);
    FA_WORD_TILE_BUF #(
        .WORDS_PER_TILE(128),
        .ADDR_W(7)
    ) u_buf (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .word_write_valid(1'b0),
        .word_write_addr(7'd0),
        .word_write_data(32'd0),
        .tile_replace_valid(tile_replace_valid),
        .tile_replace_data(tile_replace_data),
        .tile_flat(tile_flat)
    );
endmodule

module OACC_BUF (
    input  wire                 clk,
    input  wire                 rstn,
    input  wire                 clear,
    input  wire                 tile_replace_valid,
    input  wire [16383:0]       tile_replace_data,
    output wire [16383:0]       tile_flat
);
    FA_WORD_TILE_BUF_M #(
        .WORDS_PER_TILE(512),
        .ADDR_W(9)
    ) u_buf (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .tile_replace_valid(tile_replace_valid),
        .tile_replace_data(tile_replace_data),
        .tile_flat(tile_flat)
    );
endmodule
