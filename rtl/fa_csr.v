module FA_CSR (
    input  wire         aclk,
    input  wire         aresetn,
    input  wire         clear,
    input  wire [6:0]   s_axi_awaddr,
    input  wire [2:0]   s_axi_awprot,
    input  wire         s_axi_awvalid,
    output wire         s_axi_awready,
    input  wire [31:0]  s_axi_wdata,
    input  wire [3:0]   s_axi_wstrb,
    input  wire         s_axi_wvalid,
    output wire         s_axi_wready,
    output wire [1:0]   s_axi_bresp,
    output wire         s_axi_bvalid,
    input  wire         s_axi_bready,
    input  wire [6:0]   s_axi_araddr,
    input  wire [2:0]   s_axi_arprot,
    input  wire         s_axi_arvalid,
    output wire         s_axi_arready,
    output wire [31:0]  s_axi_rdata,
    output wire [1:0]   s_axi_rresp,
    output wire         s_axi_rvalid,
    input  wire         s_axi_rready,
    input  wire         status_busy,
    input  wire         status_done,
    input  wire         status_error,
    input  wire [31:0]  status_cycles,
    output wire         start_level,
    output wire         start_pulse,
    output wire         soft_reset_level,
    output wire         soft_reset_pulse,
    output wire         irq_en,
    output wire         causal_en,
    output wire [63:0]  q_base,
    output wire [63:0]  k_base,
    output wire [63:0]  v_base,
    output wire [63:0]  o_base,
    output wire [31:0]  stride_bytes,
    output wire [31:0]  neg_large,
    output wire [31:0]  scale
);

    reg start_prev_r;
    reg soft_reset_prev_r;

    wire start_level_w;
    wire soft_reset_level_w;

    assign start_level = start_level_w;
    assign soft_reset_level = soft_reset_level_w;
    assign start_pulse = start_level_w && !start_prev_r;
    assign soft_reset_pulse = soft_reset_level_w && !soft_reset_prev_r;

    csr_array #(
        .DATA_W(32),
        .ADDR_W(7),
        .STRB_W(4)
    ) u_csr_array (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arprot(s_axi_arprot),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .o_start(start_level_w),
        .o_soft_reset(soft_reset_level_w),
        .o_irq_en(irq_en),
        .o_causal_en(causal_en),
        .o_q_base(q_base),
        .o_k_base(k_base),
        .o_v_base(v_base),
        .o_o_base(o_base),
        .o_stride_bytes(stride_bytes),
        .o_neg_large(neg_large),
        .o_scale(scale),
        .i_busy(status_busy),
        .i_done(status_done),
        .i_error(status_error),
        .i_cycles(status_cycles)
    );

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            start_prev_r <= 1'b0;
            soft_reset_prev_r <= 1'b0;
        end else if (clear) begin
            start_prev_r <= 1'b0;
            soft_reset_prev_r <= 1'b0;
        end else begin
            start_prev_r <= start_level_w;
            soft_reset_prev_r <= soft_reset_level_w;
        end
    end

endmodule
