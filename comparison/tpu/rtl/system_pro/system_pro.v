module system_pro (
    input  wire         sys_clk_p ,
    input  wire         sys_clk_n ,
    input  wire         rst       ,
    
    input  wire         key_start ,
    output wire         led_done  ,

    input  wire         uart_rx   ,
    output wire         uart_tx    
);

    // 参数定义
    parameter AXI_ID_WIDTH         = 4;
    parameter AXI_ADDR_WIDTH       = 32;
    parameter AXI_DATA_WIDTH       = 64;
    parameter AXI_AWUSER_WIDTH     = 1;
    parameter AXI_WUSER_WIDTH      = 1;
    parameter AXI_BUSER_WIDTH      = 1;

    parameter CSR_DATA_WIDTH       = 32;
    parameter CSR_ADDR_WIDTH       = 8 ;

    parameter PE_SIZE              = 16;
    parameter MATRIX_DIM_WIDTH     = 8;
    parameter PRECISION_MODE_WIDTH = 4;
    parameter RAM_ADDR_WIDTH       = 5;
    parameter RAM_C_ADDR_WIDTH     = 4;
    parameter RAM_D_ADDR_WIDTH     = 4;
    parameter RAM_DATA_WIDTH       = 64;
    parameter FIFO_DATA_WIDTH      = 32;
    parameter FIFO_DEPTH           = 32;
    parameter MATRIX_A_BASE_ADDR   = 32'h0000_0000;
    parameter MATRIX_B_BASE_ADDR   = 32'h0000_4000;
    parameter MATRIX_C_BASE_ADDR   = 32'h0000_8000;
    parameter MATRIX_D_BASE_ADDR   = 32'h0000_C000;

    parameter DATA_WIDTH           = 32;
    
    // AXI突发传输最大长度 (0-255)
    parameter MAX_BURST_LEN = 255;

    localparam ALL_MATRIX_ADDR_WIDTH          = 13;
    localparam ALL_MATRIX_DATA_WIDTH          = 64;
    
    
    wire                              clk;

    wire                              rst_n;

    assign rst_n = ~rst;

    // AXI-Full-Slave接口信号
    // 写地址通道
    wire [          AXI_ID_WIDTH-1:0] s_axi_awid;
    wire [        AXI_ADDR_WIDTH-1:0] s_axi_awaddr;
    wire [                       7:0] s_axi_awlen;
    wire [                       2:0] s_axi_awsize;
    wire [                       1:0] s_axi_awburst;
    wire                              s_axi_awlock;
    wire [                       3:0] s_axi_awcache;
    wire [                       2:0] s_axi_awprot;
    wire [                       3:0] s_axi_awqos;
    wire [                       3:0] s_axi_awregion;
    wire [      AXI_AWUSER_WIDTH-1:0] s_axi_awuser;
    wire                              s_axi_awvalid;
    wire                              s_axi_awready;

    // 写数据通道
    wire [        AXI_DATA_WIDTH-1:0] s_axi_wdata;
    wire [    (AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb;
    wire                              s_axi_wlast;
    wire [       AXI_WUSER_WIDTH-1:0] s_axi_wuser;
    wire                              s_axi_wvalid;
    wire                              s_axi_wready;

    // 写响应通道
    wire [          AXI_ID_WIDTH-1:0] s_axi_bid;
    wire [                       1:0] s_axi_bresp;
    wire [       AXI_BUSER_WIDTH-1:0] s_axi_buser;
    wire                              s_axi_bvalid;
    wire                              s_axi_bready;

    
    // AXI-Lite-Slave接口信号
    // 写地址通道
    wire [                     7:0]   s_axil_awaddr;
    wire                              s_axil_awvalid;
    wire                              s_axil_awready;
    
    // 写数据通道
    wire [        CSR_DATA_WIDTH-1:0] s_axil_wdata;
    wire [    (CSR_DATA_WIDTH/8)-1:0] s_axil_wstrb;
    wire                              s_axil_wvalid;
    wire                              s_axil_wready;
    
    // 写响应通道
    wire [                      1:0]  s_axil_bresp;
    wire                              s_axil_bvalid;
    wire                              s_axil_bready;
    
    // 读地址通道
    wire  [                     7:0]  s_axil_araddr;
    wire                              s_axil_arvalid;
    wire                              s_axil_arready;
    
    // 读数据通道
    wire [        CSR_DATA_WIDTH-1:0] s_axil_rdata;
    wire [                      1:0]  s_axil_rresp;
    wire                              s_axil_rvalid;
    wire                              s_axil_rready;
    
    // AXI-Master接口信号
    wire [          AXI_ID_WIDTH-1:0] m_axi_awid;
    wire [        AXI_ADDR_WIDTH-1:0] m_axi_awaddr;
    wire [                       7:0] m_axi_awlen;
    wire [                       2:0] m_axi_awsize;
    wire [                       1:0] m_axi_awburst;
    wire                              m_axi_awlock;
    wire [                       3:0] m_axi_awcache;
    wire [                       2:0] m_axi_awprot;
    wire [                       3:0] m_axi_awqos;
    wire [                       3:0] m_axi_awregion;
    wire [      AXI_AWUSER_WIDTH-1:0] m_axi_awuser;
    wire                              m_axi_awvalid;
    wire                              m_axi_awready;
    
    wire [        AXI_DATA_WIDTH-1:0] m_axi_wdata;
    wire [    (AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb;
    wire                              m_axi_wlast;
    wire [       AXI_WUSER_WIDTH-1:0] m_axi_wuser;
    wire                              m_axi_wvalid;
    wire                              m_axi_wready;
    
    wire [          AXI_ID_WIDTH-1:0] m_axi_bid;
    wire [                       1:0] m_axi_bresp;
    wire [       AXI_BUSER_WIDTH-1:0] m_axi_buser;
    wire                              m_axi_bvalid;
    wire                              m_axi_bready;


    wire                              axi_rd_en;
    wire [13-1:0]                     axi_rd_addr;  
    wire [63:0]                       axi_rd_data; 
    wire                              axi_rd_data_vld;

    wire                              transfer_start;
    wire [15:0]                       transfer_count;
    wire [31:0]                       ram_base_addr;
    wire [31:0]                       axi_target_addr;
    wire                              transfer_done;


    wire                              usr_wr_req   ;
    wire [        CSR_ADDR_WIDTH-1:0] usr_wr_addr  ;
    wire [        CSR_DATA_WIDTH-1:0] usr_wr_data  ;
    wire [      CSR_DATA_WIDTH/8-1:0] usr_wr_strb  ;
    wire                              usr_wr_done  ;
    wire                              usr_wr_error ;
    
    // 用户接口 - 读请求
    wire                              usr_rd_req   ;
    wire [        CSR_ADDR_WIDTH-1:0] usr_rd_addr  ;
    wire [        CSR_DATA_WIDTH-1:0] usr_rd_data  ;
    wire                              usr_rd_done  ;
    wire                              usr_rd_error ;

    wire                              ram_d_rd_en      ;
    wire [                  13-1 : 0] ram_d_rd_addr    ;
    wire [                  64-1 : 0] ram_d_rd_data    ;
    wire                              save_d_done      ;

    wire                      [3 : 0] uart_axi_awaddr  ;
    wire                              uart_axi_awvalid ;
    wire                              uart_axi_awready ;
    wire                     [31 : 0] uart_axi_wdata   ;
    wire                      [3 : 0] uart_axi_wstrb   ;
    wire                              uart_axi_wvalid  ;
    wire                              uart_axi_wready  ;
    wire                      [1 : 0] uart_axi_bresp   ;
    wire                              uart_axi_bvalid  ;
    wire                              uart_axi_bready  ;
    wire                      [3 : 0] uart_axi_araddr  ;
    wire                              uart_axi_arvalid ;
    wire                              uart_axi_arready ;
    wire                     [31 : 0] uart_axi_rdata   ;
    wire                      [1 : 0] uart_axi_rresp   ;
    wire                              uart_axi_rvalid  ;
    wire                              uart_axi_rready  ;


    wire                              uart_tx_start    ;
    wire [                    64-1:0] uart_tx_cfg_data ;
    wire [                    13-1:0] uart_tx_cfg_addr ;
    wire [                      15:0] uart_tx_cfg_count;
    wire                              uart_tx_done     ;
    wire                              uart_tx_busy     ;

    wire                              fifo_full        ;
    wire                              fifo_empty       ;
    wire                              fifo_almost_full ;
    wire                              fifo_almost_empty;
    wire                              fifo_rd_en       ;
    wire [                    8-1:0]  fifo_data_out    ;

    clk_wiz_0 clk_wiz_0_inst (
        // Clock out ports
        .clk_out1(clk),            // output clk_out1
        // Status and control signals
        .resetn(rst_n),            // input resetn
        .locked(),                 // output locked
        // Clock in ports
        .clk_in1_p(sys_clk_p),     // input clk_in1_p
        .clk_in1_n(sys_clk_n)      // input clk_in1_n
    );    

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
        .MATRIX_DIM_WIDTH     (MATRIX_DIM_WIDTH),   // 矩阵维度宽度
        .PRECISION_MODE_WIDTH (PRECISION_MODE_WIDTH), // 精度模式宽度
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
    ) tpu_top_inst (
        .clk                  (clk),
        .rst_n                (rst_n),
        
        .s_axi_awid           (s_axi_awid),
        .s_axi_awaddr         (s_axi_awaddr),
        .s_axi_awlen          (s_axi_awlen),
        .s_axi_awsize         (s_axi_awsize),
        .s_axi_awburst        (s_axi_awburst),
        .s_axi_awlock         (s_axi_awlock),
        .s_axi_awcache        (s_axi_awcache),
        .s_axi_awprot         (s_axi_awprot),
        .s_axi_awqos          (s_axi_awqos),
        .s_axi_awregion       (s_axi_awregion),
        .s_axi_awuser         (s_axi_awuser),
        .s_axi_awvalid        (s_axi_awvalid),
        .s_axi_awready        (s_axi_awready),
        
        .s_axi_wdata          (s_axi_wdata),
        .s_axi_wstrb          (s_axi_wstrb),
        .s_axi_wlast          (s_axi_wlast),
        .s_axi_wuser          (s_axi_wuser),
        .s_axi_wvalid         (s_axi_wvalid),
        .s_axi_wready         (s_axi_wready),
        
        .s_axi_bid            (s_axi_bid),
        .s_axi_bresp          (s_axi_bresp),
        .s_axi_buser          (s_axi_buser),
        .s_axi_bvalid         (s_axi_bvalid),
        .s_axi_bready         (s_axi_bready),
        
        .s_axil_awaddr        (s_axil_awaddr),
        .s_axil_awvalid       (s_axil_awvalid),
        .s_axil_awready       (s_axil_awready),
        
        .s_axil_wdata         (s_axil_wdata),
        .s_axil_wstrb         (s_axil_wstrb),
        .s_axil_wvalid        (s_axil_wvalid),
        .s_axil_wready        (s_axil_wready),
        
        .s_axil_bresp         (s_axil_bresp),
        .s_axil_bvalid        (s_axil_bvalid),
        .s_axil_bready        (s_axil_bready),
        
        .s_axil_araddr        (s_axil_araddr),
        .s_axil_arvalid       (s_axil_arvalid),
        .s_axil_arready       (s_axil_arready),
        
        .s_axil_rdata         (s_axil_rdata),
        .s_axil_rresp         (s_axil_rresp),
        .s_axil_rvalid        (s_axil_rvalid),
        .s_axil_rready        (s_axil_rready),
        
        .m_axi_awid           (m_axi_awid),
        .m_axi_awaddr         (m_axi_awaddr),
        .m_axi_awlen          (m_axi_awlen),
        .m_axi_awsize         (m_axi_awsize),
        .m_axi_awburst        (m_axi_awburst),
        .m_axi_awlock         (m_axi_awlock),
        .m_axi_awcache        (m_axi_awcache),
        .m_axi_awprot         (m_axi_awprot),
        .m_axi_awqos          (m_axi_awqos),
        .m_axi_awregion       (m_axi_awregion),
        .m_axi_awuser         (m_axi_awuser),
        .m_axi_awvalid        (m_axi_awvalid),
        .m_axi_awready        (m_axi_awready),
        
        .m_axi_wdata          (m_axi_wdata),
        .m_axi_wstrb          (m_axi_wstrb),
        .m_axi_wlast          (m_axi_wlast),
        .m_axi_wuser          (m_axi_wuser),
        .m_axi_wvalid         (m_axi_wvalid),
        .m_axi_wready         (m_axi_wready),

        .m_axi_bid            (m_axi_bid),
        .m_axi_bresp          (m_axi_bresp),
        .m_axi_buser          (m_axi_buser),
        .m_axi_bvalid         (m_axi_bvalid),
        .m_axi_bready         (m_axi_bready)
    );


    axi4_full_master #(
        .AXI_ID_WIDTH     (AXI_ID_WIDTH) ,
        .AXI_ADDR_WIDTH   (AXI_ADDR_WIDTH) ,
        .AXI_DATA_WIDTH   (AXI_DATA_WIDTH) ,
        .AXI_AWUSER_WIDTH (AXI_AWUSER_WIDTH) ,
        .AXI_WUSER_WIDTH  (AXI_WUSER_WIDTH) ,
        .AXI_BUSER_WIDTH  (AXI_BUSER_WIDTH) ,
        .MAX_BURST_LEN    (MAX_BURST_LEN) ,
        .FIFO_DEPTH       (16)
    ) axi4_full_master_system_inst(
        .m_axi_aclk       (clk),
        .m_axi_aresetn    (rst_n),

        // AXI写地址通道
        .m_axi_awid       (s_axi_awid),
        .m_axi_awaddr     (s_axi_awaddr),
        .m_axi_awlen      (s_axi_awlen),
        .m_axi_awsize     (s_axi_awsize),
        .m_axi_awburst    (s_axi_awburst),
        .m_axi_awlock     (s_axi_awlock),
        .m_axi_awcache    (s_axi_awcache),
        .m_axi_awprot     (s_axi_awprot),
        .m_axi_awqos      (s_axi_awqos),
        .m_axi_awregion   (s_axi_awregion),
        .m_axi_awuser     (s_axi_awuser),
        .m_axi_awvalid    (s_axi_awvalid),
        .m_axi_awready    (s_axi_awready),

        // AXI写数据通道
        .m_axi_wdata      (s_axi_wdata),
        .m_axi_wstrb      (s_axi_wstrb),
        .m_axi_wlast      (s_axi_wlast),
        .m_axi_wuser      (s_axi_wuser),
        .m_axi_wvalid     (s_axi_wvalid),
        .m_axi_wready     (s_axi_wready),

        // AXI写响应通道
        .m_axi_bid        (s_axi_bid),
        .m_axi_bresp      (s_axi_bresp),
        .m_axi_buser      (s_axi_buser),
        .m_axi_bvalid     (s_axi_bvalid),
        .m_axi_bready     (s_axi_bready),

        // RAM接口
        .axi_rd_en        (axi_rd_en),
        .axi_rd_addr      (axi_rd_addr),
        .axi_rd_data      (axi_rd_data),
        .axi_rd_data_vld  (axi_rd_data_vld),

        // 控制信号
        .transfer_start   (transfer_start),
        .transfer_count   (transfer_count),
        .ram_base_addr    (ram_base_addr),
        .axi_target_addr  (axi_target_addr),

        // 状态信号
        .transfer_done    (transfer_done),
        .transfer_status  ()
    );

    matrix_data_ram #(
        .RAM_DATA_WIDTH (ALL_MATRIX_DATA_WIDTH),
        .RAM_ADDR_WIDTH (ALL_MATRIX_ADDR_WIDTH)
    ) matrix_data_ram_inst (
        .clk         (clk),
        .wr_en       (),
        .wr_addr     (),
        .wr_data     (),
        .wr_strb     (),
        .rd_en       (axi_rd_en),
        .rd_addr     (axi_rd_addr),
        .rd_data     (axi_rd_data),
        .rd_data_vld (axi_rd_data_vld)
    );

    axi4_lite_master #(
        .AXI_DATA_WIDTH (CSR_DATA_WIDTH),
        .AXI_ADDR_WIDTH (CSR_ADDR_WIDTH)
    ) axi4_lite_master_inst (
        .m_axil_aclk    (clk) ,
        .m_axil_aresetn (rst_n) ,
        
        // 写地址通道
        .m_axil_awaddr  (s_axil_awaddr) ,
        .m_axil_awvalid (s_axil_awvalid) ,
        .m_axil_awready (s_axil_awready) ,
        
        // 写数据通道
        .m_axil_wdata   (s_axil_wdata) ,
        .m_axil_wstrb   (s_axil_wstrb) ,
        .m_axil_wvalid  (s_axil_wvalid) ,
        .m_axil_wready  (s_axil_wready) ,
        
        // 写响应通道
        .m_axil_bresp   (s_axil_bresp) ,
        .m_axil_bvalid  (s_axil_bvalid) ,
        .m_axil_bready  (s_axil_bready) ,
        
        // 读地址通道
        .m_axil_araddr  (s_axil_araddr) ,
        .m_axil_arvalid (s_axil_arvalid) ,
        .m_axil_arready (s_axil_arready) ,
        
        // 读数据通道
        .m_axil_rdata   (s_axil_rdata) ,
        .m_axil_rresp   (s_axil_rresp) ,
        .m_axil_rvalid  (s_axil_rvalid) ,
        .m_axil_rready  (s_axil_rready) ,
        
        // 用户接口 - 写请求
        .usr_wr_req     (usr_wr_req) ,
        .usr_wr_addr    (usr_wr_addr) ,
        .usr_wr_data    (usr_wr_data) ,
        .usr_wr_strb    (usr_wr_strb) ,
        .usr_wr_done    (usr_wr_done) ,
        .usr_wr_error   (usr_wr_error) ,

        // 用户接口 - 读请求
        .usr_rd_req     (usr_rd_req) ,
        .usr_rd_addr    (usr_rd_addr) ,
        .usr_rd_data    (usr_rd_data) ,
        .usr_rd_done    (usr_rd_done) ,
        .usr_rd_error   (usr_rd_error)
    );

    save_axi_data_to_d_ram #(
        .AXI_ID_WIDTH   (AXI_ID_WIDTH),
        .AXI_ADDR_WIDTH (AXI_ADDR_WIDTH),
        .AXI_DATA_WIDTH (AXI_DATA_WIDTH),
        .RAM_DATA_WIDTH (64),
        .RAM_ADDR_WIDTH (13)
    ) save_axi_data_to_d_ram_inst (
        .clk          (clk)    ,
        .rst_n        (rst_n)    ,

        // AXI写地址通道
        .m_axi_awaddr (m_axi_awaddr)    ,
        .m_axi_awvalid(m_axi_awvalid)    ,
        .m_axi_awready(m_axi_awready)    ,

        // AXI写数据通道
        .m_axi_wdata  (m_axi_wdata)    ,
        .m_axi_wstrb  (m_axi_wstrb)    ,
        .m_axi_wlast  (m_axi_wlast)    ,
        .m_axi_wvalid (m_axi_wvalid)    ,
        .m_axi_wready (m_axi_wready)    ,

        // AXI写响应通道
        .m_axi_bid    (m_axi_bid)    ,
        .m_axi_bresp  (m_axi_bresp)  ,
        .m_axi_bvalid (m_axi_bvalid) ,
        .m_axi_bready (m_axi_bready) ,

        .ram_d_rd_en  (ram_d_rd_en)    ,
        .ram_d_rd_addr(ram_d_rd_addr)    ,
        .ram_d_rd_data(ram_d_rd_data)    ,
        .save_d_done  (save_d_done)
    );

    transfer_d_data_to_uartlite #(
        .DATA_WIDTH (64),
        .ADDR_WIDTH (13)
    ) transfer_d_data_to_uartlite_inst (
        .clk               (clk)   ,
        .rst_n             (rst_n)   ,

        // D矩阵RAM读接口
        .ram_d_rd_en       (ram_d_rd_en)   ,
        .ram_d_rd_addr     (ram_d_rd_addr) ,
        .ram_d_rd_data     (ram_d_rd_data) ,

        // UART-Lite写接口
        .uart_axi_awaddr   (uart_axi_awaddr)   ,
        .uart_axi_awvalid  (uart_axi_awvalid)  ,
        .uart_axi_awready  (uart_axi_awready)  ,
        .uart_axi_wdata    (uart_axi_wdata)    ,
        .uart_axi_wstrb    (uart_axi_wstrb)    ,
        .uart_axi_wvalid   (uart_axi_wvalid)   ,
        .uart_axi_wready   (uart_axi_wready)   ,
        .uart_axi_bresp    (uart_axi_bresp)    ,
        .uart_axi_bvalid   (uart_axi_bvalid)   ,
        .uart_axi_bready   (uart_axi_bready)   ,

        // 控制接口
        .uart_tx_start     (uart_tx_start)     ,
        .uart_tx_cfg_data  (uart_tx_cfg_data)  ,
        .uart_tx_cfg_addr  (uart_tx_cfg_addr)  ,
        .uart_tx_cfg_count (uart_tx_cfg_count) ,
        .uart_tx_done      (uart_tx_done)      ,
        .uart_tx_busy      (uart_tx_busy)    
    );

    axi_to_uart axi_to_uart_inst (
        .s_axi_aclk(clk),        // input wire s_axi_aclk
        .s_axi_aresetn(rst_n),  // input wire s_axi_aresetn
        .interrupt(),          // output wire interrupt
        .s_axi_awaddr (uart_axi_awaddr),    // input wire [3 : 0] s_axi_awaddr
        .s_axi_awvalid(uart_axi_awvalid),  // input wire s_axi_awvalid
        .s_axi_awready(uart_axi_awready),  // output wire s_axi_awready
        .s_axi_wdata  (uart_axi_wdata),      // input wire [31 : 0] s_axi_wdata
        .s_axi_wstrb  (uart_axi_wstrb),      // input wire [3 : 0] s_axi_wstrb
        .s_axi_wvalid (uart_axi_wvalid),    // input wire s_axi_wvalid
        .s_axi_wready (uart_axi_wready),    // output wire s_axi_wready
        .s_axi_bresp  (uart_axi_bresp),      // output wire [1 : 0] s_axi_bresp
        .s_axi_bvalid (uart_axi_bvalid),    // output wire s_axi_bvalid
        .s_axi_bready (uart_axi_bready),    // input wire s_axi_bready
        .s_axi_araddr (uart_axi_araddr),    // input wire [3 : 0] s_axi_araddr
        .s_axi_arvalid(uart_axi_arvalid),  // input wire s_axi_arvalid
        .s_axi_arready(uart_axi_arready),  // output wire s_axi_arready
        .s_axi_rdata  (uart_axi_rdata),      // output wire [31 : 0] s_axi_rdata
        .s_axi_rresp  (uart_axi_rresp),      // output wire [1 : 0] s_axi_rresp
        .s_axi_rvalid (uart_axi_rvalid),    // output wire s_axi_rvalid
        .s_axi_rready (uart_axi_rready),    // input wire s_axi_rready
        .rx(uart_rx),                       // input wire rx
        .tx(uart_tx)                        // output wire tx
    );

    save_uartlite_rx_data_to_fifo #(
        .FIFO_DATA_WIDTH (8),     // FIFO数据宽度
        .FIFO_DEPTH      (2048)     // FIFO深度
    ) save_uartlite_rx_data_to_fifo_inst (
        .clk               (clk),
        .rst_n             (rst_n),

        // AXI Lite接口
        .uart_axi_araddr   (uart_axi_araddr),
        .uart_axi_arvalid  (uart_axi_arvalid),
        .uart_axi_arready  (uart_axi_arready),
        .uart_axi_rdata    (uart_axi_rdata),
        .uart_axi_rresp    (uart_axi_rresp),
        .uart_axi_rvalid   (uart_axi_rvalid),
        .uart_axi_rready   (uart_axi_rready),

        // FIFO状态输出
        .fifo_full         (fifo_full),
        .fifo_empty        (fifo_empty),
        .fifo_almost_full  (fifo_almost_full),
        .fifo_almost_empty (fifo_almost_empty),

        // FIFO读取接口
        .fifo_rd_en        (fifo_rd_en),
        .fifo_data_out     (fifo_data_out)
    );

    system_ctrl #(
        .FIFO_DATA_WIDTH (8   ) ,
        .FIFO_DEPTH      (2048) ,
        .CSR_ADDR_WIDTH  (8   ) ,
        .CSR_DATA_WIDTH  (32  ) ,
        .RAM_DATA_WIDTH  (64  ) ,
        .RAM_ADDR_WIDTH  (13  ) 
    ) system_ctrl_inst (
        .clk                 (clk),
        .rst_n               (rst_n),

        .key_start           (key_start),
        .led_done            (led_done),

        // AXI-Full
        .transfer_start      (transfer_start),
        .transfer_count      (transfer_count),
        .ram_base_addr       (ram_base_addr),
        .axi_target_addr     (axi_target_addr),
        .transfer_done       (transfer_done),

        // AXI-Lite write
        .usr_wr_req          (usr_wr_req),
        .usr_wr_addr         (usr_wr_addr),
        .usr_wr_data         (usr_wr_data),
        .usr_wr_strb         (usr_wr_strb),
        .usr_wr_done         (usr_wr_done),
        .usr_wr_error        (usr_wr_error),
        // AXI-Lite read
        .usr_rd_req          (usr_rd_req),
        .usr_rd_addr         (usr_rd_addr),
        .usr_rd_data         (usr_rd_data),
        .usr_rd_done         (usr_rd_done),
        .usr_rd_error        (usr_rd_error),

        //UARTLite RX FIFO
        .fifo_full           (fifo_full),
        .fifo_empty          (fifo_empty),
        .fifo_almost_full    (fifo_almost_full),
        .fifo_almost_empty   (fifo_almost_empty),
        .fifo_rd_en          (fifo_rd_en),
        .fifo_data_out       (fifo_data_out),

        // UARTLite TX
        .uart_tx_start       (uart_tx_start),
        .uart_tx_cfg_data    (uart_tx_cfg_data),
        .uart_tx_cfg_addr    (uart_tx_cfg_addr),
        .uart_tx_cfg_count   (uart_tx_cfg_count),
        .uart_tx_done        (uart_tx_done),
        .uart_tx_busy        (uart_tx_busy),

        .save_d_done         (save_d_done)
    );



endmodule
