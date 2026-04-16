module system_ctrl #(
    parameter FIFO_DATA_WIDTH = 8   ,
    parameter FIFO_DEPTH      = 2048,
    parameter CSR_ADDR_WIDTH  = 8   ,
    parameter CSR_DATA_WIDTH  = 32  ,
    parameter RAM_DATA_WIDTH  = 64  ,
    parameter RAM_ADDR_WIDTH  = 13   
) (
    input  wire                            clk                 ,
    input  wire                            rst_n               ,
    
    input  wire                            key_start           ,
    output reg                             led_done            ,

    // AXI-Full
    output reg                             transfer_start      ,
    output reg [                     15:0] transfer_count      ,
    output reg [                     31:0] ram_base_addr       ,
    output reg [                     31:0] axi_target_addr     ,
    input  wire                            transfer_done       ,

    // AXI-Lite write
    output reg                             usr_wr_req          ,
    output reg  [      CSR_ADDR_WIDTH-1:0] usr_wr_addr         ,
    output reg  [      CSR_DATA_WIDTH-1:0] usr_wr_data         ,
    output reg  [    CSR_DATA_WIDTH/8-1:0] usr_wr_strb         ,
    input  wire                            usr_wr_done         ,
    input  wire                            usr_wr_error        ,
    // AXI-Lite read
    output reg                             usr_rd_req          ,
    output reg  [      CSR_ADDR_WIDTH-1:0] usr_rd_addr         ,
    input  wire [      CSR_DATA_WIDTH-1:0] usr_rd_data         ,
    input  wire                            usr_rd_done         ,
    input  wire                            usr_rd_error        ,

    //UARTLite RX FIFO
    input  wire                            fifo_full           ,
    input  wire                            fifo_empty          ,
    input  wire                            fifo_almost_full    ,
    input  wire                            fifo_almost_empty   ,
    output reg                             fifo_rd_en          ,
    input  wire [     FIFO_DATA_WIDTH-1:0] fifo_data_out       ,

    // UARTLite TX
    output reg                             uart_tx_start       ,
    output reg  [      RAM_DATA_WIDTH-1:0] uart_tx_cfg_data    ,
    output reg  [      RAM_ADDR_WIDTH-1:0] uart_tx_cfg_addr    ,
    output reg  [                    15:0] uart_tx_cfg_count   ,
    input  wire                            uart_tx_done        ,
    input  wire                            uart_tx_busy        ,

    input  wire                            save_d_done          
);

    // 矩阵地址和大小参数
    localparam PARAM_PM_INT4_ALL_M8N32K16_A_ADDR = 0;
    localparam PARAM_PM_INT4_ALL_M8N32K16_A_SIZE = 8;
    localparam PARAM_PM_INT4_ALL_M8N32K16_B_ADDR = 8;
    localparam PARAM_PM_INT4_ALL_M8N32K16_B_SIZE = 32;
    localparam PARAM_PM_INT4_ALL_M8N32K16_C_ADDR = 40;
    localparam PARAM_PM_INT4_ALL_M8N32K16_C_SIZE = 16;
    localparam PARAM_PM_INT4_ALL_M16N16K16_A_ADDR = 56;
    localparam PARAM_PM_INT4_ALL_M16N16K16_A_SIZE = 16;
    localparam PARAM_PM_INT4_ALL_M16N16K16_B_ADDR = 72;
    localparam PARAM_PM_INT4_ALL_M16N16K16_B_SIZE = 16;
    localparam PARAM_PM_INT4_ALL_M16N16K16_C_ADDR = 88;
    localparam PARAM_PM_INT4_ALL_M16N16K16_C_SIZE = 16;
    localparam PARAM_PM_INT4_ALL_M32N8K16_A_ADDR = 104;
    localparam PARAM_PM_INT4_ALL_M32N8K16_A_SIZE = 32;
    localparam PARAM_PM_INT4_ALL_M32N8K16_B_ADDR = 136;
    localparam PARAM_PM_INT4_ALL_M32N8K16_B_SIZE = 8;
    localparam PARAM_PM_INT4_ALL_M32N8K16_C_ADDR = 144;
    localparam PARAM_PM_INT4_ALL_M32N8K16_C_SIZE = 16;
    localparam PARAM_PM_INT8_ALL_M8N32K16_A_ADDR = 160;
    localparam PARAM_PM_INT8_ALL_M8N32K16_A_SIZE = 16;
    localparam PARAM_PM_INT8_ALL_M8N32K16_B_ADDR = 176;
    localparam PARAM_PM_INT8_ALL_M8N32K16_B_SIZE = 64;
    localparam PARAM_PM_INT8_ALL_M8N32K16_C_ADDR = 240;
    localparam PARAM_PM_INT8_ALL_M8N32K16_C_SIZE = 32;
    localparam PARAM_PM_INT8_ALL_M16N16K16_A_ADDR = 272;
    localparam PARAM_PM_INT8_ALL_M16N16K16_A_SIZE = 32;
    localparam PARAM_PM_INT8_ALL_M16N16K16_B_ADDR = 304;
    localparam PARAM_PM_INT8_ALL_M16N16K16_B_SIZE = 32;
    localparam PARAM_PM_INT8_ALL_M16N16K16_C_ADDR = 336;
    localparam PARAM_PM_INT8_ALL_M16N16K16_C_SIZE = 32;
    localparam PARAM_PM_INT8_ALL_M32N8K16_A_ADDR = 368;
    localparam PARAM_PM_INT8_ALL_M32N8K16_A_SIZE = 64;
    localparam PARAM_PM_INT8_ALL_M32N8K16_B_ADDR = 432;
    localparam PARAM_PM_INT8_ALL_M32N8K16_B_SIZE = 16;
    localparam PARAM_PM_INT8_ALL_M32N8K16_C_ADDR = 448;
    localparam PARAM_PM_INT8_ALL_M32N8K16_C_SIZE = 32;
    localparam PARAM_PM_INT4_INT32_M8N32K16_A_ADDR = 480;
    localparam PARAM_PM_INT4_INT32_M8N32K16_A_SIZE = 8;
    localparam PARAM_PM_INT4_INT32_M8N32K16_B_ADDR = 488;
    localparam PARAM_PM_INT4_INT32_M8N32K16_B_SIZE = 32;
    localparam PARAM_PM_INT4_INT32_M8N32K16_C_ADDR = 520;
    localparam PARAM_PM_INT4_INT32_M8N32K16_C_SIZE = 128;
    localparam PARAM_PM_INT4_INT32_M16N16K16_A_ADDR = 648;
    localparam PARAM_PM_INT4_INT32_M16N16K16_A_SIZE = 16;
    localparam PARAM_PM_INT4_INT32_M16N16K16_B_ADDR = 664;
    localparam PARAM_PM_INT4_INT32_M16N16K16_B_SIZE = 16;
    localparam PARAM_PM_INT4_INT32_M16N16K16_C_ADDR = 680;
    localparam PARAM_PM_INT4_INT32_M16N16K16_C_SIZE = 128;
    localparam PARAM_PM_INT4_INT32_M32N8K16_A_ADDR = 808;
    localparam PARAM_PM_INT4_INT32_M32N8K16_A_SIZE = 32;
    localparam PARAM_PM_INT4_INT32_M32N8K16_B_ADDR = 840;
    localparam PARAM_PM_INT4_INT32_M32N8K16_B_SIZE = 8;
    localparam PARAM_PM_INT4_INT32_M32N8K16_C_ADDR = 848;
    localparam PARAM_PM_INT4_INT32_M32N8K16_C_SIZE = 128;
    localparam PARAM_PM_INT8_INT32_M8N32K16_A_ADDR = 976;
    localparam PARAM_PM_INT8_INT32_M8N32K16_A_SIZE = 16;
    localparam PARAM_PM_INT8_INT32_M8N32K16_B_ADDR = 992;
    localparam PARAM_PM_INT8_INT32_M8N32K16_B_SIZE = 64;
    localparam PARAM_PM_INT8_INT32_M8N32K16_C_ADDR = 1056;
    localparam PARAM_PM_INT8_INT32_M8N32K16_C_SIZE = 128;
    localparam PARAM_PM_INT8_INT32_M16N16K16_A_ADDR = 1184;
    localparam PARAM_PM_INT8_INT32_M16N16K16_A_SIZE = 32;
    localparam PARAM_PM_INT8_INT32_M16N16K16_B_ADDR = 1216;
    localparam PARAM_PM_INT8_INT32_M16N16K16_B_SIZE = 32;
    localparam PARAM_PM_INT8_INT32_M16N16K16_C_ADDR = 1248;
    localparam PARAM_PM_INT8_INT32_M16N16K16_C_SIZE = 128;
    localparam PARAM_PM_INT8_INT32_M32N8K16_A_ADDR = 1376;
    localparam PARAM_PM_INT8_INT32_M32N8K16_A_SIZE = 64;
    localparam PARAM_PM_INT8_INT32_M32N8K16_B_ADDR = 1440;
    localparam PARAM_PM_INT8_INT32_M32N8K16_B_SIZE = 16;
    localparam PARAM_PM_INT8_INT32_M32N8K16_C_ADDR = 1456;
    localparam PARAM_PM_INT8_INT32_M32N8K16_C_SIZE = 128;
    localparam PARAM_PM_FP16_ALL_M8N32K16_A_ADDR = 1584;
    localparam PARAM_PM_FP16_ALL_M8N32K16_A_SIZE = 32;
    localparam PARAM_PM_FP16_ALL_M8N32K16_B_ADDR = 1616;
    localparam PARAM_PM_FP16_ALL_M8N32K16_B_SIZE = 128;
    localparam PARAM_PM_FP16_ALL_M8N32K16_C_ADDR = 1744;
    localparam PARAM_PM_FP16_ALL_M8N32K16_C_SIZE = 64;
    localparam PARAM_PM_FP16_ALL_M16N16K16_A_ADDR = 1808;
    localparam PARAM_PM_FP16_ALL_M16N16K16_A_SIZE = 64;
    localparam PARAM_PM_FP16_ALL_M16N16K16_B_ADDR = 1872;
    localparam PARAM_PM_FP16_ALL_M16N16K16_B_SIZE = 64;
    localparam PARAM_PM_FP16_ALL_M16N16K16_C_ADDR = 1936;
    localparam PARAM_PM_FP16_ALL_M16N16K16_C_SIZE = 64;
    localparam PARAM_PM_FP16_ALL_M32N8K16_A_ADDR = 2000;
    localparam PARAM_PM_FP16_ALL_M32N8K16_A_SIZE = 128;
    localparam PARAM_PM_FP16_ALL_M32N8K16_B_ADDR = 2128;
    localparam PARAM_PM_FP16_ALL_M32N8K16_B_SIZE = 32;
    localparam PARAM_PM_FP16_ALL_M32N8K16_C_ADDR = 2160;
    localparam PARAM_PM_FP16_ALL_M32N8K16_C_SIZE = 64;
    localparam PARAM_PM_BF16_ALL_M8N32K16_A_ADDR = 2224;
    localparam PARAM_PM_BF16_ALL_M8N32K16_A_SIZE = 32;
    localparam PARAM_PM_BF16_ALL_M8N32K16_B_ADDR = 2256;
    localparam PARAM_PM_BF16_ALL_M8N32K16_B_SIZE = 128;
    localparam PARAM_PM_BF16_ALL_M8N32K16_C_ADDR = 2384;
    localparam PARAM_PM_BF16_ALL_M8N32K16_C_SIZE = 64;
    localparam PARAM_PM_BF16_ALL_M16N16K16_A_ADDR = 2448;
    localparam PARAM_PM_BF16_ALL_M16N16K16_A_SIZE = 64;
    localparam PARAM_PM_BF16_ALL_M16N16K16_B_ADDR = 2512;
    localparam PARAM_PM_BF16_ALL_M16N16K16_B_SIZE = 64;
    localparam PARAM_PM_BF16_ALL_M16N16K16_C_ADDR = 2576;
    localparam PARAM_PM_BF16_ALL_M16N16K16_C_SIZE = 64;
    localparam PARAM_PM_BF16_ALL_M32N8K16_A_ADDR = 2640;
    localparam PARAM_PM_BF16_ALL_M32N8K16_A_SIZE = 128;
    localparam PARAM_PM_BF16_ALL_M32N8K16_B_ADDR = 2768;
    localparam PARAM_PM_BF16_ALL_M32N8K16_B_SIZE = 32;
    localparam PARAM_PM_BF16_ALL_M32N8K16_C_ADDR = 2800;
    localparam PARAM_PM_BF16_ALL_M32N8K16_C_SIZE = 64;
    localparam PARAM_PM_FP32_ALL_M8N32K16_A_ADDR = 2864;
    localparam PARAM_PM_FP32_ALL_M8N32K16_A_SIZE = 64;
    localparam PARAM_PM_FP32_ALL_M8N32K16_B_ADDR = 2928;
    localparam PARAM_PM_FP32_ALL_M8N32K16_B_SIZE = 256;
    localparam PARAM_PM_FP32_ALL_M8N32K16_C_ADDR = 3184;
    localparam PARAM_PM_FP32_ALL_M8N32K16_C_SIZE = 128;
    localparam PARAM_PM_FP32_ALL_M16N16K16_A_ADDR = 3312;
    localparam PARAM_PM_FP32_ALL_M16N16K16_A_SIZE = 128;
    localparam PARAM_PM_FP32_ALL_M16N16K16_B_ADDR = 3440;
    localparam PARAM_PM_FP32_ALL_M16N16K16_B_SIZE = 128;
    localparam PARAM_PM_FP32_ALL_M16N16K16_C_ADDR = 3568;
    localparam PARAM_PM_FP32_ALL_M16N16K16_C_SIZE = 128;
    localparam PARAM_PM_FP32_ALL_M32N8K16_A_ADDR = 3696;
    localparam PARAM_PM_FP32_ALL_M32N8K16_A_SIZE = 256;
    localparam PARAM_PM_FP32_ALL_M32N8K16_B_ADDR = 3952;
    localparam PARAM_PM_FP32_ALL_M32N8K16_B_SIZE = 64;
    localparam PARAM_PM_FP32_ALL_M32N8K16_C_ADDR = 4016;
    localparam PARAM_PM_FP32_ALL_M32N8K16_C_SIZE = 128;
    localparam PARAM_PM_FP16_MIX_M8N32K16_A_ADDR = 4144;
    localparam PARAM_PM_FP16_MIX_M8N32K16_A_SIZE = 32;
    localparam PARAM_PM_FP16_MIX_M8N32K16_B_ADDR = 4176;
    localparam PARAM_PM_FP16_MIX_M8N32K16_B_SIZE = 128;
    localparam PARAM_PM_FP16_MIX_M8N32K16_C_ADDR = 4304;
    localparam PARAM_PM_FP16_MIX_M8N32K16_C_SIZE = 128;
    localparam PARAM_PM_FP16_MIX_M16N16K16_A_ADDR = 4432;
    localparam PARAM_PM_FP16_MIX_M16N16K16_A_SIZE = 64;
    localparam PARAM_PM_FP16_MIX_M16N16K16_B_ADDR = 4496;
    localparam PARAM_PM_FP16_MIX_M16N16K16_B_SIZE = 64;
    localparam PARAM_PM_FP16_MIX_M16N16K16_C_ADDR = 4560;
    localparam PARAM_PM_FP16_MIX_M16N16K16_C_SIZE = 128;
    localparam PARAM_PM_FP16_MIX_M32N8K16_A_ADDR = 4688;
    localparam PARAM_PM_FP16_MIX_M32N8K16_A_SIZE = 128;
    localparam PARAM_PM_FP16_MIX_M32N8K16_B_ADDR = 4816;
    localparam PARAM_PM_FP16_MIX_M32N8K16_B_SIZE = 32;
    localparam PARAM_PM_FP16_MIX_M32N8K16_C_ADDR = 4848;
    localparam PARAM_PM_FP16_MIX_M32N8K16_C_SIZE = 128;
    localparam PARAM_PM_BF16_MIX_M8N32K16_A_ADDR = 4976;
    localparam PARAM_PM_BF16_MIX_M8N32K16_A_SIZE = 32;
    localparam PARAM_PM_BF16_MIX_M8N32K16_B_ADDR = 5008;
    localparam PARAM_PM_BF16_MIX_M8N32K16_B_SIZE = 128;
    localparam PARAM_PM_BF16_MIX_M8N32K16_C_ADDR = 5136;
    localparam PARAM_PM_BF16_MIX_M8N32K16_C_SIZE = 128;
    localparam PARAM_PM_BF16_MIX_M16N16K16_A_ADDR = 5264;
    localparam PARAM_PM_BF16_MIX_M16N16K16_A_SIZE = 64;
    localparam PARAM_PM_BF16_MIX_M16N16K16_B_ADDR = 5328;
    localparam PARAM_PM_BF16_MIX_M16N16K16_B_SIZE = 64;
    localparam PARAM_PM_BF16_MIX_M16N16K16_C_ADDR = 5392;
    localparam PARAM_PM_BF16_MIX_M16N16K16_C_SIZE = 128;
    localparam PARAM_PM_BF16_MIX_M32N8K16_A_ADDR = 5520;
    localparam PARAM_PM_BF16_MIX_M32N8K16_A_SIZE = 128;
    localparam PARAM_PM_BF16_MIX_M32N8K16_B_ADDR = 5648;
    localparam PARAM_PM_BF16_MIX_M32N8K16_B_SIZE = 32;
    localparam PARAM_PM_BF16_MIX_M32N8K16_C_ADDR = 5680;
    localparam PARAM_PM_BF16_MIX_M32N8K16_C_SIZE = 128;
    localparam PARAM_PM_INT8_ALL_M8N32K16_A_SPARSE_ADDR = 5808;
    localparam PARAM_PM_INT8_ALL_M8N32K16_A_SPARSE_SIZE = 10;
    localparam PARAM_PM_INT8_ALL_M16N16K16_A_SPARSE_ADDR = 5818;
    localparam PARAM_PM_INT8_ALL_M16N16K16_A_SPARSE_SIZE = 20;
    localparam PARAM_PM_INT8_ALL_M32N8K16_A_SPARSE_ADDR = 5838;
    localparam PARAM_PM_INT8_ALL_M32N8K16_A_SPARSE_SIZE = 40;
    localparam PARAM_PM_INT8_INT32_M8N32K16_A_SPARSE_ADDR = 5878;
    localparam PARAM_PM_INT8_INT32_M8N32K16_A_SPARSE_SIZE = 10;
    localparam PARAM_PM_INT8_INT32_M16N16K16_A_SPARSE_ADDR = 5888;
    localparam PARAM_PM_INT8_INT32_M16N16K16_A_SPARSE_SIZE = 20;
    localparam PARAM_PM_INT8_INT32_M32N8K16_A_SPARSE_ADDR = 5908;
    localparam PARAM_PM_INT8_INT32_M32N8K16_A_SPARSE_SIZE = 40;
    localparam PARAM_PM_FP16_ALL_M8N32K16_A_SPARSE_ADDR = 5948;
    localparam PARAM_PM_FP16_ALL_M8N32K16_A_SPARSE_SIZE = 18;
    localparam PARAM_PM_FP16_ALL_M16N16K16_A_SPARSE_ADDR = 5966;
    localparam PARAM_PM_FP16_ALL_M16N16K16_A_SPARSE_SIZE = 36;
    localparam PARAM_PM_FP16_ALL_M32N8K16_A_SPARSE_ADDR = 6002;
    localparam PARAM_PM_FP16_ALL_M32N8K16_A_SPARSE_SIZE = 72;
    localparam PARAM_PM_BF16_ALL_M8N32K16_A_SPARSE_ADDR = 6074;
    localparam PARAM_PM_BF16_ALL_M8N32K16_A_SPARSE_SIZE = 18;
    localparam PARAM_PM_BF16_ALL_M16N16K16_A_SPARSE_ADDR = 6092;
    localparam PARAM_PM_BF16_ALL_M16N16K16_A_SPARSE_SIZE = 36;
    localparam PARAM_PM_BF16_ALL_M32N8K16_A_SPARSE_ADDR = 6128;
    localparam PARAM_PM_BF16_ALL_M32N8K16_A_SPARSE_SIZE = 72;
    localparam PARAM_PM_FP32_ALL_M8N32K16_A_SPARSE_ADDR = 6200;
    localparam PARAM_PM_FP32_ALL_M8N32K16_A_SPARSE_SIZE = 34;
    localparam PARAM_PM_FP32_ALL_M16N16K16_A_SPARSE_ADDR = 6234;
    localparam PARAM_PM_FP32_ALL_M16N16K16_A_SPARSE_SIZE = 68;
    localparam PARAM_PM_FP32_ALL_M32N8K16_A_SPARSE_ADDR = 6302;
    localparam PARAM_PM_FP32_ALL_M32N8K16_A_SPARSE_SIZE = 136;
    localparam PARAM_PM_FP16_MIX_M8N32K16_A_SPARSE_ADDR = 6438;
    localparam PARAM_PM_FP16_MIX_M8N32K16_A_SPARSE_SIZE = 18;
    localparam PARAM_PM_FP16_MIX_M16N16K16_A_SPARSE_ADDR = 6456;
    localparam PARAM_PM_FP16_MIX_M16N16K16_A_SPARSE_SIZE = 36;
    localparam PARAM_PM_FP16_MIX_M32N8K16_A_SPARSE_ADDR = 6492;
    localparam PARAM_PM_FP16_MIX_M32N8K16_A_SPARSE_SIZE = 72;
    localparam PARAM_PM_BF16_MIX_M8N32K16_A_SPARSE_ADDR = 6564;
    localparam PARAM_PM_BF16_MIX_M8N32K16_A_SPARSE_SIZE = 18;
    localparam PARAM_PM_BF16_MIX_M16N16K16_A_SPARSE_ADDR = 6582;
    localparam PARAM_PM_BF16_MIX_M16N16K16_A_SPARSE_SIZE = 36;
    localparam PARAM_PM_BF16_MIX_M32N8K16_A_SPARSE_ADDR = 6618;
    localparam PARAM_PM_BF16_MIX_M32N8K16_A_SPARSE_SIZE = 72;

    localparam MATRIX_DIM_WIDTH     = 8;
    localparam PRECISION_MODE_WIDTH = 4;

    // CSR地址定义
    localparam CSR_ADDR_CTRL           = 8'h00;    // 控制寄存器
    localparam CSR_ADDR_STATUS         = 8'h04;    // 状态寄存器
    localparam CSR_ADDR_CONFIG         = 8'h08;    // 配置寄存器 (合并矩阵维度和精度模式)

    // 控制寄存器位定义
    localparam TPU_ENABLE_BIT          = 0;        // TPU使能位
    localparam TPU_SPARSE_ENABLE_BIT   = 1;        // TPU稀疏使能位

    // 状态寄存器位定义
    localparam TPU_READY_BIT           = 0;        // TPU就绪标志
    localparam TPU_LOAD_BUSY_BIT       = 1;        // TPU加载忙碌标志
    localparam TPU_COMPUTE_BUSY_BIT    = 2;        // TPU计算忙碌标志
    localparam TPU_STORE_BUSY_BIT      = 3;        // TPU存储忙碌标志
    localparam TPU_DONE_BIT            = 4;        // TPU计算完成标志
    
    // 精度模式定义
    localparam PM_INT4_ALL    = 4'd0; // ABC 矩阵均为 INT4
    localparam PM_INT8_ALL    = 4'd1; // ABC 矩阵均为 INT8
    localparam PM_INT4_INT32  = 4'd2; // AB 为 INT4，C 为 INT32
    localparam PM_INT8_INT32  = 4'd3; // AB 为 INT8，C 为 INT32
    localparam PM_FP16_ALL    = 4'd4; // ABC 矩阵均为 FP16
    localparam PM_BF16_ALL    = 4'd5; // ABC 矩阵均为 BF16
    localparam PM_FP32_ALL    = 4'd6; // ABC 矩阵均为 FP32
    localparam PM_FP16_MIX    = 4'd7; // AB 为 FP16，C 为 FP32
    localparam PM_BF16_MIX    = 4'd8; // AB 为 BF16，C 为 FP32
    
    // AXI 传输目标地址
    localparam AXI_A_MATRIX_ADDR = 32'h0000_0000; // A矩阵基地址
    localparam AXI_B_MATRIX_ADDR = 32'h0000_4000; // B矩阵基地址
    localparam AXI_C_MATRIX_ADDR = 32'h0000_8000; // C矩阵基地址
    
    // 状态机定义
    localparam [4:0] IDLE                  = 5'd0;  // 空闲状态，等待按键触发
    localparam [4:0] READ_FIFO_M           = 5'd1;  // 读取FIFO中的m
    localparam [4:0] READ_FIFO_N           = 5'd2;  // 读取FIFO中的n
    localparam [4:0] READ_FIFO_K           = 5'd3;  // 读取FIFO中的k
    localparam [4:0] READ_FIFO_PM_SPARSE   = 5'd4;  // 读取FIFO中的精度模式和稀疏使能位
    localparam [4:0] WRITE_CONFIG          = 5'd5;  // 写配置寄存器(包括矩阵维度和精度模式)
    localparam [4:0] WRITE_CTRL            = 5'd6;  // 写控制寄存器(包括TPU使能和稀疏使能)
    localparam [4:0] START_TRANS_A         = 5'd7;  // 开始传输A矩阵
    localparam [4:0] WAIT_TRANS_A          = 5'd8;  // 等待A矩阵传输完成
    localparam [4:0] START_TRANS_B         = 5'd9;  // 开始传输B矩阵
    localparam [4:0] WAIT_TRANS_B          = 5'd10; // 等待B矩阵传输完成
    localparam [4:0] START_TRANS_C         = 5'd11; // 开始传输C矩阵
    localparam [4:0] WAIT_TRANS_C          = 5'd12; // 等待C矩阵传输完成
    localparam [4:0] CHECK_STATUS          = 5'd13; // 检查计算状态
    localparam [4:0] READ_STATUS           = 5'd14; // 读取计算状态
    localparam [4:0] TASK_COMPLETE         = 5'd15; // 当前任务完成

    // UART状态机定义
    localparam [1:0] UART_IDLE      = 2'd0;  // UART空闲状态
    localparam [1:0] UART_PREPARE   = 2'd1;  // UART准备状态
    localparam [1:0] UART_TX_START  = 2'd2;  // 启动UART传输
    localparam [1:0] UART_TX_WAIT   = 2'd3;  // 等待UART传输完成

    reg fifo_data_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_data_valid <= 1'b0;
        end else begin
            fifo_data_valid <= fifo_rd_en;
        end
    end

    // 内部寄存器
    reg [4:0]  curr_state, next_state;      // 当前状态，下一状态
    reg [1:0]  uart_curr_state, uart_next_state; // UART状态机
    reg [MATRIX_DIM_WIDTH-1:0]      matrix_m;                    // 矩阵维度m
    reg [MATRIX_DIM_WIDTH-1:0]      matrix_n;                    // 矩阵维度n
    reg [MATRIX_DIM_WIDTH-1:0]      matrix_k;                    // 矩阵维度k
    reg [PRECISION_MODE_WIDTH-1:0]  precision_mode;              // 精度模式
    reg                             sparse_en;                   // 稀疏使能
    reg [31:0] read_status;              // 读取的状态寄存器值
    reg [7:0]  uart_tx_cnt;                 // UART传输计数器
    reg [7:0]  uart_tx_seq;              // UART传输序号计数器，从0开始递增
    // reg        save_d_done_reg;             // 保存save_d_done信号
    // reg        save_d_done_edge;            // save_d_done上升沿检测

    // 定义临时变量，用于计算当前传输矩阵的地址和大小
    reg [31:0] matrix_addr;
    reg [15:0] matrix_size;
    reg [1:0]  matrix_type; // 0:A, 1:B, 2:C

    always @(*) begin
        if (curr_state == START_TRANS_A) begin
            matrix_type = 2'd0; // A矩阵
        end else if (curr_state == START_TRANS_B) begin
            matrix_type = 2'd1; // B矩阵
        end else if (curr_state == START_TRANS_C) begin
            matrix_type = 2'd2; // C矩阵
        end else begin
            matrix_type = 2'd0; // 默认A矩阵
        end
    end

    // 组合逻辑块，根据精度模式、矩阵维度和矩阵类型计算地址和大小
    always @(*) begin
        // 默认值
        matrix_addr = 0;
        matrix_size = 0;
        
        case (precision_mode)
            PM_INT4_ALL: begin
                if (matrix_m == 8 && matrix_n == 32 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵 (PM_INT4_ALL不支持稀疏)
                            matrix_addr = PARAM_PM_INT4_ALL_M8N32K16_A_ADDR;
                            matrix_size = PARAM_PM_INT4_ALL_M8N32K16_A_SIZE;
                        end
                        2'd1: begin // B矩阵
                            matrix_addr = PARAM_PM_INT4_ALL_M8N32K16_B_ADDR;
                            matrix_size = PARAM_PM_INT4_ALL_M8N32K16_B_SIZE;
                        end
                        2'd2: begin // C矩阵
                            matrix_addr = PARAM_PM_INT4_ALL_M8N32K16_C_ADDR;
                            matrix_size = PARAM_PM_INT4_ALL_M8N32K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
                else if (matrix_m == 16 && matrix_n == 16 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵 (PM_INT4_ALL不支持稀疏)
                            matrix_addr = PARAM_PM_INT4_ALL_M16N16K16_A_ADDR;
                            matrix_size = PARAM_PM_INT4_ALL_M16N16K16_A_SIZE;
                        end
                        2'd1: begin
                            matrix_addr = PARAM_PM_INT4_ALL_M16N16K16_B_ADDR;
                            matrix_size = PARAM_PM_INT4_ALL_M16N16K16_B_SIZE;
                        end
                        2'd2: begin
                            matrix_addr = PARAM_PM_INT4_ALL_M16N16K16_C_ADDR;
                            matrix_size = PARAM_PM_INT4_ALL_M16N16K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
                else if (matrix_m == 32 && matrix_n == 8 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵 (PM_INT4_ALL不支持稀疏)
                            matrix_addr = PARAM_PM_INT4_ALL_M32N8K16_A_ADDR;
                            matrix_size = PARAM_PM_INT4_ALL_M32N8K16_A_SIZE;
                        end
                        2'd1: begin
                            matrix_addr = PARAM_PM_INT4_ALL_M32N8K16_B_ADDR;
                            matrix_size = PARAM_PM_INT4_ALL_M32N8K16_B_SIZE;
                        end
                        2'd2: begin
                            matrix_addr = PARAM_PM_INT4_ALL_M32N8K16_C_ADDR;
                            matrix_size = PARAM_PM_INT4_ALL_M32N8K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
            end
            
            PM_INT8_ALL: begin
                if (matrix_m == 8 && matrix_n == 32 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_INT8_ALL_M8N32K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_INT8_ALL_M8N32K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_INT8_ALL_M8N32K16_A_ADDR;
                                matrix_size = PARAM_PM_INT8_ALL_M8N32K16_A_SIZE;
                            end
                        end
                        2'd1: begin // B矩阵
                            matrix_addr = PARAM_PM_INT8_ALL_M8N32K16_B_ADDR;
                            matrix_size = PARAM_PM_INT8_ALL_M8N32K16_B_SIZE;
                        end
                        2'd2: begin // C矩阵
                            matrix_addr = PARAM_PM_INT8_ALL_M8N32K16_C_ADDR;
                            matrix_size = PARAM_PM_INT8_ALL_M8N32K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
                else if (matrix_m == 16 && matrix_n == 16 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_INT8_ALL_M16N16K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_INT8_ALL_M16N16K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_INT8_ALL_M16N16K16_A_ADDR;
                                matrix_size = PARAM_PM_INT8_ALL_M16N16K16_A_SIZE;
                            end
                        end
                        2'd1: begin
                            matrix_addr = PARAM_PM_INT8_ALL_M16N16K16_B_ADDR;
                            matrix_size = PARAM_PM_INT8_ALL_M16N16K16_B_SIZE;
                        end
                        2'd2: begin
                            matrix_addr = PARAM_PM_INT8_ALL_M16N16K16_C_ADDR;
                            matrix_size = PARAM_PM_INT8_ALL_M16N16K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
                else if (matrix_m == 32 && matrix_n == 8 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_INT8_ALL_M32N8K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_INT8_ALL_M32N8K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_INT8_ALL_M32N8K16_A_ADDR;
                                matrix_size = PARAM_PM_INT8_ALL_M32N8K16_A_SIZE;
                            end
                        end
                        2'd1: begin
                            matrix_addr = PARAM_PM_INT8_ALL_M32N8K16_B_ADDR;
                            matrix_size = PARAM_PM_INT8_ALL_M32N8K16_B_SIZE;
                        end
                        2'd2: begin
                            matrix_addr = PARAM_PM_INT8_ALL_M32N8K16_C_ADDR;
                            matrix_size = PARAM_PM_INT8_ALL_M32N8K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
            end
            
            PM_INT4_INT32: begin
                if (matrix_m == 8 && matrix_n == 32 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵 (PM_INT4_INT32不支持稀疏)
                            matrix_addr = PARAM_PM_INT4_INT32_M8N32K16_A_ADDR;
                            matrix_size = PARAM_PM_INT4_INT32_M8N32K16_A_SIZE;
                        end
                        2'd1: begin // B矩阵
                            matrix_addr = PARAM_PM_INT4_INT32_M8N32K16_B_ADDR;
                            matrix_size = PARAM_PM_INT4_INT32_M8N32K16_B_SIZE;
                        end
                        2'd2: begin // C矩阵
                            matrix_addr = PARAM_PM_INT4_INT32_M8N32K16_C_ADDR;
                            matrix_size = PARAM_PM_INT4_INT32_M8N32K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
                else if (matrix_m == 16 && matrix_n == 16 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵 (PM_INT4_INT32不支持稀疏)
                            matrix_addr = PARAM_PM_INT4_INT32_M16N16K16_A_ADDR;
                            matrix_size = PARAM_PM_INT4_INT32_M16N16K16_A_SIZE;
                        end
                        2'd1: begin
                            matrix_addr = PARAM_PM_INT4_INT32_M16N16K16_B_ADDR;
                            matrix_size = PARAM_PM_INT4_INT32_M16N16K16_B_SIZE;
                        end
                        2'd2: begin
                            matrix_addr = PARAM_PM_INT4_INT32_M16N16K16_C_ADDR;
                            matrix_size = PARAM_PM_INT4_INT32_M16N16K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
                else if (matrix_m == 32 && matrix_n == 8 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵 (PM_INT4_INT32不支持稀疏)
                            matrix_addr = PARAM_PM_INT4_INT32_M32N8K16_A_ADDR;
                            matrix_size = PARAM_PM_INT4_INT32_M32N8K16_A_SIZE;
                        end
                        2'd1: begin
                            matrix_addr = PARAM_PM_INT4_INT32_M32N8K16_B_ADDR;
                            matrix_size = PARAM_PM_INT4_INT32_M32N8K16_B_SIZE;
                        end
                        2'd2: begin
                            matrix_addr = PARAM_PM_INT4_INT32_M32N8K16_C_ADDR;
                            matrix_size = PARAM_PM_INT4_INT32_M32N8K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
            end
            
            PM_INT8_INT32: begin
                if (matrix_m == 8 && matrix_n == 32 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_INT8_INT32_M8N32K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_INT8_INT32_M8N32K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_INT8_INT32_M8N32K16_A_ADDR;
                                matrix_size = PARAM_PM_INT8_INT32_M8N32K16_A_SIZE;
                            end
                        end
                        2'd1: begin // B矩阵
                            matrix_addr = PARAM_PM_INT8_INT32_M8N32K16_B_ADDR;
                            matrix_size = PARAM_PM_INT8_INT32_M8N32K16_B_SIZE;
                        end
                        2'd2: begin // C矩阵
                            matrix_addr = PARAM_PM_INT8_INT32_M8N32K16_C_ADDR;
                            matrix_size = PARAM_PM_INT8_INT32_M8N32K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
                else if (matrix_m == 16 && matrix_n == 16 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_INT8_INT32_M16N16K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_INT8_INT32_M16N16K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_INT8_INT32_M16N16K16_A_ADDR;
                                matrix_size = PARAM_PM_INT8_INT32_M16N16K16_A_SIZE;
                            end
                        end
                        2'd1: begin
                            matrix_addr = PARAM_PM_INT8_INT32_M16N16K16_B_ADDR;
                            matrix_size = PARAM_PM_INT8_INT32_M16N16K16_B_SIZE;
                        end
                        2'd2: begin
                            matrix_addr = PARAM_PM_INT8_INT32_M16N16K16_C_ADDR;
                            matrix_size = PARAM_PM_INT8_INT32_M16N16K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
                else if (matrix_m == 32 && matrix_n == 8 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_INT8_INT32_M32N8K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_INT8_INT32_M32N8K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_INT8_INT32_M32N8K16_A_ADDR;
                                matrix_size = PARAM_PM_INT8_INT32_M32N8K16_A_SIZE;
                            end
                        end
                        2'd1: begin
                            matrix_addr = PARAM_PM_INT8_INT32_M32N8K16_B_ADDR;
                            matrix_size = PARAM_PM_INT8_INT32_M32N8K16_B_SIZE;
                        end
                        2'd2: begin
                            matrix_addr = PARAM_PM_INT8_INT32_M32N8K16_C_ADDR;
                            matrix_size = PARAM_PM_INT8_INT32_M32N8K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
            end
            
            PM_FP16_ALL: begin
                if (matrix_m == 8 && matrix_n == 32 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_FP16_ALL_M8N32K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_FP16_ALL_M8N32K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_FP16_ALL_M8N32K16_A_ADDR;
                                matrix_size = PARAM_PM_FP16_ALL_M8N32K16_A_SIZE;
                            end
                        end
                        2'd1: begin // B矩阵
                            matrix_addr = PARAM_PM_FP16_ALL_M8N32K16_B_ADDR;
                            matrix_size = PARAM_PM_FP16_ALL_M8N32K16_B_SIZE;
                        end
                        2'd2: begin // C矩阵
                            matrix_addr = PARAM_PM_FP16_ALL_M8N32K16_C_ADDR;
                            matrix_size = PARAM_PM_FP16_ALL_M8N32K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
                else if (matrix_m == 16 && matrix_n == 16 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_FP16_ALL_M16N16K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_FP16_ALL_M16N16K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_FP16_ALL_M16N16K16_A_ADDR;
                                matrix_size = PARAM_PM_FP16_ALL_M16N16K16_A_SIZE;
                            end
                        end
                        2'd1: begin
                            matrix_addr = PARAM_PM_FP16_ALL_M16N16K16_B_ADDR;
                            matrix_size = PARAM_PM_FP16_ALL_M16N16K16_B_SIZE;
                        end
                        2'd2: begin
                            matrix_addr = PARAM_PM_FP16_ALL_M16N16K16_C_ADDR;
                            matrix_size = PARAM_PM_FP16_ALL_M16N16K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
                else if (matrix_m == 32 && matrix_n == 8 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_FP16_ALL_M32N8K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_FP16_ALL_M32N8K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_FP16_ALL_M32N8K16_A_ADDR;
                                matrix_size = PARAM_PM_FP16_ALL_M32N8K16_A_SIZE;
                            end
                        end
                        2'd1: begin
                            matrix_addr = PARAM_PM_FP16_ALL_M32N8K16_B_ADDR;
                            matrix_size = PARAM_PM_FP16_ALL_M32N8K16_B_SIZE;
                        end
                        2'd2: begin
                            matrix_addr = PARAM_PM_FP16_ALL_M32N8K16_C_ADDR;
                            matrix_size = PARAM_PM_FP16_ALL_M32N8K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
            end
            
            PM_BF16_ALL: begin
                if (matrix_m == 8 && matrix_n == 32 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_BF16_ALL_M8N32K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_BF16_ALL_M8N32K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_BF16_ALL_M8N32K16_A_ADDR;
                                matrix_size = PARAM_PM_BF16_ALL_M8N32K16_A_SIZE;
                            end
                        end
                        2'd1: begin // B矩阵
                            matrix_addr = PARAM_PM_BF16_ALL_M8N32K16_B_ADDR;
                            matrix_size = PARAM_PM_BF16_ALL_M8N32K16_B_SIZE;
                        end
                        2'd2: begin // C矩阵
                            matrix_addr = PARAM_PM_BF16_ALL_M8N32K16_C_ADDR;
                            matrix_size = PARAM_PM_BF16_ALL_M8N32K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
                else if (matrix_m == 16 && matrix_n == 16 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_BF16_ALL_M16N16K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_BF16_ALL_M16N16K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_BF16_ALL_M16N16K16_A_ADDR;
                                matrix_size = PARAM_PM_BF16_ALL_M16N16K16_A_SIZE;
                            end
                        end
                        2'd1: begin
                            matrix_addr = PARAM_PM_BF16_ALL_M16N16K16_B_ADDR;
                            matrix_size = PARAM_PM_BF16_ALL_M16N16K16_B_SIZE;
                        end
                        2'd2: begin
                            matrix_addr = PARAM_PM_BF16_ALL_M16N16K16_C_ADDR;
                            matrix_size = PARAM_PM_BF16_ALL_M16N16K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
                else if (matrix_m == 32 && matrix_n == 8 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_BF16_ALL_M32N8K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_BF16_ALL_M32N8K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_BF16_ALL_M32N8K16_A_ADDR;
                                matrix_size = PARAM_PM_BF16_ALL_M32N8K16_A_SIZE;
                            end
                        end
                        2'd1: begin
                            matrix_addr = PARAM_PM_BF16_ALL_M32N8K16_B_ADDR;
                            matrix_size = PARAM_PM_BF16_ALL_M32N8K16_B_SIZE;
                        end
                        2'd2: begin
                            matrix_addr = PARAM_PM_BF16_ALL_M32N8K16_C_ADDR;
                            matrix_size = PARAM_PM_BF16_ALL_M32N8K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
            end
            
            PM_FP32_ALL: begin
                if (matrix_m == 8 && matrix_n == 32 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_FP32_ALL_M8N32K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_FP32_ALL_M8N32K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_FP32_ALL_M8N32K16_A_ADDR;
                                matrix_size = PARAM_PM_FP32_ALL_M8N32K16_A_SIZE;
                            end
                        end
                        2'd1: begin // B矩阵
                            matrix_addr = PARAM_PM_FP32_ALL_M8N32K16_B_ADDR;
                            matrix_size = PARAM_PM_FP32_ALL_M8N32K16_B_SIZE;
                        end
                        2'd2: begin // C矩阵
                            matrix_addr = PARAM_PM_FP32_ALL_M8N32K16_C_ADDR;
                            matrix_size = PARAM_PM_FP32_ALL_M8N32K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
                else if (matrix_m == 16 && matrix_n == 16 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_FP32_ALL_M16N16K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_FP32_ALL_M16N16K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_FP32_ALL_M16N16K16_A_ADDR;
                                matrix_size = PARAM_PM_FP32_ALL_M16N16K16_A_SIZE;
                            end
                        end
                        2'd1: begin
                            matrix_addr = PARAM_PM_FP32_ALL_M16N16K16_B_ADDR;
                            matrix_size = PARAM_PM_FP32_ALL_M16N16K16_B_SIZE;
                        end
                        2'd2: begin
                            matrix_addr = PARAM_PM_FP32_ALL_M16N16K16_C_ADDR;
                            matrix_size = PARAM_PM_FP32_ALL_M16N16K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
                else if (matrix_m == 32 && matrix_n == 8 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_FP32_ALL_M32N8K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_FP32_ALL_M32N8K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_FP32_ALL_M32N8K16_A_ADDR;
                                matrix_size = PARAM_PM_FP32_ALL_M32N8K16_A_SIZE;
                            end
                        end
                        2'd1: begin
                            matrix_addr = PARAM_PM_FP32_ALL_M32N8K16_B_ADDR;
                            matrix_size = PARAM_PM_FP32_ALL_M32N8K16_B_SIZE;
                        end
                        2'd2: begin
                            matrix_addr = PARAM_PM_FP32_ALL_M32N8K16_C_ADDR;
                            matrix_size = PARAM_PM_FP32_ALL_M32N8K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
            end
            
            PM_FP16_MIX: begin
                if (matrix_m == 8 && matrix_n == 32 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_FP16_MIX_M8N32K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_FP16_MIX_M8N32K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_FP16_MIX_M8N32K16_A_ADDR;
                                matrix_size = PARAM_PM_FP16_MIX_M8N32K16_A_SIZE;
                            end
                        end
                        2'd1: begin // B矩阵
                            matrix_addr = PARAM_PM_FP16_MIX_M8N32K16_B_ADDR;
                            matrix_size = PARAM_PM_FP16_MIX_M8N32K16_B_SIZE;
                        end
                        2'd2: begin // C矩阵
                            matrix_addr = PARAM_PM_FP16_MIX_M8N32K16_C_ADDR;
                            matrix_size = PARAM_PM_FP16_MIX_M8N32K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
                else if (matrix_m == 16 && matrix_n == 16 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_FP16_MIX_M16N16K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_FP16_MIX_M16N16K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_FP16_MIX_M16N16K16_A_ADDR;
                                matrix_size = PARAM_PM_FP16_MIX_M16N16K16_A_SIZE;
                            end
                        end
                        2'd1: begin
                            matrix_addr = PARAM_PM_FP16_MIX_M16N16K16_B_ADDR;
                            matrix_size = PARAM_PM_FP16_MIX_M16N16K16_B_SIZE;
                        end
                        2'd2: begin
                            matrix_addr = PARAM_PM_FP16_MIX_M16N16K16_C_ADDR;
                            matrix_size = PARAM_PM_FP16_MIX_M16N16K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
                else if (matrix_m == 32 && matrix_n == 8 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_FP16_MIX_M32N8K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_FP16_MIX_M32N8K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_FP16_MIX_M32N8K16_A_ADDR;
                                matrix_size = PARAM_PM_FP16_MIX_M32N8K16_A_SIZE;
                            end
                        end
                        2'd1: begin
                            matrix_addr = PARAM_PM_FP16_MIX_M32N8K16_B_ADDR;
                            matrix_size = PARAM_PM_FP16_MIX_M32N8K16_B_SIZE;
                        end
                        2'd2: begin
                            matrix_addr = PARAM_PM_FP16_MIX_M32N8K16_C_ADDR;
                            matrix_size = PARAM_PM_FP16_MIX_M32N8K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
            end
            
            PM_BF16_MIX: begin
                if (matrix_m == 8 && matrix_n == 32 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_BF16_MIX_M8N32K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_BF16_MIX_M8N32K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_BF16_MIX_M8N32K16_A_ADDR;
                                matrix_size = PARAM_PM_BF16_MIX_M8N32K16_A_SIZE;
                            end
                        end
                        2'd1: begin // B矩阵
                            matrix_addr = PARAM_PM_BF16_MIX_M8N32K16_B_ADDR;
                            matrix_size = PARAM_PM_BF16_MIX_M8N32K16_B_SIZE;
                        end
                        2'd2: begin // C矩阵
                            matrix_addr = PARAM_PM_BF16_MIX_M8N32K16_C_ADDR;
                            matrix_size = PARAM_PM_BF16_MIX_M8N32K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
                else if (matrix_m == 16 && matrix_n == 16 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_BF16_MIX_M16N16K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_BF16_MIX_M16N16K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_BF16_MIX_M16N16K16_A_ADDR;
                                matrix_size = PARAM_PM_BF16_MIX_M16N16K16_A_SIZE;
                            end
                        end
                        2'd1: begin
                            matrix_addr = PARAM_PM_BF16_MIX_M16N16K16_B_ADDR;
                            matrix_size = PARAM_PM_BF16_MIX_M16N16K16_B_SIZE;
                        end
                        2'd2: begin
                            matrix_addr = PARAM_PM_BF16_MIX_M16N16K16_C_ADDR;
                            matrix_size = PARAM_PM_BF16_MIX_M16N16K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
                else if (matrix_m == 32 && matrix_n == 8 && matrix_k == 16) begin
                    case (matrix_type)
                        2'd0: begin // A矩阵
                            if (sparse_en) begin
                                matrix_addr = PARAM_PM_BF16_MIX_M32N8K16_A_SPARSE_ADDR;
                                matrix_size = PARAM_PM_BF16_MIX_M32N8K16_A_SPARSE_SIZE;
                            end else begin
                                matrix_addr = PARAM_PM_BF16_MIX_M32N8K16_A_ADDR;
                                matrix_size = PARAM_PM_BF16_MIX_M32N8K16_A_SIZE;
                            end
                        end
                        2'd1: begin
                            matrix_addr = PARAM_PM_BF16_MIX_M32N8K16_B_ADDR;
                            matrix_size = PARAM_PM_BF16_MIX_M32N8K16_B_SIZE;
                        end
                        2'd2: begin
                            matrix_addr = PARAM_PM_BF16_MIX_M32N8K16_C_ADDR;
                            matrix_size = PARAM_PM_BF16_MIX_M32N8K16_C_SIZE;
                        end
                        default: begin
                            matrix_addr = 0;
                            matrix_size = 0;
                        end
                    endcase
                end
            end
            
            default: begin
                matrix_addr = 0;
                matrix_size = 0;
            end
        endcase
    end
    

    // // 上升沿检测 - 用于save_d_done信号
    // always @(posedge clk or negedge rst_n) begin
    //     if (!rst_n) begin
    //         save_d_done_reg <= 1'b0;
    //         save_d_done_edge <= 1'b0;
    //     end else begin
    //         save_d_done_reg <= save_d_done;
    //         save_d_done_edge <= save_d_done & ~save_d_done_reg;
    //     end
    // end

    // 主状态机寄存器更新
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            curr_state <= IDLE;
        end else begin
            curr_state <= next_state;
        end
    end
    
    // UART状态机寄存器更新 - 独立于主状态机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_curr_state <= UART_IDLE;
        end else begin
            uart_curr_state <= uart_next_state;
        end
    end

    // 主状态转移逻辑
    always @(*) begin
        next_state = curr_state;
        
        case (curr_state)
            IDLE: begin
                if (key_start && !fifo_empty) begin
                    next_state = READ_FIFO_M;
                end
            end
            
            READ_FIFO_M: begin
                if (fifo_data_valid) begin
                    next_state = READ_FIFO_N;
                end
            end
            
            READ_FIFO_N: begin
                if (fifo_data_valid) begin
                    next_state = READ_FIFO_K;
                end
            end
            
            READ_FIFO_K: begin
                if (fifo_data_valid) begin
                    next_state = READ_FIFO_PM_SPARSE;
                end
            end
            
            READ_FIFO_PM_SPARSE: begin
                if (fifo_data_valid) begin
                    next_state = WRITE_CONFIG;
                end
            end
            
            WRITE_CONFIG: begin
                if (usr_wr_done) begin
                    next_state = WRITE_CTRL;
                end
            end
            
            WRITE_CTRL: begin
                if (usr_wr_done) begin
                    next_state = START_TRANS_A;
                end
            end
            
            START_TRANS_A: begin
                next_state = WAIT_TRANS_A;
            end
            
            WAIT_TRANS_A: begin
                if (transfer_done) begin
                    next_state = START_TRANS_B;
                end
            end
            
            START_TRANS_B: begin
                next_state = WAIT_TRANS_B;
            end
            
            WAIT_TRANS_B: begin
                if (transfer_done) begin
                    next_state = START_TRANS_C;
                end
            end
            
            START_TRANS_C: begin
                next_state = WAIT_TRANS_C;
            end
            
            WAIT_TRANS_C: begin
                if (transfer_done) begin
                    next_state = CHECK_STATUS;
                end
            end
            
            CHECK_STATUS: begin
                next_state = READ_STATUS;
            end
            
            READ_STATUS: begin
                if (usr_rd_done) begin
                    // 如果计算完成位为高
                    if (usr_rd_data[TPU_READY_BIT]) begin
                        next_state = TASK_COMPLETE;
                    end else begin
                        next_state = CHECK_STATUS;
                    end
                end
            end
            
            TASK_COMPLETE: begin
                if (!fifo_empty) begin
                    next_state = READ_FIFO_M;  // 有新任务
                end else begin
                    next_state = IDLE;  // 回到空闲状态
                end
            end
            
            default:
                next_state = IDLE;
        endcase
    end
    
    // UART状态转移逻辑 - 独立于主状态机
    always @(*) begin
        uart_next_state = uart_curr_state;
        
        case (uart_curr_state)
            UART_IDLE: begin
                if (uart_tx_cnt > 0) begin
                    uart_next_state = UART_PREPARE;
                end
            end

            UART_PREPARE: begin
                uart_next_state = UART_TX_START;
            end
            
            UART_TX_START: begin
                uart_next_state = UART_TX_WAIT;
            end
            
            UART_TX_WAIT: begin
                if (uart_tx_done) begin
                    uart_next_state = UART_IDLE;
                end
            end
            
            default:
                uart_next_state = UART_IDLE;
        endcase
    end
    
    // 主状态机输出逻辑 
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // 复位所有信号
            led_done <= 1'b0;
            
            transfer_start <= 1'b0;
            transfer_count <= 16'd0;
            ram_base_addr <= 32'd0;
            axi_target_addr <= 32'd0;
            
            usr_wr_req <= 1'b0;
            usr_wr_addr <= {CSR_ADDR_WIDTH{1'b0}};
            usr_wr_data <= 32'd0;
            usr_wr_strb <= 4'd0;
            
            usr_rd_req <= 1'b0;
            usr_rd_addr <= {CSR_ADDR_WIDTH{1'b0}};
            
            fifo_rd_en <= 1'b0;

            matrix_m <= {MATRIX_DIM_WIDTH{1'b0}};
            matrix_n <= {MATRIX_DIM_WIDTH{1'b0}};
            matrix_k <= {MATRIX_DIM_WIDTH{1'b0}};
            precision_mode <= {PRECISION_MODE_WIDTH{1'b0}};
            sparse_en      <= 1'b0;
            read_status <= 32'd0;
        end else begin
            // 默认值
            usr_wr_req <= 1'b0;
            usr_rd_req <= 1'b0;
            fifo_rd_en <= 1'b0;
            transfer_start <= 1'b0;

            case (curr_state)
                IDLE: begin
                    // led_done <= 1'b0;
                    if (key_start && !fifo_empty) begin
                        fifo_rd_en <= 1'b1;  // 读取矩阵维度m
                    end
                end
                
                READ_FIFO_M: begin
                    if (fifo_data_valid) begin
                        matrix_m <= fifo_data_out;
                        fifo_rd_en <= 1'b1;  // 读取矩阵维度n
                    end
                end
                
                READ_FIFO_N: begin
                    if (fifo_data_valid) begin
                        matrix_n <= fifo_data_out;
                        fifo_rd_en <= 1'b1;  // 读取矩阵维度k
                    end
                end
                
                READ_FIFO_K: begin
                    if (fifo_data_valid) begin
                        matrix_k <= fifo_data_out;
                        fifo_rd_en <= 1'b1;  // 读取精度模式
                    end
                end
                
                READ_FIFO_PM_SPARSE: begin
                    if (fifo_data_valid) begin
                        precision_mode <= fifo_data_out[0+:PRECISION_MODE_WIDTH];  // 只取低4位作为精度模式
                        sparse_en      <= fifo_data_out[7];  // 读取稀疏使能
                    end
                end
                
                WRITE_CONFIG: begin
                    // 写入矩阵维度寄存器和精度模式寄存器
                    usr_wr_req <= 1'b1;
                    usr_wr_addr <= CSR_ADDR_CONFIG;
                    usr_wr_data <= {4'b0, precision_mode, matrix_m, matrix_n, matrix_k};
                    usr_wr_strb <= 4'b1111;  // 写入所有字节
                end
                
                WRITE_CTRL: begin
                    // 写入控制寄存器
                    usr_wr_req <= 1'b1;
                    usr_wr_addr <= CSR_ADDR_CTRL;
                    usr_wr_data <= {30'b0, sparse_en, 1'b1};
                    usr_wr_strb <= 4'b0001;  // 只写入最低字节
                end
                
                START_TRANS_A: begin
                    // matrix_type <= 2'd0; // 选择A矩阵
                    transfer_start <= 1'b1;
                    ram_base_addr <= matrix_addr;
                    transfer_count <= matrix_size;
                    axi_target_addr <= AXI_A_MATRIX_ADDR;
                end
                
                WAIT_TRANS_A: begin
                    // 等待传输完成
                end
                
                START_TRANS_B: begin
                    // matrix_type <= 2'd1; // 选择B矩阵
                    transfer_start <= 1'b1;
                    ram_base_addr <= matrix_addr;
                    transfer_count <= matrix_size;
                    axi_target_addr <= AXI_B_MATRIX_ADDR;
                end
                
                WAIT_TRANS_B: begin
                    // 等待传输完成
                end
                
                START_TRANS_C: begin
                    // matrix_type <= 2'd2; // 选择C矩阵
                    transfer_start <= 1'b1;
                    ram_base_addr <= matrix_addr;
                    transfer_count <= matrix_size;
                    axi_target_addr <= AXI_C_MATRIX_ADDR;
                end
                
                WAIT_TRANS_C: begin
                    // 等待C矩阵传输完成，无需操作
                end
                
                CHECK_STATUS: begin
                    // 检查计算状态
                    usr_rd_req <= 1'b1;
                    usr_rd_addr <= CSR_ADDR_STATUS;
                end
                
                READ_STATUS: begin
                    // 读取状态寄存器结果
                    if (usr_rd_done) begin
                        read_status <= usr_rd_data;
                    end
                end
                
                TASK_COMPLETE: begin
                    if (!fifo_empty) begin
                        fifo_rd_en <= 1'b1;  // 读取下一组任务
                    end else begin
                        led_done <= 1'b1;  // 所有任务完成，点亮LED
                    end
                end
                
                default: begin
                    // 默认不做操作
                end
            endcase
        end
    end

    // FIFO参数定义
    localparam PM_FIFO_DEPTH = 512;
    localparam PM_FIFO_ADDR_WIDTH = $clog2(PM_FIFO_DEPTH);
    reg [PRECISION_MODE_WIDTH-1:0] pm_fifo_data [0:PM_FIFO_DEPTH-1]; // 数据存储
    reg [PM_FIFO_ADDR_WIDTH:0]  pm_fifo_wr_ptr; // 写指针，多一位用于判断FIFO满
    reg [PM_FIFO_ADDR_WIDTH:0]  pm_fifo_rd_ptr; // 读指针，多一位用于判断FIFO空
    wire [PM_FIFO_ADDR_WIDTH:0] pm_fifo_count;  // FIFO中数据计数
    wire pm_fifo_empty; // FIFO是否为空
    wire pm_fifo_full;  // FIFO是否已满
    reg [15:0] matrix_d_size;

    // FIFO状态信号
    assign pm_fifo_count = pm_fifo_wr_ptr - pm_fifo_rd_ptr;
    assign pm_fifo_empty = (pm_fifo_count == 0);
    assign pm_fifo_full  = (pm_fifo_count == PM_FIFO_DEPTH);
    
    wire [PRECISION_MODE_WIDTH-1:0] pm_fifo_data_out;
    assign pm_fifo_data_out = pm_fifo_empty ? {PRECISION_MODE_WIDTH{1'b0}} : pm_fifo_data[pm_fifo_rd_ptr[PM_FIFO_ADDR_WIDTH-1:0]];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pm_fifo_wr_ptr <= 0;
        end else begin
            if (curr_state == READ_FIFO_PM_SPARSE && fifo_data_valid) begin
                pm_fifo_data[pm_fifo_wr_ptr[PM_FIFO_ADDR_WIDTH-1:0]] <= fifo_data_out[0+:PRECISION_MODE_WIDTH];
                pm_fifo_wr_ptr <= pm_fifo_wr_ptr + 1'b1;
            end
        end
    end

    // UART传输逻辑 - 独立于主状态机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_tx_start <= 1'b0;
            uart_tx_cfg_data <= {RAM_DATA_WIDTH{1'b0}};
            uart_tx_cfg_addr <= {RAM_ADDR_WIDTH{1'b0}};
            uart_tx_cfg_count <= 16'd0;
            uart_tx_cnt <= 8'd0;
            uart_tx_seq <= 8'd0;
            pm_fifo_rd_ptr <= 0;
            matrix_d_size <= 16'd0;
        end else begin
            // 默认值
            uart_tx_start <= 1'b0;
            
            // 当检测到save_d_done信号上升沿时增加UART传输计数
            if (save_d_done && !uart_tx_done) begin
                uart_tx_cnt <= uart_tx_cnt + 1'b1;
            end else if (!save_d_done && uart_tx_done) begin
                uart_tx_cnt <= uart_tx_cnt - 1'b1;
            end
            
            case (uart_curr_state)
                UART_IDLE: begin
                    // 等待传输请求
                end

                UART_PREPARE: begin
                    case (pm_fifo_data_out)
                        PM_INT8_ALL, PM_INT4_INT32, PM_INT8_INT32, PM_FP32_ALL, PM_FP16_MIX, PM_BF16_MIX: begin
                            matrix_d_size <= 16'd128;
                        end

                        PM_INT4_ALL, PM_FP16_ALL, PM_BF16_ALL: begin
                            matrix_d_size <= 16'd64;
                        end

                        default: begin
                            matrix_d_size <= 16'd128;
                        end
                    endcase
                end
                
                UART_TX_START: begin
                    // 启动UART传输
                    uart_tx_start <= 1'b1;
                    uart_tx_cfg_data <= {56'd0, uart_tx_seq}; // 当前传输编号
                    // uart_tx_cfg_addr <= uart_tx_cfg_addr + matrix_d_size;
                    uart_tx_cfg_count <= matrix_d_size;  // 每次传输matrix_d_size个数据
                end
                
                UART_TX_WAIT: begin
                    // 等待UART传输完成
                    if (uart_tx_done) begin
                        // uart_tx_cnt <= uart_tx_cnt - 1'b1; // 完成一次传输，计数减1
                        uart_tx_seq <= uart_tx_seq + 1'b1; // 传输序号递增
                        uart_tx_cfg_addr <= uart_tx_cfg_addr + matrix_d_size;
                        pm_fifo_rd_ptr <= pm_fifo_rd_ptr + 1'b1; // 读取下一个精度模式
                    end
                end
                
                default: begin
                    // 默认不做操作
                end
            endcase
        end
    end

endmodule