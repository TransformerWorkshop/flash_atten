`timescale 1ns/1ps

module fa_top_optim_windowed_tb;
    localparam [63:0] Q_BASE = 64'h0000_1000;
    localparam [63:0] K_BASE = 64'h0001_0000;
    localparam [63:0] V_BASE = 64'h0002_0000;
    localparam [63:0] O_BASE = 64'h0003_0000;
    localparam integer Q_TILE_BYTES = 512;
    localparam integer KV_TILE_BYTES = 2048;

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
    wire [63:0] m_axi_araddr;
    wire [7:0]  m_axi_arlen;
    wire [2:0]  m_axi_arsize;
    wire [1:0]  m_axi_arburst;
    wire        m_axi_arvalid;
    reg         m_axi_arready;
    reg [127:0] m_axi_rdata;
    reg [1:0]   m_axi_rresp;
    reg         m_axi_rlast;
    reg         m_axi_rvalid;
    wire        m_axi_rready;
    wire [63:0] m_axi_awaddr;
    wire [7:0]  m_axi_awlen;
    wire [2:0]  m_axi_awsize;
    wire [1:0]  m_axi_awburst;
    wire        m_axi_awvalid;
    reg         m_axi_awready;
    wire [127:0] m_axi_wdata;
    wire [15:0]  m_axi_wstrb;
    wire         m_axi_wlast;
    wire         m_axi_wvalid;
    reg          m_axi_wready;
    reg [1:0]    m_axi_bresp;
    reg          m_axi_bvalid;
    wire         m_axi_bready;
    wire         irq;

    integer error_count;
    integer wait_count;
    reg [31:0] read_data;
    reg [31:0] status_data;
    reg [31:0] cycles_data;
    reg [31:0] rd_bytes_data;
    integer ar_count;
    integer r_beat_count;
    integer current_burst_idx;
    integer current_burst_beats;
    reg [63:0] current_araddr;

    FA_TOP_OPTIM_WINDOWED dut (
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
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .irq(irq)
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

    task expect32;
        input [31:0] actual;
        input [31:0] expected;
        input [8*56-1:0] name;
        begin
            if (actual !== expected) begin
                $display("FAIL: %0s expected %0d got %0d", name, expected, actual);
                error_count = error_count + 1;
            end
        end
    endtask

    function [15:0] make_q_word;
        input [5:0] q_tile_idx;
        input [1:0] row_idx;
        input [5:0] col_idx;
        begin
            make_q_word = 16'h0001
                        + {13'd0, (row_idx + q_tile_idx[1:0])}
                        + {13'd0, col_idx[1:0]};
        end
    endfunction

    function [15:0] make_k_word;
        input [4:0] kv_tile_idx;
        input [3:0] row_idx;
        input [5:0] col_idx;
        begin
            make_k_word = 16'h0001
                        + {13'd0, (row_idx[1:0] + kv_tile_idx[1:0])}
                        + {13'd0, col_idx[1:0]};
        end
    endfunction

    function [15:0] make_v_word;
        input [4:0] kv_tile_idx;
        input [3:0] row_idx;
        input [5:0] col_idx;
        begin
            make_v_word = 16'h0010 + ({12'd0, kv_tile_idx[3:0]} << 4)
                        + {12'd0, row_idx} + {10'd0, col_idx};
        end
    endfunction

    function [31:0] make_axi_read_word;
        input [63:0] addr;
        integer byte_offset;
        integer word_idx;
        integer tile_idx;
        integer word_in_tile;
        integer row_idx;
        integer col_pair_idx;
        integer col_idx;
        reg [15:0] lo_word;
        reg [15:0] hi_word;
        begin
            if ((addr >= Q_BASE) && (addr < K_BASE)) begin
                byte_offset = addr - Q_BASE;
                tile_idx = byte_offset / Q_TILE_BYTES;
                word_in_tile = (byte_offset % Q_TILE_BYTES) >> 2;
                row_idx = word_in_tile / 32;
                col_pair_idx = word_in_tile % 32;
                col_idx = col_pair_idx * 2;
                lo_word = make_q_word(tile_idx[5:0], row_idx[1:0], col_idx[5:0]);
                hi_word = make_q_word(tile_idx[5:0], row_idx[1:0], (col_idx + 1) & 6'h3f);
            end else if ((addr >= K_BASE) && (addr < V_BASE)) begin
                byte_offset = addr - K_BASE;
                tile_idx = byte_offset / KV_TILE_BYTES;
                word_in_tile = (byte_offset % KV_TILE_BYTES) >> 2;
                row_idx = word_in_tile / 32;
                col_pair_idx = word_in_tile % 32;
                col_idx = col_pair_idx * 2;
                lo_word = make_k_word(tile_idx[4:0], row_idx[3:0], col_idx[5:0]);
                hi_word = make_k_word(tile_idx[4:0], row_idx[3:0], (col_idx + 1) & 6'h3f);
            end else if ((addr >= V_BASE) && (addr < O_BASE)) begin
                byte_offset = addr - V_BASE;
                tile_idx = byte_offset / KV_TILE_BYTES;
                word_in_tile = (byte_offset % KV_TILE_BYTES) >> 2;
                row_idx = word_in_tile / 32;
                col_pair_idx = word_in_tile % 32;
                col_idx = col_pair_idx * 2;
                lo_word = make_v_word(tile_idx[4:0], row_idx[3:0], col_idx[5:0]);
                hi_word = make_v_word(tile_idx[4:0], row_idx[3:0], (col_idx + 1) & 6'h3f);
            end else begin
                lo_word = 16'hx;
                hi_word = 16'hx;
                $display("FAIL: AXI read addr outside Q/K/V regions addr=0x%016h", addr);
                error_count = error_count + 1;
            end
            make_axi_read_word = {hi_word, lo_word};
        end
    endfunction

    function [127:0] make_axi_read_beat;
        input [63:0] addr;
        begin
            make_axi_read_beat = {
                make_axi_read_word(addr + 64'd12),
                make_axi_read_word(addr + 64'd8),
                make_axi_read_word(addr + 64'd4),
                make_axi_read_word(addr)
            };
        end
    endfunction

    task drive_axi_read_channel;
        integer safety_count;
        integer next_burst_idx;
        reg read_active;
        reg ar_fire;
        reg r_fire;
        reg [63:0] araddr_sample;
        reg [7:0] arlen_sample;
        reg [63:0] next_araddr;
        begin
            m_axi_arready = 1'b0;
            m_axi_rvalid = 1'b0;
            m_axi_rlast = 1'b0;
            m_axi_rdata = 128'd0;
            m_axi_rresp = 2'b00;
            ar_count = 0;
            r_beat_count = 0;
            current_burst_idx = 0;
            current_burst_beats = 0;
            current_araddr = 64'd0;
            read_active = 1'b0;
            ar_fire = 1'b0;
            r_fire = 1'b0;
            araddr_sample = 64'd0;
            arlen_sample = 8'd0;
            next_araddr = 64'd0;
            safety_count = 0;
            wait (rstn === 1'b1);
            forever begin
                m_axi_arready = (!read_active && !m_axi_rvalid);
                ar_fire = m_axi_arvalid && m_axi_arready;
                r_fire = m_axi_rvalid && m_axi_rready;

                if (ar_fire) begin
                    araddr_sample = m_axi_araddr;
                    arlen_sample = m_axi_arlen;
                    if (m_axi_arsize !== 3'd4) begin
                        $display("FAIL: AXI arsize expected 4 got %0d", m_axi_arsize);
                        error_count = error_count + 1;
                    end
                    if (m_axi_arburst !== 2'b01) begin
                        $display("FAIL: AXI arburst expected INCR got %0d", m_axi_arburst);
                        error_count = error_count + 1;
                    end
                end

                tick();

                if (ar_fire) begin
                    current_araddr = araddr_sample;
                    current_burst_beats = arlen_sample + 1;
                    current_burst_idx = 0;
                    ar_count = ar_count + 1;
                    read_active = 1'b1;
                    m_axi_rvalid = 1'b1;
                    m_axi_rdata = make_axi_read_beat(araddr_sample);
                    m_axi_rlast = (arlen_sample == 8'd0);
                end else if (r_fire) begin
                    r_beat_count = r_beat_count + 1;
                    if (current_burst_idx == current_burst_beats - 1) begin
                        m_axi_rvalid = 1'b0;
                        m_axi_rlast = 1'b0;
                        m_axi_rdata = 128'd0;
                        read_active = 1'b0;
                    end else begin
                        next_burst_idx = current_burst_idx + 1;
                        next_araddr = current_araddr + 64'd16;
                        current_burst_idx = next_burst_idx;
                        current_araddr = next_araddr;
                        m_axi_rdata = make_axi_read_beat(next_araddr);
                        m_axi_rlast = (next_burst_idx == current_burst_beats - 1);
                    end
                end

                safety_count = safety_count + 1;
                if (safety_count > 2500000) begin
                    $display("FAIL: AXI read channel driver timeout ar_count=%0d r_beat_count=%0d",
                             ar_count, r_beat_count);
                    error_count = error_count + 1;
                    $fatal(1);
                end
            end
        end
    endtask

    initial begin
        error_count = 0;
        wait_count = 0;
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
        m_axi_arready = 1'b0;
        m_axi_rdata = 128'd0;
        m_axi_rresp = 2'b00;
        m_axi_rlast = 1'b0;
        m_axi_rvalid = 1'b0;
        m_axi_awready = 1'b0;
        m_axi_wready = 1'b0;
        m_axi_bresp = 2'b00;
        m_axi_bvalid = 1'b0;

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
        axil_write(7'h34, 32'd128);
        axil_write(7'h00, 32'h0000_0001);

        while (wait_count < 400000) begin
            axil_read(7'h04, status_data);
            if (status_data[1]) begin
                wait_count = 400000;
            end else begin
                if (status_data[2]) begin
                    $display("FAIL: STATUS error set before done, status=0x%08h", status_data);
                    error_count = error_count + 1;
                    wait_count = 400000;
                end else begin
                    wait_count = wait_count + 1;
                end
            end
        end

        axil_read(7'h04, status_data);
        if (!status_data[1]) begin
            $display("FAIL: timeout waiting for windowed top done, status=0x%08h", status_data);
            error_count = error_count + 1;
        end
        if (status_data[2]) begin
            $display("FAIL: windowed top status error set, status=0x%08h", status_data);
            error_count = error_count + 1;
        end

        axil_read(7'h40, read_data);
        cycles_data = read_data;
        if (read_data !== 32'd155013) begin
            $display("FAIL: CYCLES expected 155013 got %0d", read_data);
            error_count = error_count + 1;
        end

        axil_read(7'h44, read_data);
        rd_bytes_data = read_data;
        if (read_data !== 32'd393216) begin
            $display("FAIL: RD_BYTES expected 393216 got %0d", read_data);
            error_count = error_count + 1;
        end

        expect32(ar_count, 32'd1536, "ar_count");
        expect32(r_beat_count, 32'd24576, "r_beat_count");

        if (m_axi_awvalid || m_axi_wvalid || m_axi_bready) begin
            $display("FAIL: windowed top should keep AXI write master idle");
            error_count = error_count + 1;
        end

        if (error_count == 0) begin
            $display("PASS: fa_top_optim_windowed_tb numeric=dense_qk_reference cycles=%0d rd_bytes=%0d ar_count=%0d r_beat_count=%0d",
                     cycles_data, rd_bytes_data, ar_count, r_beat_count);
            $finish;
        end

        $display("FAIL: fa_top_optim_windowed_tb errors=%0d", error_count);
        $fatal(1);
    end

    initial begin
        drive_axi_read_channel();
    end
endmodule
