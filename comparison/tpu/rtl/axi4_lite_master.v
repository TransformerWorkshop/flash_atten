module axi4_lite_master #(
    parameter AXI_DATA_WIDTH = 32, 
    parameter AXI_ADDR_WIDTH = 8  
)(
    input  wire                            m_axil_aclk     ,
    input  wire                            m_axil_aresetn  ,
    
    // 写地址通道
    output wire [      AXI_ADDR_WIDTH-1:0] m_axil_awaddr   ,
    output wire                            m_axil_awvalid  ,
    input  wire                            m_axil_awready  ,
    
    // 写数据通道
    output wire [      AXI_DATA_WIDTH-1:0] m_axil_wdata    ,
    output wire [    AXI_DATA_WIDTH/8-1:0] m_axil_wstrb    ,
    output wire                            m_axil_wvalid   ,
    input  wire                            m_axil_wready   ,
    
    // 写响应通道
    input  wire [                     1:0] m_axil_bresp    ,
    input  wire                            m_axil_bvalid   ,
    output wire                            m_axil_bready   ,
    
    // 读地址通道
    output wire [      AXI_ADDR_WIDTH-1:0] m_axil_araddr   ,
    output wire                            m_axil_arvalid  ,
    input  wire                            m_axil_arready  ,
    
    // 读数据通道
    input  wire [      AXI_DATA_WIDTH-1:0] m_axil_rdata    ,
    input  wire [                     1:0] m_axil_rresp    ,
    input  wire                            m_axil_rvalid   ,
    output wire                            m_axil_rready   ,
    
    // 用户接口 - 写请求
    input  wire                            usr_wr_req      ,
    input  wire [      AXI_ADDR_WIDTH-1:0] usr_wr_addr     ,
    input  wire [      AXI_DATA_WIDTH-1:0] usr_wr_data     ,
    input  wire [    AXI_DATA_WIDTH/8-1:0] usr_wr_strb     ,
    output wire                            usr_wr_done     ,
    output wire                            usr_wr_error    ,
    
    // 用户接口 - 读请求
    input  wire                            usr_rd_req      ,
    input  wire [      AXI_ADDR_WIDTH-1:0] usr_rd_addr     ,
    output wire [      AXI_DATA_WIDTH-1:0] usr_rd_data     ,
    output wire                            usr_rd_done     ,
    output wire                            usr_rd_error     
);

    localparam RESP_OKAY   = 2'b00;    // OK响应
    localparam RESP_SLVERR = 2'b10;    // Slave错误响应
    
    // 状态机定义
    localparam IDLE       = 2'b00;
    localparam ADDR_PHASE = 2'b01;
    localparam DATA_PHASE = 2'b10;
    localparam RESP_PHASE = 2'b11;

    // 写状态机
    reg [1:0] wr_state;
    reg [AXI_ADDR_WIDTH-1:0] axi_awaddr;
    reg axi_awvalid;
    reg [AXI_DATA_WIDTH-1:0] axi_wdata;
    reg [AXI_DATA_WIDTH/8-1:0] axi_wstrb;
    reg axi_wvalid;
    reg axi_bready;
    reg usr_wr_done_r;
    reg usr_wr_error_r;
    
    // 读状态机
    reg [1:0] rd_state;
    reg [AXI_ADDR_WIDTH-1:0] axi_araddr;
    reg axi_arvalid;
    reg axi_rready;
    reg [AXI_DATA_WIDTH-1:0] usr_rd_data_r;
    reg usr_rd_done_r;
    reg usr_rd_error_r;

    // 输出赋值
    assign m_axil_awaddr  = axi_awaddr;
    assign m_axil_awvalid = axi_awvalid;
    assign m_axil_wdata   = axi_wdata;
    assign m_axil_wstrb   = axi_wstrb;
    assign m_axil_wvalid  = axi_wvalid;
    assign m_axil_bready  = axi_bready;
    
    assign m_axil_araddr  = axi_araddr;
    assign m_axil_arvalid = axi_arvalid;
    assign m_axil_rready  = axi_rready;
    
    assign usr_wr_done    = usr_wr_done_r;
    assign usr_wr_error   = usr_wr_error_r;
    assign usr_rd_data    = usr_rd_data_r;
    assign usr_rd_done    = usr_rd_done_r;
    assign usr_rd_error   = usr_rd_error_r;

    // 写状态机实现
    always @(posedge m_axil_aclk or negedge m_axil_aresetn) begin
        if (!m_axil_aresetn) begin
            wr_state       <= IDLE;
            axi_awaddr     <= {AXI_ADDR_WIDTH{1'b0}};
            axi_awvalid    <= 1'b0;
            axi_wdata      <= {AXI_DATA_WIDTH{1'b0}};
            axi_wstrb      <= {(AXI_DATA_WIDTH/8){1'b0}};
            axi_wvalid     <= 1'b0;
            axi_bready     <= 1'b0;
            usr_wr_done_r  <= 1'b0;
            usr_wr_error_r <= 1'b0;
        end else begin
            // 默认每个周期复位用户完成信号
            usr_wr_done_r  <= 1'b0;
            usr_wr_error_r <= 1'b0;
            
            case (wr_state)
                IDLE: begin
                    if (usr_wr_req) begin
                        // 加载用户提供的写请求参数
                        axi_awaddr  <= usr_wr_addr;
                        axi_awvalid <= 1'b1;
                        axi_wdata   <= usr_wr_data;
                        axi_wstrb   <= usr_wr_strb;
                        axi_wvalid  <= 1'b1;
                        wr_state    <= ADDR_PHASE;
                    end
                end
                
                ADDR_PHASE: begin
                    // 等待地址和数据通道就绪信号
                    if (m_axil_awready && axi_awvalid) begin
                        axi_awvalid <= 1'b0;
                    end
                    
                    if (m_axil_wready && axi_wvalid) begin
                        axi_wvalid <= 1'b0;
                    end
                    
                    // 当地址和数据都被接收后，进入响应阶段
                    if ((axi_awvalid == 1'b0 || m_axil_awready == 1'b1) && 
                        (axi_wvalid == 1'b0 || m_axil_wready == 1'b1)) begin
                        axi_bready <= 1'b1;
                        wr_state   <= RESP_PHASE;
                    end
                end
                
                RESP_PHASE: begin
                    // 等待写响应
                    if (m_axil_bvalid && axi_bready) begin
                        axi_bready     <= 1'b0;
                        usr_wr_done_r  <= 1'b1;
                        usr_wr_error_r <= (m_axil_bresp != RESP_OKAY);
                        wr_state       <= IDLE;
                    end
                end
                
                default: begin
                    wr_state <= IDLE;
                end
            endcase
        end
    end

    // 读状态机实现
    always @(posedge m_axil_aclk or negedge m_axil_aresetn) begin
        if (!m_axil_aresetn) begin
            rd_state       <= IDLE;
            axi_araddr     <= {AXI_ADDR_WIDTH{1'b0}};
            axi_arvalid    <= 1'b0;
            axi_rready     <= 1'b0;
            usr_rd_data_r  <= {AXI_DATA_WIDTH{1'b0}};
            usr_rd_done_r  <= 1'b0;
            usr_rd_error_r <= 1'b0;
        end else begin
            // 默认每个周期复位用户完成信号
            usr_rd_done_r  <= 1'b0;
            usr_rd_error_r <= 1'b0;
            
            case (rd_state)
                IDLE: begin
                    if (usr_rd_req) begin
                        // 加载用户提供的读请求参数
                        axi_araddr  <= usr_rd_addr;
                        axi_arvalid <= 1'b1;
                        rd_state    <= ADDR_PHASE;
                    end
                end
                
                ADDR_PHASE: begin
                    // 等待地址通道就绪信号
                    if (m_axil_arready && axi_arvalid) begin
                        axi_arvalid <= 1'b0;
                        axi_rready  <= 1'b1;
                        rd_state    <= DATA_PHASE;
                    end
                end
                
                DATA_PHASE: begin
                    // 等待数据通道有效信号
                    if (m_axil_rvalid && axi_rready) begin
                        axi_rready     <= 1'b0;
                        usr_rd_data_r  <= m_axil_rdata;
                        usr_rd_done_r  <= 1'b1;
                        usr_rd_error_r <= (m_axil_rresp != RESP_OKAY);
                        rd_state       <= IDLE;
                    end
                end
                
                default: begin
                    rd_state <= IDLE;
                end
            endcase
        end
    end

endmodule