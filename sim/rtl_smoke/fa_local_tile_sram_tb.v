`timescale 1ns/1ps

module fa_local_tile_sram_tb;
    reg         clk;
    reg         rstn;
    reg         clear;
    reg         wr_en;
    reg  [3:0]  wr_row_idx;
    reg  [3:0]  wr_chunk_idx;
    reg  [63:0] wr_data;
    reg  [63:0] wr_mask;
    reg         rd_en;
    reg  [3:0]  rd_row_idx;
    reg  [3:0]  rd_chunk_idx;
    wire        rd_valid;
    wire [63:0] rd_data;

    integer error_count;

    FA_LOCAL_TILE_SRAM_16X64X16 dut (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .wr_en(wr_en),
        .wr_row_idx(wr_row_idx),
        .wr_chunk_idx(wr_chunk_idx),
        .wr_data(wr_data),
        .wr_mask(wr_mask),
        .rd_en(rd_en),
        .rd_row_idx(rd_row_idx),
        .rd_chunk_idx(rd_chunk_idx),
        .rd_valid(rd_valid),
        .rd_data(rd_data)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task expect_word;
        input [63:0] expected;
        begin
            if (rd_valid !== 1'b1) begin
                $display("FAIL: rd_valid expected 1, got %b at %0t", rd_valid, $time);
                error_count = error_count + 1;
            end
            if (rd_data !== expected) begin
                $display("FAIL: rd_data expected 0x%016h, got 0x%016h at %0t", expected, rd_data, $time);
                error_count = error_count + 1;
            end
        end
    endtask

    initial begin
        error_count = 0;
        rstn = 1'b0;
        clear = 1'b0;
        wr_en = 1'b0;
        wr_row_idx = 4'd0;
        wr_chunk_idx = 4'd0;
        wr_data = 64'd0;
        wr_mask = 64'd0;
        rd_en = 1'b0;
        rd_row_idx = 4'd0;
        rd_chunk_idx = 4'd0;

        tick();
        tick();
        rstn = 1'b1;
        tick();

        wr_row_idx = 4'd3;
        wr_chunk_idx = 4'd5;
        wr_data = 64'h1122_3344_5566_7788;
        wr_mask = 64'hffff_ffff_ffff_ffff;
        wr_en = 1'b1;
        tick();
        wr_en = 1'b0;
        wr_mask = 64'd0;
        wr_data = 64'd0;
        tick();

        rd_row_idx = 4'd3;
        rd_chunk_idx = 4'd5;
        rd_en = 1'b1;
        tick();
        rd_en = 1'b0;
        expect_word(64'h1122_3344_5566_7788);
        tick();

        wr_row_idx = 4'd3;
        wr_chunk_idx = 4'd5;
        wr_data = 64'hdead_beef_cafe_babe;
        wr_mask = 64'h0000_0000_ffff_ffff;
        wr_en = 1'b1;
        tick();
        wr_en = 1'b0;
        wr_mask = 64'd0;
        wr_data = 64'd0;
        tick();

        rd_row_idx = 4'd3;
        rd_chunk_idx = 4'd5;
        rd_en = 1'b1;
        tick();
        rd_en = 1'b0;
        expect_word(64'h1122_3344_cafe_babe);

        clear = 1'b1;
        tick();
        clear = 1'b0;
        if (rd_valid !== 1'b0) begin
            $display("FAIL: clear should drop rd_valid, got %b at %0t", rd_valid, $time);
            error_count = error_count + 1;
        end

        if (error_count == 0) begin
            $display("PASS: fa_local_tile_sram_tb");
            $finish;
        end
        $display("FAIL: fa_local_tile_sram_tb errors=%0d", error_count);
        $fatal(1);
    end
endmodule
