// =============================================================================
// CSR Array with AXI4-Lite Slave Interface
// Flash-Attention Accelerator – Control / Status Registers
// =============================================================================

module csr_array #(
    parameter DATA_W   = 32,
    parameter ADDR_W   = 7,       // covers 0x00 – 0x48
    parameter STRB_W   = DATA_W/8
)(
    input  wire                 aclk,
    input  wire                 aresetn,

    // ---- AXI4-Lite Write Address Channel ----
    input  wire [ADDR_W-1:0]   s_axi_awaddr,
    input  wire [2:0]          s_axi_awprot,
    input  wire                s_axi_awvalid,
    output reg                 s_axi_awready,

    // ---- AXI4-Lite Write Data Channel ----
    input  wire [DATA_W-1:0]   s_axi_wdata,
    input  wire [STRB_W-1:0]   s_axi_wstrb,
    input  wire                s_axi_wvalid,
    output reg                 s_axi_wready,

    // ---- AXI4-Lite Write Response Channel ----
    output reg  [1:0]          s_axi_bresp,
    output reg                 s_axi_bvalid,
    input  wire                s_axi_bready,

    // ---- AXI4-Lite Read Address Channel ----
    input  wire [ADDR_W-1:0]   s_axi_araddr,
    input  wire [2:0]          s_axi_arprot,
    input  wire                s_axi_arvalid,
    output reg                 s_axi_arready,

    // ---- AXI4-Lite Read Data Channel ----
    output reg  [DATA_W-1:0]   s_axi_rdata,
    output reg  [1:0]          s_axi_rresp,
    output reg                 s_axi_rvalid,
    input  wire                s_axi_rready,

    // ---- CSR outputs to datapath ----
    output wire                o_start,
    output wire                o_soft_reset,
    output wire                o_irq_en,
    output wire                o_causal_en,
    output wire [63:0]         o_q_base,
    output wire [63:0]         o_k_base,
    output wire [63:0]         o_v_base,
    output wire [63:0]         o_o_base,
    output wire [DATA_W-1:0]   o_stride_bytes,
    output wire [DATA_W-1:0]   o_neg_large,
    output wire [DATA_W-1:0]   o_scale,

    // ---- CSR inputs from datapath ----
    input  wire                i_busy,
    input  wire                i_done,
    input  wire                i_error,
    input  wire [DATA_W-1:0]   i_cycles,
    input  wire [DATA_W-1:0]   i_rd_bytes,
    input  wire [DATA_W-1:0]   i_wr_bytes
);

    // =========================================================================
    // Register Offset Definitions
    // =========================================================================
    localparam ADDR_CTRL         = 7'h00;
    localparam ADDR_STATUS       = 7'h04;
    localparam ADDR_CFG          = 7'h08;
    localparam ADDR_Q_BASE_L     = 7'h14;
    localparam ADDR_Q_BASE_H     = 7'h18;
    localparam ADDR_K_BASE_L     = 7'h1C;
    localparam ADDR_K_BASE_H     = 7'h20;
    localparam ADDR_V_BASE_L     = 7'h24;
    localparam ADDR_V_BASE_H     = 7'h28;
    localparam ADDR_O_BASE_L     = 7'h2C;
    localparam ADDR_O_BASE_H     = 7'h30;
    localparam ADDR_STRIDE_BYTES = 7'h34;
    localparam ADDR_NEG_LARGE    = 7'h38;
    localparam ADDR_SCALE        = 7'h3C;
    localparam ADDR_CYCLES       = 7'h40;
    localparam ADDR_RD_BYTES     = 7'h44;
    localparam ADDR_WR_BYTES     = 7'h48;

    // =========================================================================
    // R/W Registers
    // =========================================================================
    reg [DATA_W-1:0] reg_ctrl;
    reg [DATA_W-1:0] reg_cfg;
    reg [DATA_W-1:0] reg_q_base_l;
    reg [DATA_W-1:0] reg_q_base_h;
    reg [DATA_W-1:0] reg_k_base_l;
    reg [DATA_W-1:0] reg_k_base_h;
    reg [DATA_W-1:0] reg_v_base_l;
    reg [DATA_W-1:0] reg_v_base_h;
    reg [DATA_W-1:0] reg_o_base_l;
    reg [DATA_W-1:0] reg_o_base_h;
    reg [DATA_W-1:0] reg_stride_bytes;
    reg [DATA_W-1:0] reg_neg_large;
    reg [DATA_W-1:0] reg_scale;

    // =========================================================================
    // CSR Output Assignments
    // =========================================================================
    assign o_start        = reg_ctrl[0];
    assign o_soft_reset   = reg_ctrl[1];
    assign o_irq_en       = reg_ctrl[2];
    assign o_causal_en    = reg_cfg[0];
    assign o_q_base       = {reg_q_base_h, reg_q_base_l};
    assign o_k_base       = {reg_k_base_h, reg_k_base_l};
    assign o_v_base       = {reg_v_base_h, reg_v_base_l};
    assign o_o_base       = {reg_o_base_h, reg_o_base_l};
    assign o_stride_bytes = reg_stride_bytes;
    assign o_neg_large    = reg_neg_large;
    assign o_scale        = reg_scale;

    // =========================================================================
    // AXI-Lite Write Logic
    // =========================================================================
    reg                aw_en;        // write-address phase enable
    reg [ADDR_W-1:0]  wr_addr;      // latched write address

    // -- AW ready --
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_awready <= 1'b0;
            aw_en         <= 1'b1;
        end else begin
            if (~s_axi_awready && s_axi_awvalid && s_axi_wvalid && aw_en) begin
                s_axi_awready <= 1'b1;
                aw_en         <= 1'b0;
            end else if (s_axi_bready && s_axi_bvalid) begin
                s_axi_awready <= 1'b0;
                aw_en         <= 1'b1;
            end else begin
                s_axi_awready <= 1'b0;
            end
        end
    end

    // -- Latch write address --
    always @(posedge aclk) begin
        if (!aresetn)
            wr_addr <= {ADDR_W{1'b0}};
        else if (~s_axi_awready && s_axi_awvalid && s_axi_wvalid && aw_en)
            wr_addr <= s_axi_awaddr;
    end

    // -- W ready --
    always @(posedge aclk) begin
        if (!aresetn)
            s_axi_wready <= 1'b0;
        else if (~s_axi_wready && s_axi_wvalid && s_axi_awvalid && aw_en)
            s_axi_wready <= 1'b1;
        else
            s_axi_wready <= 1'b0;
    end

    // -- Write strobe helper --
    wire wr_en = s_axi_wready && s_axi_wvalid && s_axi_awready && s_axi_awvalid;

    integer byte_idx;

    always @(posedge aclk) begin
        if (!aresetn) begin
            reg_ctrl         <= 32'h0;
            reg_cfg          <= 32'h0;
            reg_q_base_l     <= 32'h0;
            reg_q_base_h     <= 32'h0;
            reg_k_base_l     <= 32'h0;
            reg_k_base_h     <= 32'h0;
            reg_v_base_l     <= 32'h0;
            reg_v_base_h     <= 32'h0;
            reg_o_base_l     <= 32'h0;
            reg_o_base_h     <= 32'h0;
            reg_stride_bytes <= 32'h0;
            reg_neg_large    <= 32'h0;
            reg_scale        <= 32'h0;
        end else if (wr_en) begin
            case (wr_addr)
                ADDR_CTRL:
                    for (byte_idx = 0; byte_idx < STRB_W; byte_idx = byte_idx + 1)
                        if (s_axi_wstrb[byte_idx])
                            reg_ctrl[byte_idx*8 +: 8] <= s_axi_wdata[byte_idx*8 +: 8];
                ADDR_CFG:
                    for (byte_idx = 0; byte_idx < STRB_W; byte_idx = byte_idx + 1)
                        if (s_axi_wstrb[byte_idx])
                            reg_cfg[byte_idx*8 +: 8] <= s_axi_wdata[byte_idx*8 +: 8];
                ADDR_Q_BASE_L:
                    for (byte_idx = 0; byte_idx < STRB_W; byte_idx = byte_idx + 1)
                        if (s_axi_wstrb[byte_idx])
                            reg_q_base_l[byte_idx*8 +: 8] <= s_axi_wdata[byte_idx*8 +: 8];
                ADDR_Q_BASE_H:
                    for (byte_idx = 0; byte_idx < STRB_W; byte_idx = byte_idx + 1)
                        if (s_axi_wstrb[byte_idx])
                            reg_q_base_h[byte_idx*8 +: 8] <= s_axi_wdata[byte_idx*8 +: 8];
                ADDR_K_BASE_L:
                    for (byte_idx = 0; byte_idx < STRB_W; byte_idx = byte_idx + 1)
                        if (s_axi_wstrb[byte_idx])
                            reg_k_base_l[byte_idx*8 +: 8] <= s_axi_wdata[byte_idx*8 +: 8];
                ADDR_K_BASE_H:
                    for (byte_idx = 0; byte_idx < STRB_W; byte_idx = byte_idx + 1)
                        if (s_axi_wstrb[byte_idx])
                            reg_k_base_h[byte_idx*8 +: 8] <= s_axi_wdata[byte_idx*8 +: 8];
                ADDR_V_BASE_L:
                    for (byte_idx = 0; byte_idx < STRB_W; byte_idx = byte_idx + 1)
                        if (s_axi_wstrb[byte_idx])
                            reg_v_base_l[byte_idx*8 +: 8] <= s_axi_wdata[byte_idx*8 +: 8];
                ADDR_V_BASE_H:
                    for (byte_idx = 0; byte_idx < STRB_W; byte_idx = byte_idx + 1)
                        if (s_axi_wstrb[byte_idx])
                            reg_v_base_h[byte_idx*8 +: 8] <= s_axi_wdata[byte_idx*8 +: 8];
                ADDR_O_BASE_L:
                    for (byte_idx = 0; byte_idx < STRB_W; byte_idx = byte_idx + 1)
                        if (s_axi_wstrb[byte_idx])
                            reg_o_base_l[byte_idx*8 +: 8] <= s_axi_wdata[byte_idx*8 +: 8];
                ADDR_O_BASE_H:
                    for (byte_idx = 0; byte_idx < STRB_W; byte_idx = byte_idx + 1)
                        if (s_axi_wstrb[byte_idx])
                            reg_o_base_h[byte_idx*8 +: 8] <= s_axi_wdata[byte_idx*8 +: 8];
                ADDR_STRIDE_BYTES:
                    for (byte_idx = 0; byte_idx < STRB_W; byte_idx = byte_idx + 1)
                        if (s_axi_wstrb[byte_idx])
                            reg_stride_bytes[byte_idx*8 +: 8] <= s_axi_wdata[byte_idx*8 +: 8];
                ADDR_NEG_LARGE:
                    for (byte_idx = 0; byte_idx < STRB_W; byte_idx = byte_idx + 1)
                        if (s_axi_wstrb[byte_idx])
                            reg_neg_large[byte_idx*8 +: 8] <= s_axi_wdata[byte_idx*8 +: 8];
                ADDR_SCALE:
                    for (byte_idx = 0; byte_idx < STRB_W; byte_idx = byte_idx + 1)
                        if (s_axi_wstrb[byte_idx])
                            reg_scale[byte_idx*8 +: 8] <= s_axi_wdata[byte_idx*8 +: 8];
                default: ; // STATUS, CYCLES are read-only; unmapped → ignore
            endcase
        end
    end

    // -- Write response --
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_bvalid <= 1'b0;
            s_axi_bresp  <= 2'b00;
        end else if (wr_en && ~s_axi_bvalid) begin
            s_axi_bvalid <= 1'b1;
            s_axi_bresp  <= 2'b00;   // OKAY
        end else if (s_axi_bready && s_axi_bvalid) begin
            s_axi_bvalid <= 1'b0;
        end
    end

    // =========================================================================
    // AXI-Lite Read Logic
    // =========================================================================
    reg [ADDR_W-1:0] rd_addr;

    // -- AR ready --
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_arready <= 1'b0;
            rd_addr       <= {ADDR_W{1'b0}};
        end else if (~s_axi_arready && s_axi_arvalid) begin
            s_axi_arready <= 1'b1;
            rd_addr       <= s_axi_araddr;
        end else begin
            s_axi_arready <= 1'b0;
        end
    end

    // -- R valid / resp --
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rresp  <= 2'b00;
        end else if (s_axi_arready && s_axi_arvalid && ~s_axi_rvalid) begin
            s_axi_rvalid <= 1'b1;
            s_axi_rresp  <= 2'b00;   // OKAY
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end

    // -- Read data mux --
    reg [DATA_W-1:0] reg_rdata;

    always @(*) begin
        reg_rdata = {DATA_W{1'b0}};
        case (rd_addr)
            ADDR_CTRL:         reg_rdata = reg_ctrl;
            ADDR_STATUS:       reg_rdata = {29'b0, i_error, i_done, i_busy};
            ADDR_CFG:          reg_rdata = reg_cfg;
            ADDR_Q_BASE_L:     reg_rdata = reg_q_base_l;
            ADDR_Q_BASE_H:     reg_rdata = reg_q_base_h;
            ADDR_K_BASE_L:     reg_rdata = reg_k_base_l;
            ADDR_K_BASE_H:     reg_rdata = reg_k_base_h;
            ADDR_V_BASE_L:     reg_rdata = reg_v_base_l;
            ADDR_V_BASE_H:     reg_rdata = reg_v_base_h;
            ADDR_O_BASE_L:     reg_rdata = reg_o_base_l;
            ADDR_O_BASE_H:     reg_rdata = reg_o_base_h;
            ADDR_STRIDE_BYTES: reg_rdata = reg_stride_bytes;
            ADDR_NEG_LARGE:    reg_rdata = reg_neg_large;
            ADDR_SCALE:        reg_rdata = reg_scale;
            ADDR_CYCLES:       reg_rdata = i_cycles;
            ADDR_RD_BYTES:     reg_rdata = i_rd_bytes;
            ADDR_WR_BYTES:     reg_rdata = i_wr_bytes;
            default:           reg_rdata = {DATA_W{1'b0}};
        endcase
    end

    always @(posedge aclk) begin
        if (!aresetn)
            s_axi_rdata <= {DATA_W{1'b0}};
        else if (s_axi_arready && s_axi_arvalid && ~s_axi_rvalid)
            s_axi_rdata <= reg_rdata;
    end

endmodule
