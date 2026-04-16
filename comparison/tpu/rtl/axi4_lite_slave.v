module axi4_lite_slave #(
    parameter AXI_DATA_WIDTH = 32, 
    parameter AXI_ADDR_WIDTH = 8  
)(
    input  wire                            s_axil_aclk     ,
    input  wire                            s_axil_aresetn  ,
    
    // 写地址通道
    input  wire [      AXI_ADDR_WIDTH-1:0] s_axil_awaddr   ,
    input  wire                            s_axil_awvalid  ,
    output wire                            s_axil_awready  ,
    
    // 写数据通道
    input  wire [      AXI_DATA_WIDTH-1:0] s_axil_wdata    ,
    input  wire [    AXI_DATA_WIDTH/8-1:0] s_axil_wstrb    ,
    input  wire                            s_axil_wvalid   ,
    output wire                            s_axil_wready   ,
    
    // 写响应通道
    output wire [                     1:0] s_axil_bresp    ,
    output wire                            s_axil_bvalid   ,
    input  wire                            s_axil_bready   ,
    
    // 读地址通道
    input  wire [      AXI_ADDR_WIDTH-1:0] s_axil_araddr   ,
    input  wire                            s_axil_arvalid  ,
    output wire                            s_axil_arready  ,
    
    // 读数据通道
    output wire [      AXI_DATA_WIDTH-1:0] s_axil_rdata    ,
    output wire [                     1:0] s_axil_rresp    ,
    output wire                            s_axil_rvalid   ,
    input  wire                            s_axil_rready   ,
    
    // CSR接口信号
    output wire                            csr_wr_en       ,
    output wire [      AXI_ADDR_WIDTH-1:0] csr_wr_addr     ,
    output wire [      AXI_DATA_WIDTH-1:0] csr_wr_data     ,
    output wire [    AXI_DATA_WIDTH/8-1:0] csr_wr_strb     ,
    output wire                            csr_rd_en       ,
    output wire [      AXI_ADDR_WIDTH-1:0] csr_rd_addr     ,
    input  wire [      AXI_DATA_WIDTH-1:0] csr_rd_data      
);

    localparam RESP_OKAY   = 2'b00;    // OK响应
    localparam RESP_SLVERR = 2'b10;    // Slave错误响应
    
    // 状态机定义
    localparam IDLE = 2'b00;
    localparam BUSY = 2'b01;
    localparam RESP = 2'b10;

    // 状态机寄存器
    reg [                   1:0] write_state   ;
    reg [                   1:0] read_state    ;
    
    // 写通道信号
    reg                          axi_awready   ;
    reg                          axi_wready    ;
    reg                          axi_bvalid    ;
    reg [                   1:0] axi_bresp     ;
    reg                          csr_wr_en_r   ;
    reg [    AXI_ADDR_WIDTH-1:0] csr_wr_addr_r ;
    reg [    AXI_DATA_WIDTH-1:0] csr_wr_data_r ;
    reg [  AXI_DATA_WIDTH/8-1:0] csr_wr_strb_r ;    

    // 读通道信号
    reg                          axi_arready   ;
    reg                          axi_rvalid    ;
    reg [                   1:0] axi_rresp     ;
    reg [    AXI_DATA_WIDTH-1:0] axi_rdata     ;

    assign s_axil_awready = axi_awready;
    assign s_axil_wready  = axi_wready ;
    assign s_axil_bresp   = axi_bresp  ;
    assign s_axil_bvalid  = axi_bvalid ;
    
    assign s_axil_arready = axi_arready;
    assign s_axil_rdata   = csr_rd_data;
    assign s_axil_rresp   = axi_rresp  ;
    assign s_axil_rvalid  = axi_rvalid ;

    assign csr_wr_en      = csr_wr_en_r  ;
    assign csr_wr_addr    = csr_wr_addr_r;
    assign csr_wr_data    = csr_wr_data_r;
    assign csr_wr_strb    = csr_wr_strb_r;

    assign csr_rd_addr    = s_axil_araddr;
    assign csr_rd_en      = s_axil_arvalid && axi_arready;
    
    
    // 写地址 写数据 写响应状态机
    // Fix: gate awready/wready on BOTH channels being valid simultaneously.
    // The Xilinx SmartConnect (AXI4→AXI4-Lite converter) may present awvalid
    // and wvalid in different clock cycles.  The old code asserted awready/wready
    // unconditionally in IDLE, so the AW handshake could complete in one cycle
    // while W had not yet arrived (or vice-versa).  The address/data were never
    // captured, BVALID was never driven, and the PS AXI write path hung forever.
    // Solution: only assert awready when BOTH awvalid AND wvalid are present,
    // preventing either channel from handshaking before both are ready.
    always @(posedge s_axil_aclk or negedge s_axil_aresetn) begin
        if (!s_axil_aresetn) begin
            axi_awready    <= 1'b0;
            csr_wr_addr_r  <= {AXI_ADDR_WIDTH{1'b0}};
            axi_wready     <= 1'b0;
            csr_wr_data_r  <= {AXI_DATA_WIDTH{1'b0}};
            csr_wr_strb_r  <= {(AXI_DATA_WIDTH/8){1'b0}};
            csr_wr_en_r    <= 1'b0;
            axi_bvalid     <= 1'b0;
            axi_bresp      <= RESP_OKAY;
            write_state    <= IDLE;
        end else begin
            case (write_state)
                IDLE: begin
                    if (s_axil_awvalid && axi_awready && s_axil_wvalid && axi_wready) begin
                        // Both channels handshaked simultaneously — capture and respond
                        csr_wr_addr_r  <= s_axil_awaddr;
                        csr_wr_data_r  <= s_axil_wdata;
                        csr_wr_strb_r  <= s_axil_wstrb;
                        csr_wr_en_r    <= 1'b1;
                        axi_awready    <= 1'b0;
                        axi_wready     <= 1'b0;
                        axi_bvalid     <= 1'b1;
                        axi_bresp      <= RESP_OKAY;
                        write_state    <= RESP;
                    end else begin
                        // Only assert ready when BOTH channels are valid,
                        // preventing a partial handshake that loses the address or data.
                        axi_awready    <= s_axil_awvalid & s_axil_wvalid;
                        axi_wready     <= s_axil_awvalid & s_axil_wvalid;
                        write_state    <= IDLE;
                    end
                end
                
                RESP: begin
                    csr_wr_en_r <= 1'b0;
                    axi_awready <= 1'b0;
                    axi_wready  <= 1'b0;

                    if (s_axil_bready && axi_bvalid) begin
                        axi_bvalid  <= 1'b0;
                        write_state <= IDLE;
                    end
                end
                
                default: begin
                    axi_awready <= 1'b0;
                    axi_wready  <= 1'b0;
                    csr_wr_en_r <= 1'b0;
                    write_state <= IDLE;
                end
            endcase
        end
    end


    // 读地址 读数据状态机
    always @(posedge s_axil_aclk or negedge s_axil_aresetn) begin
        if (!s_axil_aresetn) begin
            axi_arready   <= 1'b0;
            axi_rvalid    <= 1'b0;
            axi_rresp     <= RESP_OKAY;
            axi_rdata     <= {AXI_DATA_WIDTH{1'b0}};
            read_state    <= IDLE;
        end else begin
            case (read_state)
                IDLE: begin
                    if (s_axil_arvalid && axi_arready) begin
                        axi_arready   <= 1'b0;
                        axi_rvalid    <= 1'b1;
                        read_state    <= BUSY;
                    end else begin
                        axi_arready   <= 1'b1;
                        read_state    <= IDLE;
                    end
                end
                
                BUSY: begin
                    axi_arready <= 1'b0;
                    axi_rresp   <= RESP_OKAY;  // 所有读操作都成功
                    if (s_axil_rready && axi_rvalid) begin
                        axi_rvalid <= 1'b0;
                        read_state <= IDLE;
                    end
                end
                
                default: begin
                    read_state <= IDLE;
                end
            endcase
        end
    end

endmodule