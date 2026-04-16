module save_axi_data_to_d_ram #(
    parameter AXI_ID_WIDTH   = 4 ,
    parameter AXI_ADDR_WIDTH = 32,
    parameter AXI_DATA_WIDTH = 64,
    parameter RAM_DATA_WIDTH = 64,
    parameter RAM_ADDR_WIDTH = 13  
) (
    input  wire                              clk              ,
    input  wire                              rst_n            ,

    // AXI写地址通道
    input  wire [        AXI_ADDR_WIDTH-1:0] m_axi_awaddr     ,
    input  wire                              m_axi_awvalid    ,
    output wire                              m_axi_awready    ,

    // AXI写数据通道
    input  wire [        AXI_DATA_WIDTH-1:0] m_axi_wdata      ,
    input  wire [    (AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb      ,
    input  wire                              m_axi_wlast      ,
    input  wire                              m_axi_wvalid     ,
    output wire                              m_axi_wready     ,

    // AXI写响应通道
    output reg  [          AXI_ID_WIDTH-1:0] m_axi_bid        ,
    output reg  [                       1:0] m_axi_bresp      ,
    output reg                               m_axi_bvalid     ,
    input  wire                              m_axi_bready     ,

    input  wire                              ram_d_rd_en      ,
    input  wire [      RAM_ADDR_WIDTH-1 : 0] ram_d_rd_addr    ,
    output wire [      RAM_DATA_WIDTH-1 : 0] ram_d_rd_data    ,

    output wire                              save_d_done       
);

    assign save_d_done = m_axi_wvalid && m_axi_wready && m_axi_wlast;

    // 定义RAM写地址寄存器和写使能信号
    reg [RAM_ADDR_WIDTH-1:0] wr_addr;
    reg [RAM_ADDR_WIDTH-1:0] wr_addr_base;
    wire wr_en;
    
    // 写使能信号 - 当AXI握手成功时使能
    assign wr_en = m_axi_wvalid && m_axi_wready;
    
    // 将AXI数据直接连接到RAM
    wire [RAM_DATA_WIDTH-1:0] wr_data;
    wire [(RAM_DATA_WIDTH/8)-1:0] wr_strb;
    
    assign wr_data = m_axi_wdata;
    assign wr_strb = m_axi_wstrb;

    assign m_axi_awready = 1'b1; // 总是准备好接收写地址
    assign m_axi_wready  = 1'b1; // 总是准备好接收写数据

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_addr <= {RAM_ADDR_WIDTH{1'b0}}; // 复位时地址清零
            wr_addr_base <= {RAM_ADDR_WIDTH{1'b0}};
            m_axi_bvalid <= 1'b0;
            m_axi_bid <= {AXI_ID_WIDTH{1'b0}};
            m_axi_bresp <= 2'b00;
        end else begin
            if (m_axi_wvalid && m_axi_wready) begin
                // 每次握手成功时，地址加1
                wr_addr <= wr_addr + 1'b1;
            end 
            // else begin
            //     wr_addr <= wr_addr_base;
            // end
            
            // AXI写响应逻辑
            if (m_axi_wvalid && m_axi_wready && m_axi_wlast) begin
                m_axi_bvalid <= 1'b1;
                m_axi_bid    <= 4'h0;  // 占位符ID
                m_axi_bresp  <= 2'b00;  // OKAY响应
                wr_addr_base <= wr_addr_base + 128;
            end else if (m_axi_bvalid && m_axi_bready) begin
                m_axi_bvalid <= 1'b0;
            end
        end
    end

    sdp_ram #(
        .RAM_DATA_WIDTH (RAM_DATA_WIDTH),
        .RAM_ADDR_WIDTH (RAM_ADDR_WIDTH)
    ) output_d_ram_inst(
        .clk                  (clk),
        .wr_en                (wr_en),
        .wr_addr              (wr_addr),
        .wr_data              (wr_data),
        .wr_strb              (wr_strb),
        .rd_en                (ram_d_rd_en),
        .rd_addr              (ram_d_rd_addr),
        .rd_data              (ram_d_rd_data)
    );

endmodule