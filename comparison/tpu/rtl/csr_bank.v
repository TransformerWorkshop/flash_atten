module csr_bank #(
    parameter CSR_DATA_WIDTH       = 32 ,
    parameter CSR_ADDR_WIDTH       = 8  ,
    parameter MATRIX_DIM_WIDTH     = 8  ,   // 矩阵维度宽度
    parameter PRECISION_MODE_WIDTH = 4      ,   // 精度模式宽度
    parameter MATRIX_D_BASE_ADDR   = 32'h0000_C000
)(
    // 时钟和复位
    input  wire                            clk                 ,
    input  wire                            rst_n               ,
    
    // CSR访问接口
    input  wire                            csr_wr_en           ,
    input  wire [      CSR_ADDR_WIDTH-1:0] csr_wr_addr         ,
    input  wire [      CSR_DATA_WIDTH-1:0] csr_wr_data         ,
    input  wire [    CSR_DATA_WIDTH/8-1:0] csr_wr_strb         ,
    input  wire                            csr_rd_en           ,
    input  wire [      CSR_ADDR_WIDTH-1:0] csr_rd_addr         ,
    output reg  [      CSR_DATA_WIDTH-1:0] csr_rd_data         ,

    input  wire                            axi_ram_wr_en       ,
    input  wire [               31:0]      axi_ram_wr_addr     ,

    // AXI数据传输控制
    output wire                            axi_wr_ready        , // AXI写就绪信号

    input  wire                            ram_a_wr_done       , // RAM A写完成信号
    input  wire                            ram_b_wr_done       , // RAM B写完成信号
    input  wire                            ram_c_write_ready   , // RAM C写就绪信号
    input  wire                            ram_c_wr_done       , // RAM C写完成信号

    input  wire                            ram_a_read_ready    , // RAM A读就绪信号
    input  wire                            ram_b_read_ready    , // RAM B读就绪信号
    input  wire                            ram_a_write_ready   , // RAM A写就绪信号
    input  wire                            ram_b_write_ready   , // RAM B写就绪信号
    input  wire                            ram_d_write_ready   , // RAM D写就绪信号
    input  wire                            compute_done        , // 计算完成信号

    input  wire                            ram_d_read_ready    ,
    input  wire                            transfer_done       ,
    input  wire                            mapper_a_active_dbg ,
    input  wire                            mapper_b_active_dbg ,
    input  wire                            mapper_c_active_dbg ,
    input  wire                            rctf_done_dbg       ,
    input  wire                            systolic_done_dbg   ,
    input  wire                            accu_output_done_dbg,
    input  wire                            accu_partial_accept_dbg,
    input  wire                            accu_fifo_wr_en_dbg ,
    input  wire                            fifo_c_rd_en_dbg    ,
    input  wire                            ram_d_wr_en_dbg     ,
    input  wire [7:0]                      ram_d_wr_addr_dbg   ,
    input  wire                            systolic_valid_dbg  ,
    input  wire                            systolic_wr_en_dbg  ,
    input  wire                            first_data_dbg      ,
    input  wire                            last_data_dbg       ,
    input  wire [31:0]                     accu_first_word_dbg ,
    input  wire                            accu_first_word_vld_dbg,
    input  wire [31:0]                     accu_last_word_dbg  ,
    input  wire                            accu_last_word_vld_dbg,
    input  wire [7:0]                      accu_ctrl_flags_dbg ,
    input  wire [7:0]                      accu_ctrl_partial_phase_dbg,
    input  wire [7:0]                      accu_ctrl_partials_per_output_dbg,
    input  wire [19:0]                     accu_ctrl_valid_cycle_count_dbg,
    input  wire [19:0]                     accu_ctrl_emit_cycle_count_dbg,
    input  wire [19:0]                     accu_ctrl_valid_cycle_limit_dbg,
    input  wire [19:0]                     accu_ctrl_output_cycle_limit_dbg,
    input  wire [PRECISION_MODE_WIDTH-1:0] accu_ctrl_precision_mode_dbg,
    input  wire [31:0]                     axi_aw_counts_dbg   ,
    input  wire [31:0]                     axi_aw_beats_dbg    ,
    input  wire [31:0]                     axi_w_counts_dbg    ,
    input  wire [31:0]                     axi_wlast_counts_dbg,
    input  wire [31:0]                     axi_ram_wr_counts_dbg,
    input  wire [31:0]                     axi_last_ctrl_dbg   ,
    input  wire [31:0]                     axi_short_burst_counts_dbg,
    input  wire [31:0]                     axi_short_missing_beats_dbg,
    input  wire [31:0]                     axi_totals_dbg,
    input  wire [31:0]                     axi_none_counts_dbg,
    input  wire                            master_axi_aw_hs_dbg,
    input  wire                            master_axi_w_hs_dbg,
    input  wire                            master_axi_wlast_hs_dbg,
    input  wire                            master_axi_b_hs_dbg,
    input  wire                            master_axi_bvalid_dbg,
    input  wire                            master_axi_awvalid_dbg,
    input  wire                            master_axi_wvalid_dbg,
    input  wire                            master_axi_bready_dbg,
    input  wire                            master_axi_awready_dbg,
    input  wire                            master_axi_wready_dbg,
    input  wire                            branch_m00_aw_hs_dbg,
    input  wire                            branch_m00_w_hs_dbg,
    input  wire                            branch_m00_wlast_hs_dbg,
    input  wire                            branch_m00_b_hs_dbg,
    input  wire                            branch_m00_bvalid_dbg,
    input  wire                            branch_m00_awvalid_dbg,
    input  wire                            branch_m00_wvalid_dbg,
    input  wire                            branch_m00_bready_dbg,
    input  wire                            branch_m00_awready_dbg,
    input  wire                            branch_m00_wready_dbg,
    input  wire                            branch_m01_aw_hs_dbg,
    input  wire                            branch_m01_w_hs_dbg,
    input  wire                            branch_m01_wlast_hs_dbg,
    input  wire                            branch_m01_b_hs_dbg,
    input  wire                            branch_m01_bvalid_dbg,
    input  wire                            branch_m01_awvalid_dbg,
    input  wire                            branch_m01_wvalid_dbg,
    input  wire                            branch_m01_bready_dbg,
    input  wire                            branch_m01_awready_dbg,
    input  wire                            branch_m01_wready_dbg,
    
    // 配置输出
    output wire [    MATRIX_DIM_WIDTH-1:0] matrix_m1           ,
    output wire [    MATRIX_DIM_WIDTH-1:0] matrix_n1           ,
    output wire [    MATRIX_DIM_WIDTH-1:0] matrix_k1           ,
    output wire [PRECISION_MODE_WIDTH-1:0] precision_mode1     ,
    output wire                            sparse_en1          ,

    output wire [    MATRIX_DIM_WIDTH-1:0] matrix_m2           ,
    output wire [    MATRIX_DIM_WIDTH-1:0] matrix_n2           ,
    output wire [    MATRIX_DIM_WIDTH-1:0] matrix_k2           ,
    output wire [PRECISION_MODE_WIDTH-1:0] precision_mode2     ,
    output wire                            sparse_en2          ,

    output wire [    MATRIX_DIM_WIDTH-1:0] matrix_m3           ,
    output wire [    MATRIX_DIM_WIDTH-1:0] matrix_n3           ,
    output wire [    MATRIX_DIM_WIDTH-1:0] matrix_k3           ,
    output wire [PRECISION_MODE_WIDTH-1:0] precision_mode3     ,
    output wire [               31:0]      store_target_addr   ,
    output wire                            soft_reset_active
);
    
    // CSR地址定义
    localparam CSR_ADDR_CTRL           = 8'h00;    // 控制寄存器
    localparam CSR_ADDR_STATUS         = 8'h04;    // 状态寄存器
    localparam CSR_ADDR_CONFIG         = 8'h08;    // 配置寄存器 (合并矩阵维度和精度模式)
    localparam CSR_ADDR_DBG_DONE       = 8'h0C;    // 调试寄存器: sticky done脉冲
    localparam CSR_ADDR_DBG_LAST_ADDR  = 8'h10;    // 调试寄存器: 最近一次AXI写地址
    localparam CSR_ADDR_DBG_FLOW       = 8'h14;    // 调试寄存器: compute/store阶段关键事件
    localparam CSR_ADDR_DBG_COUNTS     = 8'h18;    // 调试寄存器: 关键读写计数
    localparam CSR_ADDR_DBG_COUNTS2    = 8'h1C;    // 调试寄存器: systolic控制/valid计数
    localparam CSR_ADDR_DBG_COUNTS3    = 8'h20;    // 调试寄存器: full计数(accu/fifo_c)
    localparam CSR_ADDR_DBG_COUNTS4    = 8'h24;    // 调试寄存器: full计数(ram_d/systolic_valid)
    localparam CSR_ADDR_DBG_COUNTS5    = 8'h28;    // 调试寄存器: full计数(systolic_wr/first/last)
    localparam CSR_ADDR_DBG_COUNTS6    = 8'h2C;    // 调试寄存器: 累加层valid/accept计数
    localparam CSR_ADDR_DBG_ACC_FIRST  = 8'h30;    // 调试寄存器: 首个累加输出word
    localparam CSR_ADDR_DBG_ACC_LAST   = 8'h34;    // 调试寄存器: 最后一个累加输出word
    localparam CSR_ADDR_DBG_CFG1       = 8'h38;    // 调试寄存器: load阶段锁存配置
    localparam CSR_ADDR_DBG_CFG2       = 8'h3C;    // 调试寄存器: compute阶段锁存配置
    localparam CSR_ADDR_DBG_CFG3       = 8'h40;    // 调试寄存器: store阶段锁存配置
    localparam CSR_ADDR_DBG_ACC_CTRL0  = 8'h44;    // 调试寄存器: 累加控制标志/相位
    localparam CSR_ADDR_DBG_ACC_CTRL1  = 8'h48;    // 调试寄存器: 累加控制计数
    localparam CSR_ADDR_DBG_ACC_CTRL2  = 8'h4C;    // 调试寄存器: 累加控制limit
    localparam CSR_ADDR_DBG_AXI_AW     = 8'h50;    // 调试寄存器: AXI AW按矩阵计数
    localparam CSR_ADDR_DBG_AXI_W      = 8'h54;    // 调试寄存器: AXI W按矩阵计数
    localparam CSR_ADDR_DBG_AXI_WLAST  = 8'h58;    // 调试寄存器: AXI WLAST按矩阵计数
    localparam CSR_ADDR_DBG_AXI_RAM_WR = 8'h5C;    // 调试寄存器: RAM写拍按矩阵计数
    localparam CSR_ADDR_DBG_AXI_LAST   = 8'h60;    // 调试寄存器: 最近一次AXI控制信息
    localparam CSR_ADDR_DBG_AXI_AW_BEATS = 8'h64;  // 调试寄存器: AWLEN+1按矩阵累计
    localparam CSR_ADDR_DBG_AXI_SHORT_BURST = 8'h68; // 调试寄存器: 短burst个数
    localparam CSR_ADDR_DBG_AXI_SHORT_MISS  = 8'h6C; // 调试寄存器: 短burst缺失拍数累计
    localparam CSR_ADDR_DBG_AXI_TOTALS      = 8'h70; // 调试寄存器: 全局W/RAM总拍数
    localparam CSR_ADDR_DBG_AXI_NONE        = 8'h74; // 调试寄存器: W/RAM窗口外拍数
    localparam CSR_ADDR_SOFT_RESET_CFG      = 8'h84; // soft reset 保持周期
    localparam CSR_ADDR_STORE_TARGET_ADDR   = 8'h88; // D矩阵外部写回目标地址
    localparam CSR_ADDR_DBG_INGRESS         = 8'h8C; // 调试寄存器: ingress/live候选握手
    localparam CSR_ADDR_DBG_AXI_MASTER      = 8'h90; // 调试寄存器: master AXI握手计数
    localparam CSR_ADDR_DBG_AXI_MASTER_LIVE = 8'h94; // 调试寄存器: master AXI valid/ready观测
    localparam CSR_ADDR_DBG_AXI_M00         = 8'h98; // 调试寄存器: 下游M00(HPC0) AXI握手计数
    localparam CSR_ADDR_DBG_AXI_M00_LIVE    = 8'h9C; // 调试寄存器: 下游M00(HPC0) AXI valid/ready观测
    localparam CSR_ADDR_DBG_AXI_M01         = 8'hA0; // 调试寄存器: 下游M01(BRAM) AXI握手计数
    localparam CSR_ADDR_DBG_AXI_M01_LIVE    = 8'hA4; // 调试寄存器: 下游M01(BRAM) AXI valid/ready观测

    // 控制寄存器位定义
    localparam TPU_ENABLE_BIT          = 0;        // TPU使能位
    localparam TPU_SPARSE_ENABLE_BIT   = 1;        // TPU稀疏使能位
    localparam TPU_SOFT_RESET_BIT      = 2;        // 核心软复位位

    // 状态寄存器位定义
    localparam TPU_READY_BIT           = 0;        // TPU就绪标志
    localparam TPU_LOAD_BUSY_BIT       = 1;        // TPU加载忙碌标志
    localparam TPU_COMPUTE_BUSY_BIT    = 2;        // TPU计算忙碌标志
    localparam TPU_STORE_BUSY_BIT      = 3;        // TPU存储忙碌标志
    localparam TPU_DONE_BIT            = 4;        // TPU计算完成标志
    localparam TPU_SOFT_RESET_ACTIVE_BIT = 5;      // 核心软复位进行中
    localparam TPU_DBG_A_WR_DONE_BIT   = 8;        // 调试: A写完成脉冲
    localparam TPU_DBG_B_WR_DONE_BIT   = 9;        // 调试: B写完成脉冲
    localparam TPU_DBG_C_WR_DONE_BIT   = 10;       // 调试: C写完成脉冲
    localparam TPU_DBG_A_RD_READY_BIT  = 11;       // 调试: A读缓冲有效
    localparam TPU_DBG_B_RD_READY_BIT  = 12;       // 调试: B读缓冲有效
    localparam TPU_DBG_C_WR_READY_BIT  = 13;       // 调试: C写缓冲可写
    localparam TPU_DBG_D_WR_READY_BIT  = 14;       // 调试: D写缓冲可写
    localparam TPU_DBG_D_RD_READY_BIT  = 15;       // 调试: D读缓冲有效

    // 精度模式定义
    localparam PM_INT8_ALL    = 4'd1; // ABC 矩阵均为 INT8
    localparam PM_INT8_INT32  = 4'd3; // AB 为 INT8，C 为 INT32

    // 配置寄存器位定义
    localparam CONFIG_K_POS          = 0;                     // K维度位置
    localparam CONFIG_N_POS          = MATRIX_DIM_WIDTH;      // N维度位置
    localparam CONFIG_M_POS          = MATRIX_DIM_WIDTH * 2;  // M维度位置
    localparam CONFIG_PRECISION_POS  = 24;                    // 精度模式位置

    // 状态机定义
    localparam IDLE            = 3'd0;
    localparam BUSY            = 3'd1;
    localparam DONE            = 3'd2;
    localparam [19:0] SOFT_RESET_HOLD_CYCLES_DEFAULT = 20'd500000;


    reg [2:0] load_state; // 数据加载状态机
    reg [2:0] compute_state; // 数据传输状态机
    reg [2:0] store_state; // 数据存储状态机
    reg       compute_start_pending;
    reg       store_start_pending;

    // CSR寄存器定义
    reg [CSR_DATA_WIDTH-1:0] ctrl_reg;            // 控制寄存器
    reg [CSR_DATA_WIDTH-1:0] status_reg;          // 状态寄存器
    reg [CSR_DATA_WIDTH-1:0] config_reg;          // 配置寄存器
    reg [CSR_DATA_WIDTH-1:0] dbg_done_reg;        // sticky写完成观测
    reg [CSR_DATA_WIDTH-1:0] dbg_last_addr_reg;   // 最近一次AXI写地址
    reg [CSR_DATA_WIDTH-1:0] dbg_flow_reg;        // sticky计算阶段事件观测
    reg [CSR_DATA_WIDTH-1:0] dbg_count_reg;       // 关键读写计数
    reg [CSR_DATA_WIDTH-1:0] dbg_count2_reg;      // systolic控制/valid计数
    reg [CSR_DATA_WIDTH-1:0] dbg_count3_reg;      // full计数(accu/fifo_c)
    reg [CSR_DATA_WIDTH-1:0] dbg_count4_reg;      // full计数(ram_d/systolic_valid)
    reg [CSR_DATA_WIDTH-1:0] dbg_count5_reg;      // full计数(systolic_wr/first/last)
    reg [CSR_DATA_WIDTH-1:0] dbg_count6_reg;      // 累加层valid/accept计数
    reg [CSR_DATA_WIDTH-1:0] dbg_acc_first_reg;   // 首个累加输出word
    reg [CSR_DATA_WIDTH-1:0] dbg_acc_last_reg;    // 最后一个累加输出word
    reg [CSR_DATA_WIDTH-1:0] dbg_ingress_reg;     // ingress/live条件观测
    reg [CSR_DATA_WIDTH-1:0] dbg_axi_master_reg;  // master AXI握手计数
    reg [CSR_DATA_WIDTH-1:0] dbg_axi_master_live_reg; // master AXI seen/valid计数
    reg [CSR_DATA_WIDTH-1:0] dbg_axi_m00_reg;     // downstream M00(HPC0) AXI握手计数
    reg [CSR_DATA_WIDTH-1:0] dbg_axi_m00_live_reg;// downstream M00(HPC0) AXI seen/valid计数
    reg [CSR_DATA_WIDTH-1:0] dbg_axi_m01_reg;     // downstream M01(BRAM) AXI握手计数
    reg [CSR_DATA_WIDTH-1:0] dbg_axi_m01_live_reg;// downstream M01(BRAM) AXI seen/valid计数
    reg                      soft_reset_active_r;
    reg [19:0]               soft_reset_countdown_r;
    reg [19:0]               soft_reset_hold_cycles_r;
    reg [31:0]               store_target_addr_r;

    // 配置寄存器
    reg [MATRIX_DIM_WIDTH-1:0] matrix_m1_r;
    reg [MATRIX_DIM_WIDTH-1:0] matrix_n1_r;
    reg [MATRIX_DIM_WIDTH-1:0] matrix_k1_r;
    reg [PRECISION_MODE_WIDTH-1:0] precision_mode1_r;
    reg                        sparse_en1_r;

    reg [MATRIX_DIM_WIDTH-1:0] matrix_m2_r;
    reg [MATRIX_DIM_WIDTH-1:0] matrix_n2_r;
    reg [MATRIX_DIM_WIDTH-1:0] matrix_k2_r;
    reg [PRECISION_MODE_WIDTH-1:0] precision_mode2_r;
    reg                        sparse_en2_r;

    reg [MATRIX_DIM_WIDTH-1:0] matrix_m3_r;
    reg [MATRIX_DIM_WIDTH-1:0] matrix_n3_r;
    reg [MATRIX_DIM_WIDTH-1:0] matrix_k3_r;
    reg [PRECISION_MODE_WIDTH-1:0] precision_mode3_r;

    // 配置锁定标志
    reg config_locked;

    // load状态机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || soft_reset_active_r) begin
            config_locked     <= 1'b0;
            matrix_m1_r       <= {MATRIX_DIM_WIDTH{1'b0}};
            matrix_n1_r       <= {MATRIX_DIM_WIDTH{1'b0}};
            matrix_k1_r       <= {MATRIX_DIM_WIDTH{1'b0}};
            precision_mode1_r <= {PRECISION_MODE_WIDTH{1'b0}};
            sparse_en1_r      <= 1'b0;
            load_state        <= IDLE;
            compute_start_pending <= 1'b0;
            store_start_pending   <= 1'b0;
        end else begin
            case (load_state)
                IDLE: begin
                    if (ctrl_reg[TPU_ENABLE_BIT] && !config_locked) begin
                        config_locked     <= 1'b1;
                        matrix_m1_r       <= config_reg[CONFIG_M_POS +: MATRIX_DIM_WIDTH];
                        matrix_n1_r       <= config_reg[CONFIG_N_POS +: MATRIX_DIM_WIDTH];
                        matrix_k1_r       <= config_reg[CONFIG_K_POS +: MATRIX_DIM_WIDTH];
                        precision_mode1_r <= config_reg[CONFIG_PRECISION_POS +: PRECISION_MODE_WIDTH];
                        sparse_en1_r      <= ctrl_reg[TPU_SPARSE_ENABLE_BIT];
                        load_state        <= BUSY;
                    end
                end

                BUSY: begin
                    if (ram_c_wr_done) begin
                        config_locked <= 1'b0;
                        load_state <= IDLE;
                    end
                end

                default: begin
                    load_state <= IDLE;
                end
            endcase

            if (load_state == IDLE && ctrl_reg[TPU_ENABLE_BIT] && !config_locked) begin
                compute_start_pending <= 1'b0;
                store_start_pending   <= 1'b0;
            end else begin
                if (ram_c_wr_done && load_state == BUSY) begin
                    compute_start_pending <= 1'b1;
                end else if (compute_state == IDLE && compute_start_pending && ram_b_read_ready && ram_d_write_ready) begin
                    compute_start_pending <= 1'b0;
                end

                if (compute_done && compute_state == BUSY) begin
                    store_start_pending <= 1'b1;
                end else if (store_state == IDLE && store_start_pending && ram_d_read_ready) begin
                    store_start_pending <= 1'b0;
                end
            end
        end
    end

    // compute状态机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || soft_reset_active_r) begin
            matrix_m2_r       <= {MATRIX_DIM_WIDTH{1'b0}};
            matrix_n2_r       <= {MATRIX_DIM_WIDTH{1'b0}};
            matrix_k2_r       <= {MATRIX_DIM_WIDTH{1'b0}};
            precision_mode2_r <= {PRECISION_MODE_WIDTH{1'b0}};
            sparse_en2_r      <= 1'b0;
            compute_state     <= IDLE;
        end else begin
            case (compute_state)
                IDLE: begin
                    if (compute_start_pending && ram_b_read_ready && ram_d_write_ready) begin
                        matrix_m2_r       <= matrix_m1_r;
                        matrix_n2_r       <= matrix_n1_r;
                        matrix_k2_r       <= matrix_k1_r;
                        precision_mode2_r <= precision_mode1_r;
                        sparse_en2_r      <= sparse_en1_r;
                        compute_state     <= BUSY;
                    end
                end

                BUSY: begin
                    if (compute_done) begin
                        compute_state <= IDLE;
                    end
                end

                default: begin
                    compute_state <= IDLE;
                end
            endcase
        end
    end

    // store状态机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n || soft_reset_active_r) begin
            matrix_m3_r       <= {MATRIX_DIM_WIDTH{1'b0}};
            matrix_n3_r       <= {MATRIX_DIM_WIDTH{1'b0}};
            matrix_k3_r       <= {MATRIX_DIM_WIDTH{1'b0}};
            precision_mode3_r <= {PRECISION_MODE_WIDTH{1'b0}};
            store_state       <= IDLE;
        end else begin
            case (store_state)
                IDLE: begin
                    if (store_start_pending && ram_d_read_ready) begin
                        matrix_m3_r       <= matrix_m2_r;
                        matrix_n3_r       <= matrix_n2_r;
                        matrix_k3_r       <= matrix_k2_r;
                        precision_mode3_r <= precision_mode2_r;
                        store_state       <= BUSY;
                    end
                end

                BUSY: begin
                    if (transfer_done) begin
                        store_state <= IDLE;
                    end
                end

                default: begin
                    store_state <= IDLE;
                end
            endcase
        end
    end

    // CSR写入
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ctrl_reg   <= 32'h00000000;
            // 默认配置: 精度模式=INT8_ALL(1), M=16, N=16, K=16
            config_reg <= {4'h0, PM_INT8_ALL, 8'h10, 8'h10, 8'h10};
            dbg_done_reg <= 32'h00000000;
            dbg_last_addr_reg <= 32'h00000000;
            dbg_flow_reg <= 32'h00000000;
            dbg_count_reg <= 32'h00000000;
            dbg_count2_reg <= 32'h00000000;
            dbg_count3_reg <= 32'h00000000;
            dbg_count4_reg <= 32'h00000000;
            dbg_count5_reg <= 32'h00000000;
            dbg_count6_reg <= 32'h00000000;
            dbg_acc_first_reg <= 32'h00000000;
            dbg_acc_last_reg <= 32'h00000000;
            dbg_ingress_reg <= 32'h00000000;
            dbg_axi_master_reg <= 32'h00000000;
            dbg_axi_master_live_reg <= 32'h00000000;
            dbg_axi_m00_reg <= 32'h00000000;
            dbg_axi_m00_live_reg <= 32'h00000000;
            dbg_axi_m01_reg <= 32'h00000000;
            dbg_axi_m01_live_reg <= 32'h00000000;
            soft_reset_active_r <= 1'b0;
            soft_reset_countdown_r <= 20'd0;
            soft_reset_hold_cycles_r <= SOFT_RESET_HOLD_CYCLES_DEFAULT;
            store_target_addr_r <= MATRIX_D_BASE_ADDR;
        end else begin
            if (csr_wr_en && csr_wr_addr == CSR_ADDR_CTRL && csr_wr_strb[0] && csr_wr_data[TPU_SOFT_RESET_BIT]) begin
                soft_reset_active_r <= 1'b1;
                soft_reset_countdown_r <= soft_reset_hold_cycles_r - 20'd1;
            end else if (soft_reset_active_r) begin
                if (soft_reset_countdown_r == 20'd0) begin
                    soft_reset_active_r <= 1'b0;
                end else begin
                    soft_reset_countdown_r <= soft_reset_countdown_r - 20'd1;
                end
            end

            if (soft_reset_active_r) begin
                ctrl_reg <= 32'h00000000;
                dbg_done_reg <= 32'h00000000;
                dbg_last_addr_reg <= 32'h00000000;
                dbg_flow_reg <= 32'h00000000;
                dbg_count_reg <= 32'h00000000;
                dbg_count2_reg <= 32'h00000000;
                dbg_count3_reg <= 32'h00000000;
                dbg_count4_reg <= 32'h00000000;
                dbg_count5_reg <= 32'h00000000;
                dbg_count6_reg <= 32'h00000000;
                dbg_acc_first_reg <= 32'h00000000;
                dbg_acc_last_reg <= 32'h00000000;
                dbg_ingress_reg <= 32'h00000000;
                dbg_axi_master_reg <= 32'h00000000;
                dbg_axi_master_live_reg <= 32'h00000000;
                dbg_axi_m00_reg <= 32'h00000000;
                dbg_axi_m00_live_reg <= 32'h00000000;
                dbg_axi_m01_reg <= 32'h00000000;
                dbg_axi_m01_live_reg <= 32'h00000000;
            end else begin
                // 处理CSR写入 - 随时可写
                if (csr_wr_en) begin
                    case (csr_wr_addr)
                        CSR_ADDR_CTRL: begin
                            if (csr_wr_strb[0]) ctrl_reg[7:0]   <= csr_wr_data[7:0];
                            if (csr_wr_strb[1]) ctrl_reg[15:8]  <= csr_wr_data[15:8];
                            if (csr_wr_strb[2]) ctrl_reg[23:16] <= csr_wr_data[23:16];
                            if (csr_wr_strb[3]) ctrl_reg[31:24] <= csr_wr_data[31:24];
                        end
                        
                        CSR_ADDR_CONFIG: begin
                            if (csr_wr_strb[0]) config_reg[7:0]   <= csr_wr_data[7:0];
                            if (csr_wr_strb[1]) config_reg[15:8]  <= csr_wr_data[15:8];
                            if (csr_wr_strb[2]) config_reg[23:16] <= csr_wr_data[23:16];
                            if (csr_wr_strb[3]) config_reg[31:24] <= csr_wr_data[31:24];
                        end

                        CSR_ADDR_SOFT_RESET_CFG: begin
                            if (|csr_wr_strb[2:0]) begin
                                if (csr_wr_data[19:0] == 20'd0) begin
                                    soft_reset_hold_cycles_r <= 20'd1;
                                end else begin
                                    soft_reset_hold_cycles_r <= csr_wr_data[19:0];
                                end
                            end
                        end

                        CSR_ADDR_STORE_TARGET_ADDR: begin
                            if (csr_wr_strb[0]) store_target_addr_r[7:0]   <= csr_wr_data[7:0];
                            if (csr_wr_strb[1]) store_target_addr_r[15:8]  <= csr_wr_data[15:8];
                            if (csr_wr_strb[2]) store_target_addr_r[23:16] <= csr_wr_data[23:16];
                            if (csr_wr_strb[3]) store_target_addr_r[31:24] <= csr_wr_data[31:24];
                        end
                        
                        default: begin
                            // 不操作
                        end
                    endcase
                end
                
                // 自动清除使能位
                if (load_state == IDLE && ctrl_reg[TPU_ENABLE_BIT] && !config_locked) begin
                    ctrl_reg[TPU_ENABLE_BIT] <= 1'b0;
                end

                if (load_state == IDLE && ctrl_reg[TPU_ENABLE_BIT] && !config_locked) begin
                    dbg_done_reg <= 32'h00000000;
                    dbg_last_addr_reg <= 32'h00000000;
                    dbg_flow_reg <= 32'h00000000;
                    dbg_count_reg <= 32'h00000000;
                    dbg_count2_reg <= 32'h00000000;
                    dbg_count3_reg <= 32'h00000000;
                    dbg_count4_reg <= 32'h00000000;
                    dbg_count5_reg <= 32'h00000000;
                    dbg_count6_reg <= 32'h00000000;
                    dbg_acc_first_reg <= 32'h00000000;
                    dbg_acc_last_reg <= 32'h00000000;
                    dbg_ingress_reg <= 32'h00000000;
                    dbg_axi_master_reg <= 32'h00000000;
                    dbg_axi_master_live_reg <= 32'h00000000;
                    dbg_axi_m00_reg <= 32'h00000000;
                    dbg_axi_m00_live_reg <= 32'h00000000;
                    dbg_axi_m01_reg <= 32'h00000000;
                    dbg_axi_m01_live_reg <= 32'h00000000;
                end else begin
                    if (axi_ram_wr_en) begin
                        dbg_last_addr_reg <= axi_ram_wr_addr;
                    end
                    if (ram_a_wr_done) begin
                        dbg_done_reg[0] <= 1'b1;
                    end
                    if (ram_b_wr_done) begin
                        dbg_done_reg[1] <= 1'b1;
                    end
                    if (ram_c_wr_done) begin
                        dbg_done_reg[2] <= 1'b1;
                    end
                    if (rctf_done_dbg) begin
                        dbg_flow_reg[0] <= 1'b1;
                    end
                    if (systolic_done_dbg) begin
                        dbg_flow_reg[1] <= 1'b1;
                    end
                    if (accu_fifo_wr_en_dbg) begin
                        dbg_flow_reg[2] <= 1'b1;
                        dbg_count_reg[7:0] <= dbg_count_reg[7:0] + 8'd1;
                        dbg_count3_reg[15:0] <= dbg_count3_reg[15:0] + 16'd1;
                    end
                    if (fifo_c_rd_en_dbg) begin
                        dbg_flow_reg[3] <= 1'b1;
                        dbg_count_reg[15:8] <= dbg_count_reg[15:8] + 8'd1;
                        dbg_count3_reg[31:16] <= dbg_count3_reg[31:16] + 16'd1;
                    end
                    if (ram_d_wr_en_dbg) begin
                        dbg_flow_reg[4] <= 1'b1;
                        dbg_count_reg[23:16] <= dbg_count_reg[23:16] + 8'd1;
                        dbg_count_reg[31:24] <= ram_d_wr_addr_dbg;
                        dbg_count4_reg[15:0] <= dbg_count4_reg[15:0] + 16'd1;
                    end
                    if (compute_done) begin
                        dbg_flow_reg[5] <= 1'b1;
                    end
                    if (transfer_done) begin
                        dbg_flow_reg[6] <= 1'b1;
                    end
                    if (systolic_valid_dbg) begin
                        dbg_flow_reg[7] <= 1'b1;
                        dbg_count2_reg[7:0] <= dbg_count2_reg[7:0] + 8'd1;
                        dbg_count4_reg[31:16] <= dbg_count4_reg[31:16] + 16'd1;
                        dbg_count6_reg[15:0] <= dbg_count6_reg[15:0] + 16'd1;
                    end
                    if (first_data_dbg) begin
                        dbg_flow_reg[8] <= 1'b1;
                        dbg_count2_reg[15:8] <= dbg_count2_reg[15:8] + 8'd1;
                        dbg_count5_reg[23:16] <= dbg_count5_reg[23:16] + 8'd1;
                    end
                    if (last_data_dbg) begin
                        dbg_flow_reg[9] <= 1'b1;
                        dbg_count2_reg[23:16] <= dbg_count2_reg[23:16] + 8'd1;
                        dbg_count5_reg[31:24] <= dbg_count5_reg[31:24] + 8'd1;
                    end
                    if (systolic_wr_en_dbg) begin
                        dbg_flow_reg[10] <= 1'b1;
                        dbg_count2_reg[31:24] <= dbg_count2_reg[31:24] + 8'd1;
                        dbg_count5_reg[15:0] <= dbg_count5_reg[15:0] + 16'd1;
                    end
                    if (accu_output_done_dbg) begin
                        dbg_flow_reg[11] <= 1'b1;
                    end
                    if (accu_partial_accept_dbg) begin
                        dbg_count6_reg[31:16] <= dbg_count6_reg[31:16] + 16'd1;
                    end
                    if (accu_first_word_vld_dbg) begin
                        dbg_acc_first_reg <= accu_first_word_dbg;
                    end
                    if (accu_last_word_vld_dbg) begin
                        dbg_acc_last_reg <= accu_last_word_dbg;
                    end
                    if (master_axi_aw_hs_dbg) begin
                        dbg_axi_master_reg[7:0] <= dbg_axi_master_reg[7:0] + 8'd1;
                        dbg_axi_master_live_reg[24] <= 1'b1;
                    end
                    if (master_axi_w_hs_dbg) begin
                        dbg_axi_master_reg[15:8] <= dbg_axi_master_reg[15:8] + 8'd1;
                        dbg_axi_master_live_reg[25] <= 1'b1;
                    end
                    if (master_axi_wlast_hs_dbg) begin
                        dbg_axi_master_reg[23:16] <= dbg_axi_master_reg[23:16] + 8'd1;
                        dbg_axi_master_live_reg[26] <= 1'b1;
                    end
                    if (master_axi_b_hs_dbg) begin
                        dbg_axi_master_reg[31:24] <= dbg_axi_master_reg[31:24] + 8'd1;
                        dbg_axi_master_live_reg[27] <= 1'b1;
                    end
                    if (master_axi_bvalid_dbg) begin
                        dbg_axi_master_live_reg[7:0] <= dbg_axi_master_live_reg[7:0] + 8'd1;
                        dbg_axi_master_live_reg[28] <= 1'b1;
                    end
                    if (master_axi_awvalid_dbg) begin
                        dbg_axi_master_live_reg[15:8] <= dbg_axi_master_live_reg[15:8] + 8'd1;
                    end
                    if (master_axi_wvalid_dbg) begin
                        dbg_axi_master_live_reg[23:16] <= dbg_axi_master_live_reg[23:16] + 8'd1;
                    end
                    if (master_axi_bready_dbg) begin
                        dbg_axi_master_live_reg[29] <= 1'b1;
                    end
                    if (master_axi_awready_dbg) begin
                        dbg_axi_master_live_reg[30] <= 1'b1;
                    end
                    if (master_axi_wready_dbg) begin
                        dbg_axi_master_live_reg[31] <= 1'b1;
                    end
                    if (branch_m00_aw_hs_dbg) begin
                        dbg_axi_m00_reg[7:0] <= dbg_axi_m00_reg[7:0] + 8'd1;
                        dbg_axi_m00_live_reg[24] <= 1'b1;
                    end
                    if (branch_m00_w_hs_dbg) begin
                        dbg_axi_m00_reg[15:8] <= dbg_axi_m00_reg[15:8] + 8'd1;
                        dbg_axi_m00_live_reg[25] <= 1'b1;
                    end
                    if (branch_m00_wlast_hs_dbg) begin
                        dbg_axi_m00_reg[23:16] <= dbg_axi_m00_reg[23:16] + 8'd1;
                        dbg_axi_m00_live_reg[26] <= 1'b1;
                    end
                    if (branch_m00_b_hs_dbg) begin
                        dbg_axi_m00_reg[31:24] <= dbg_axi_m00_reg[31:24] + 8'd1;
                        dbg_axi_m00_live_reg[27] <= 1'b1;
                    end
                    if (branch_m00_bvalid_dbg) begin
                        dbg_axi_m00_live_reg[7:0] <= dbg_axi_m00_live_reg[7:0] + 8'd1;
                        dbg_axi_m00_live_reg[28] <= 1'b1;
                    end
                    if (branch_m00_awvalid_dbg) begin
                        dbg_axi_m00_live_reg[15:8] <= dbg_axi_m00_live_reg[15:8] + 8'd1;
                    end
                    if (branch_m00_wvalid_dbg) begin
                        dbg_axi_m00_live_reg[23:16] <= dbg_axi_m00_live_reg[23:16] + 8'd1;
                    end
                    if (branch_m00_bready_dbg) begin
                        dbg_axi_m00_live_reg[29] <= 1'b1;
                    end
                    if (branch_m00_awready_dbg) begin
                        dbg_axi_m00_live_reg[30] <= 1'b1;
                    end
                    if (branch_m00_wready_dbg) begin
                        dbg_axi_m00_live_reg[31] <= 1'b1;
                    end
                    if (branch_m01_aw_hs_dbg) begin
                        dbg_axi_m01_reg[7:0] <= dbg_axi_m01_reg[7:0] + 8'd1;
                        dbg_axi_m01_live_reg[24] <= 1'b1;
                    end
                    if (branch_m01_w_hs_dbg) begin
                        dbg_axi_m01_reg[15:8] <= dbg_axi_m01_reg[15:8] + 8'd1;
                        dbg_axi_m01_live_reg[25] <= 1'b1;
                    end
                    if (branch_m01_wlast_hs_dbg) begin
                        dbg_axi_m01_reg[23:16] <= dbg_axi_m01_reg[23:16] + 8'd1;
                        dbg_axi_m01_live_reg[26] <= 1'b1;
                    end
                    if (branch_m01_b_hs_dbg) begin
                        dbg_axi_m01_reg[31:24] <= dbg_axi_m01_reg[31:24] + 8'd1;
                        dbg_axi_m01_live_reg[27] <= 1'b1;
                    end
                    if (branch_m01_bvalid_dbg) begin
                        dbg_axi_m01_live_reg[7:0] <= dbg_axi_m01_live_reg[7:0] + 8'd1;
                        dbg_axi_m01_live_reg[28] <= 1'b1;
                    end
                    if (branch_m01_awvalid_dbg) begin
                        dbg_axi_m01_live_reg[15:8] <= dbg_axi_m01_live_reg[15:8] + 8'd1;
                    end
                    if (branch_m01_wvalid_dbg) begin
                        dbg_axi_m01_live_reg[23:16] <= dbg_axi_m01_live_reg[23:16] + 8'd1;
                    end
                    if (branch_m01_bready_dbg) begin
                        dbg_axi_m01_live_reg[29] <= 1'b1;
                    end
                    if (branch_m01_awready_dbg) begin
                        dbg_axi_m01_live_reg[30] <= 1'b1;
                    end
                    if (branch_m01_wready_dbg) begin
                        dbg_axi_m01_live_reg[31] <= 1'b1;
                    end
                end

                dbg_ingress_reg[0] <= ram_a_read_ready;
                dbg_ingress_reg[1] <= ram_a_write_ready;
                dbg_ingress_reg[2] <= ram_b_read_ready;
                dbg_ingress_reg[3] <= ram_b_write_ready;
                dbg_ingress_reg[4] <= ram_c_write_ready;
                dbg_ingress_reg[5] <= ram_d_write_ready;
                dbg_ingress_reg[6] <= mapper_a_active_dbg;
                dbg_ingress_reg[7] <= mapper_b_active_dbg;
                dbg_ingress_reg[8] <= mapper_c_active_dbg;
                dbg_ingress_reg[9] <= axi_wr_ready;
                dbg_ingress_reg[10] <= ram_a_read_ready && !mapper_a_active_dbg;
                dbg_ingress_reg[11] <= ram_b_read_ready && !mapper_b_active_dbg;
                dbg_ingress_reg[12] <= compute_start_pending;
                dbg_ingress_reg[13] <= store_start_pending;
                dbg_ingress_reg[14] <= compute_start_pending && ram_b_read_ready && ram_d_write_ready;
                dbg_ingress_reg[15] <= store_start_pending && ram_d_read_ready;
            end
        end
    end
    
    // 状态寄存器更新
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            status_reg <= 32'h00000001; // 默认空闲状态
        end else if (soft_reset_active_r) begin
            status_reg <= (32'h1 << TPU_SOFT_RESET_ACTIVE_BIT);
        end else begin

            // 更新就绪标志
            if (ram_c_write_ready && ram_d_write_ready && !config_locked) begin
                status_reg[TPU_READY_BIT] <= 1'b1;
            end else begin
                status_reg[TPU_READY_BIT] <= 1'b0;
            end

            // 更新忙碌标志
            status_reg[TPU_LOAD_BUSY_BIT] <= (load_state == BUSY);
            status_reg[TPU_STORE_BUSY_BIT] <= (store_state == BUSY);
            status_reg[TPU_COMPUTE_BUSY_BIT] <= (compute_state == BUSY);
            status_reg[TPU_SOFT_RESET_ACTIVE_BIT] <= 1'b0;

            // 调试观测位，帮助定位 load 阶段卡住的位置
            status_reg[TPU_DBG_A_WR_DONE_BIT] <= ram_a_wr_done;
            status_reg[TPU_DBG_B_WR_DONE_BIT] <= ram_b_wr_done;
            status_reg[TPU_DBG_C_WR_DONE_BIT] <= ram_c_wr_done;
            status_reg[TPU_DBG_A_RD_READY_BIT] <= ram_a_read_ready;
            status_reg[TPU_DBG_B_RD_READY_BIT] <= ram_b_read_ready;
            status_reg[TPU_DBG_C_WR_READY_BIT] <= ram_c_write_ready;
            status_reg[TPU_DBG_D_WR_READY_BIT] <= ram_d_write_ready;
            status_reg[TPU_DBG_D_RD_READY_BIT] <= ram_d_read_ready;

            // 更新计算完成标志
            if (transfer_done) begin
                status_reg[TPU_DONE_BIT] <= 1'b1;
            end else if (csr_rd_en && csr_rd_addr == CSR_ADDR_STATUS) begin
                status_reg[TPU_DONE_BIT] <= 1'b0; // 读取后清除
            end
        end
    end
    
    // CSR读取
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            csr_rd_data     <= 32'h0;
        end else begin
            
            if (csr_rd_en) begin
                
                case (csr_rd_addr)
                    
                    CSR_ADDR_CTRL: begin
                        csr_rd_data <= ctrl_reg;
                    end

                    CSR_ADDR_STATUS: begin
                        csr_rd_data <= status_reg;
                    end

                    CSR_ADDR_CONFIG: begin
                        csr_rd_data <= config_reg;
                    end

                    CSR_ADDR_DBG_DONE: begin
                        csr_rd_data <= dbg_done_reg;
                    end

                    CSR_ADDR_DBG_LAST_ADDR: begin
                        csr_rd_data <= dbg_last_addr_reg;
                    end

                    CSR_ADDR_DBG_FLOW: begin
                        csr_rd_data <= dbg_flow_reg;
                    end

                    CSR_ADDR_DBG_COUNTS: begin
                        csr_rd_data <= dbg_count_reg;
                    end

                    CSR_ADDR_DBG_COUNTS2: begin
                        csr_rd_data <= dbg_count2_reg;
                    end

                    CSR_ADDR_DBG_COUNTS3: begin
                        csr_rd_data <= dbg_count3_reg;
                    end

                    CSR_ADDR_DBG_COUNTS4: begin
                        csr_rd_data <= dbg_count4_reg;
                    end

                    CSR_ADDR_DBG_COUNTS5: begin
                        csr_rd_data <= dbg_count5_reg;
                    end

                    CSR_ADDR_DBG_COUNTS6: begin
                        csr_rd_data <= dbg_count6_reg;
                    end

                    CSR_ADDR_DBG_ACC_FIRST: begin
                        csr_rd_data <= dbg_acc_first_reg;
                    end

                    CSR_ADDR_DBG_ACC_LAST: begin
                        csr_rd_data <= dbg_acc_last_reg;
                    end

                    CSR_ADDR_DBG_CFG1: begin
                        csr_rd_data <= {4'h0, precision_mode1_r, matrix_m1_r, matrix_n1_r, matrix_k1_r};
                    end

                    CSR_ADDR_DBG_CFG2: begin
                        csr_rd_data <= {4'h0, precision_mode2_r, matrix_m2_r, matrix_n2_r, matrix_k2_r};
                    end

                    CSR_ADDR_DBG_CFG3: begin
                        csr_rd_data <= {4'h0, precision_mode3_r, matrix_m3_r, matrix_n3_r, matrix_k3_r};
                    end

                    CSR_ADDR_DBG_ACC_CTRL0: begin
                        csr_rd_data <= {
                            4'h0,
                            accu_ctrl_precision_mode_dbg,
                            accu_ctrl_partials_per_output_dbg,
                            accu_ctrl_partial_phase_dbg,
                            accu_ctrl_flags_dbg
                        };
                    end

                    CSR_ADDR_DBG_ACC_CTRL1: begin
                        csr_rd_data <= {
                            accu_ctrl_emit_cycle_count_dbg[15:0],
                            accu_ctrl_valid_cycle_count_dbg[15:0]
                        };
                    end

                    CSR_ADDR_DBG_ACC_CTRL2: begin
                        csr_rd_data <= {
                            accu_ctrl_output_cycle_limit_dbg[15:0],
                            accu_ctrl_valid_cycle_limit_dbg[15:0]
                        };
                    end

                    CSR_ADDR_DBG_AXI_AW: begin
                        csr_rd_data <= axi_aw_counts_dbg;
                    end

                    CSR_ADDR_DBG_AXI_AW_BEATS: begin
                        csr_rd_data <= axi_aw_beats_dbg;
                    end

                    CSR_ADDR_DBG_AXI_W: begin
                        csr_rd_data <= axi_w_counts_dbg;
                    end

                    CSR_ADDR_DBG_AXI_WLAST: begin
                        csr_rd_data <= axi_wlast_counts_dbg;
                    end

                    CSR_ADDR_DBG_AXI_RAM_WR: begin
                        csr_rd_data <= axi_ram_wr_counts_dbg;
                    end

                    CSR_ADDR_DBG_AXI_LAST: begin
                        csr_rd_data <= axi_last_ctrl_dbg;
                    end

                    CSR_ADDR_DBG_AXI_SHORT_BURST: begin
                        csr_rd_data <= axi_short_burst_counts_dbg;
                    end

                    CSR_ADDR_DBG_AXI_SHORT_MISS: begin
                        csr_rd_data <= axi_short_missing_beats_dbg;
                    end

                    CSR_ADDR_DBG_AXI_TOTALS: begin
                        csr_rd_data <= axi_totals_dbg;
                    end

                    CSR_ADDR_DBG_AXI_NONE: begin
                        csr_rd_data <= axi_none_counts_dbg;
                    end

                    CSR_ADDR_SOFT_RESET_CFG: begin
                        csr_rd_data <= {12'h0, soft_reset_hold_cycles_r};
                    end

                    CSR_ADDR_STORE_TARGET_ADDR: begin
                        csr_rd_data <= store_target_addr_r;
                    end

                    CSR_ADDR_DBG_INGRESS: begin
                        csr_rd_data <= dbg_ingress_reg;
                    end

                    CSR_ADDR_DBG_AXI_MASTER: begin
                        csr_rd_data <= dbg_axi_master_reg;
                    end

                    CSR_ADDR_DBG_AXI_MASTER_LIVE: begin
                        csr_rd_data <= dbg_axi_master_live_reg;
                    end

                    CSR_ADDR_DBG_AXI_M00: begin
                        csr_rd_data <= dbg_axi_m00_reg;
                    end

                    CSR_ADDR_DBG_AXI_M00_LIVE: begin
                        csr_rd_data <= dbg_axi_m00_live_reg;
                    end

                    CSR_ADDR_DBG_AXI_M01: begin
                        csr_rd_data <= dbg_axi_m01_reg;
                    end

                    CSR_ADDR_DBG_AXI_M01_LIVE: begin
                        csr_rd_data <= dbg_axi_m01_live_reg;
                    end

                    default: begin
                        csr_rd_data <= 32'h0;
                    end
                endcase
            end
        end
    end


    assign axi_wr_ready = !soft_reset_active_r && (load_state == BUSY) && ram_c_write_ready && ram_d_write_ready;

    assign matrix_m1 = matrix_m1_r;
    assign matrix_n1 = matrix_n1_r;
    assign matrix_k1 = matrix_k1_r;
    assign precision_mode1 = precision_mode1_r;
    assign sparse_en1 = sparse_en1_r;

    assign matrix_m2 = matrix_m2_r;
    assign matrix_n2 = matrix_n2_r;
    assign matrix_k2 = matrix_k2_r;
    assign precision_mode2 = precision_mode2_r;
    assign sparse_en2 = sparse_en2_r;

    assign matrix_m3 = matrix_m3_r;
    assign matrix_n3 = matrix_n3_r;
    assign matrix_k3 = matrix_k3_r;
    assign precision_mode3 = precision_mode3_r;
    assign store_target_addr = store_target_addr_r;
    assign soft_reset_active = soft_reset_active_r;

endmodule
