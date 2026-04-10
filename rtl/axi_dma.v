// =============================================================================
// AXI4 Master Read/Write DMA Engine
// Flash-Attention Accelerator �? Memory Fetch & Write-Back Unit
// =============================================================================
//
// Read path  �? Fetches data from memory via AXI4 INCR bursts and streams it
//              out on an AXI-Stream master interface (m_axis_*).
// Write path �? Accepts data on an AXI-Stream slave interface (s_axis_*) and
//              writes it back to memory via AXI4 INCR bursts.
//
// Each path has its own start pulse, base address, and beat count.  The two
// paths operate with independent FSMs and can run concurrently.
// =============================================================================

module axi_dma #(
    parameter ADDR_W         = 40,       // AXI address width
    parameter DATA_W         = 128,      // AXI data width (bits)
    parameter STRB_W         = DATA_W/8, // byte-strobe width (derived)
    parameter ID_W           = 4,        // AXI ID width
    parameter LEN_W          = 8,        // AXI burst length field (8 �? max 256 beats)
    parameter MAX_BURST      = 256,      // maximum beats per AXI burst (�? 2^LEN_W)
    parameter BYTES_PER_BEAT = DATA_W/8
)(
    input  wire                 aclk,
    input  wire                 aresetn,

    // ---- Read-side control (sequencer / CSR array) ----
    input  wire                 i_rd_start,       // pulse to begin read transfer
    input  wire [ADDR_W-1:0]   i_rd_base_addr,   // read start address (byte-aligned)
    input  wire [31:0]         i_rd_total_beats,  // total beats to fetch
    output wire                 o_rd_busy,
    output reg                  o_rd_done,

    // ---- Write-side control (sequencer / CSR array) ----
    input  wire                 i_wr_start,       // pulse to begin write transfer
    input  wire [ADDR_W-1:0]   i_wr_base_addr,   // write start address (byte-aligned)
    input  wire [31:0]         i_wr_total_beats,  // total beats to write
    output wire                 o_wr_busy,
    output reg                  o_wr_done,

    // ---- AXI4 Master Read Address Channel ----
    output wire [ID_W-1:0]     m_axi_arid,
    output reg  [ADDR_W-1:0]   m_axi_araddr,
    output reg  [LEN_W-1:0]    m_axi_arlen,
    output wire [2:0]          m_axi_arsize,
    output wire [1:0]          m_axi_arburst,
    output wire                m_axi_arlock,
    output wire [3:0]          m_axi_arcache,
    output wire [2:0]          m_axi_arprot,
    output wire [3:0]          m_axi_arqos,
    output reg                 m_axi_arvalid,
    input  wire                m_axi_arready,

    // ---- AXI4 Master Read Data Channel ----
    input  wire [ID_W-1:0]     m_axi_rid,
    input  wire [DATA_W-1:0]   m_axi_rdata,
    input  wire [1:0]          m_axi_rresp,
    input  wire                m_axi_rlast,
    input  wire                m_axi_rvalid,
    output reg                 m_axi_rready,

    // ---- AXI4 Master Write Address Channel ----
    output wire [ID_W-1:0]     m_axi_awid,
    output reg  [ADDR_W-1:0]   m_axi_awaddr,
    output reg  [LEN_W-1:0]    m_axi_awlen,
    output wire [2:0]          m_axi_awsize,
    output wire [1:0]          m_axi_awburst,
    output wire                m_axi_awlock,
    output wire [3:0]          m_axi_awcache,
    output wire [2:0]          m_axi_awprot,
    output wire [3:0]          m_axi_awqos,
    output reg                 m_axi_awvalid,
    input  wire                m_axi_awready,

    // ---- AXI4 Master Write Data Channel ----
    output reg  [DATA_W-1:0]   m_axi_wdata,
    output reg  [STRB_W-1:0]   m_axi_wstrb,
    output reg                 m_axi_wlast,
    output reg                 m_axi_wvalid,
    input  wire                m_axi_wready,

    // ---- AXI4 Master Write Response Channel ----
    input  wire [ID_W-1:0]     m_axi_bid,
    input  wire [1:0]          m_axi_bresp,
    input  wire                m_axi_bvalid,
    output reg                 m_axi_bready,

    // ---- Streaming data output (read path �? datapath) ----
    output wire [DATA_W-1:0]   m_axis_tdata,
    output wire                m_axis_tlast,
    output reg                 m_axis_tvalid,
    input  wire                m_axis_tready,

    // ---- Streaming data input (datapath �? write path) ----
    input  wire [DATA_W-1:0]   s_axis_tdata,
    input  wire                s_axis_tlast,
    input  wire                s_axis_tvalid,
    output reg                 s_axis_tready,

    // ---- Error flags ----
    output reg                 o_rd_error,
    output reg                 o_wr_error
);

    // =========================================================================
    // Fixed AR channel signals
    // =========================================================================
    assign m_axi_arid    = {ID_W{1'b0}};
    assign m_axi_arsize  = $clog2(BYTES_PER_BEAT);  // full-width beats
    assign m_axi_arburst = 2'b01;   // INCR
    assign m_axi_arlock  = 1'b0;
    assign m_axi_arcache = 4'b0011; // bufferable, modifiable
    assign m_axi_arprot  = 3'b000;  // unprivileged, secure, data
    assign m_axi_arqos   = 4'b0;

    // =========================================================================
    // Fixed AW channel signals
    // =========================================================================
    assign m_axi_awid    = {ID_W{1'b0}};
    assign m_axi_awsize  = $clog2(BYTES_PER_BEAT);  // full-width beats
    assign m_axi_awburst = 2'b01;   // INCR
    assign m_axi_awlock  = 1'b0;
    assign m_axi_awcache = 4'b0011; // bufferable, modifiable
    assign m_axi_awprot  = 3'b000;  // unprivileged, secure, data
    assign m_axi_awqos   = 4'b0;

    // #########################################################################
    //  READ PATH
    // #########################################################################

    // =========================================================================
    // Read FSM States
    // =========================================================================
    localparam [1:0] RD_IDLE = 2'd0,
                     RD_AR   = 2'd1,
                     RD_DATA = 2'd2,
                     RD_DONE = 2'd3;

    reg [1:0] rd_state, rd_state_nxt;

    // =========================================================================
    // Read-path counters
    // =========================================================================
    reg [31:0]      rd_beats_remaining;
    reg [LEN_W-1:0] rd_burst_len;
    reg [LEN_W:0]   rd_beat_cnt;
    reg [31:0]      rd_total_received;

    assign o_rd_busy = (rd_state != RD_IDLE);

    // =========================================================================
    // Streaming output �? pass-through from R channel with back-pressure
    // =========================================================================
    assign m_axis_tdata = m_axi_rdata;
    assign m_axis_tlast = (rd_total_received + 1 == i_rd_total_beats) &&
                          m_axi_rvalid && m_axi_rready;

    // =========================================================================
    // Read FSM �? next state (combinational)
    // =========================================================================
    always @(*) begin
        rd_state_nxt = rd_state;
        case (rd_state)
            RD_IDLE: if (i_rd_start)                          rd_state_nxt = RD_AR;
            RD_AR:   if (m_axi_arvalid && m_axi_arready)     rd_state_nxt = RD_DATA;
            RD_DATA: begin
                if (m_axi_rvalid && m_axi_rready && m_axi_rlast) begin
                    if (rd_beats_remaining == 0)  rd_state_nxt = RD_DONE;
                    else                          rd_state_nxt = RD_AR;
                end
            end
            RD_DONE: rd_state_nxt = RD_IDLE;
        endcase
    end

    // =========================================================================
    // Read FSM �? registered datapath
    // =========================================================================
    always @(posedge aclk) begin
        if (!aresetn) begin
            rd_state          <= RD_IDLE;
            m_axi_araddr      <= {ADDR_W{1'b0}};
            m_axi_arlen       <= {LEN_W{1'b0}};
            m_axi_arvalid     <= 1'b0;
            m_axi_rready      <= 1'b0;
            m_axis_tvalid     <= 1'b0;
            rd_beats_remaining<= 32'd0;
            rd_burst_len      <= {LEN_W{1'b0}};
            rd_beat_cnt       <= {(LEN_W+1){1'b0}};
            rd_total_received <= 32'd0;
            o_rd_done         <= 1'b0;
            o_rd_error        <= 1'b0;
        end else begin
            rd_state  <= rd_state_nxt;
            o_rd_done <= 1'b0;

            case (rd_state)
                // ---------------------------------------------------------
                RD_IDLE: begin
                    m_axi_arvalid <= 1'b0;
                    m_axi_rready  <= 1'b0;
                    m_axis_tvalid <= 1'b0;
                    if (i_rd_start) begin
                        rd_beats_remaining <= i_rd_total_beats;
                        m_axi_araddr       <= i_rd_base_addr;
                        rd_total_received  <= 32'd0;
                        o_rd_error         <= 1'b0;
                    end
                end

                // ---------------------------------------------------------
                RD_AR: begin
                    m_axi_rready  <= 1'b0;
                    m_axis_tvalid <= 1'b0;

                    if (rd_beats_remaining >= MAX_BURST)
                        rd_burst_len <= MAX_BURST[LEN_W-1:0] - 1;
                    else
                        rd_burst_len <= rd_beats_remaining[LEN_W-1:0] - 1;

                    if (!m_axi_arvalid) begin
                        m_axi_arvalid <= 1'b1;
                        if (rd_beats_remaining >= MAX_BURST)
                            m_axi_arlen <= MAX_BURST[LEN_W-1:0] - 1;
                        else
                            m_axi_arlen <= rd_beats_remaining[LEN_W-1:0] - 1;
                    end

                    if (m_axi_arvalid && m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        rd_beat_cnt   <= {(LEN_W+1){1'b0}};
                        if (rd_beats_remaining >= MAX_BURST)
                            rd_beats_remaining <= rd_beats_remaining - MAX_BURST;
                        else
                            rd_beats_remaining <= 32'd0;
                    end
                end

                // ---------------------------------------------------------
                RD_DATA: begin
                    m_axi_rready  <= m_axis_tready;
                    m_axis_tvalid <= m_axi_rvalid && m_axi_rready;

                    if (m_axi_rvalid && m_axi_rready) begin
                        rd_beat_cnt       <= rd_beat_cnt + 1;
                        rd_total_received <= rd_total_received + 1;

                        if (m_axi_rresp[1])
                            o_rd_error <= 1'b1;

                        if (m_axi_rlast)
                            m_axi_araddr <= m_axi_araddr +
                                            (rd_beat_cnt + 1) * BYTES_PER_BEAT;
                    end
                end

                // ---------------------------------------------------------
                RD_DONE: begin
                    o_rd_done     <= 1'b1;
                    m_axi_rready  <= 1'b0;
                    m_axis_tvalid <= 1'b0;
                end
            endcase
        end
    end

    // #########################################################################
    //  WRITE PATH
    // #########################################################################

    // =========================================================================
    // Write FSM States
    // =========================================================================
    localparam [2:0] WR_IDLE  = 3'd0,
                     WR_AW    = 3'd1,
                     WR_DATA  = 3'd2,
                     WR_RESP  = 3'd3,
                     WR_DONE  = 3'd4;

    reg [2:0] wr_state, wr_state_nxt;

    // =========================================================================
    // Write-path counters
    // =========================================================================
    reg [31:0]      wr_beats_remaining;
    reg [LEN_W-1:0] wr_burst_len;       // AWLEN for current burst (0-based)
    reg [LEN_W:0]   wr_beat_cnt;        // beats sent in current burst
    reg [31:0]      wr_total_sent;

    assign o_wr_busy = (wr_state != WR_IDLE);

    // =========================================================================
    // Write FSM �? next state (combinational)
    // =========================================================================
    always @(*) begin
        wr_state_nxt = wr_state;
        case (wr_state)
            WR_IDLE: if (i_wr_start)                          wr_state_nxt = WR_AW;
            WR_AW:   if (m_axi_awvalid && m_axi_awready)     wr_state_nxt = WR_DATA;
            WR_DATA: begin
                if (m_axi_wvalid && m_axi_wready && m_axi_wlast)
                    wr_state_nxt = WR_RESP;
            end
            WR_RESP: begin
                if (m_axi_bvalid && m_axi_bready) begin
                    if (wr_beats_remaining == 0)  wr_state_nxt = WR_DONE;
                    else                          wr_state_nxt = WR_AW;
                end
            end
            WR_DONE: wr_state_nxt = WR_IDLE;
            default: wr_state_nxt = WR_IDLE;
        endcase
    end

    // =========================================================================
    // Write FSM �? registered datapath
    // =========================================================================
    always @(posedge aclk) begin
        if (!aresetn) begin
            wr_state          <= WR_IDLE;
            m_axi_awaddr      <= {ADDR_W{1'b0}};
            m_axi_awlen       <= {LEN_W{1'b0}};
            m_axi_awvalid     <= 1'b0;
            m_axi_wdata       <= {DATA_W{1'b0}};
            m_axi_wstrb       <= {STRB_W{1'b1}};
            m_axi_wlast       <= 1'b0;
            m_axi_wvalid      <= 1'b0;
            m_axi_bready      <= 1'b0;
            s_axis_tready     <= 1'b0;
            wr_beats_remaining<= 32'd0;
            wr_burst_len      <= {LEN_W{1'b0}};
            wr_beat_cnt       <= {(LEN_W+1){1'b0}};
            wr_total_sent     <= 32'd0;
            o_wr_done         <= 1'b0;
            o_wr_error        <= 1'b0;
        end else begin
            wr_state  <= wr_state_nxt;
            o_wr_done <= 1'b0;

            case (wr_state)
                // ---------------------------------------------------------
                WR_IDLE: begin
                    m_axi_awvalid <= 1'b0;
                    m_axi_wvalid  <= 1'b0;
                    m_axi_wlast   <= 1'b0;
                    m_axi_bready  <= 1'b0;
                    s_axis_tready <= 1'b0;
                    if (i_wr_start) begin
                        wr_beats_remaining <= i_wr_total_beats;
                        m_axi_awaddr       <= i_wr_base_addr;
                        wr_total_sent      <= 32'd0;
                        o_wr_error         <= 1'b0;
                    end
                end

                // ---------------------------------------------------------
                WR_AW: begin
                    m_axi_wvalid  <= 1'b0;
                    m_axi_wlast   <= 1'b0;
                    m_axi_bready  <= 1'b0;
                    s_axis_tready <= 1'b0;

                    if (wr_beats_remaining >= MAX_BURST)
                        wr_burst_len <= MAX_BURST[LEN_W-1:0] - 1;
                    else
                        wr_burst_len <= wr_beats_remaining[LEN_W-1:0] - 1;

                    if (!m_axi_awvalid) begin
                        m_axi_awvalid <= 1'b1;
                        if (wr_beats_remaining >= MAX_BURST)
                            m_axi_awlen <= MAX_BURST[LEN_W-1:0] - 1;
                        else
                            m_axi_awlen <= wr_beats_remaining[LEN_W-1:0] - 1;
                    end

                    if (m_axi_awvalid && m_axi_awready) begin
                        m_axi_awvalid <= 1'b0;
                        wr_beat_cnt   <= {(LEN_W+1){1'b0}};
                        if (wr_beats_remaining >= MAX_BURST)
                            wr_beats_remaining <= wr_beats_remaining - MAX_BURST;
                        else
                            wr_beats_remaining <= 32'd0;
                    end
                end

                // ---------------------------------------------------------
                WR_DATA: begin
                    m_axi_bready  <= 1'b0;
                    s_axis_tready <= m_axi_wready;   // back-pressure from AXI

                    if (s_axis_tvalid && s_axis_tready) begin
                        m_axi_wdata  <= s_axis_tdata;
                        m_axi_wstrb  <= {STRB_W{1'b1}};  // all bytes valid
                        m_axi_wvalid <= 1'b1;
                        m_axi_wlast  <= (wr_beat_cnt == wr_burst_len);

                        wr_beat_cnt   <= wr_beat_cnt + 1;
                        wr_total_sent <= wr_total_sent + 1;
                    end else if (m_axi_wvalid && m_axi_wready) begin
                        // Previous beat accepted; deassert until next stream beat
                        m_axi_wvalid <= 1'b0;
                        m_axi_wlast  <= 1'b0;
                    end
                end

                // ---------------------------------------------------------
                WR_RESP: begin
                    m_axi_wvalid  <= 1'b0;
                    m_axi_wlast   <= 1'b0;
                    s_axis_tready <= 1'b0;
                    m_axi_bready  <= 1'b1;

                    if (m_axi_bvalid && m_axi_bready) begin
                        m_axi_bready <= 1'b0;
                        if (m_axi_bresp[1])
                            o_wr_error <= 1'b1;

                        // Advance address for the next burst
                        m_axi_awaddr <= m_axi_awaddr +
                                        (wr_burst_len + 1) * BYTES_PER_BEAT;
                    end
                end

                // ---------------------------------------------------------
                WR_DONE: begin
                    o_wr_done     <= 1'b1;
                    m_axi_wvalid  <= 1'b0;
                    m_axi_bready  <= 1'b0;
                    s_axis_tready <= 1'b0;
                end
            endcase
        end
    end

endmodule
