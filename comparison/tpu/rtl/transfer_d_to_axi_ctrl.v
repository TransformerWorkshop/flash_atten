module transfer_d_to_axi_ctrl #(
    parameter PE_SIZE              = 8             ,
    parameter MATRIX_DIM_WIDTH     = 8             ,   // 矩阵维度宽度
    parameter PRECISION_MODE_WIDTH = 4             ,   // 精度模式宽度
    parameter AXI_DATA_WIDTH       = 32            ,
    parameter AXI_ADDR_WIDTH       = 32            ,
    parameter RAM_ADDR_WIDTH       = 5             ,
    parameter RAM_DATA_WIDTH       = 32            ,
    parameter MATRIX_D_BASE_ADDR   = 32'h0000_C000  
) (
    // 时钟和复位
    input  wire                              clk               ,
    input  wire                              rst_n             ,
    
    // AXI读请求接口
    input  wire                              axi_rd_en         , // 读使能信号
    input  wire [        AXI_ADDR_WIDTH-1:0] axi_rd_addr       , // 请求读地址
    output reg  [        AXI_DATA_WIDTH-1:0] axi_rd_data       , // 读出的数据
    output reg                               axi_rd_data_vld   , // 读数据有效
    
    // CSR寄存器配置
    input  wire [      MATRIX_DIM_WIDTH-1:0] matrix_m          ,
    input  wire [      MATRIX_DIM_WIDTH-1:0] matrix_n          ,
    input  wire [  PRECISION_MODE_WIDTH-1:0] precision_mode    ,
    
    // RAM阵列D读取接口
    output reg  [               PE_SIZE-1:0] ram_d_rd_en       ,
    output reg  [RAM_ADDR_WIDTH*PE_SIZE-1:0] ram_d_rd_addr     ,
    input  wire [RAM_DATA_WIDTH*PE_SIZE-1:0] ram_d_rd_data     ,

    // 传输控制信号
    input  wire                              a_dot_b_add_c_done, // 矩阵计算完成
    input  wire [        AXI_ADDR_WIDTH-1:0] axi_target_addr_cfg, // 外部写回目标地址配置
    output reg                               transfer_start    , // 开始传输脉冲
    output reg  [                      15:0] transfer_count    , // 传输数据量
    output reg  [        AXI_ADDR_WIDTH-1:0] ram_base_addr     , // RAM基地址
    output reg  [        AXI_ADDR_WIDTH-1:0] axi_target_addr   , // AXI目标地址
    
    // 状态信号
    input  wire                              transfer_done     , // 传输完成
    input  wire [                       1:0] transfer_status     // 传输状态
);

    // 内部参数定义
    localparam LOG2_PE_SIZE = $clog2(PE_SIZE);
    
    // 精度模式定义
    localparam PM_INT8_ALL    = 4'd1; // ABC 矩阵均为 INT8
    localparam PM_INT8_INT32  = 4'd3; // AB 为 INT8，C 为 INT32

    // 数据宽度类型定义
    localparam DATA_WIDTH_HALF_BYTE = 2'd0;
    localparam DATA_WIDTH_ONE_BYTE  = 2'd1;
    localparam DATA_WIDTH_TWO_BYTE  = 2'd2;
    localparam DATA_WIDTH_FOUR_BYTE = 2'd3;
    
    // 状态机定义
    localparam IDLE        = 2'b00;
    localparam PREPARE     = 2'b01;
    localparam WAIT_DONE   = 2'b10;
    
    reg [1:0] curr_state;
    reg [1:0] next_state;
    
    // 定义计算对数值的函数
    function [3:0] get_log2;
        input [7:0] value;
        begin
            case (value)
                8'd1:    get_log2 = 4'd0;
                8'd2:    get_log2 = 4'd1;
                8'd4:    get_log2 = 4'd2;
                8'd8:    get_log2 = 4'd3;
                8'd16:   get_log2 = 4'd4;
                8'd32:   get_log2 = 4'd5;
                8'd64:   get_log2 = 4'd6;
                8'd128:  get_log2 = 4'd7;
                default: get_log2 = 4'd0;
            endcase
        end
    endfunction

    reg [2:0] data_width_d;
    reg [3:0] log2_n_div_epw_d;
    
    // 计算矩阵维度的对数值
    wire [3:0] log2_matrix_n = get_log2(matrix_n);
    
    // 计算行列索引
    wire [7:0] row_idx = axi_rd_addr >> log2_n_div_epw_d; // linear_index / matrix_n
    wire [7:0] col_idx = axi_rd_addr & ((1 << log2_n_div_epw_d) - 1); // linear_index % matrix_n
    
    // 计算RAM编号和RAM内部地址
    wire [LOG2_PE_SIZE-1:0]   ram_index = row_idx[LOG2_PE_SIZE-1:0]; // row_idx % PE_SIZE
    wire [RAM_ADDR_WIDTH-1:0] ram_addr = ((row_idx >> LOG2_PE_SIZE) << log2_n_div_epw_d) + col_idx; // (row_idx / PE_SIZE) * matrix_n + col_idx
    
    // 保存RAM编号以进行数据选择
    reg  [LOG2_PE_SIZE-1:0] selected_ram;
    reg  [PE_SIZE-1:0] ram_d_rd_data_vld;


    always @(*) begin
        case (precision_mode)
            PM_INT8_ALL, PM_INT8_INT32: begin
                data_width_d = DATA_WIDTH_FOUR_BYTE;
            end

            default: begin
                data_width_d = DATA_WIDTH_FOUR_BYTE;
            end
        endcase
    end
    
    always @(*) begin
        case (data_width_d)
            DATA_WIDTH_TWO_BYTE: begin
                log2_n_div_epw_d = (log2_matrix_n > 2) ? (log2_matrix_n - 2) : 0;
            end
            DATA_WIDTH_FOUR_BYTE: begin
                log2_n_div_epw_d = (log2_matrix_n > 1) ? (log2_matrix_n - 1) : 0;
            end
            default: begin
                log2_n_div_epw_d = (log2_matrix_n > 1) ? (log2_matrix_n - 1) : 0;
            end
        endcase
    end
    
    // 状态机实现
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            curr_state <= IDLE;
        else
            curr_state <= next_state;
    end
    
    // 状态转换逻辑
    always @(*) begin
        next_state = curr_state;
        
        case (curr_state)
            IDLE: begin
                if (a_dot_b_add_c_done)
                    next_state = PREPARE;
            end
            
            PREPARE: begin
                next_state = WAIT_DONE;
            end
            
            WAIT_DONE: begin
                if (transfer_done)
                    next_state = IDLE;
            end
            
            default: next_state = IDLE;
        endcase
    end
    
    // 传输控制信号生成
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            transfer_start <= 1'b0;
            transfer_count <= 16'b0;
            axi_target_addr <= 32'b0;
            ram_base_addr   <= 32'b0;
        end else begin
            // 默认值
            transfer_start <= 1'b0;
            
            case (curr_state)
                IDLE: begin
                    // 空闲状态，保持默认值
                end
                
                PREPARE: begin
                    // 计算完成，准备传输
                    transfer_start  <= 1'b1;                      // 触发传输开始
                    transfer_count  <= matrix_m << log2_n_div_epw_d; // 设置传输数量(矩阵总元素数)
                    if (axi_target_addr_cfg != {AXI_ADDR_WIDTH{1'b0}})
                        axi_target_addr <= axi_target_addr_cfg;  // 使用可编程目标地址
                    else
                        axi_target_addr <= MATRIX_D_BASE_ADDR;   // 回退到历史固定地址
                    ram_base_addr   <= 32'b0;
                end
                
                WAIT_DONE: begin
                    // 等待传输完成，不做操作
                end
            endcase
        end
    end
    
    // 读请求处理
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            selected_ram <= {LOG2_PE_SIZE{1'b0}};
        end else if (axi_rd_en) begin
            selected_ram <= ram_index; // 记录选定的RAM
        end
    end

    always @(posedge clk) begin
        if (|ram_d_rd_en) begin
            ram_d_rd_data_vld <= (1'b1 << ram_index);
        end else begin
            ram_d_rd_data_vld <= {PE_SIZE{1'b0}}; // 清除有效标志
        end
    end
    
    // 地址逆映射与RAM读控制
    integer i;
    always @(*) begin
        // 默认情况下禁用所有RAM读取
        ram_d_rd_en = {PE_SIZE{1'b0}};
        ram_d_rd_addr = {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
        
        // 如果有读请求，使能对应的RAM
        if (axi_rd_en) begin
            ram_d_rd_en = (1'b1 << ram_index);  // 只使能相应的RAM
            
            // 设置相应RAM的地址
            for (i = 0; i < PE_SIZE; i = i + 1) begin
                if (i == ram_index) begin
                    ram_d_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] = ram_addr;
                end
            end
        end
    end
    
    // 数据选择与输出逻辑
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_rd_data <= {AXI_DATA_WIDTH{1'b0}};
            axi_rd_data_vld <= 1'b0;
        end else begin
            // 默认无效
            axi_rd_data_vld <= 1'b0;
            
            // 检测RAM数据有效信号
            if (ram_d_rd_data_vld[selected_ram]) begin
                // 选择对应RAM的数据
                axi_rd_data <= ram_d_rd_data[selected_ram*RAM_DATA_WIDTH +: RAM_DATA_WIDTH];
                axi_rd_data_vld <= 1'b1;
            end
        end
    end

endmodule
