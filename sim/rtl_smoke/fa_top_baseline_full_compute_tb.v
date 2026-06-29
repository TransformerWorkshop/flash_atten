`timescale 1ns/1ps

module fa_top_baseline_full_compute_tb;
    localparam integer SEQ_LEN = 256;
    localparam integer HEAD_DIM = 64;
    localparam integer WORDS_PER_ROW = HEAD_DIM / 2;
    localparam integer MATRIX_WORDS = SEQ_LEN * WORDS_PER_ROW;
    localparam [63:0] Q_BASE = 64'h0000_0000_0000_1000;
    localparam [63:0] K_BASE = 64'h0000_0000_0000_3000;
    localparam [63:0] V_BASE = 64'h0000_0000_0000_5000;
    localparam [63:0] O_BASE = 64'h0000_0000_0000_7000;
    localparam [31:0] STRIDE_BYTES = 32'd128;
    localparam [31:0] NEG_LARGE_Q16_16 = 32'hffc0_0000;
    localparam [31:0] SCALE_Q16_16 = 32'h0000_2000;
    localparam [31:0] Q88_ONE_PAIR = 32'h0100_0100;
    localparam integer Q88_ONE = 256;
    localparam integer Q88_TOL = 16;

    reg         clk;
    reg         rstn;
    reg         clear;
    reg [6:0]   s_axil_awaddr;
    reg         s_axil_awvalid;
    wire        s_axil_awready;
    reg [31:0]  s_axil_wdata;
    reg [3:0]   s_axil_wstrb;
    reg         s_axil_wvalid;
    wire        s_axil_wready;
    wire [1:0]  s_axil_bresp;
    wire        s_axil_bvalid;
    reg         s_axil_bready;
    reg [6:0]   s_axil_araddr;
    reg         s_axil_arvalid;
    wire        s_axil_arready;
    wire [31:0] s_axil_rdata;
    wire [1:0]  s_axil_rresp;
    wire        s_axil_rvalid;
    reg         s_axil_rready;
    wire        rd_desc_valid;
    reg         rd_desc_ready;
    wire [63:0] rd_desc_addr;
    wire [15:0] rd_desc_words;
    wire [3:0]  rd_desc_tag;
    reg         rd_beat_valid;
    wire        rd_beat_ready;
    reg [127:0] rd_beat_data;
    reg [2:0]   rd_beat_word_count;
    reg         rd_beat_last;
    wire        wr_desc_valid;
    reg         wr_desc_ready;
    wire [63:0] wr_desc_addr;
    wire [15:0] wr_desc_words;
    wire        wr_data_valid;
    reg         wr_data_ready;
    wire [31:0] wr_data;
    wire        wr_data_last;
    wire        irq;

    reg [31:0] q_mem [0:MATRIX_WORDS-1];
    reg [31:0] k_mem [0:MATRIX_WORDS-1];
    reg [31:0] v_mem [0:MATRIX_WORDS-1];
    reg [31:0] o_mem [0:MATRIX_WORDS-1];

    reg        rd_active_r;
    reg [63:0] rd_addr_r;
    reg [15:0] rd_words_r;
    reg [15:0] rd_sent_words_r;
    reg [3:0]  rd_tag_r;
    reg        wr_active_r;
    reg [63:0] wr_addr_r;
    reg [15:0] wr_words_r;
    reg [15:0] wr_recv_words_r;

    integer error_count;
    integer wait_count;
    integer word_idx;
    integer lane_idx;
    integer mismatch_count;
    integer read_index;
    integer write_index;
    integer beat_words;
    integer q88_lo;
    integer q88_hi;
    reg [31:0] read_data;
    reg [31:0] cycles_read;
    reg [31:0] rd_bytes_read;
    reg [31:0] wr_bytes_read;

    FA_TOP_BASELINE_SIM dut (
        .clk(clk),
        .rstn(rstn),
        .clear(clear),
        .s_axil_awaddr(s_axil_awaddr),
        .s_axil_awvalid(s_axil_awvalid),
        .s_axil_awready(s_axil_awready),
        .s_axil_wdata(s_axil_wdata),
        .s_axil_wstrb(s_axil_wstrb),
        .s_axil_wvalid(s_axil_wvalid),
        .s_axil_wready(s_axil_wready),
        .s_axil_bresp(s_axil_bresp),
        .s_axil_bvalid(s_axil_bvalid),
        .s_axil_bready(s_axil_bready),
        .s_axil_araddr(s_axil_araddr),
        .s_axil_arvalid(s_axil_arvalid),
        .s_axil_arready(s_axil_arready),
        .s_axil_rdata(s_axil_rdata),
        .s_axil_rresp(s_axil_rresp),
        .s_axil_rvalid(s_axil_rvalid),
        .s_axil_rready(s_axil_rready),
        .rd_desc_valid(rd_desc_valid),
        .rd_desc_ready(rd_desc_ready),
        .rd_desc_addr(rd_desc_addr),
        .rd_desc_words(rd_desc_words),
        .rd_desc_tag(rd_desc_tag),
        .rd_beat_valid(rd_beat_valid),
        .rd_beat_ready(rd_beat_ready),
        .rd_beat_data(rd_beat_data),
        .rd_beat_word_count(rd_beat_word_count),
        .rd_beat_last(rd_beat_last),
        .wr_desc_valid(wr_desc_valid),
        .wr_desc_ready(wr_desc_ready),
        .wr_desc_addr(wr_desc_addr),
        .wr_desc_words(wr_desc_words),
        .wr_data_valid(wr_data_valid),
        .wr_data_ready(wr_data_ready),
        .wr_data(wr_data),
        .wr_data_last(wr_data_last),
        .irq(irq)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function integer abs_int;
        input integer value;
        begin
            abs_int = (value < 0) ? -value : value;
        end
    endfunction

    function integer q88_signed;
        input [15:0] value;
        begin
            q88_signed = value[15] ? ({16'hffff, value}) : ({16'h0000, value});
        end
    endfunction

    function [31:0] read_matrix_word;
        input [3:0] tag;
        input [63:0] addr;
        reg [63:0] base;
        integer index;
        begin
            case (tag)
                4'h1: base = Q_BASE;
                4'h2: base = K_BASE;
                4'h3: base = V_BASE;
                default: base = Q_BASE;
            endcase
            index = (addr - base) >> 2;
            if ((index < 0) || (index >= MATRIX_WORDS)) begin
                read_matrix_word = 32'd0;
            end else if (tag == 4'h1) begin
                read_matrix_word = q_mem[index];
            end else if (tag == 4'h2) begin
                read_matrix_word = k_mem[index];
            end else begin
                read_matrix_word = v_mem[index];
            end
        end
    endfunction

    task tick;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task axil_write;
        input [6:0] addr;
        input [31:0] data;
        begin
            s_axil_awaddr = addr;
            s_axil_wdata = data;
            s_axil_wstrb = 4'hf;
            s_axil_awvalid = 1'b1;
            s_axil_wvalid = 1'b1;
            s_axil_bready = 1'b1;
            while (!(s_axil_awready && s_axil_wready)) begin
                tick();
            end
            tick();
            s_axil_awvalid = 1'b0;
            s_axil_wvalid = 1'b0;
            while (!s_axil_bvalid) begin
                tick();
            end
            if (s_axil_bresp !== 2'b00) begin
                $display("FAIL: AXI-Lite write addr=0x%0h bresp=%0d", addr, s_axil_bresp);
                error_count = error_count + 1;
            end
            tick();
            s_axil_bready = 1'b0;
        end
    endtask

    task axil_read;
        input [6:0] addr;
        output [31:0] data;
        begin
            s_axil_araddr = addr;
            s_axil_arvalid = 1'b1;
            s_axil_rready = 1'b1;
            while (!s_axil_arready) begin
                tick();
            end
            tick();
            s_axil_arvalid = 1'b0;
            while (!s_axil_rvalid) begin
                tick();
            end
            data = s_axil_rdata;
            if (s_axil_rresp !== 2'b00) begin
                $display("FAIL: AXI-Lite read addr=0x%0h rresp=%0d", addr, s_axil_rresp);
                error_count = error_count + 1;
            end
            tick();
            s_axil_rready = 1'b0;
        end
    endtask

    always @(*) begin
        rd_desc_ready = !rd_active_r;
        rd_beat_valid = rd_active_r;
        rd_beat_data = 128'd0;
        rd_beat_word_count = 3'd0;
        rd_beat_last = 1'b0;
        beat_words = 0;
        if (rd_active_r) begin
            beat_words = rd_words_r - rd_sent_words_r;
            if (beat_words > 4) begin
                beat_words = 4;
            end
            rd_beat_word_count = beat_words[2:0];
            rd_beat_last = ((rd_sent_words_r + beat_words[15:0]) >= rd_words_r);
            for (lane_idx = 0; lane_idx < 4; lane_idx = lane_idx + 1) begin
                if (lane_idx < beat_words) begin
                    rd_beat_data[(lane_idx * 32) +: 32] =
                        read_matrix_word(rd_tag_r, rd_addr_r + ((rd_sent_words_r + lane_idx) << 2));
                end
            end
        end
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            rd_active_r <= 1'b0;
            rd_addr_r <= 64'd0;
            rd_words_r <= 16'd0;
            rd_sent_words_r <= 16'd0;
            rd_tag_r <= 4'd0;
        end else begin
            if (!rd_active_r && rd_desc_valid && rd_desc_ready) begin
                rd_active_r <= 1'b1;
                rd_addr_r <= rd_desc_addr;
                rd_words_r <= rd_desc_words;
                rd_sent_words_r <= 16'd0;
                rd_tag_r <= rd_desc_tag;
            end else if (rd_active_r && rd_beat_valid && rd_beat_ready) begin
                rd_sent_words_r <= rd_sent_words_r + {13'd0, rd_beat_word_count};
                if (rd_beat_last) begin
                    rd_active_r <= 1'b0;
                end
            end
        end
    end

    always @(*) begin
        wr_desc_ready = !wr_active_r;
        wr_data_ready = 1'b1;
    end

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            wr_active_r <= 1'b0;
            wr_addr_r <= 64'd0;
            wr_words_r <= 16'd0;
            wr_recv_words_r <= 16'd0;
        end else begin
            if (!wr_active_r && wr_desc_valid && wr_desc_ready) begin
                wr_active_r <= 1'b1;
                wr_addr_r <= wr_desc_addr;
                wr_words_r <= wr_desc_words;
                wr_recv_words_r <= 16'd0;
            end else if (wr_active_r && wr_data_valid && wr_data_ready) begin
                write_index = ((wr_addr_r - O_BASE) >> 2) + wr_recv_words_r;
                if ((write_index >= 0) && (write_index < MATRIX_WORDS)) begin
                    o_mem[write_index] <= wr_data;
                end
                wr_recv_words_r <= wr_recv_words_r + 16'd1;
                if (wr_data_last) begin
                    wr_active_r <= 1'b0;
                end
            end
        end
    end

    initial begin
        error_count = 0;
        wait_count = 0;
        mismatch_count = 0;
        rstn = 1'b0;
        clear = 1'b0;
        s_axil_awaddr = 7'd0;
        s_axil_awvalid = 1'b0;
        s_axil_wdata = 32'd0;
        s_axil_wstrb = 4'd0;
        s_axil_wvalid = 1'b0;
        s_axil_bready = 1'b0;
        s_axil_araddr = 7'd0;
        s_axil_arvalid = 1'b0;
        s_axil_rready = 1'b0;

        for (word_idx = 0; word_idx < MATRIX_WORDS; word_idx = word_idx + 1) begin
            q_mem[word_idx] = 32'd0;
            k_mem[word_idx] = 32'd0;
            v_mem[word_idx] = Q88_ONE_PAIR;
            o_mem[word_idx] = 32'd0;
        end

        tick();
        tick();
        rstn = 1'b1;
        tick();

        axil_write(7'h14, Q_BASE[31:0]);
        axil_write(7'h18, Q_BASE[63:32]);
        axil_write(7'h1c, K_BASE[31:0]);
        axil_write(7'h20, K_BASE[63:32]);
        axil_write(7'h24, V_BASE[31:0]);
        axil_write(7'h28, V_BASE[63:32]);
        axil_write(7'h2c, O_BASE[31:0]);
        axil_write(7'h30, O_BASE[63:32]);
        axil_write(7'h34, STRIDE_BYTES);
        axil_write(7'h38, NEG_LARGE_Q16_16);
        axil_write(7'h3c, SCALE_Q16_16);
        axil_write(7'h08, 32'd0);
        axil_write(7'h00, 32'h0000_0004);
        axil_write(7'h00, 32'h0000_0005);
        axil_write(7'h00, 32'h0000_0004);

        while ((dut.status_done !== 1'b1) && (dut.status_error !== 1'b1) && (wait_count < 600000)) begin
            wait_count = wait_count + 1;
            tick();
        end
        repeat (16) tick();

        axil_read(7'h04, read_data);
        if (!read_data[1]) begin
            $display("FAIL: full compute did not finish, status=0x%08h wait_count=%0d", read_data, wait_count);
            error_count = error_count + 1;
        end
        if (read_data[2]) begin
            $display("FAIL: full compute status error set, status=0x%08h", read_data);
            error_count = error_count + 1;
        end

        axil_read(7'h40, cycles_read);
        if ((cycles_read == 32'd0) || (cycles_read > 32'd300000)) begin
            $display("FAIL: full compute cycles out of range: %0d", cycles_read);
            error_count = error_count + 1;
        end

        for (word_idx = 0; word_idx < MATRIX_WORDS; word_idx = word_idx + 1) begin
            q88_lo = q88_signed(o_mem[word_idx][15:0]);
            q88_hi = q88_signed(o_mem[word_idx][31:16]);
            if ((abs_int(q88_lo - Q88_ONE) > Q88_TOL) || (abs_int(q88_hi - Q88_ONE) > Q88_TOL)) begin
                if (mismatch_count < 8) begin
                    $display("FAIL: O word %0d expected about 0x0100_0100 got 0x%08h lo=%0d hi=%0d",
                             word_idx, o_mem[word_idx], q88_lo, q88_hi);
                end
                mismatch_count = mismatch_count + 1;
            end
        end
        if (mismatch_count != 0) begin
            $display("FAIL: full compute output mismatches=%0d", mismatch_count);
            error_count = error_count + 1;
        end

        axil_read(7'h44, rd_bytes_read);
        if (rd_bytes_read == 32'd0) begin
            $display("FAIL: rd_bytes did not increment");
            error_count = error_count + 1;
        end
        axil_read(7'h48, wr_bytes_read);
        if (wr_bytes_read == 32'd0) begin
            $display("FAIL: wr_bytes did not increment");
            error_count = error_count + 1;
        end

        if (error_count == 0) begin
            $display("PASS: fa_top_baseline_full_compute_tb shape=S256_D64_B1_H1 format=Q8.8 cycles=%0d rd_bytes=%0d wr_bytes=%0d",
                     cycles_read, rd_bytes_read, wr_bytes_read);
            $finish;
        end

        $display("FAIL: fa_top_baseline_full_compute_tb errors=%0d cycles=%0d rd_bytes=%0d wr_bytes=%0d",
                 error_count, cycles_read, rd_bytes_read, wr_bytes_read);
        $fatal(1);
    end
endmodule
