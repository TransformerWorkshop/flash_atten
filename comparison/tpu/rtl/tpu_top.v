module tpu_top #(
    parameter AXI_ID_WIDTH         = 4             ,
    parameter AXI_ADDR_WIDTH       = 32            ,
    parameter AXI_DATA_WIDTH       = 128           ,
    parameter AXI_AWUSER_WIDTH     = 8             ,
    parameter AXI_WUSER_WIDTH      = 8             ,
    parameter AXI_BUSER_WIDTH      = 8             ,

    parameter CSR_DATA_WIDTH       = 32            ,
    parameter CSR_ADDR_WIDTH       = 8             ,

    parameter PE_SIZE              = 16            ,    // PE数量/阵列大小
    parameter MATRIX_DIM_WIDTH     = 8             ,    // 矩阵维度宽度
    parameter PRECISION_MODE_WIDTH = 4             ,    // 精度模式宽度
    parameter RAM_ADDR_WIDTH       = 8             ,    // RAM地址宽度
    parameter RAM_C_ADDR_WIDTH     = 10            ,    // RAM地址宽度
    parameter RAM_D_ADDR_WIDTH     = 10            ,    // RAM地址宽度
    parameter RAM_DATA_WIDTH       = 64            ,    // RAM数据宽度
    parameter FIFO_DATA_WIDTH      = 32            ,    // FIFO数据宽度
    parameter FIFO_DEPTH           = 512           ,    // FIFO深度
    parameter MATRIX_A_BASE_ADDR   = 32'h0000_0000 ,    // 矩阵A的基地址
    parameter MATRIX_B_BASE_ADDR   = 32'h0000_4000 ,    // 矩阵B的基地址
    parameter MATRIX_C_BASE_ADDR   = 32'h0000_8000 ,    // 矩阵C的基地址
    parameter MATRIX_D_BASE_ADDR   = 32'h0000_C000 ,

    parameter DATA_WIDTH           = 32             

) (
    /******************** AXI-Slave 接口 ********************/
    // Global signals
    input wire                               clk              ,
    input wire                               rst_n            ,

    // Write address channel
    input  wire [        AXI_ID_WIDTH-1:0]   s_axi_awid       ,
    input  wire [      AXI_ADDR_WIDTH-1:0]   s_axi_awaddr     ,
    input  wire [                     7:0]   s_axi_awlen      ,
    input  wire [                     2:0]   s_axi_awsize     ,
    input  wire [                     1:0]   s_axi_awburst    ,
    input  wire                              s_axi_awlock     ,
    input  wire [                     3:0]   s_axi_awcache    ,
    input  wire [                     2:0]   s_axi_awprot     ,
    input  wire [                     3:0]   s_axi_awqos      ,
    input  wire [                     3:0]   s_axi_awregion   ,
    input  wire [    AXI_AWUSER_WIDTH-1:0]   s_axi_awuser     ,
    input  wire                              s_axi_awvalid    ,
    output wire                              s_axi_awready    ,

    // Write data channel
    input  wire [        AXI_DATA_WIDTH-1:0] s_axi_wdata      ,
    input  wire [(    AXI_DATA_WIDTH/8)-1:0] s_axi_wstrb      ,
    input  wire                              s_axi_wlast      ,
    input  wire [       AXI_WUSER_WIDTH-1:0] s_axi_wuser      ,
    input  wire                              s_axi_wvalid     ,
    output wire                              s_axi_wready     ,

    // Write response channel
    output wire [       AXI_ID_WIDTH-1:0]    s_axi_bid        ,
    output wire [                    1:0]    s_axi_bresp      ,
    output wire [    AXI_BUSER_WIDTH-1:0]    s_axi_buser      ,
    output wire                              s_axi_bvalid     ,
    input  wire                              s_axi_bready     ,

    /******************** AXI-Lite-Slave 接口 ********************/
    // 写地址通道
    input  wire [                 8-1:0]     s_axil_awaddr    ,
    input  wire                              s_axil_awvalid   ,
    output wire                              s_axil_awready   ,
    
    // 写数据通道
    input  wire [    CSR_DATA_WIDTH-1:0]     s_axil_wdata     ,
    input  wire [    CSR_DATA_WIDTH/8-1:0]   s_axil_wstrb     ,
    input  wire                              s_axil_wvalid    ,
    output wire                              s_axil_wready    ,
    
    // 写响应通道
    output wire [1:0]                        s_axil_bresp     ,
    output wire                              s_axil_bvalid    ,
    input  wire                              s_axil_bready    ,
    
    // 读地址通道
    input  wire [                 8-1:0]     s_axil_araddr    ,
    input  wire                              s_axil_arvalid   ,
    output wire                              s_axil_arready   ,
    
    // 读数据通道
    output wire [    CSR_DATA_WIDTH-1:0]     s_axil_rdata     ,
    output wire [1:0]                        s_axil_rresp     ,
    output wire                              s_axil_rvalid    ,
    input  wire                              s_axil_rready    ,

    /******************** AXI-Master接口 ********************/
    output wire [          AXI_ID_WIDTH-1:0] m_axi_awid       ,
    output wire [        AXI_ADDR_WIDTH-1:0] m_axi_awaddr     ,
    output wire [                       7:0] m_axi_awlen      ,
    output wire [                       2:0] m_axi_awsize     ,
    output wire [                       1:0] m_axi_awburst    ,
    output wire                              m_axi_awlock     ,
    output wire [                       3:0] m_axi_awcache    ,
    output wire [                       2:0] m_axi_awprot     ,
    output wire [                       3:0] m_axi_awqos      ,
    output wire [                       3:0] m_axi_awregion   ,
    output wire [      AXI_AWUSER_WIDTH-1:0] m_axi_awuser     ,
    output wire                              m_axi_awvalid    ,
    input  wire                              m_axi_awready    ,

    // AXI写数据通道
    output wire [        AXI_DATA_WIDTH-1:0] m_axi_wdata      ,
    output wire [    (AXI_DATA_WIDTH/8)-1:0] m_axi_wstrb      ,
    output wire                              m_axi_wlast      ,
    output wire [       AXI_WUSER_WIDTH-1:0] m_axi_wuser      ,
    output wire                              m_axi_wvalid     ,
    input  wire                              m_axi_wready     ,

    // AXI写响应通道
    input  wire [          AXI_ID_WIDTH-1:0] m_axi_bid        ,
    input  wire [                       1:0] m_axi_bresp      ,
    input  wire [       AXI_BUSER_WIDTH-1:0] m_axi_buser      ,
    input  wire                              m_axi_bvalid     ,
    output wire                              m_axi_bready      ,
    input  wire                              dbg_m00_awvalid   ,
    input  wire                              dbg_m00_awready   ,
    input  wire                              dbg_m00_wvalid    ,
    input  wire                              dbg_m00_wready    ,
    input  wire                              dbg_m00_wlast     ,
    input  wire                              dbg_m00_bvalid    ,
    input  wire                              dbg_m00_bready    ,
    input  wire                              dbg_m01_awvalid   ,
    input  wire                              dbg_m01_awready   ,
    input  wire                              dbg_m01_wvalid    ,
    input  wire                              dbg_m01_wready    ,
    input  wire                              dbg_m01_wlast     ,
    input  wire                              dbg_m01_bvalid    ,
    input  wire                              dbg_m01_bready

);

    // AXI RAM 写接口
    wire                                  ram_wr_en          ;
    wire [            AXI_ADDR_WIDTH-1:0] ram_wr_addr        ;
    wire [            AXI_DATA_WIDTH-1:0] ram_wr_data        ;
    wire [        (AXI_DATA_WIDTH/8)-1:0] ram_wr_strb        ;
    
    // RAM阵列A写入接口
    wire [                   PE_SIZE-1:0] ram_a_wr_en        ;
    wire [    RAM_ADDR_WIDTH*PE_SIZE-1:0] ram_a_wr_addr      ;
    wire [    RAM_DATA_WIDTH*PE_SIZE-1:0] ram_a_wr_data      ;
    wire [(RAM_DATA_WIDTH/8)*PE_SIZE-1:0] ram_a_wr_strb      ; // 写选通

    wire                                  a_index_wr_en      ;
    wire [            RAM_ADDR_WIDTH-1:0] a_index_wr_addr    ;
    wire [            RAM_DATA_WIDTH-1:0] a_index_wr_data    ;
    
    // RAM阵列B写入接口
    wire [                   PE_SIZE-1:0] ram_b_wr_en        ;
    wire [    RAM_ADDR_WIDTH*PE_SIZE-1:0] ram_b_wr_addr      ;
    wire [    RAM_DATA_WIDTH*PE_SIZE-1:0] ram_b_wr_data      ;
    wire [(RAM_DATA_WIDTH/8)*PE_SIZE-1:0] ram_b_wr_strb      ;  // 写选通

    // RAM阵列C写入接口
    wire [                   PE_SIZE-1:0] ram_c_wr_en        ;
    wire [  RAM_C_ADDR_WIDTH*PE_SIZE-1:0] ram_c_wr_addr      ;
    wire [    RAM_DATA_WIDTH*PE_SIZE-1:0] ram_c_wr_data      ;
    wire [(RAM_DATA_WIDTH/8)*PE_SIZE-1:0] ram_c_wr_strb      ;  // 写选通
    
    // A矩阵RAM阵列读接口
    wire [                   PE_SIZE-1:0] ram_a_rd_en        ;
    wire [    RAM_ADDR_WIDTH*PE_SIZE-1:0] ram_a_rd_addr      ;
    wire [    RAM_DATA_WIDTH*PE_SIZE-1:0] ram_a_rd_data      ;
    
    // A矩阵阵列写接口
    wire [                   PE_SIZE-1:0] systolic_a_wr_en   ;
    wire [        DATA_WIDTH*PE_SIZE-1:0] systolic_a_wr_data ;

    // B矩阵RAM阵列读接口
    wire [                   PE_SIZE-1:0] ram_b_rd_en        ;
    wire [    RAM_ADDR_WIDTH*PE_SIZE-1:0] ram_b_rd_addr      ;
    wire [    RAM_DATA_WIDTH*PE_SIZE-1:0] ram_b_rd_data      ;
    
    // B矩阵阵列写接口
    wire [                   PE_SIZE-1:0] systolic_b_wr_en   ;
    wire [        DATA_WIDTH*PE_SIZE-1:0] systolic_b_wr_data ;

    // C矩阵RAM阵列读接口
    wire [                   PE_SIZE-1:0] ram_c_rd_en        ;
    wire [  RAM_C_ADDR_WIDTH*PE_SIZE-1:0] ram_c_rd_addr      ;
    wire [    RAM_DATA_WIDTH*PE_SIZE-1:0] ram_c_rd_data      ;
    
    // C矩阵FIFO阵列写接口
    wire [                   PE_SIZE-1:0] fifo_c_wr_en       ;
    wire [   FIFO_DATA_WIDTH*PE_SIZE-1:0] fifo_c_wr_data     ;
    wire [                   PE_SIZE-1:0] fifo_c_full        ; // FIFO满信号
    wire [                   PE_SIZE-1:0] fifo_c_almost_full ; // FIFO接近满信号

    wire                                  axi_wr_ready       ;

    // CSR访问
    wire                                  csr_wr_en          ;
    wire [            CSR_ADDR_WIDTH-1:0] csr_wr_addr        ;
    wire [            CSR_DATA_WIDTH-1:0] csr_wr_data        ;
    wire [          CSR_DATA_WIDTH/8-1:0] csr_wr_strb        ;
    wire                                  csr_rd_en          ;
    wire [            CSR_ADDR_WIDTH-1:0] csr_rd_addr        ;
    wire [            CSR_DATA_WIDTH-1:0] csr_rd_data        ;

    wire [          MATRIX_DIM_WIDTH-1:0] matrix_m1          ;
    wire [          MATRIX_DIM_WIDTH-1:0] matrix_n1          ;
    wire [          MATRIX_DIM_WIDTH-1:0] matrix_k1          ;
    wire [      PRECISION_MODE_WIDTH-1:0] precision_mode1    ;
    wire                                  sparse_en1         ;

    wire [          MATRIX_DIM_WIDTH-1:0] matrix_m2          ;
    wire [          MATRIX_DIM_WIDTH-1:0] matrix_n2          ;
    wire [          MATRIX_DIM_WIDTH-1:0] matrix_k2          ;
    wire [      PRECISION_MODE_WIDTH-1:0] precision_mode2    ;
    wire                                  sparse_en2         ;

    wire [          MATRIX_DIM_WIDTH-1:0] matrix_m3          ;
    wire [          MATRIX_DIM_WIDTH-1:0] matrix_n3          ;
    wire [          MATRIX_DIM_WIDTH-1:0] matrix_k3          ;
    wire [      PRECISION_MODE_WIDTH-1:0] precision_mode3    ;

    wire                                  ram_a_wr_done      ; // A矩阵写入完成信号
    wire                                  ram_b_wr_done      ; // B矩阵写入完成信号
    wire                                  ram_c_wr_done      ; // C矩阵写入完成信号

    wire                                  ram_a_read_ready   ; // A矩阵读取准备就绪信号
    wire                                  ram_b_read_ready   ; // B矩阵读取准备就绪信号
    wire                                  ram_c_read_ready   ; // C矩阵读取准备就绪信号
    wire                                  ram_d_read_ready   ; // D矩阵读取准备就绪信号

    wire                                  ram_a_write_ready  ; // A矩阵写入准备就绪信号
    wire                                  ram_b_write_ready  ; // B矩阵写入准备就绪信号
    wire                                  ram_c_write_ready  ; // C矩阵写入准备就绪信号
    wire                                  ram_d_write_ready  ; // D矩阵写入准备就绪信号
    wire                                  mapper_a_active_dbg;
    wire                                  mapper_b_active_dbg;
    wire                                  mapper_c_active_dbg;

    wire                                  load_busy          ; // 忙状态指示
    wire                                  load_done          ; // 传输完成指示

    wire                                  rctf_done          ;
    wire                                  rctf_busy          ;

    // A矩阵FIFO阵列读接口
    wire [                   PE_SIZE-1:0] fifo_a_rd_en       ;
    wire [   FIFO_DATA_WIDTH*PE_SIZE-1:0] fifo_a_rd_data     ;
    wire [                   PE_SIZE-1:0] fifo_a_empty       ;
    wire [                   PE_SIZE-1:0] fifo_a_almost_empty;

    // B矩阵FIFO阵列读接口
    wire [                   PE_SIZE-1:0] fifo_b_rd_en       ;
    wire [   FIFO_DATA_WIDTH*PE_SIZE-1:0] fifo_b_rd_data     ;
    wire [                   PE_SIZE-1:0] fifo_b_empty       ;
    wire [                   PE_SIZE-1:0] fifo_b_almost_empty;

    // C矩阵FIFO阵列读接口
    wire [                   PE_SIZE-1:0] fifo_c_rd_en       ;
    wire [   FIFO_DATA_WIDTH*PE_SIZE-1:0] fifo_c_rd_data     ;
    wire [                   PE_SIZE-1:0] fifo_c_empty       ;
    wire [                   PE_SIZE-1:0] fifo_c_almost_empty;

    // 脉动阵列数据接口
    wire [   FIFO_DATA_WIDTH*PE_SIZE-1:0] systolic_a_data    ;
    wire [   FIFO_DATA_WIDTH*PE_SIZE-1:0] systolic_b_data    ;
    
    // 第一个数据和最后一个数据脉冲
    wire                                  first_data         ;
    wire                                  last_data          ;

    wire [     DATA_WIDTH*PE_SIZE*PE_SIZE-1:0]  systolic_to_accu_data ;
    wire [     PE_SIZE-1:0]               systolic_to_accu_sel  ;

    wire [     DATA_WIDTH*PE_SIZE-1:0]    accu_to_fifo_data     ;
    wire [     PE_SIZE-1:0]               accu_to_fifo_wr_en    ;

    wire                                  systolic_done         ;
    wire                                  accu_output_done      ;
    wire                                  soft_reset_active     ;
    wire                                  core_rst_n            ;
    wire                                  accu_partial_accept_dbg;
    wire [     DATA_WIDTH*PE_SIZE-1:0]    accu_data             ;
    wire [        DATA_WIDTH-1:0]          accu_first_word_dbg   ;
    wire [        DATA_WIDTH-1:0]          accu_last_word_dbg    ;
    wire                                   accu_first_word_vld_dbg;
    wire                                   accu_last_word_vld_dbg;
    wire [                  7:0]           accu_ctrl_flags_dbg   ;
    wire [                  7:0]           accu_ctrl_partial_phase_dbg;
    wire [                  7:0]           accu_ctrl_partials_per_output_dbg;
    wire [                 19:0]           accu_ctrl_valid_cycle_count_dbg;
    wire [                 19:0]           accu_ctrl_emit_cycle_count_dbg;
    wire [                 19:0]           accu_ctrl_valid_cycle_limit_dbg;
    wire [                 19:0]           accu_ctrl_output_cycle_limit_dbg;
    wire [PRECISION_MODE_WIDTH-1:0]        accu_ctrl_precision_mode_dbg;

    wire                                  fifo_c_rd_en_single   ;

    wire [    RAM_DATA_WIDTH*PE_SIZE-1:0] ram_d_wr_data         ;
    wire [          RAM_DATA_WIDTH/8-1:0] ram_d_wr_strb         ;
    wire                                  ram_d_wr_en           ;
    wire [          RAM_D_ADDR_WIDTH-1:0] ram_d_wr_addr         ;

    wire                                  compute_done          ;

    wire [    RAM_DATA_WIDTH*PE_SIZE-1:0] ram_d_rd_data         ;
    wire [                   PE_SIZE-1:0] ram_d_rd_en           ;
    wire [  RAM_D_ADDR_WIDTH*PE_SIZE-1:0] ram_d_rd_addr         ;

    wire [        DATA_WIDTH*PE_SIZE-1:0] up_all                ;      //8columns input,8bit num
    wire [        DATA_WIDTH*PE_SIZE-1:0] left_all              ;      //8rows input ,8bit num
    wire [        1:0]                    control               ;

    wire                                  transfer_start        ; // 传输开始脉冲
    wire [            AXI_ADDR_WIDTH-1:0] store_target_addr_cfg ; // 外部写回目标地址配置
    wire [            AXI_ADDR_WIDTH-1:0] axi_target_addr       ; // AXI目标地址
    wire [                          15:0] transfer_count        ; // 传输数据量
    wire [            AXI_ADDR_WIDTH-1:0] ram_base_addr         ; // RAM基地址
    wire                                  transfer_done         ; // 传输完成信号
    wire [                           7:0] ram_d_wr_addr_dbg     ; // 调试: D写地址扩展到8bit
    wire [                           1:0] transfer_status       ; // 传输状态

    wire                                  axi_rd_en             ;
    wire [            AXI_ADDR_WIDTH-1:0] axi_rd_addr           ;
    wire [            AXI_DATA_WIDTH-1:0] axi_rd_data           ;
    wire                                  axi_rd_data_vld       ;

    localparam [1:0] AXI_DBG_SEL_NONE = 2'd0;
    localparam [1:0] AXI_DBG_SEL_A    = 2'd1;
    localparam [1:0] AXI_DBG_SEL_B    = 2'd2;
    localparam [1:0] AXI_DBG_SEL_C    = 2'd3;

    wire                                  axi_aw_hs            ;
    wire                                  axi_w_hs             ;
    wire                                  branch_m00_aw_hs_dbg ;
    wire                                  branch_m00_w_hs_dbg  ;
    wire                                  branch_m00_wlast_hs_dbg;
    wire                                  branch_m00_b_hs_dbg  ;
    wire                                  branch_m01_aw_hs_dbg ;
    wire                                  branch_m01_w_hs_dbg  ;
    wire                                  branch_m01_wlast_hs_dbg;
    wire                                  branch_m01_b_hs_dbg  ;
    wire [1:0]                            axi_aw_matrix_sel_dbg;
    wire [1:0]                            axi_ram_matrix_sel_dbg;
    wire                                  axi_dbg_clear        ;
    reg  [1:0]                            axi_active_matrix_sel_dbg;
    reg  [1:0]                            axi_last_aw_matrix_sel_dbg;
    reg  [9:0]                            axi_aw_count_a_dbg   ;
    reg  [9:0]                            axi_aw_count_b_dbg   ;
    reg  [9:0]                            axi_aw_count_c_dbg   ;
    reg  [9:0]                            axi_aw_beats_a_dbg   ;
    reg  [9:0]                            axi_aw_beats_b_dbg   ;
    reg  [9:0]                            axi_aw_beats_c_dbg   ;
    reg  [9:0]                            axi_w_count_a_dbg    ;
    reg  [9:0]                            axi_w_count_b_dbg    ;
    reg  [9:0]                            axi_w_count_c_dbg    ;
    reg  [9:0]                            axi_wlast_count_a_dbg;
    reg  [9:0]                            axi_wlast_count_b_dbg;
    reg  [9:0]                            axi_wlast_count_c_dbg;
    reg  [9:0]                            axi_ram_wr_count_a_dbg;
    reg  [9:0]                            axi_ram_wr_count_b_dbg;
    reg  [9:0]                            axi_ram_wr_count_c_dbg;
    reg  [7:0]                            axi_last_awlen_dbg   ;
    reg  [(AXI_DATA_WIDTH/8)-1:0]         axi_last_wstrb_dbg   ;
    wire [31:0]                           axi_aw_counts_dbg    ;
    wire [31:0]                           axi_aw_beats_dbg     ;
    wire [31:0]                           axi_w_counts_dbg     ;
    wire [31:0]                           axi_wlast_counts_dbg ;
    wire [31:0]                           axi_ram_wr_counts_dbg;
    wire [31:0]                           axi_last_ctrl_dbg    ;
    wire                                  axi_short_burst_event_dbg;
    wire [7:0]                            axi_short_burst_missing_beats_dbg;
    reg  [9:0]                            axi_short_burst_count_a_dbg;
    reg  [9:0]                            axi_short_burst_count_b_dbg;
    reg  [9:0]                            axi_short_burst_count_c_dbg;
    reg  [9:0]                            axi_short_missing_beats_a_dbg;
    reg  [9:0]                            axi_short_missing_beats_b_dbg;
    reg  [9:0]                            axi_short_missing_beats_c_dbg;
    wire [31:0]                           axi_short_burst_counts_dbg;
    wire [31:0]                           axi_short_missing_beats_dbg;
    reg  [15:0]                           axi_w_total_count_dbg;
    reg  [15:0]                           axi_ram_wr_total_count_dbg;
    reg  [15:0]                           axi_w_none_count_dbg;
    reg  [15:0]                           axi_ram_wr_none_count_dbg;
    wire [31:0]                           axi_totals_dbg;
    wire [31:0]                           axi_none_counts_dbg;

    assign control                = {last_data, first_data} ;
    assign left_all               = systolic_a_data         ;
    assign up_all                 = systolic_b_data         ;
    assign fifo_c_rd_en           = {PE_SIZE{fifo_c_rd_en_single}};
    assign ram_d_wr_addr_dbg      = ram_d_wr_addr[7:0];
    assign axi_aw_hs              = s_axi_awvalid && s_axi_awready;
    assign axi_w_hs               = s_axi_wvalid && s_axi_wready;
    assign branch_m00_aw_hs_dbg   = dbg_m00_awvalid && dbg_m00_awready;
    assign branch_m00_w_hs_dbg    = dbg_m00_wvalid && dbg_m00_wready;
    assign branch_m00_wlast_hs_dbg = dbg_m00_wvalid && dbg_m00_wready && dbg_m00_wlast;
    assign branch_m00_b_hs_dbg    = dbg_m00_bvalid && dbg_m00_bready;
    assign branch_m01_aw_hs_dbg   = dbg_m01_awvalid && dbg_m01_awready;
    assign branch_m01_w_hs_dbg    = dbg_m01_wvalid && dbg_m01_wready;
    assign branch_m01_wlast_hs_dbg = dbg_m01_wvalid && dbg_m01_wready && dbg_m01_wlast;
    assign branch_m01_b_hs_dbg    = dbg_m01_bvalid && dbg_m01_bready;
    assign axi_aw_matrix_sel_dbg  = (s_axi_awaddr >= MATRIX_A_BASE_ADDR && s_axi_awaddr < MATRIX_B_BASE_ADDR) ? AXI_DBG_SEL_A :
                                    (s_axi_awaddr >= MATRIX_B_BASE_ADDR && s_axi_awaddr < MATRIX_C_BASE_ADDR) ? AXI_DBG_SEL_B :
                                    (s_axi_awaddr >= MATRIX_C_BASE_ADDR && s_axi_awaddr < MATRIX_D_BASE_ADDR) ? AXI_DBG_SEL_C :
                                                                                                                 AXI_DBG_SEL_NONE;
    assign axi_ram_matrix_sel_dbg = (ram_wr_addr >= MATRIX_A_BASE_ADDR && ram_wr_addr < MATRIX_B_BASE_ADDR) ? AXI_DBG_SEL_A :
                                    (ram_wr_addr >= MATRIX_B_BASE_ADDR && ram_wr_addr < MATRIX_C_BASE_ADDR) ? AXI_DBG_SEL_B :
                                    (ram_wr_addr >= MATRIX_C_BASE_ADDR && ram_wr_addr < MATRIX_D_BASE_ADDR) ? AXI_DBG_SEL_C :
                                                                                                               AXI_DBG_SEL_NONE;
    assign axi_dbg_clear          = csr_wr_en && (csr_wr_addr == 8'h00) && csr_wr_strb[0] && csr_wr_data[0];
    assign axi_aw_counts_dbg      = {2'b00, axi_aw_count_c_dbg, axi_aw_count_b_dbg, axi_aw_count_a_dbg};
    assign axi_aw_beats_dbg       = {2'b00, axi_aw_beats_c_dbg, axi_aw_beats_b_dbg, axi_aw_beats_a_dbg};
    assign axi_w_counts_dbg       = {2'b00, axi_w_count_c_dbg, axi_w_count_b_dbg, axi_w_count_a_dbg};
    assign axi_wlast_counts_dbg   = {2'b00, axi_wlast_count_c_dbg, axi_wlast_count_b_dbg, axi_wlast_count_a_dbg};
    assign axi_ram_wr_counts_dbg  = {2'b00, axi_ram_wr_count_c_dbg, axi_ram_wr_count_b_dbg, axi_ram_wr_count_a_dbg};
    assign axi_last_ctrl_dbg      = {12'h000, axi_last_wstrb_dbg[7:0], axi_last_awlen_dbg, 4'h0, axi_active_matrix_sel_dbg, axi_last_aw_matrix_sel_dbg};
    assign axi_short_burst_counts_dbg = {2'b00, axi_short_burst_count_c_dbg, axi_short_burst_count_b_dbg, axi_short_burst_count_a_dbg};
    assign axi_short_missing_beats_dbg = {2'b00, axi_short_missing_beats_c_dbg, axi_short_missing_beats_b_dbg, axi_short_missing_beats_a_dbg};
    assign axi_totals_dbg         = {axi_ram_wr_total_count_dbg, axi_w_total_count_dbg};
    assign axi_none_counts_dbg    = {axi_ram_wr_none_count_dbg, axi_w_none_count_dbg};
    assign core_rst_n             = rst_n && !soft_reset_active;

    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            axi_active_matrix_sel_dbg  <= AXI_DBG_SEL_NONE;
            axi_last_aw_matrix_sel_dbg <= AXI_DBG_SEL_NONE;
            axi_aw_count_a_dbg         <= 10'd0;
            axi_aw_count_b_dbg         <= 10'd0;
            axi_aw_count_c_dbg         <= 10'd0;
            axi_aw_beats_a_dbg         <= 10'd0;
            axi_aw_beats_b_dbg         <= 10'd0;
            axi_aw_beats_c_dbg         <= 10'd0;
            axi_w_count_a_dbg          <= 10'd0;
            axi_w_count_b_dbg          <= 10'd0;
            axi_w_count_c_dbg          <= 10'd0;
            axi_wlast_count_a_dbg      <= 10'd0;
            axi_wlast_count_b_dbg      <= 10'd0;
            axi_wlast_count_c_dbg      <= 10'd0;
            axi_ram_wr_count_a_dbg     <= 10'd0;
            axi_ram_wr_count_b_dbg     <= 10'd0;
            axi_ram_wr_count_c_dbg     <= 10'd0;
            axi_short_burst_count_a_dbg <= 10'd0;
            axi_short_burst_count_b_dbg <= 10'd0;
            axi_short_burst_count_c_dbg <= 10'd0;
            axi_short_missing_beats_a_dbg <= 10'd0;
            axi_short_missing_beats_b_dbg <= 10'd0;
            axi_short_missing_beats_c_dbg <= 10'd0;
            axi_w_total_count_dbg       <= 16'd0;
            axi_ram_wr_total_count_dbg  <= 16'd0;
            axi_w_none_count_dbg        <= 16'd0;
            axi_ram_wr_none_count_dbg   <= 16'd0;
            axi_last_awlen_dbg         <= 8'd0;
            axi_last_wstrb_dbg         <= {(AXI_DATA_WIDTH/8){1'b0}};
        end else if (axi_dbg_clear) begin
            axi_active_matrix_sel_dbg  <= AXI_DBG_SEL_NONE;
            axi_last_aw_matrix_sel_dbg <= AXI_DBG_SEL_NONE;
            axi_aw_count_a_dbg         <= 10'd0;
            axi_aw_count_b_dbg         <= 10'd0;
            axi_aw_count_c_dbg         <= 10'd0;
            axi_aw_beats_a_dbg         <= 10'd0;
            axi_aw_beats_b_dbg         <= 10'd0;
            axi_aw_beats_c_dbg         <= 10'd0;
            axi_w_count_a_dbg          <= 10'd0;
            axi_w_count_b_dbg          <= 10'd0;
            axi_w_count_c_dbg          <= 10'd0;
            axi_wlast_count_a_dbg      <= 10'd0;
            axi_wlast_count_b_dbg      <= 10'd0;
            axi_wlast_count_c_dbg      <= 10'd0;
            axi_ram_wr_count_a_dbg     <= 10'd0;
            axi_ram_wr_count_b_dbg     <= 10'd0;
            axi_ram_wr_count_c_dbg     <= 10'd0;
            axi_short_burst_count_a_dbg <= 10'd0;
            axi_short_burst_count_b_dbg <= 10'd0;
            axi_short_burst_count_c_dbg <= 10'd0;
            axi_short_missing_beats_a_dbg <= 10'd0;
            axi_short_missing_beats_b_dbg <= 10'd0;
            axi_short_missing_beats_c_dbg <= 10'd0;
            axi_w_total_count_dbg       <= 16'd0;
            axi_ram_wr_total_count_dbg  <= 16'd0;
            axi_w_none_count_dbg        <= 16'd0;
            axi_ram_wr_none_count_dbg   <= 16'd0;
            axi_last_awlen_dbg         <= 8'd0;
            axi_last_wstrb_dbg         <= {(AXI_DATA_WIDTH/8){1'b0}};
        end else begin
            if (axi_aw_hs) begin
                axi_active_matrix_sel_dbg  <= axi_aw_matrix_sel_dbg;
                axi_last_aw_matrix_sel_dbg <= axi_aw_matrix_sel_dbg;
                axi_last_awlen_dbg         <= s_axi_awlen;
                case (axi_aw_matrix_sel_dbg)
                    AXI_DBG_SEL_A: begin
                        axi_aw_count_a_dbg <= axi_aw_count_a_dbg + 10'd1;
                        axi_aw_beats_a_dbg <= axi_aw_beats_a_dbg + {2'b00, s_axi_awlen} + 10'd1;
                    end
                    AXI_DBG_SEL_B: begin
                        axi_aw_count_b_dbg <= axi_aw_count_b_dbg + 10'd1;
                        axi_aw_beats_b_dbg <= axi_aw_beats_b_dbg + {2'b00, s_axi_awlen} + 10'd1;
                    end
                    AXI_DBG_SEL_C: begin
                        axi_aw_count_c_dbg <= axi_aw_count_c_dbg + 10'd1;
                        axi_aw_beats_c_dbg <= axi_aw_beats_c_dbg + {2'b00, s_axi_awlen} + 10'd1;
                    end
                    default: begin
                    end
                endcase
            end

            if (axi_w_hs) begin
                axi_w_total_count_dbg <= axi_w_total_count_dbg + 16'd1;
                axi_last_wstrb_dbg <= s_axi_wstrb;
                case (axi_active_matrix_sel_dbg)
                    AXI_DBG_SEL_A: begin
                        axi_w_count_a_dbg <= axi_w_count_a_dbg + 10'd1;
                        if (s_axi_wlast) begin
                            axi_wlast_count_a_dbg <= axi_wlast_count_a_dbg + 10'd1;
                        end
                    end
                    AXI_DBG_SEL_B: begin
                        axi_w_count_b_dbg <= axi_w_count_b_dbg + 10'd1;
                        if (s_axi_wlast) begin
                            axi_wlast_count_b_dbg <= axi_wlast_count_b_dbg + 10'd1;
                        end
                    end
                    AXI_DBG_SEL_C: begin
                        axi_w_count_c_dbg <= axi_w_count_c_dbg + 10'd1;
                        if (s_axi_wlast) begin
                            axi_wlast_count_c_dbg <= axi_wlast_count_c_dbg + 10'd1;
                        end
                    end
                    default: begin
                        axi_w_none_count_dbg <= axi_w_none_count_dbg + 16'd1;
                    end
                endcase
                if (s_axi_wlast) begin
                    axi_active_matrix_sel_dbg <= AXI_DBG_SEL_NONE;
                end
            end

            if (ram_wr_en) begin
                axi_ram_wr_total_count_dbg <= axi_ram_wr_total_count_dbg + 16'd1;
                case (axi_ram_matrix_sel_dbg)
                    AXI_DBG_SEL_A: axi_ram_wr_count_a_dbg <= axi_ram_wr_count_a_dbg + 10'd1;
                    AXI_DBG_SEL_B: axi_ram_wr_count_b_dbg <= axi_ram_wr_count_b_dbg + 10'd1;
                    AXI_DBG_SEL_C: axi_ram_wr_count_c_dbg <= axi_ram_wr_count_c_dbg + 10'd1;
                    default: begin
                        axi_ram_wr_none_count_dbg <= axi_ram_wr_none_count_dbg + 16'd1;
                    end
                endcase
            end

            if (axi_short_burst_event_dbg) begin
                case (axi_active_matrix_sel_dbg)
                    AXI_DBG_SEL_A: begin
                        axi_short_burst_count_a_dbg <= axi_short_burst_count_a_dbg + 10'd1;
                        axi_short_missing_beats_a_dbg <= axi_short_missing_beats_a_dbg + {2'b00, axi_short_burst_missing_beats_dbg};
                    end
                    AXI_DBG_SEL_B: begin
                        axi_short_burst_count_b_dbg <= axi_short_burst_count_b_dbg + 10'd1;
                        axi_short_missing_beats_b_dbg <= axi_short_missing_beats_b_dbg + {2'b00, axi_short_burst_missing_beats_dbg};
                    end
                    AXI_DBG_SEL_C: begin
                        axi_short_burst_count_c_dbg <= axi_short_burst_count_c_dbg + 10'd1;
                        axi_short_missing_beats_c_dbg <= axi_short_missing_beats_c_dbg + {2'b00, axi_short_burst_missing_beats_dbg};
                    end
                    default: begin
                    end
                endcase
            end
        end
    end




    axi4_full_slave #(
        .AXI_ID_WIDTH     (AXI_ID_WIDTH    ) ,
        .AXI_ADDR_WIDTH   (AXI_ADDR_WIDTH  ) ,
        .AXI_DATA_WIDTH   (AXI_DATA_WIDTH  ) ,
        .AXI_AWUSER_WIDTH (AXI_AWUSER_WIDTH) ,
        .AXI_WUSER_WIDTH  (AXI_WUSER_WIDTH ) ,
        .AXI_BUSER_WIDTH  (AXI_BUSER_WIDTH )
    ) axi4_full_slave_inst (
        // Global signals
        .s_axi_aclk       (clk),
        .s_axi_aresetn    (core_rst_n),

        // Write address channel
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

        // Write data channel
        .s_axi_wdata      (s_axi_wdata),
        .s_axi_wstrb      (s_axi_wstrb),
        .s_axi_wlast      (s_axi_wlast),
        .s_axi_wuser      (s_axi_wuser),
        .s_axi_wvalid     (s_axi_wvalid),
        .s_axi_wready     (s_axi_wready),

        // Write response channel
        .s_axi_bid        (s_axi_bid),
        .s_axi_bresp      (s_axi_bresp),
        .s_axi_buser      (s_axi_buser),
        .s_axi_bvalid     (s_axi_bvalid),
        .s_axi_bready     (s_axi_bready),

        // RAM interface outputs
        .ram_wr_en        (ram_wr_en),
        .ram_wr_addr      (ram_wr_addr),
        .ram_wr_data      (ram_wr_data),
        .ram_wr_strb      (ram_wr_strb),
        .dbg_short_burst_event(axi_short_burst_event_dbg),
        .dbg_short_burst_missing_beats(axi_short_burst_missing_beats_dbg),

        .ram_wr_ready     (axi_wr_ready)
    );

    axi4_lite_slave #(
        .AXI_DATA_WIDTH(CSR_DATA_WIDTH),  // 数据位宽
        .AXI_ADDR_WIDTH(CSR_ADDR_WIDTH)   // 地址位宽，8bit=256字节空间
    ) axi4_lite_slave_inst (
        .s_axil_aclk     (clk),
        .s_axil_aresetn  (rst_n),
        
        // 写地址通道
        .s_axil_awaddr   (s_axil_awaddr),
        .s_axil_awvalid  (s_axil_awvalid),
        .s_axil_awready  (s_axil_awready),
        
        // 写数据通道
        .s_axil_wdata    (s_axil_wdata),
        .s_axil_wstrb    (s_axil_wstrb),
        .s_axil_wvalid   (s_axil_wvalid),
        .s_axil_wready   (s_axil_wready),
        
        // 写响应通道
        .s_axil_bresp    (s_axil_bresp),
        .s_axil_bvalid   (s_axil_bvalid),
        .s_axil_bready   (s_axil_bready),
        
        // 读地址通道
        .s_axil_araddr   (s_axil_araddr),
        .s_axil_arvalid  (s_axil_arvalid),
        .s_axil_arready  (s_axil_arready),
        
        // 读数据通道
        .s_axil_rdata    (s_axil_rdata),
        .s_axil_rresp    (s_axil_rresp),
        .s_axil_rvalid   (s_axil_rvalid),
        .s_axil_rready   (s_axil_rready),
        
        // CSR接口信号
        .csr_wr_en       (csr_wr_en),
        .csr_wr_addr     (csr_wr_addr),
        .csr_wr_data     (csr_wr_data),
        .csr_wr_strb     (csr_wr_strb),
        .csr_rd_en       (csr_rd_en),
        .csr_rd_addr     (csr_rd_addr),
        .csr_rd_data     (csr_rd_data)
    );

    csr_bank #(
        .CSR_DATA_WIDTH (CSR_DATA_WIDTH) ,
        .CSR_ADDR_WIDTH (CSR_ADDR_WIDTH) ,
        .MATRIX_DIM_WIDTH (MATRIX_DIM_WIDTH) ,
        .PRECISION_MODE_WIDTH (PRECISION_MODE_WIDTH) ,
        .MATRIX_D_BASE_ADDR (MATRIX_D_BASE_ADDR)
    ) csr_bank_inst(
        // 时钟和复位
        .clk                 (clk),
        .rst_n               (rst_n),
        
        // CSR访问接口
        .csr_wr_en           (csr_wr_en),
        .csr_wr_addr         (csr_wr_addr),
        .csr_wr_data         (csr_wr_data),
        .csr_wr_strb         (csr_wr_strb),
        .csr_rd_en           (csr_rd_en),
        .csr_rd_addr         (csr_rd_addr),
        .csr_rd_data         (csr_rd_data),

        .axi_ram_wr_en       (ram_wr_en),
        .axi_ram_wr_addr     (ram_wr_addr),
        
        // AXI数据传输控制
        .axi_wr_ready        (axi_wr_ready), // AXI写就绪信号

        .ram_a_wr_done       (ram_a_wr_done), // RAM A写完成信号
        .ram_b_wr_done       (ram_b_wr_done), // RAM B写完成信号
        .ram_c_write_ready   (ram_c_write_ready), // RAM 写就绪信号
        .ram_c_wr_done       (ram_c_wr_done), // RAM C写完成信号

        .ram_a_read_ready    (ram_a_read_ready), // RAM A读就绪信号
        .ram_b_read_ready    (ram_b_read_ready), // RAM B读就绪信号
        .ram_a_write_ready   (ram_a_write_ready), // RAM A写就绪信号
        .ram_b_write_ready   (ram_b_write_ready), // RAM B写就绪信号
        .ram_d_write_ready   (ram_d_write_ready), // RAM D写就绪信号
        .compute_done        (compute_done), // 计算完成信号

        .ram_d_read_ready    (ram_d_read_ready),
        .transfer_done       (transfer_done),
        .mapper_a_active_dbg (mapper_a_active_dbg),
        .mapper_b_active_dbg (mapper_b_active_dbg),
        .mapper_c_active_dbg (mapper_c_active_dbg),
        .rctf_done_dbg       (rctf_done),
        .systolic_done_dbg   (systolic_done),
        .accu_output_done_dbg(accu_output_done),
        .accu_partial_accept_dbg(accu_partial_accept_dbg),
        .accu_fifo_wr_en_dbg (|accu_to_fifo_wr_en),
        .fifo_c_rd_en_dbg    (fifo_c_rd_en_single),
        .ram_d_wr_en_dbg     (ram_d_wr_en),
        .ram_d_wr_addr_dbg   (ram_d_wr_addr_dbg),
        .systolic_valid_dbg  (|systolic_to_accu_sel),
        .systolic_wr_en_dbg  (|systolic_a_wr_en),
        .first_data_dbg      (first_data),
        .last_data_dbg       (last_data),
        .accu_first_word_dbg (accu_first_word_dbg),
        .accu_first_word_vld_dbg(accu_first_word_vld_dbg),
        .accu_last_word_dbg  (accu_last_word_dbg),
        .accu_last_word_vld_dbg(accu_last_word_vld_dbg),
        .accu_ctrl_flags_dbg (accu_ctrl_flags_dbg),
        .accu_ctrl_partial_phase_dbg(accu_ctrl_partial_phase_dbg),
        .accu_ctrl_partials_per_output_dbg(accu_ctrl_partials_per_output_dbg),
        .accu_ctrl_valid_cycle_count_dbg(accu_ctrl_valid_cycle_count_dbg),
        .accu_ctrl_emit_cycle_count_dbg(accu_ctrl_emit_cycle_count_dbg),
        .accu_ctrl_valid_cycle_limit_dbg(accu_ctrl_valid_cycle_limit_dbg),
        .accu_ctrl_output_cycle_limit_dbg(accu_ctrl_output_cycle_limit_dbg),
        .accu_ctrl_precision_mode_dbg(accu_ctrl_precision_mode_dbg),
        .axi_aw_counts_dbg     (axi_aw_counts_dbg),
        .axi_aw_beats_dbg      (axi_aw_beats_dbg),
        .axi_w_counts_dbg      (axi_w_counts_dbg),
        .axi_wlast_counts_dbg  (axi_wlast_counts_dbg),
        .axi_ram_wr_counts_dbg (axi_ram_wr_counts_dbg),
        .axi_last_ctrl_dbg     (axi_last_ctrl_dbg),
        .axi_short_burst_counts_dbg(axi_short_burst_counts_dbg),
        .axi_short_missing_beats_dbg(axi_short_missing_beats_dbg),
        .axi_totals_dbg        (axi_totals_dbg),
        .axi_none_counts_dbg   (axi_none_counts_dbg),
        .master_axi_aw_hs_dbg  (m_axi_awvalid && m_axi_awready),
        .master_axi_w_hs_dbg   (m_axi_wvalid && m_axi_wready),
        .master_axi_wlast_hs_dbg(m_axi_wvalid && m_axi_wready && m_axi_wlast),
        .master_axi_b_hs_dbg   (m_axi_bvalid && m_axi_bready),
        .master_axi_bvalid_dbg (m_axi_bvalid),
        .master_axi_awvalid_dbg(m_axi_awvalid),
        .master_axi_wvalid_dbg (m_axi_wvalid),
        .master_axi_bready_dbg (m_axi_bready),
        .master_axi_awready_dbg(m_axi_awready),
        .master_axi_wready_dbg (m_axi_wready),
        .branch_m00_aw_hs_dbg  (branch_m00_aw_hs_dbg),
        .branch_m00_w_hs_dbg   (branch_m00_w_hs_dbg),
        .branch_m00_wlast_hs_dbg(branch_m00_wlast_hs_dbg),
        .branch_m00_b_hs_dbg   (branch_m00_b_hs_dbg),
        .branch_m00_bvalid_dbg (dbg_m00_bvalid),
        .branch_m00_awvalid_dbg(dbg_m00_awvalid),
        .branch_m00_wvalid_dbg (dbg_m00_wvalid),
        .branch_m00_bready_dbg (dbg_m00_bready),
        .branch_m00_awready_dbg(dbg_m00_awready),
        .branch_m00_wready_dbg (dbg_m00_wready),
        .branch_m01_aw_hs_dbg  (branch_m01_aw_hs_dbg),
        .branch_m01_w_hs_dbg   (branch_m01_w_hs_dbg),
        .branch_m01_wlast_hs_dbg(branch_m01_wlast_hs_dbg),
        .branch_m01_b_hs_dbg   (branch_m01_b_hs_dbg),
        .branch_m01_bvalid_dbg (dbg_m01_bvalid),
        .branch_m01_awvalid_dbg(dbg_m01_awvalid),
        .branch_m01_wvalid_dbg (dbg_m01_wvalid),
        .branch_m01_bready_dbg (dbg_m01_bready),
        .branch_m01_awready_dbg(dbg_m01_awready),
        .branch_m01_wready_dbg (dbg_m01_wready),

        // 配置输出
        .matrix_m1           (matrix_m1),
        .matrix_n1           (matrix_n1),
        .matrix_k1           (matrix_k1),
        .precision_mode1     (precision_mode1),
        .sparse_en1          (sparse_en1),

        .matrix_m2           (matrix_m2),
        .matrix_n2           (matrix_n2),
        .matrix_k2           (matrix_k2),
        .precision_mode2     (precision_mode2),
        .sparse_en2          (sparse_en2),

        .matrix_m3           (matrix_m3),
        .matrix_n3           (matrix_n3),
        .matrix_k3           (matrix_k3),
        .precision_mode3     (precision_mode3),
        .store_target_addr   (store_target_addr_cfg),
        .soft_reset_active   (soft_reset_active)
    );

    matrix_mem_mapper #(
        .PE_SIZE              (PE_SIZE),
        .MATRIX_DIM_WIDTH     (MATRIX_DIM_WIDTH),
        .PRECISION_MODE_WIDTH (PRECISION_MODE_WIDTH),
        .AXI_DATA_WIDTH       (AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH       (AXI_ADDR_WIDTH),
        .RAM_ADDR_WIDTH       (RAM_ADDR_WIDTH),
        .RAM_C_ADDR_WIDTH     (RAM_C_ADDR_WIDTH),
        .RAM_DATA_WIDTH       (RAM_DATA_WIDTH),
        .MATRIX_A_BASE_ADDR   (MATRIX_A_BASE_ADDR),
        .MATRIX_B_BASE_ADDR   (MATRIX_B_BASE_ADDR),
        .MATRIX_C_BASE_ADDR   (MATRIX_C_BASE_ADDR),
        .MATRIX_D_BASE_ADDR   (MATRIX_D_BASE_ADDR)
    ) matrix_mem_mapper_inst (
        // 时钟和复位
        .clk              (clk),
        .rst_n            (core_rst_n),
        
        // AXI RAM 写接口
        .ram_wr_en        (ram_wr_en),
        .ram_wr_addr      (ram_wr_addr),
        .ram_wr_data      (ram_wr_data),
        .ram_wr_strb      (ram_wr_strb),
        
        // CSR 寄存器配置
        .matrix_m         (matrix_m1),  
        .matrix_n         (matrix_n1),  
        .matrix_k         (matrix_k1),  
        .precision_mode   (precision_mode1),  // 数据精度模式
        .sparse_en        (sparse_en1),
        
        // RAM阵列A写入接口
        .ram_a_wr_en      (ram_a_wr_en),
        .ram_a_wr_addr    (ram_a_wr_addr),
        .ram_a_wr_data    (ram_a_wr_data),
        .ram_a_wr_strb    (ram_a_wr_strb), // 写选通

        .a_index_wr_en    (a_index_wr_en),
        .a_index_wr_addr  (a_index_wr_addr),
        .a_index_wr_data  (a_index_wr_data),

        // RAM阵列B写入接口
        .ram_b_wr_en      (ram_b_wr_en),
        .ram_b_wr_addr    (ram_b_wr_addr),
        .ram_b_wr_data    (ram_b_wr_data),
        .ram_b_wr_strb    (ram_b_wr_strb),  // 写选通

        // RAM阵列C写入接口
        .ram_c_wr_en      (ram_c_wr_en),
        .ram_c_wr_addr    (ram_c_wr_addr),
        .ram_c_wr_data    (ram_c_wr_data),
        .ram_c_wr_strb    (ram_c_wr_strb),  // 写选通

        // 矩阵写入完成信号
        .ram_a_wr_done    (ram_a_wr_done),  // A矩阵写入完成信号
        .ram_b_wr_done    (ram_b_wr_done),  // B矩阵写入完成信号  
        .ram_c_wr_done    (ram_c_wr_done),  // C矩阵写入完成信号

        // mapper内部活动导出
        .mapper_a_active  (mapper_a_active_dbg),
        .mapper_b_active  (mapper_b_active_dbg),
        .mapper_c_active  (mapper_c_active_dbg)
    );

    ram_array_pingpong #(
        .PE_SIZE        (PE_SIZE),   // PE数量/阵列大小
        .RAM_ADDR_WIDTH (RAM_ADDR_WIDTH),   // RAM地址宽度
        .RAM_DATA_WIDTH (RAM_DATA_WIDTH)    // RAM数据宽度
    ) a_ram_array_pingpong_inst (
        // 全局时钟
        .clk            (clk),
        .rst_n          (core_rst_n),

        // 缓冲区控制信号
        .write_complete (ram_a_wr_done), 
        .read_complete  (load_done),
        .buffer_select  (),
        .read_ready     (ram_a_read_ready), 
        .write_ready    (ram_a_write_ready),

        // 写接口
        .ram_wr_en      (ram_a_wr_en),
        .ram_wr_addr    (ram_a_wr_addr),
        .ram_wr_data    (ram_a_wr_data),
        .ram_wr_strb    (ram_a_wr_strb),

        // 读接口
        .ram_rd_en      (ram_a_rd_en),
        .ram_rd_addr    (ram_a_rd_addr),
        .ram_rd_data    (ram_a_rd_data)
    );

    ram_array_pingpong #(
        .PE_SIZE        (PE_SIZE),   // PE数量/阵列大小
        .RAM_ADDR_WIDTH (RAM_ADDR_WIDTH),   // RAM地址宽度
        .RAM_DATA_WIDTH (RAM_DATA_WIDTH)    // RAM数据宽度
    ) b_ram_array_pingpong_inst (
        // 全局时钟
        .clk            (clk),
        .rst_n          (core_rst_n),

        // 缓冲区控制信号
        .write_complete (ram_b_wr_done), 
        .read_complete  (load_done),
        .buffer_select  (),
        .read_ready     (ram_b_read_ready), 
        .write_ready    (ram_b_write_ready),

        // 写接口
        .ram_wr_en      (ram_b_wr_en),
        .ram_wr_addr    (ram_b_wr_addr),
        .ram_wr_data    (ram_b_wr_data),
        .ram_wr_strb    (ram_b_wr_strb),

        // 读接口
        .ram_rd_en      (ram_b_rd_en),
        .ram_rd_addr    (ram_b_rd_addr),
        .ram_rd_data    (ram_b_rd_data)
    );

    ram_array_pingpong #(
        .PE_SIZE        (PE_SIZE),   // PE数量/阵列大小
        .RAM_ADDR_WIDTH (RAM_C_ADDR_WIDTH),   // RAM地址宽度
        .RAM_DATA_WIDTH (RAM_DATA_WIDTH)    // RAM数据宽度
    ) c_ram_array_pingpong_inst (
        // 全局时钟
        .clk            (clk),
        .rst_n          (core_rst_n),

        // 缓冲区控制信号
        .write_complete (ram_c_wr_done), 
        .read_complete  (load_done),
        .buffer_select  (),
        .read_ready     (ram_c_read_ready), 
        .write_ready    (ram_c_write_ready),

        // 写接口
        .ram_wr_en      (ram_c_wr_en),
        .ram_wr_addr    (ram_c_wr_addr),
        .ram_wr_data    (ram_c_wr_data),
        .ram_wr_strb    (ram_c_wr_strb),

        // 读接口
        .ram_rd_en      (ram_c_rd_en),
        .ram_rd_addr    (ram_c_rd_addr),
        .ram_rd_data    (ram_c_rd_data)
    );

    data_flow_load #(
        .PE_SIZE              (PE_SIZE),   // PE数量/阵列大小
        .MATRIX_DIM_WIDTH     (MATRIX_DIM_WIDTH),   // 矩阵维度宽度
        .PRECISION_MODE_WIDTH (PRECISION_MODE_WIDTH),   // 精度模式宽度
        .RAM_ADDR_WIDTH       (RAM_ADDR_WIDTH),   // RAM地址宽度
        .RAM_DATA_WIDTH       (RAM_DATA_WIDTH),   // RAM数据宽度
        .SYS_DATA_WIDTH       (DATA_WIDTH)    
    ) data_flow_load_inst(
        // 时钟和复位
        .clk                (clk) ,
        .rst_n              (core_rst_n) ,

        // CSR 寄存器配置
        .matrix_m           (matrix_m1) ,
        .matrix_n           (matrix_n1) ,
        .matrix_k           (matrix_k1) ,
        .precision_mode     (precision_mode1) ,
        .sparse_en          (sparse_en1) ,
        
        // 控制信号
        .ram_a_read_ready   (ram_a_read_ready) , // A矩阵RAM准备好信号
        .ram_b_read_ready   (ram_b_read_ready) , // B矩阵RAM准备好信号
        .ram_d_write_ready  (ram_d_write_ready) ,
        .load_busy          (load_busy) , // 忙状态指示
        .load_done          (load_done) , // 传输完成指示

        .compute_done       (compute_done) ,

        .a_index_wr_en      (a_index_wr_en) ,
        .a_index_wr_addr    (a_index_wr_addr) ,
        .a_index_wr_data    (a_index_wr_data) ,

        // A矩阵RAM阵列读接口
        .ram_a_rd_en        (ram_a_rd_en) ,
        .ram_a_rd_addr      (ram_a_rd_addr) ,
        .ram_a_rd_data      (ram_a_rd_data) ,
        
        // A矩阵阵列写接口
        .systolic_a_wr_en   (systolic_a_wr_en) ,
        .systolic_a_wr_data (systolic_a_wr_data) ,

        // B矩阵RAM阵列读接口
        .ram_b_rd_en        (ram_b_rd_en) ,
        .ram_b_rd_addr      (ram_b_rd_addr) ,
        .ram_b_rd_data      (ram_b_rd_data) ,

        // B矩阵阵列写接口
        .systolic_b_wr_en   (systolic_b_wr_en) ,
        .systolic_b_wr_data (systolic_b_wr_data),

        .first_data         (first_data), // 第一个数据脉冲
        .last_data          (last_data)  // 最后一个数据脉冲
    );

    data_flow_load_c #(
        .PE_SIZE              (PE_SIZE),   // PE数量/阵列大小
        .MATRIX_DIM_WIDTH     (MATRIX_DIM_WIDTH),   // 矩阵维度宽度
        .PRECISION_MODE_WIDTH (PRECISION_MODE_WIDTH),   // 精度模式宽度
        .RAM_ADDR_WIDTH       (RAM_C_ADDR_WIDTH),   // RAM地址宽度
        .RAM_DATA_WIDTH       (RAM_DATA_WIDTH),   // RAM数据宽度
        .FIFO_DATA_WIDTH      (FIFO_DATA_WIDTH)    // FIFO数据宽度，通常与RAM_DATA_WIDTH相同
    ) data_flow_load_c_inst (
        // 时钟和复位
        .clk               (clk),
        .rst_n             (core_rst_n),
        
        // CSR 寄存器配置
        .matrix_m          (matrix_m1), // 矩阵C的行数
        .matrix_n          (matrix_n1), // 矩阵C的列数
        .precision_mode    (precision_mode1), // 精度模式
        
        // 控制信号
        .ram_c_read_ready  (ram_c_read_ready), // C矩阵写入RAM完成信号
        .ram_d_write_ready (ram_d_write_ready), // D矩阵写入RAM完成信号
        .rctf_busy         (rctf_busy), // 忙状态指示
        .rctf_done         (rctf_done), // 传输完成指示

        .compute_done      (compute_done), // 计算完成信号
        
        // C矩阵RAM读接口
        .ram_c_rd_en       (ram_c_rd_en),
        .ram_c_rd_addr     (ram_c_rd_addr),
        .ram_c_rd_data     (ram_c_rd_data),
        
        // C矩阵FIFO写接口
        .fifo_c_wr_en      (fifo_c_wr_en),
        .fifo_c_wr_data    (fifo_c_wr_data),
        .fifo_c_full       (fifo_c_full), // FIFO满信号
        .fifo_c_almost_full(fifo_c_almost_full)  // FIFO接近满信号
    );

    delay_array #(
        .PE_SIZE         (PE_SIZE),
        .DATA_WIDTH      (DATA_WIDTH)
    ) a_delay_array_inst (
        // 时钟和复位
        .clk           (clk),
        .rst_n         (core_rst_n),

        .wr_en         (systolic_a_wr_en),
        .data_in       (systolic_a_wr_data),

        .data_out      (systolic_a_data)
    );

    delay_array #(
        .PE_SIZE         (PE_SIZE),
        .DATA_WIDTH      (DATA_WIDTH)
    ) b_delay_array_inst (
        // 时钟和复位
        .clk           (clk),
        .rst_n         (core_rst_n),

        .wr_en         (systolic_b_wr_en),
        .data_in       (systolic_b_wr_data),

        .data_out      (systolic_b_data)
    );

    fifo_array #(
        .PE_SIZE        (PE_SIZE),   // FIFO数量/阵列大小
        .DATA_WIDTH     (FIFO_DATA_WIDTH),   // 每个FIFO的数据宽度
        .FIFO_DEPTH     (FIFO_DEPTH),   // 每个FIFO的深度
        .ALMOST_FULL_TH (4),   // 接近满阈值
        .ALMOST_EMPTY_TH(4)    // 接近空阈值
    ) c_fifo_array_inst (
        // 时钟和复位
        .clk           (clk),
        .rst_n         (core_rst_n),

        // 写接口
        .wr_en         (fifo_c_wr_en),
        .data_in       (fifo_c_wr_data),

        // 读接口
        .rd_en         (fifo_c_rd_en),
        .data_out      (fifo_c_rd_data),

        // 状态信号
        .full          (fifo_c_full),
        .empty         (fifo_c_empty),
        .almost_full   (fifo_c_almost_full),
        .almost_empty  (fifo_c_almost_empty)
    );


    systolic_array #(
        .DATA_WIDTH(DATA_WIDTH),
        .PE_SIZE(PE_SIZE) 
    )systolic_array_inst(
        .clk            (clk),
        .rst_n          (core_rst_n),
        .control        (control),
        .matrix_n       (matrix_n1),
        .up_all         (up_all),      //8columns input,8bit num
        .left_all       (left_all),    //8rows input ,8bit num
        .precision_mode (precision_mode1),
        .data_selected  (systolic_to_accu_data),
        .done_systolic  (systolic_done),
        .data_valid     (systolic_to_accu_sel)//sel信号，接累加器control
    );

    accumulator_array #(
        .DATA_WIDTH(DATA_WIDTH),
        .PE_SIZE(PE_SIZE)
    )accumulator_array_inst(
        .clk            (clk),
        .rst_n          (core_rst_n),
        .precision_mode (precision_mode1),
        .num            (systolic_to_accu_data),
        .data_valid     (systolic_to_accu_sel),
        .matrix_m       (matrix_m1),
        .matrix_n       (matrix_n1),
        .matrix_k       (matrix_k1),
        .out            (accu_to_fifo_data),//累加输出，接fifo阵列
        .wr_en_to_fifo  (accu_to_fifo_wr_en),
        .accu_partial_accept_dbg(accu_partial_accept_dbg),
        .accu_output_done(accu_output_done),
        .first_emitted_word_dbg(accu_first_word_dbg),
        .last_emitted_word_dbg(accu_last_word_dbg),
        .first_emitted_word_vld_dbg(accu_first_word_vld_dbg),
        .last_emitted_word_vld_dbg(accu_last_word_vld_dbg),
        .dbg_ctrl_flags(accu_ctrl_flags_dbg),
        .dbg_ctrl_partial_phase(accu_ctrl_partial_phase_dbg),
        .dbg_ctrl_partials_per_output(accu_ctrl_partials_per_output_dbg),
        .dbg_ctrl_valid_cycle_count(accu_ctrl_valid_cycle_count_dbg),
        .dbg_ctrl_emit_cycle_count(accu_ctrl_emit_cycle_count_dbg),
        .dbg_ctrl_valid_cycle_limit(accu_ctrl_valid_cycle_limit_dbg),
        .dbg_ctrl_output_cycle_limit(accu_ctrl_output_cycle_limit_dbg),
        .dbg_ctrl_precision_mode(accu_ctrl_precision_mode_dbg)
    );


    fifo_array #(
        .PE_SIZE        (PE_SIZE),   // FIFO数量/阵列大小
        .DATA_WIDTH     (FIFO_DATA_WIDTH),   // 每个FIFO的数据宽度
        .FIFO_DEPTH     (FIFO_DEPTH),   // 每个FIFO的深度
        .ALMOST_FULL_TH (4),   // 接近满阈值
        .ALMOST_EMPTY_TH(4)    // 接近空阈值
    ) a_dot_b_fifo_array_inst (
        // 时钟和复位
        .clk           (clk),
        .rst_n         (core_rst_n),

        // 写接口
        .wr_en         (accu_to_fifo_wr_en),
        .data_in       (accu_to_fifo_data),

        // 读接口
        .rd_en         (fifo_c_rd_en),
        .data_out      (accu_data),

        // 状态信号
        .full          (),
        .empty         (),
        .almost_full   (),
        .almost_empty  ()
    );

    c_matrix_adder #(
        .DATA_WIDTH(DATA_WIDTH),
        .PE_SIZE(PE_SIZE),
        .RAM_DATA_WIDTH(RAM_DATA_WIDTH),
        .ADDR_WIDTH(RAM_D_ADDR_WIDTH)
    ) c_matrix_adder_inst(
        .clk            (clk),
        .rst_n          (core_rst_n),
        .PE_data        (accu_data),
        .RAM_C_data     (fifo_c_rd_data),
        .done_systolic  (accu_output_done),
        .done_fifoC     (!fifo_c_empty),
        .done_transfer  (ram_d_write_ready),
        .precision_mode (precision_mode1),
        .matrix_m       (matrix_m1),
        .matrix_n       (matrix_n1),
        .rd_en          (fifo_c_rd_en_single),
        .wr_data        (ram_d_wr_data),
        .wr_strb        (ram_d_wr_strb),
        .wr_en          (ram_d_wr_en),
        .wr_addr        (ram_d_wr_addr),
        .done           (compute_done)
    );

    ram_array_pingpong #(
        .PE_SIZE        (PE_SIZE),   // PE数量/阵列大小
        .RAM_ADDR_WIDTH (RAM_D_ADDR_WIDTH),   // RAM地址宽度
        .RAM_DATA_WIDTH (RAM_DATA_WIDTH)    // RAM数据宽度
    ) d_ram_array_pingpong_inst (
        // 全局时钟
        .clk            (clk),
        .rst_n          (core_rst_n),

        // 缓冲区控制信号
        .write_complete (compute_done), 
        .read_complete  (transfer_done),
        .buffer_select  (),
        .read_ready     (ram_d_read_ready), 
        .write_ready    (ram_d_write_ready),

        // 写接口
        .ram_wr_en      ({PE_SIZE{ram_d_wr_en}}),
        .ram_wr_addr    ({PE_SIZE{ram_d_wr_addr}}),
        .ram_wr_data    (ram_d_wr_data),
        .ram_wr_strb    ({PE_SIZE{ram_d_wr_strb}}),

        // 读接口
        .ram_rd_en      (ram_d_rd_en),
        .ram_rd_addr    (ram_d_rd_addr),
        .ram_rd_data    (ram_d_rd_data)
    );

    transfer_d_to_axi_ctrl #(
        .PE_SIZE            (PE_SIZE),
        .AXI_DATA_WIDTH     (AXI_DATA_WIDTH),
        .AXI_ADDR_WIDTH     (AXI_ADDR_WIDTH),
        .RAM_ADDR_WIDTH     (RAM_D_ADDR_WIDTH),
        .RAM_DATA_WIDTH     (RAM_DATA_WIDTH),
        .MATRIX_D_BASE_ADDR (MATRIX_D_BASE_ADDR)
    ) transfer_d_to_axi_ctrl_inst (
        // 时钟和复位
        .clk               (clk),
        .rst_n             (core_rst_n),

        // AXI读请求接口
        .axi_rd_en         (axi_rd_en), // 读使能信号
        .axi_rd_addr       (axi_rd_addr), // 请求读地址
        .axi_rd_data       (axi_rd_data), // 读出的数据
        .axi_rd_data_vld   (axi_rd_data_vld), // 读数据有效

        // CSR寄存器配置
        .matrix_m          (matrix_m3),
        .matrix_n          (matrix_n3),
        .precision_mode    (precision_mode3),

        // RAM阵列D读取接口
        .ram_d_rd_en       (ram_d_rd_en),
        .ram_d_rd_addr     (ram_d_rd_addr),
        .ram_d_rd_data     (ram_d_rd_data),

        // 传输控制信号
        .a_dot_b_add_c_done(ram_d_read_ready), // 矩阵计算完成
        .axi_target_addr_cfg(store_target_addr_cfg), // 外部写回目标地址配置
        .transfer_start    (transfer_start), // 开始传输脉冲
        .transfer_count    (transfer_count), // 传输数据量
        .ram_base_addr     (ram_base_addr), // RAM基地址
        .axi_target_addr   (axi_target_addr), // AXI目标地址

        // 状态信号
        .transfer_done     (transfer_done), // 传输完成
        .transfer_status   (transfer_status)  // 传输状态
    );

    axi4_full_master #(
        .AXI_ID_WIDTH     (AXI_ID_WIDTH) ,
        .AXI_ADDR_WIDTH   (AXI_ADDR_WIDTH) ,
        .AXI_DATA_WIDTH   (AXI_DATA_WIDTH) ,
        .RAM_DATA_WIDTH   (RAM_DATA_WIDTH) ,
        .AXI_AWUSER_WIDTH (AXI_AWUSER_WIDTH) ,
        .AXI_WUSER_WIDTH  (AXI_WUSER_WIDTH) ,
        .AXI_BUSER_WIDTH  (AXI_BUSER_WIDTH) ,
        .MAX_BURST_LEN    (255) ,
        .FIFO_DEPTH       (16)
    ) axi4_full_master_inst(
        .m_axi_aclk       (clk),
        .m_axi_aresetn    (core_rst_n),

        // AXI写地址通道
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

        // AXI写数据通道
        .m_axi_wdata      (m_axi_wdata),
        .m_axi_wstrb      (m_axi_wstrb),
        .m_axi_wlast      (m_axi_wlast),
        .m_axi_wuser      (m_axi_wuser),
        .m_axi_wvalid     (m_axi_wvalid),
        .m_axi_wready     (m_axi_wready),

        // AXI写响应通道
        .m_axi_bid        (m_axi_bid),
        .m_axi_bresp      (m_axi_bresp),
        .m_axi_buser      (m_axi_buser),
        .m_axi_bvalid     (m_axi_bvalid),
        .m_axi_bready     (m_axi_bready),

        // RAM接口
        .axi_rd_en        (axi_rd_en),
        .axi_rd_addr      (axi_rd_addr),
        .axi_rd_data      (axi_rd_data),
        .axi_rd_data_vld  (axi_rd_data_vld),

        // 控制信号
        .transfer_start   (transfer_start),
        .transfer_count   (transfer_count),
        .ram_base_addr    (ram_base_addr), // RAM基地址
        .axi_target_addr  (axi_target_addr),

        // 状态信号
        .transfer_done    (transfer_done),
        .transfer_status  (transfer_status)
    );

    
endmodule
