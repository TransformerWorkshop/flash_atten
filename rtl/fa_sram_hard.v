module FA_SRAM64X64 #(
    parameter integer DEPTH = 8,
    parameter integer ADDR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
    input  wire                  clk,
    input  wire                  en,
    input  wire                  we,
    input  wire [ADDR_WIDTH-1:0] addr,
    input  wire [63:0]           din,
    input  wire [63:0]           bweb,
    output reg  [63:0]           dout
);

`ifdef SYNTHESIS
    localparam integer MACRO_ADDR_W = 6;
    localparam USE_TSMC_64X32_PAIR = (DEPTH > 0) && (DEPTH <= 64) && (ADDR_WIDTH <= MACRO_ADDR_W);
    wire [63:0] macro_q;
    wire        macro_ceb = ~en;
    wire        macro_web = ~we;
    wire [63:0] macro_bweb = we ? bweb : {64{1'b1}};
    wire [MACRO_ADDR_W-1:0] macro_addr = {{(MACRO_ADDR_W-ADDR_WIDTH){1'b0}}, addr};
    wire unsupported_cfg_zero_w = (clk & 1'b0) | (en & 1'b0) | (we & 1'b0) | ((|addr) & 1'b0) | ((|din) & 1'b0) | ((|bweb) & 1'b0);

    generate
        if (USE_TSMC_64X32_PAIR) begin : gen_tsmc_sram
            TEM5N28HPCPLVTA64X32M4SWSO u_tsmc_sram_lo (
                .SLP (1'b0      ),
                .SD  (1'b0      ),
                .A   (macro_addr ),
                .D   (din[31:0]  ),
                .BWEB(macro_bweb[31:0]),
                .Q   (macro_q[31:0]),
                .WEB (macro_web  ),
                .CEB (macro_ceb  ),
                .CLK (clk        )
            );

            TEM5N28HPCPLVTA64X32M4SWSO u_tsmc_sram_hi (
                .SLP (1'b0      ),
                .SD  (1'b0      ),
                .A   (macro_addr ),
                .D   (din[63:32] ),
                .BWEB(macro_bweb[63:32]),
                .Q   (macro_q[63:32]),
                .WEB (macro_web  ),
                .CEB (macro_ceb  ),
                .CLK (clk        )
            );

            always @(*) begin
                if (en && !we) begin
                    dout = macro_q;
                end else begin
                    dout = 64'd0;
                end
            end
        end else begin : gen_unsup_cfg
            always @(*) begin
                dout = {64{unsupported_cfg_zero_w}};
            end
        end
    endgenerate
`endif

`ifndef SYNTHESIS
    reg [63:0] mem [0:DEPTH-1];
    integer bi;
    reg [63:0] merged_word_r;

    initial begin
        for (bi = 0; bi < DEPTH; bi = bi + 1) begin
            mem[bi] = 64'd0;
        end
        dout = 64'd0;
    end

    always @(posedge clk) begin
        if (en) begin
            if (we) begin
                merged_word_r = mem[addr];
                for (bi = 0; bi < 64; bi = bi + 1) begin
                    if (!bweb[bi]) begin
                        merged_word_r[bi] = din[bi];
                    end
                end
                mem[addr] <= merged_word_r;
                dout <= 64'd0;
            end else begin
                dout <= mem[addr];
            end
        end else begin
            dout <= 64'd0;
        end
    end
`endif

endmodule

module FA_SRAM256X64_1RW (
    input  wire        clk,
    input  wire        en,
    input  wire        we,
    input  wire [7:0]  addr,
    input  wire [63:0] din,
    input  wire [63:0] bweb,
    output reg  [63:0] dout
);

`ifdef SYNTHESIS
    wire [63:0] macro_q;
    wire        macro_ceb = ~en;
    wire        macro_web = ~we;
    wire [63:0] macro_bweb = we ? bweb : {64{1'b1}};

    TEM5N28HPCPLVTA256X64M4SWSO u_tsmc_sram (
        .SLP (1'b0       ),
        .SD  (1'b0       ),
        .A   (addr       ),
        .D   (din        ),
        .BWEB(macro_bweb ),
        .Q   (macro_q    ),
        .WEB (macro_web  ),
        .CEB (macro_ceb  ),
        .CLK (clk        )
    );

    always @(*) begin
        if (en && !we) begin
            dout = macro_q;
        end else begin
            dout = 64'd0;
        end
    end
`endif

`ifndef SYNTHESIS
    reg [63:0] mem [0:255];
    integer bi;
    reg [63:0] merged_word_r;

    initial begin
        for (bi = 0; bi < 256; bi = bi + 1) begin
            mem[bi] = 64'd0;
        end
        dout = 64'd0;
    end

    always @(posedge clk) begin
        if (en) begin
            if (we) begin
                merged_word_r = mem[addr];
                for (bi = 0; bi < 64; bi = bi + 1) begin
                    if (!bweb[bi]) begin
                        merged_word_r[bi] = din[bi];
                    end
                end
                mem[addr] <= merged_word_r;
                dout <= 64'd0;
            end else begin
                dout <= mem[addr];
            end
        end else begin
            dout <= 64'd0;
        end
    end
`endif

endmodule

module FA_SRAM256X32_1RW (
    input  wire        clk,
    input  wire        en,
    input  wire        we,
    input  wire [7:0]  addr,
    input  wire [31:0] din,
    input  wire [31:0] bweb,
    output reg  [31:0] dout
);

`ifdef SYNTHESIS
    wire [31:0] macro_q;
    wire        macro_ceb = ~en;
    wire        macro_web = ~we;
    wire [31:0] macro_bweb = we ? bweb : {32{1'b1}};

    TEM5N28HPCPLVTA256X32M4SWSO u_tsmc_sram (
        .SLP (1'b0       ),
        .SD  (1'b0       ),
        .A   (addr       ),
        .D   (din        ),
        .BWEB(macro_bweb ),
        .Q   (macro_q    ),
        .WEB (macro_web  ),
        .CEB (macro_ceb  ),
        .CLK (clk        )
    );

    always @(*) begin
        if (en && !we) begin
            dout = macro_q;
        end else begin
            dout = 32'd0;
        end
    end
`endif

`ifndef SYNTHESIS
    reg [31:0] mem [0:255];
    integer bi;
    reg [31:0] merged_word_r;

    initial begin
        for (bi = 0; bi < 256; bi = bi + 1) begin
            mem[bi] = 32'd0;
        end
        dout = 32'd0;
    end

    always @(posedge clk) begin
        if (en) begin
            if (we) begin
                merged_word_r = mem[addr];
                for (bi = 0; bi < 32; bi = bi + 1) begin
                    if (!bweb[bi]) begin
                        merged_word_r[bi] = din[bi];
                    end
                end
                mem[addr] <= merged_word_r;
                dout <= 32'd0;
            end else begin
                dout <= mem[addr];
            end
        end else begin
            dout <= 32'd0;
        end
    end
`endif

endmodule

module FA_SKY130_SRAM_256X64_1RW (
    input  wire        clk,
    input  wire        en,
    input  wire        we,
    input  wire [7:0]  addr,
    input  wire [63:0] din,
    input  wire [63:0] bweb,
    output wire [63:0] dout
);

    FA_SRAM256X64_1RW u_sram (
        .clk(clk),
        .en(en),
        .we(we),
        .addr(addr),
        .din(din),
        .bweb(bweb),
        .dout(dout)
    );

endmodule

module FA_SKY130_SRAM_256X32_1RW (
    input  wire        clk,
    input  wire        en,
    input  wire        we,
    input  wire [7:0]  addr,
    input  wire [31:0] din,
    input  wire [31:0] bweb,
    output wire [31:0] dout
);

    FA_SRAM256X32_1RW u_sram (
        .clk(clk),
        .en(en),
        .we(we),
        .addr(addr),
        .din(din),
        .bweb(bweb),
        .dout(dout)
    );

endmodule

module FA_MASKED_ROWBUF_REG_REAL #(
    parameter integer ROW_WIDTH = 512,
    parameter integer DEPTH = 16,
    parameter integer ADDR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter integer WRITE_GRANULARITY = 1
) (
    input  wire                  clk,
    input  wire                  wr_en,
    input  wire [ADDR_WIDTH-1:0] wr_addr,
    input  wire [ROW_WIDTH-1:0]  wr_data,
    input  wire [ROW_WIDTH-1:0]  wr_mask,
    input  wire                  rd_en,
    input  wire [ADDR_WIDTH-1:0] rd_addr,
    output wire [ROW_WIDTH-1:0]  rd_data
);

    reg [ROW_WIDTH-1:0] mem_r [0:DEPTH-1];
    reg [ROW_WIDTH-1:0] rd_data_r;
    integer bi;
    integer wi_chunk;
`ifndef SYNTHESIS
    integer wi;

    initial begin
        if ((WRITE_GRANULARITY < 1) || ((ROW_WIDTH % WRITE_GRANULARITY) != 0)) begin
            $fatal(1, "FA_MASKED_ROWBUF_REG_REAL ROW_WIDTH=%0d must be divisible by WRITE_GRANULARITY=%0d",
                   ROW_WIDTH, WRITE_GRANULARITY);
        end
        rd_data_r = {ROW_WIDTH{1'b0}};
        for (wi = 0; wi < DEPTH; wi = wi + 1) begin
            mem_r[wi] = {ROW_WIDTH{1'b0}};
        end
    end

    always @(posedge clk) begin
        if (wr_en && rd_en) begin
            $fatal(1, "FA_MASKED_ROWBUF_REG_REAL saw simultaneous read/write on single-port row buffer");
        end
        if (wr_en && (WRITE_GRANULARITY > 1)) begin
            for (wi = 0; wi < ROW_WIDTH; wi = wi + WRITE_GRANULARITY) begin
                if ((|wr_mask[wi +: WRITE_GRANULARITY]) &&
                    (wr_mask[wi +: WRITE_GRANULARITY] != {WRITE_GRANULARITY{1'b1}})) begin
                    $fatal(1, "FA_MASKED_ROWBUF_REG_REAL saw partial write mask inside a %0d-bit chunk at bit %0d",
                           WRITE_GRANULARITY, wi);
                end
            end
        end
    end
`endif

    assign rd_data = rd_data_r;

    always @(posedge clk) begin
        if (wr_en) begin
            if (WRITE_GRANULARITY == 1) begin
                for (bi = 0; bi < ROW_WIDTH; bi = bi + 1) begin
                    if (wr_mask[bi]) begin
                        mem_r[wr_addr][bi] <= wr_data[bi];
                    end
                end
            end else begin
                for (wi_chunk = 0; wi_chunk < ROW_WIDTH; wi_chunk = wi_chunk + WRITE_GRANULARITY) begin
                    if (|wr_mask[wi_chunk +: WRITE_GRANULARITY]) begin
                        mem_r[wr_addr][wi_chunk +: WRITE_GRANULARITY] <= wr_data[wi_chunk +: WRITE_GRANULARITY];
                    end
                end
            end
            rd_data_r <= {ROW_WIDTH{1'b0}};
        end else if (rd_en) begin
            rd_data_r <= mem_r[rd_addr];
        end else begin
            rd_data_r <= {ROW_WIDTH{1'b0}};
        end
    end

endmodule

module FA_MASKED_ROWBUF_REAL #(
    parameter integer ROW_WIDTH = 512,
    parameter integer DEPTH = 8,
    parameter integer ADDR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH),
    parameter integer CHUNK_COUNT = ROW_WIDTH / 64
) (
    input  wire                  clk,
    input  wire                  wr_en,
    input  wire [ADDR_WIDTH-1:0] wr_addr,
    input  wire [ROW_WIDTH-1:0]  wr_data,
    input  wire [ROW_WIDTH-1:0]  wr_mask,
    input  wire                  rd_en,
    input  wire [ADDR_WIDTH-1:0] rd_addr,
    output wire [ROW_WIDTH-1:0]  rd_data
);

// synthesis translate_off
`ifndef SYNTHESIS
    initial begin
        if ((ROW_WIDTH % 64) != 0) begin
            $fatal(1, "FA_MASKED_ROWBUF_REAL requires ROW_WIDTH to be a multiple of 64, got %0d", ROW_WIDTH);
        end
    end

    always @(posedge clk) begin
        if (wr_en && rd_en) begin
            $fatal(1, "FA_MASKED_ROWBUF_REAL saw simultaneous read/write on single-port SRAM");
        end
    end
`endif
// synthesis translate_on

    genvar gi;
    generate
        for (gi = 0; gi < CHUNK_COUNT; gi = gi + 1) begin : gen_chunk
            wire [63:0] chunk_rd_data_w;
            wire [63:0] chunk_wr_mask_w = wr_mask[(gi * 64) +: 64];
            wire        chunk_wr_en_w = wr_en && |chunk_wr_mask_w;
            wire        chunk_en_w = chunk_wr_en_w || rd_en;
            wire [ADDR_WIDTH-1:0] chunk_addr_w = chunk_wr_en_w ? wr_addr : rd_addr;

            FA_SRAM64X64 #(
                .DEPTH(DEPTH),
                .ADDR_WIDTH(ADDR_WIDTH)
            ) u_sram (
                .clk(clk),
                .en(chunk_en_w),
                .we(chunk_wr_en_w),
                .addr(chunk_addr_w),
                .din(wr_data[(gi * 64) +: 64]),
                .bweb(~chunk_wr_mask_w),
                .dout(chunk_rd_data_w)
            );

            assign rd_data[(gi * 64) +: 64] = chunk_rd_data_w;
        end
    endgenerate

endmodule
