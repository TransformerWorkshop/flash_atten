`timescale 1ns/1ps

module fa_top_optim_packed_tb;
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

    FA_TOP_OPTIM_PACKED dut (
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

        axil_write(7'h00, 32'h0000_0001);

        while (wait_count < 5000) begin
            axil_read(7'h04, read_data);
            if (read_data[1]) begin
                wait_count = 5000;
            end else begin
                if (read_data[2]) begin
                    $display("FAIL: STATUS error set before done, status=0x%08h", read_data);
                    error_count = error_count + 1;
                    wait_count = 5000;
                end else begin
                    wait_count = wait_count + 1;
                end
            end
        end

        axil_read(7'h04, read_data);
        if (!read_data[1]) begin
            $display("FAIL: timeout waiting for optim packed top done, status=0x%08h", read_data);
            error_count = error_count + 1;
        end
        if (read_data[2]) begin
            $display("FAIL: optim packed top status error set, status=0x%08h", read_data);
            error_count = error_count + 1;
        end

        axil_read(7'h40, read_data);
        if (read_data !== 32'd2242) begin
            $display("FAIL: CYCLES expected 2242 got %0d", read_data);
            error_count = error_count + 1;
        end

        if (m_axi_arvalid || m_axi_awvalid || m_axi_wvalid || m_axi_rready || m_axi_bready) begin
            $display("FAIL: optim packed top should keep AXI master idle");
            error_count = error_count + 1;
        end

        if (error_count == 0) begin
            $display("PASS: fa_top_optim_packed_tb cycles=%0d", read_data);
            $finish;
        end

        $display("FAIL: fa_top_optim_packed_tb errors=%0d", error_count);
        $fatal(1);
    end
endmodule
