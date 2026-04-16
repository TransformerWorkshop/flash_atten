module tb_tpu_top_64bit #(
    parameter AXI_ID_WIDTH         = 4,
    parameter AXI_ADDR_WIDTH       = 32,
    parameter AXI_DATA_WIDTH       = 64,
    parameter AXI_AWUSER_WIDTH     = 8,
    parameter AXI_WUSER_WIDTH      = 8,
    parameter AXI_BUSER_WIDTH      = 8,
    parameter CSR_DATA_WIDTH       = 32,
    parameter CSR_ADDR_WIDTH       = 8,
    parameter PE_SIZE              = 8,
    parameter MATRIX_DIM_WIDTH     = 8,
    parameter PRECISION_MODE_WIDTH = 4,
    parameter RAM_ADDR_WIDTH       = 8,
    parameter RAM_C_ADDR_WIDTH     = 10,
    parameter RAM_D_ADDR_WIDTH     = 10,
    parameter RAM_DATA_WIDTH       = 64,
    parameter FIFO_DATA_WIDTH      = 32,
    parameter FIFO_DEPTH           = 512,
    parameter MATRIX_A_BASE_ADDR   = 32'h0000_0000,
    parameter MATRIX_B_BASE_ADDR   = 32'h0000_4000,
    parameter MATRIX_C_BASE_ADDR   = 32'h0000_8000,
    parameter MATRIX_D_BASE_ADDR   = 32'h0000_C000,
    parameter DATA_WIDTH           = 32,
    parameter OBS_MAX_WRITE_WORDS  = 256
) (
    input  wire                              clk,
    input  wire                              rst_n,

    input  wire [      AXI_ID_WIDTH-1:0]     s_axi_awid,
    input  wire [    AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  wire [                   7:0]     s_axi_awlen,
    input  wire [                   2:0]     s_axi_awsize,
    input  wire [                   1:0]     s_axi_awburst,
    input  wire                              s_axi_awlock,
    input  wire [                   3:0]     s_axi_awcache,
    input  wire [                   2:0]     s_axi_awprot,
    input  wire [                   3:0]     s_axi_awqos,
    input  wire [                   3:0]     s_axi_awregion,
    input  wire [  AXI_AWUSER_WIDTH-1:0]     s_axi_awuser,
    input  wire                              s_axi_awvalid,
    output wire                              s_axi_awready,

    input  wire [    AXI_DATA_WIDTH-1:0]     s_axi_wdata,
    input  wire [(AXI_DATA_WIDTH/8)-1:0]     s_axi_wstrb,
    input  wire                              s_axi_wlast,
    input  wire [   AXI_WUSER_WIDTH-1:0]     s_axi_wuser,
    input  wire                              s_axi_wvalid,
    output wire                              s_axi_wready,

    output wire [      AXI_ID_WIDTH-1:0]     s_axi_bid,
    output wire [                   1:0]     s_axi_bresp,
    output wire [  AXI_BUSER_WIDTH-1:0]     s_axi_buser,
    output wire                              s_axi_bvalid,
    input  wire                              s_axi_bready,

    input  wire [             8-1:0]         s_axil_awaddr,
    input  wire                              s_axil_awvalid,
    output wire                              s_axil_awready,

    input  wire [    CSR_DATA_WIDTH-1:0]     s_axil_wdata,
    input  wire [  CSR_DATA_WIDTH/8-1:0]     s_axil_wstrb,
    input  wire                              s_axil_wvalid,
    output wire                              s_axil_wready,

    output wire [                   1:0]     s_axil_bresp,
    output wire                              s_axil_bvalid,
    input  wire                              s_axil_bready,

    input  wire [             8-1:0]         s_axil_araddr,
    input  wire                              s_axil_arvalid,
    output wire                              s_axil_arready,

    output wire [    CSR_DATA_WIDTH-1:0]     s_axil_rdata,
    output wire [                   1:0]     s_axil_rresp,
    output wire                              s_axil_rvalid,
    input  wire                              s_axil_rready,

    output wire                              obs_soft_reset_active,
    output wire                              obs_axi_wr_ready,
    output wire                              obs_load_busy,
    output wire                              obs_load_done,
    output wire                              obs_compute_done,
    output wire                              obs_transfer_done,
    output wire                              obs_ram_a_wr_done,
    output wire                              obs_ram_b_wr_done,
    output wire                              obs_ram_c_wr_done,
    output reg  [                   7:0]     obs_load_done_count,
    output reg  [                   7:0]     obs_compute_done_count,
    output reg  [                   7:0]     obs_transfer_done_count,
    output reg  [                   7:0]     obs_ram_a_wr_done_count,
    output reg  [                   7:0]     obs_ram_b_wr_done_count,
    output reg  [                   7:0]     obs_ram_c_wr_done_count,
    output reg  [                  15:0]     obs_m_axi_aw_count,
    output reg  [                  15:0]     obs_m_axi_w_count,
    output reg  [                  15:0]     obs_m_axi_b_count,
    output reg  [                  15:0]     obs_writeback_word_count,
    output reg  [    AXI_ADDR_WIDTH-1:0]     obs_last_m_axi_awaddr,
    output reg  [    AXI_DATA_WIDTH-1:0]     obs_last_m_axi_wdata,
    output reg  [                   7:0]     obs_last_m_axi_awlen,
    output reg  [(AXI_DATA_WIDTH/8)-1:0]     obs_last_m_axi_wstrb,
    output reg                               obs_last_m_axi_wlast,
    output reg  [AXI_DATA_WIDTH*OBS_MAX_WRITE_WORDS-1:0] obs_writeback_words,
    output reg  [(AXI_DATA_WIDTH/8)*OBS_MAX_WRITE_WORDS-1:0] obs_writeback_strbs
);

    wire [      AXI_ID_WIDTH-1:0] m_axi_awid;
    wire [    AXI_ADDR_WIDTH-1:0] m_axi_awaddr;
    wire [                   7:0] m_axi_awlen;
    wire [                   2:0] m_axi_awsize;
    wire [                   1:0] m_axi_awburst;
    wire                          m_axi_awlock;
    wire [                   3:0] m_axi_awcache;
    wire [                   2:0] m_axi_awprot;
    wire [                   3:0] m_axi_awqos;
    wire [                   3:0] m_axi_awregion;
    wire [  AXI_AWUSER_WIDTH-1:0] m_axi_awuser;
    wire                          m_axi_awvalid;
    wire                          m_axi_awready;
    wire [    AXI_DATA_WIDTH-1:0] m_axi_wdata;
    wire [(AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb;
    wire                          m_axi_wlast;
    wire [   AXI_WUSER_WIDTH-1:0] m_axi_wuser;
    wire                          m_axi_wvalid;
    wire                          m_axi_wready;
    reg  [      AXI_ID_WIDTH-1:0] m_axi_bid;
    reg  [                   1:0] m_axi_bresp;
    reg  [  AXI_BUSER_WIDTH-1:0]  m_axi_buser;
    reg                           m_axi_bvalid;
    wire                          m_axi_bready;

    wire                          dbg_m00_awvalid;
    wire                          dbg_m00_awready;
    wire                          dbg_m00_wvalid;
    wire                          dbg_m00_wready;
    wire                          dbg_m00_wlast;
    wire                          dbg_m00_bvalid;
    wire                          dbg_m00_bready;

    wire                          dbg_m01_awvalid;
    wire                          dbg_m01_awready;
    wire                          dbg_m01_wvalid;
    wire                          dbg_m01_wready;
    wire                          dbg_m01_wlast;
    wire                          dbg_m01_bvalid;
    wire                          dbg_m01_bready;

    wire                          sink_rst_n;
    reg                           b_pending;
    reg  [      AXI_ID_WIDTH-1:0] pending_bid;

    assign m_axi_awready    = 1'b1;
    assign m_axi_wready     = 1'b1;
    assign dbg_m00_awvalid  = m_axi_awvalid;
    assign dbg_m00_awready  = m_axi_awready;
    assign dbg_m00_wvalid   = m_axi_wvalid;
    assign dbg_m00_wready   = m_axi_wready;
    assign dbg_m00_wlast    = m_axi_wlast;
    assign dbg_m00_bvalid   = m_axi_bvalid;
    assign dbg_m00_bready   = m_axi_bready;
    assign dbg_m01_awvalid  = 1'b0;
    assign dbg_m01_awready  = 1'b0;
    assign dbg_m01_wvalid   = 1'b0;
    assign dbg_m01_wready   = 1'b0;
    assign dbg_m01_wlast    = 1'b0;
    assign dbg_m01_bvalid   = 1'b0;
    assign dbg_m01_bready   = 1'b0;

    tpu_top #(
        .AXI_ID_WIDTH         (AXI_ID_WIDTH),
        .AXI_ADDR_WIDTH       (AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH       (AXI_DATA_WIDTH),
        .AXI_AWUSER_WIDTH     (AXI_AWUSER_WIDTH),
        .AXI_WUSER_WIDTH      (AXI_WUSER_WIDTH),
        .AXI_BUSER_WIDTH      (AXI_BUSER_WIDTH),
        .CSR_DATA_WIDTH       (CSR_DATA_WIDTH),
        .CSR_ADDR_WIDTH       (CSR_ADDR_WIDTH),
        .PE_SIZE              (PE_SIZE),
        .MATRIX_DIM_WIDTH     (MATRIX_DIM_WIDTH),
        .PRECISION_MODE_WIDTH (PRECISION_MODE_WIDTH),
        .RAM_ADDR_WIDTH       (RAM_ADDR_WIDTH),
        .RAM_C_ADDR_WIDTH     (RAM_C_ADDR_WIDTH),
        .RAM_D_ADDR_WIDTH     (RAM_D_ADDR_WIDTH),
        .RAM_DATA_WIDTH       (RAM_DATA_WIDTH),
        .FIFO_DATA_WIDTH      (FIFO_DATA_WIDTH),
        .FIFO_DEPTH           (FIFO_DEPTH),
        .MATRIX_A_BASE_ADDR   (MATRIX_A_BASE_ADDR),
        .MATRIX_B_BASE_ADDR   (MATRIX_B_BASE_ADDR),
        .MATRIX_C_BASE_ADDR   (MATRIX_C_BASE_ADDR),
        .MATRIX_D_BASE_ADDR   (MATRIX_D_BASE_ADDR),
        .DATA_WIDTH           (DATA_WIDTH)
    ) u_dut (
        .clk              (clk),
        .rst_n            (rst_n),

        .s_axi_awid       (s_axi_awid),
        .s_axi_awaddr     (s_axi_awaddr),
        .s_axi_awlen      (s_axi_awlen),
        .s_axi_awsize     (s_axi_awsize),
        .s_axi_awburst    (s_axi_awburst),
        .s_axi_awlock     (s_axi_awlock),
        .s_axi_awcache    (s_axi_awcache),
        .s_axi_awprot     (s_axi_awprot),
        .s_axi_awqos      (s_axi_awqos),
        .s_axi_awregion   (s_axi_awregion),
        .s_axi_awuser     (s_axi_awuser),
        .s_axi_awvalid    (s_axi_awvalid),
        .s_axi_awready    (s_axi_awready),

        .s_axi_wdata      (s_axi_wdata),
        .s_axi_wstrb      (s_axi_wstrb),
        .s_axi_wlast      (s_axi_wlast),
        .s_axi_wuser      (s_axi_wuser),
        .s_axi_wvalid     (s_axi_wvalid),
        .s_axi_wready     (s_axi_wready),

        .s_axi_bid        (s_axi_bid),
        .s_axi_bresp      (s_axi_bresp),
        .s_axi_buser      (s_axi_buser),
        .s_axi_bvalid     (s_axi_bvalid),
        .s_axi_bready     (s_axi_bready),

        .s_axil_awaddr    (s_axil_awaddr),
        .s_axil_awvalid   (s_axil_awvalid),
        .s_axil_awready   (s_axil_awready),
        .s_axil_wdata     (s_axil_wdata),
        .s_axil_wstrb     (s_axil_wstrb),
        .s_axil_wvalid    (s_axil_wvalid),
        .s_axil_wready    (s_axil_wready),
        .s_axil_bresp     (s_axil_bresp),
        .s_axil_bvalid    (s_axil_bvalid),
        .s_axil_bready    (s_axil_bready),
        .s_axil_araddr    (s_axil_araddr),
        .s_axil_arvalid   (s_axil_arvalid),
        .s_axil_arready   (s_axil_arready),
        .s_axil_rdata     (s_axil_rdata),
        .s_axil_rresp     (s_axil_rresp),
        .s_axil_rvalid    (s_axil_rvalid),
        .s_axil_rready    (s_axil_rready),

        .m_axi_awid       (m_axi_awid),
        .m_axi_awaddr     (m_axi_awaddr),
        .m_axi_awlen      (m_axi_awlen),
        .m_axi_awsize     (m_axi_awsize),
        .m_axi_awburst    (m_axi_awburst),
        .m_axi_awlock     (m_axi_awlock),
        .m_axi_awcache    (m_axi_awcache),
        .m_axi_awprot     (m_axi_awprot),
        .m_axi_awqos      (m_axi_awqos),
        .m_axi_awregion   (m_axi_awregion),
        .m_axi_awuser     (m_axi_awuser),
        .m_axi_awvalid    (m_axi_awvalid),
        .m_axi_awready    (m_axi_awready),
        .m_axi_wdata      (m_axi_wdata),
        .m_axi_wstrb      (m_axi_wstrb),
        .m_axi_wlast      (m_axi_wlast),
        .m_axi_wuser      (m_axi_wuser),
        .m_axi_wvalid     (m_axi_wvalid),
        .m_axi_wready     (m_axi_wready),
        .m_axi_bid        (m_axi_bid),
        .m_axi_bresp      (m_axi_bresp),
        .m_axi_buser      (m_axi_buser),
        .m_axi_bvalid     (m_axi_bvalid),
        .m_axi_bready     (m_axi_bready),
        .dbg_m00_awvalid  (dbg_m00_awvalid),
        .dbg_m00_awready  (dbg_m00_awready),
        .dbg_m00_wvalid   (dbg_m00_wvalid),
        .dbg_m00_wready   (dbg_m00_wready),
        .dbg_m00_wlast    (dbg_m00_wlast),
        .dbg_m00_bvalid   (dbg_m00_bvalid),
        .dbg_m00_bready   (dbg_m00_bready),
        .dbg_m01_awvalid  (dbg_m01_awvalid),
        .dbg_m01_awready  (dbg_m01_awready),
        .dbg_m01_wvalid   (dbg_m01_wvalid),
        .dbg_m01_wready   (dbg_m01_wready),
        .dbg_m01_wlast    (dbg_m01_wlast),
        .dbg_m01_bvalid   (dbg_m01_bvalid),
        .dbg_m01_bready   (dbg_m01_bready)
    );

    assign obs_soft_reset_active = u_dut.soft_reset_active;
    assign obs_axi_wr_ready      = u_dut.axi_wr_ready;
    assign obs_load_busy         = u_dut.load_busy;
    assign obs_load_done         = u_dut.load_done;
    assign obs_compute_done      = u_dut.compute_done;
    assign obs_transfer_done     = u_dut.transfer_done;
    assign obs_ram_a_wr_done     = u_dut.ram_a_wr_done;
    assign obs_ram_b_wr_done     = u_dut.ram_b_wr_done;
    assign obs_ram_c_wr_done     = u_dut.ram_c_wr_done;
    assign sink_rst_n            = rst_n && !obs_soft_reset_active;

    always @(posedge clk or negedge sink_rst_n) begin
        if (!sink_rst_n) begin
            m_axi_bid           <= {AXI_ID_WIDTH{1'b0}};
            m_axi_bresp         <= 2'b00;
            m_axi_buser         <= {AXI_BUSER_WIDTH{1'b0}};
            m_axi_bvalid        <= 1'b0;
            b_pending           <= 1'b0;
            pending_bid         <= {AXI_ID_WIDTH{1'b0}};
            obs_m_axi_aw_count  <= 16'd0;
            obs_m_axi_w_count   <= 16'd0;
            obs_m_axi_b_count   <= 16'd0;
            obs_writeback_word_count <= 16'd0;
            obs_last_m_axi_awaddr <= {AXI_ADDR_WIDTH{1'b0}};
            obs_last_m_axi_wdata  <= {AXI_DATA_WIDTH{1'b0}};
            obs_last_m_axi_awlen <= 8'd0;
            obs_last_m_axi_wstrb <= {(AXI_DATA_WIDTH/8){1'b0}};
            obs_last_m_axi_wlast <= 1'b0;
            obs_writeback_words <= {(AXI_DATA_WIDTH*OBS_MAX_WRITE_WORDS){1'b0}};
            obs_writeback_strbs <= {((AXI_DATA_WIDTH/8)*OBS_MAX_WRITE_WORDS){1'b0}};
        end else begin
            if (m_axi_awvalid && m_axi_awready) begin
                pending_bid         <= m_axi_awid;
                obs_m_axi_aw_count  <= obs_m_axi_aw_count + 16'd1;
                obs_last_m_axi_awaddr <= m_axi_awaddr;
                obs_last_m_axi_awlen <= m_axi_awlen;
            end

            if (m_axi_wvalid && m_axi_wready) begin
                obs_m_axi_w_count   <= obs_m_axi_w_count + 16'd1;
                obs_last_m_axi_wdata <= m_axi_wdata;
                obs_last_m_axi_wstrb <= m_axi_wstrb;
                obs_last_m_axi_wlast <= m_axi_wlast;
                if (obs_writeback_word_count < OBS_MAX_WRITE_WORDS) begin
                    obs_writeback_words[obs_writeback_word_count*AXI_DATA_WIDTH +: AXI_DATA_WIDTH] <= m_axi_wdata;
                    obs_writeback_strbs[obs_writeback_word_count*(AXI_DATA_WIDTH/8) +: (AXI_DATA_WIDTH/8)] <= m_axi_wstrb;
                    obs_writeback_word_count <= obs_writeback_word_count + 16'd1;
                end
                if (m_axi_wlast) begin
                    b_pending <= 1'b1;
                end
            end

            if (!m_axi_bvalid && b_pending) begin
                m_axi_bvalid <= 1'b1;
                m_axi_bid    <= pending_bid;
                m_axi_bresp  <= 2'b00;
                m_axi_buser  <= {AXI_BUSER_WIDTH{1'b0}};
                b_pending    <= 1'b0;
            end else if (m_axi_bvalid && m_axi_bready) begin
                m_axi_bvalid   <= 1'b0;
                obs_m_axi_b_count <= obs_m_axi_b_count + 16'd1;
            end
        end
    end

    always @(posedge clk or negedge sink_rst_n) begin
        if (!sink_rst_n) begin
            obs_load_done_count     <= 8'd0;
            obs_compute_done_count  <= 8'd0;
            obs_transfer_done_count <= 8'd0;
            obs_ram_a_wr_done_count <= 8'd0;
            obs_ram_b_wr_done_count <= 8'd0;
            obs_ram_c_wr_done_count <= 8'd0;
        end else begin
            if (obs_load_done) begin
                obs_load_done_count <= obs_load_done_count + 8'd1;
            end
            if (obs_compute_done) begin
                obs_compute_done_count <= obs_compute_done_count + 8'd1;
            end
            if (obs_transfer_done) begin
                obs_transfer_done_count <= obs_transfer_done_count + 8'd1;
            end
            if (obs_ram_a_wr_done) begin
                obs_ram_a_wr_done_count <= obs_ram_a_wr_done_count + 8'd1;
            end
            if (obs_ram_b_wr_done) begin
                obs_ram_b_wr_done_count <= obs_ram_b_wr_done_count + 8'd1;
            end
            if (obs_ram_c_wr_done) begin
                obs_ram_c_wr_done_count <= obs_ram_c_wr_done_count + 8'd1;
            end
        end
    end

endmodule
