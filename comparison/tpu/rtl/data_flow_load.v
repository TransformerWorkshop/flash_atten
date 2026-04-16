module data_flow_load #(
    parameter PE_SIZE              = 8 ,   // PE数量/阵列大小
    parameter MATRIX_DIM_WIDTH     = 8 ,   // 矩阵维度宽度
    parameter PRECISION_MODE_WIDTH = 4 ,   // 精度模式宽度
    parameter RAM_ADDR_WIDTH       = 8 ,   // RAM地址宽度
    parameter RAM_DATA_WIDTH       = 64,   // RAM数据宽度
    parameter SYS_DATA_WIDTH       = 32    
) (
    // 时钟和复位
    input  wire                               clk                 ,
    input  wire                               rst_n               ,
    
    // CSR 寄存器配置
    input  wire [       MATRIX_DIM_WIDTH-1:0] matrix_m            ,
    input  wire [       MATRIX_DIM_WIDTH-1:0] matrix_n            ,
    input  wire [       MATRIX_DIM_WIDTH-1:0] matrix_k            ,
    input  wire [   PRECISION_MODE_WIDTH-1:0] precision_mode      ,
    input  wire                               sparse_en           ,
    
    // 控制信号
    input  wire                               ram_a_read_ready    , // A矩阵RAM准备好信号
    input  wire                               ram_b_read_ready    , // B矩阵RAM准备好信号
    input  wire                               ram_d_write_ready   , // D矩阵RAM写就绪信号
    output reg                                load_busy           , // 忙状态指示
    output reg                                load_done           , // 传输完成指示

    input  wire                               compute_done        ,

    input  wire                               a_index_wr_en       ,
    input  wire  [        RAM_ADDR_WIDTH-1:0] a_index_wr_addr     ,
    input  wire  [        RAM_DATA_WIDTH-1:0] a_index_wr_data     ,
    
    // A矩阵RAM阵列读接口
    output reg  [               PE_SIZE-1:0]  ram_a_rd_en         ,
    output reg  [RAM_ADDR_WIDTH*PE_SIZE-1:0]  ram_a_rd_addr       ,
    input  wire [RAM_DATA_WIDTH*PE_SIZE-1:0]  ram_a_rd_data       ,
    
    // A矩阵阵列写接口
    output reg  [                PE_SIZE-1:0] systolic_a_wr_en    ,
    output reg  [ SYS_DATA_WIDTH*PE_SIZE-1:0] systolic_a_wr_data  ,

    // B矩阵RAM阵列读接口
    output reg  [               PE_SIZE-1:0]  ram_b_rd_en         ,
    output reg  [RAM_ADDR_WIDTH*PE_SIZE-1:0]  ram_b_rd_addr       ,
    input  wire [RAM_DATA_WIDTH*PE_SIZE-1:0]  ram_b_rd_data       ,
    
    // B矩阵阵列写接口
    output reg  [                PE_SIZE-1:0] systolic_b_wr_en    ,
    output reg  [ SYS_DATA_WIDTH*PE_SIZE-1:0] systolic_b_wr_data  ,

    output wire                               first_data          ,
    output wire                               last_data            
);

    // 精度模式定义
    localparam PM_INT4_ALL    = 4'd0; // ABC 矩阵均为 INT4
    localparam PM_INT8_ALL    = 4'd1; // ABC 矩阵均为 INT8
    localparam PM_INT4_INT32  = 4'd2; // AB 为 INT4，C 为 INT32
    localparam PM_INT8_INT32  = 4'd3; // AB 为 INT8，C 为 INT32
    localparam PM_FP32_ALL    = 4'd6; // ABC 矩阵均为 FP32

    // 数据宽度类型定义
    localparam DATA_WIDTH_HALF_BYTE = 2'd0;
    localparam DATA_WIDTH_ONE_BYTE  = 2'd1;
    localparam DATA_WIDTH_TWO_BYTE  = 2'd2;
    localparam DATA_WIDTH_FOUR_BYTE = 2'd3;
    localparam RAM_ONE_BYTE_ELEMS   = RAM_DATA_WIDTH / 8;
    localparam RAM_TWO_BYTE_ELEMS   = RAM_DATA_WIDTH / 16;
    localparam RAM_FOUR_BYTE_ELEMS  = RAM_DATA_WIDTH / 32;
    localparam LOG2_RAM_ONE_BYTE_ELEMS  = $clog2(RAM_ONE_BYTE_ELEMS);
    localparam LOG2_RAM_TWO_BYTE_ELEMS  = $clog2(RAM_TWO_BYTE_ELEMS);
    localparam LOG2_RAM_FOUR_BYTE_ELEMS = $clog2(RAM_FOUR_BYTE_ELEMS);

    // 计算PE_SIZE的对数
    localparam LOG2_PE_SIZE = $clog2(PE_SIZE);
    
    // 状态定义
    localparam IDLE       = 3'd0; // 空闲状态
    localparam PREPARE    = 3'd1; // 准备状态
    localparam BUSY       = 3'd2; // 工作状态
    localparam WAIT       = 3'd3; // 等待状态
    localparam DONE       = 3'd4; // 完成状态

    localparam MAX_PREPARE_CNT = 5'd2;

    // 模块状态
    reg [2:0]  curr_state, next_state;

    wire ram_data_ready;

    // 计数器
    reg [5:0] sub_elem_cnt;  // 子元素计数器
    reg [5:0] elem_k_cnt;    // 列计数器
    reg [5:0] block_n_cnt;   // 迭代计数器
    reg [5:0] block_m_cnt;   // 块计数器

    reg [5:0] prepare_cnt; // 准备状态计数器

    // 计数器上限
    reg [5:0] max_sub_elem;  // 每RAM字的最大子元素索引
    reg [5:0] max_elem_k;    // 每次迭代的最大列索引
    reg [5:0] max_block_n;   // 每个块的最大迭代次数
    reg [5:0] max_block_m;   // 最大块索引
    reg [5:0] block_groups_m;

    reg [15:0] systolic_wr_cnt;     // FIFO写入计数器
    reg [15:0] max_systolic_wr_cnt; // FIFO写入计数器上限
    
    reg [3:0] log2_k_div_epw;

    reg [15:0] a_meta_data_indices_0 [0:31];
    reg [15:0] a_meta_data_indices_1 [0:31];
    reg [3:0]  sparse_elem_cnt;
    reg [5:0]  sparse_index [0:31]; // 稀疏计数器
    reg [5:0]  block_m_sparse_cnt;
    reg [5:0]  block_n_sparse_cnt;

    reg a_index_wr_en_r;

    reg [PE_SIZE-1:0] a_meta_data_indices_sel;

    wire a_index_wr_done = a_index_wr_en_r && !a_index_wr_en;
    // 缓冲区选择寄存器 - 指示当前活动缓冲区(用于读取)
    reg buffer_sel_reg;
    // 缓冲区状态: 0=空, 1=满
    reg [1:0] buffer_status;  // [0]=buffer0状态, [1]=buffer1状态

    integer i;
    integer meta_idx;

    always @(posedge clk) begin
        a_index_wr_en_r <= a_index_wr_en;
    end
    
    // 缓冲区切换和状态管理
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buffer_sel_reg <= 1'b0;
            buffer_status <= 2'b00;
        end else begin
            // 使用case处理组合情况，明确优先级
            case ({a_index_wr_done, load_done})
                2'b11: begin // 同时读完和写完
                    // 更新两个缓冲区状态
                    buffer_status[~buffer_sel_reg] <= 1'b1;  // 新写入的标记为满
                    buffer_status[buffer_sel_reg] <= 1'b0;   // 读取的标记为空
                    
                    // 无论如何都切换到新写入的缓冲区
                    buffer_sel_reg <= ~buffer_sel_reg;
                end
                
                2'b10: begin // 仅写完
                    buffer_status[~buffer_sel_reg] <= 1'b1;
                    if (buffer_status[buffer_sel_reg] == 1'b0)
                        buffer_sel_reg <= ~buffer_sel_reg;
                end
                
                2'b01: begin // 仅读完
                    buffer_status[buffer_sel_reg] <= 1'b0;
                    if (buffer_status[~buffer_sel_reg] == 1'b1)
                        buffer_sel_reg <= ~buffer_sel_reg;
                end
                
                default: begin end // 无操作
            endcase
        end
    end

    always @(posedge clk) begin
        if (a_index_wr_en && buffer_sel_reg) begin
            for (meta_idx = 0; meta_idx < (RAM_DATA_WIDTH / 16); meta_idx = meta_idx + 1) begin
                a_meta_data_indices_0[(a_index_wr_addr << LOG2_RAM_TWO_BYTE_ELEMS) + meta_idx] <=
                    a_index_wr_data[(meta_idx * 16) +: 16];
            end
        end else if (a_index_wr_en && !buffer_sel_reg) begin
            for (meta_idx = 0; meta_idx < (RAM_DATA_WIDTH / 16); meta_idx = meta_idx + 1) begin
                a_meta_data_indices_1[(a_index_wr_addr << LOG2_RAM_TWO_BYTE_ELEMS) + meta_idx] <=
                    a_index_wr_data[(meta_idx * 16) +: 16];
            end
        end
    end

    always @(*) begin
        for (i = 0; i < PE_SIZE; i = i + 1) begin
            a_meta_data_indices_sel[i] = buffer_sel_reg ? a_meta_data_indices_1[i+block_m_sparse_cnt*PE_SIZE][sparse_elem_cnt] : a_meta_data_indices_0[i+block_m_sparse_cnt*PE_SIZE][sparse_elem_cnt];
        end
    end

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
    
    // 根据precision_mode解析为内部数据类型
    reg [1:0] data_width_ab;
    
    always @(*) begin
        case (precision_mode)
            PM_INT4_ALL, PM_INT4_INT32:
                data_width_ab =  DATA_WIDTH_HALF_BYTE;
            PM_INT8_ALL, PM_INT8_INT32:
                data_width_ab = DATA_WIDTH_ONE_BYTE;
            PM_FP32_ALL:
                data_width_ab = DATA_WIDTH_FOUR_BYTE;
            default:
                data_width_ab = DATA_WIDTH_ONE_BYTE;
        endcase
    end

    // 矩阵维度和计数器上限计算 - 使用时序逻辑
    always @(*) begin
        // 计算每个维度的最大计数器值
        max_block_n = (matrix_n >> LOG2_PE_SIZE) - 8'd1;
        if (matrix_m == 0) begin
            block_groups_m = 6'd0;
        end else begin
            // M can be smaller than PE_SIZE; use ceil(m / PE_SIZE) so m=1..7 still
            // runs exactly one row-group instead of underflowing the block counter.
            block_groups_m = (matrix_m + PE_SIZE - 1) >> LOG2_PE_SIZE;
        end
        max_block_m = (block_groups_m == 0) ? 6'd0 : (block_groups_m - 6'd1);

        // 根据数据类型设置参数
        case (data_width_ab)
            DATA_WIDTH_HALF_BYTE: begin
                max_sub_elem   = 5'd7;  // 8个元素每个RAM字，索引0-7
                max_elem_k     = (matrix_k >> 4) - 8'd1;  // k/8-1
                log2_k_div_epw = get_log2(matrix_k) > 4 ? get_log2(matrix_k) - 4 : 0;
            end
            
            DATA_WIDTH_ONE_BYTE: begin
                if (matrix_k <= RAM_ONE_BYTE_ELEMS) begin
                    max_sub_elem = matrix_k - 8'd1;
                    max_elem_k   = 6'd0;
                end else begin
                    max_sub_elem = RAM_ONE_BYTE_ELEMS - 1;
                    max_elem_k   = ((matrix_k + RAM_ONE_BYTE_ELEMS - 1) >> LOG2_RAM_ONE_BYTE_ELEMS) - 8'd1;
                end
                log2_k_div_epw = get_log2(matrix_k) > LOG2_RAM_ONE_BYTE_ELEMS ?
                    (get_log2(matrix_k) - LOG2_RAM_ONE_BYTE_ELEMS) : 0;
            end
            
            DATA_WIDTH_TWO_BYTE: begin
                if (matrix_k <= RAM_TWO_BYTE_ELEMS) begin
                    max_sub_elem = matrix_k - 8'd1;
                    max_elem_k   = 6'd0;
                end else begin
                    max_sub_elem = RAM_TWO_BYTE_ELEMS - 1;
                    max_elem_k   = ((matrix_k + RAM_TWO_BYTE_ELEMS - 1) >> LOG2_RAM_TWO_BYTE_ELEMS) - 8'd1;
                end
                log2_k_div_epw = get_log2(matrix_k) > LOG2_RAM_TWO_BYTE_ELEMS ?
                    (get_log2(matrix_k) - LOG2_RAM_TWO_BYTE_ELEMS) : 0;
            end
            
            DATA_WIDTH_FOUR_BYTE: begin
                if (matrix_k <= RAM_FOUR_BYTE_ELEMS) begin
                    max_sub_elem = matrix_k - 8'd1;
                    max_elem_k   = 6'd0;
                end else begin
                    max_sub_elem = RAM_FOUR_BYTE_ELEMS - 1;
                    max_elem_k   = ((matrix_k + RAM_FOUR_BYTE_ELEMS - 1) >> LOG2_RAM_FOUR_BYTE_ELEMS) - 8'd1;
                end
                log2_k_div_epw = get_log2(matrix_k) > LOG2_RAM_FOUR_BYTE_ELEMS ?
                    (get_log2(matrix_k) - LOG2_RAM_FOUR_BYTE_ELEMS) : 0;
            end

            default: begin
                if (matrix_k <= RAM_ONE_BYTE_ELEMS) begin
                    max_sub_elem = matrix_k - 8'd1;
                    max_elem_k   = 6'd0;
                end else begin
                    max_sub_elem = RAM_ONE_BYTE_ELEMS - 1;
                    max_elem_k   = ((matrix_k + RAM_ONE_BYTE_ELEMS - 1) >> LOG2_RAM_ONE_BYTE_ELEMS) - 8'd1;
                end
                log2_k_div_epw = get_log2(matrix_k) > LOG2_RAM_ONE_BYTE_ELEMS ?
                    (get_log2(matrix_k) - LOG2_RAM_ONE_BYTE_ELEMS) : 0;
            end
        endcase

        /*
         * Total systolic feed cycles are:
         *   (sub-elements per RAM word)
         * * (RAM words across K for one tile)
         * * (N tiles)
         * * (M tiles)
         * plus the PE pipeline drain latency (PE_SIZE-1).
         *
         * The original fp32 tree hard-coded 262, which happens to match
         * m16n16k16 in FP32:
         *   8 * 8 * 2 * 2 + 7 - 1 = 262
         *
         * Keep the same zero-based terminal count, but derive it from the
         * active dimensions and data packing so smaller shapes do not overrun
         * and FP32 keeps its full 256 feed cycles.
         */
        max_systolic_wr_cnt =
            ({11'd0, max_sub_elem} + 16'd1) *
            ({11'd0, max_elem_k} + 16'd1) *
            ({10'd0, max_block_n} + 16'd1) *
            ({10'd0, max_block_m} + 16'd1) +
            (PE_SIZE - 1'b1) - 16'd1;
    end

    assign ram_data_ready = ram_a_read_ready && ram_b_read_ready;
    assign first_data = (curr_state == BUSY) && (|systolic_a_wr_en) && (systolic_wr_cnt == 0);
    assign last_data = (curr_state == BUSY) && (systolic_wr_cnt == max_systolic_wr_cnt);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            curr_state <= IDLE;
        end else begin
            curr_state <= next_state;
        end
    end

    // 状态转移逻辑
    always @(*) begin
        next_state = curr_state;
        
        case (curr_state)
            IDLE: begin
                if (ram_data_ready && ram_d_write_ready) begin
                    next_state = PREPARE;
                end else begin
                    next_state = IDLE;
                end
            end

            PREPARE: begin
                if (prepare_cnt == MAX_PREPARE_CNT) begin
                    next_state = BUSY;
                end else begin
                    next_state = PREPARE;
                end
            end
            
            BUSY: begin
                if (systolic_wr_cnt == max_systolic_wr_cnt) begin
                    next_state = WAIT;
                end else begin
                    next_state = BUSY;
                end
            end

            WAIT: begin
                if (compute_done) begin
                    next_state = DONE;
                end else begin
                    next_state = WAIT;
                end
            end
            
            DONE: begin
                next_state = IDLE;
            end
                
            default: begin
                next_state = IDLE;
            end
        endcase
    end

    // 状态机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            load_busy    <= 1'b0;
            load_done    <= 1'b0;
            sub_elem_cnt <= 5'd0;
            elem_k_cnt   <= 8'd0;
            block_n_cnt  <= 8'd0;
            block_m_cnt  <= 8'd0;
            prepare_cnt  <= 5'd0;
            systolic_wr_cnt  <= 16'd0;
        end else begin
            case (curr_state)
                IDLE: begin
                    load_busy    <= 1'b0;
                    load_done    <= 1'b0;
                    sub_elem_cnt <= 5'd0;
                    elem_k_cnt   <= 8'd0;
                    block_n_cnt  <= 8'd0;
                    block_m_cnt  <= 8'd0;
                    prepare_cnt  <= 5'd0;
                    systolic_wr_cnt  <= 16'd0;
                end

                PREPARE: begin
                    sub_elem_cnt <= max_sub_elem - 5'd1; // 准备状态，设置子元素计数器为最大值
                    prepare_cnt <= prepare_cnt + 1'b1; // 准备状态计数器递增
                    if (prepare_cnt == MAX_PREPARE_CNT) begin
                        prepare_cnt <= 5'd0; // 重置准备状态计数器
                    end
                end
                
                BUSY: begin
                    // 循环计数逻辑
                    if (sub_elem_cnt == max_sub_elem) begin
                        sub_elem_cnt <= 5'd0;
                        
                        if (elem_k_cnt == max_elem_k) begin
                            elem_k_cnt <= 8'd0;

                            if (block_n_cnt == max_block_n) begin
                                block_n_cnt <= 8'd0;

                                if (block_m_cnt == max_block_m) begin
                                    block_m_cnt <= 8'd0;
                                end else begin
                                    block_m_cnt <= block_m_cnt + 8'd1;
                                end
                            end else begin
                                block_n_cnt <= block_n_cnt + 8'd1;
                            end
                        end else begin
                            elem_k_cnt <= elem_k_cnt + 8'd1;
                        end
                    end else begin
                        sub_elem_cnt <= sub_elem_cnt + 5'd1;
                    end
                    
                    // FIFO写入计数
                    if ((|systolic_a_wr_en) && (|systolic_b_wr_en)) begin
                        systolic_wr_cnt <= systolic_wr_cnt + 16'd1;
                        if (systolic_wr_cnt == max_systolic_wr_cnt) begin
                            systolic_wr_cnt <= 16'd0;
                            // load_done       <= 1'b1;
                        end
                    end

                    load_busy <= 1'b1;
                    load_done <= 1'b0;
                end

                WAIT: begin
                    if (compute_done) begin
                        load_done <= 1'b1;
                    end
                end
                
                DONE: begin
                    load_busy        <= 1'b0;
                    load_done        <= 1'b0;
                    sub_elem_cnt     <= 5'd0;
                    elem_k_cnt       <= 8'd0;
                    block_n_cnt      <= 8'd0;
                    block_m_cnt      <= 8'd0;
                    systolic_wr_cnt  <= 16'd0;
                end
                
                default: begin
                    load_busy        <= 1'b0;
                    load_done        <= 1'b0;
                    sub_elem_cnt     <= 5'd0;
                    elem_k_cnt       <= 8'd0;
                    block_n_cnt      <= 8'd0;
                    block_m_cnt      <= 8'd0;
                    systolic_wr_cnt  <= 16'd0;
                end
            endcase
        end
    end

    // RAM读取逻辑
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ram_a_rd_en   <= {PE_SIZE{1'b0}};
            ram_a_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
            ram_b_rd_en   <= {PE_SIZE{1'b0}};
            ram_b_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
        end else begin
            if (curr_state == BUSY) begin
                if (!sparse_en) begin
                    case (data_width_ab)
                        DATA_WIDTH_HALF_BYTE: begin
                            if ((sub_elem_cnt == max_sub_elem - 1'b1) && (systolic_wr_cnt < max_systolic_wr_cnt - (PE_SIZE - 1'b1) - 16'd1)) begin
                                // A矩阵RAM阵列读取
                                ram_a_rd_en <= {PE_SIZE{1'b1}};
                                for (i = 0; i < PE_SIZE; i = i + 1) begin
                                    ram_a_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                                        (block_m_cnt << log2_k_div_epw) + elem_k_cnt;
                                end
                                // B矩阵RAM阵列读取
                                ram_b_rd_en <= {PE_SIZE{1'b1}};
                                for (i = 0; i < PE_SIZE; i = i + 1) begin
                                    ram_b_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                                        (block_n_cnt << log2_k_div_epw) + elem_k_cnt;
                                end
                            end else begin
                                ram_a_rd_en   <= {PE_SIZE{1'b0}};
                                ram_a_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                                ram_b_rd_en   <= {PE_SIZE{1'b0}};
                                ram_b_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                            end
                        end

                        DATA_WIDTH_ONE_BYTE: begin
                            if ((sub_elem_cnt == max_sub_elem - 1'b1) && (systolic_wr_cnt < max_systolic_wr_cnt - (PE_SIZE - 1'b1) - 16'd1)) begin
                                // A矩阵RAM阵列读取
                                ram_a_rd_en <= {PE_SIZE{1'b1}};
                                for (i = 0; i < PE_SIZE; i = i + 1) begin
                                    ram_a_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                                        (block_m_cnt << log2_k_div_epw) + elem_k_cnt;
                                end
                                // B矩阵RAM阵列读取
                                ram_b_rd_en <= {PE_SIZE{1'b1}};
                                for (i = 0; i < PE_SIZE; i = i + 1) begin
                                    ram_b_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                                        (block_n_cnt << log2_k_div_epw) + elem_k_cnt;
                                end
                            end else begin
                                ram_a_rd_en   <= {PE_SIZE{1'b0}};
                                ram_a_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                                ram_b_rd_en   <= {PE_SIZE{1'b0}};
                                ram_b_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                            end
                        end

                        DATA_WIDTH_TWO_BYTE: begin
                            if ((sub_elem_cnt == max_sub_elem - 1'b1) && (systolic_wr_cnt < max_systolic_wr_cnt - (PE_SIZE - 1'b1) - 16'd1)) begin
                                // A矩阵RAM阵列读取
                                ram_a_rd_en <= {PE_SIZE{1'b1}};
                                for (i = 0; i < PE_SIZE; i = i + 1) begin
                                    ram_a_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                                        (block_m_cnt << log2_k_div_epw) + elem_k_cnt;
                                end
                                // B矩阵RAM阵列读取
                                ram_b_rd_en <= {PE_SIZE{1'b1}};
                                for (i = 0; i < PE_SIZE; i = i + 1) begin
                                    ram_b_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                                        (block_n_cnt << log2_k_div_epw) + elem_k_cnt;
                                end
                            end else begin
                                ram_a_rd_en   <= {PE_SIZE{1'b0}};
                                ram_a_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                                ram_b_rd_en   <= {PE_SIZE{1'b0}};
                                ram_b_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                            end
                        end

                        DATA_WIDTH_FOUR_BYTE: begin
                            if ((sub_elem_cnt == max_sub_elem - 1'b1) && (systolic_wr_cnt < max_systolic_wr_cnt - (PE_SIZE - 1'b1) - 16'd1)) begin
                                // A矩阵RAM阵列读取
                                ram_a_rd_en <= {PE_SIZE{1'b1}};
                                for (i = 0; i < PE_SIZE; i = i + 1) begin
                                    ram_a_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                                        (block_m_cnt << log2_k_div_epw) + elem_k_cnt;
                                end
                                // B矩阵RAM阵列读取
                                ram_b_rd_en <= {PE_SIZE{1'b1}};
                                for (i = 0; i < PE_SIZE; i = i + 1) begin
                                    ram_b_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                                        (block_n_cnt << log2_k_div_epw) + elem_k_cnt;
                                end
                            end else begin
                                ram_a_rd_en   <= {PE_SIZE{1'b0}};
                                ram_a_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                                ram_b_rd_en   <= {PE_SIZE{1'b0}};
                                ram_b_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                            end
                        end
                    endcase
                end else begin
                    case (data_width_ab)
                        DATA_WIDTH_HALF_BYTE: begin
                            if ((sub_elem_cnt == max_sub_elem - 1'b1) && (systolic_wr_cnt < max_systolic_wr_cnt - (PE_SIZE - 1'b1) - 16'd1)) begin
                                // A矩阵RAM阵列读取
                                ram_a_rd_en <= {PE_SIZE{1'b1}};
                                for (i = 0; i < PE_SIZE; i = i + 1) begin
                                    ram_a_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                                        (block_m_cnt << log2_k_div_epw) + elem_k_cnt;
                                end
                                // B矩阵RAM阵列读取
                                ram_b_rd_en <= {PE_SIZE{1'b1}};
                                for (i = 0; i < PE_SIZE; i = i + 1) begin
                                    ram_b_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                                        (block_n_cnt << log2_k_div_epw) + elem_k_cnt;
                                end
                            end else begin
                                ram_a_rd_en   <= {PE_SIZE{1'b0}};
                                ram_a_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                                ram_b_rd_en   <= {PE_SIZE{1'b0}};
                                ram_b_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                            end
                        end

                        DATA_WIDTH_ONE_BYTE: begin
                            if ((sub_elem_cnt == max_sub_elem - 1'b1) && (elem_k_cnt[0] == 1'b0) && (systolic_wr_cnt < max_systolic_wr_cnt - (PE_SIZE - 1'b1) - 16'd1)) begin
                                // A矩阵RAM阵列读取
                                ram_a_rd_en <= {PE_SIZE{1'b1}};
                                for (i = 0; i < PE_SIZE; i = i + 1) begin
                                    ram_a_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                                        (block_m_cnt << (log2_k_div_epw - 1)) + (elem_k_cnt >> 1);
                                end
                            end else begin
                                ram_a_rd_en   <= {PE_SIZE{1'b0}};
                                ram_a_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                            end

                            if ((sub_elem_cnt == max_sub_elem - 1'b1) && (systolic_wr_cnt < max_systolic_wr_cnt - (PE_SIZE - 1'b1) - 16'd1)) begin
                                // B矩阵RAM阵列读取
                                ram_b_rd_en <= {PE_SIZE{1'b1}};
                                for (i = 0; i < PE_SIZE; i = i + 1) begin
                                    ram_b_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                                        (block_n_cnt << log2_k_div_epw) + elem_k_cnt;
                                end
                            end else begin
                                ram_b_rd_en   <= {PE_SIZE{1'b0}};
                                ram_b_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                            end
                        end

                        // DATA_WIDTH_ONE_BYTE: begin
                        //     if ((sub_elem_cnt == max_sub_elem - 1'b1) && (systolic_wr_cnt < max_systolic_wr_cnt - (PE_SIZE - 1'b1) - 16'd1)) begin
                        //         // A矩阵RAM阵列读取
                        //         ram_a_rd_en <= {PE_SIZE{1'b1}};
                        //         for (i = 0; i < PE_SIZE; i = i + 1) begin
                        //             ram_a_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                        //                 (block_m_cnt << log2_k_div_epw) + elem_k_cnt;
                        //         end
                        //         // B矩阵RAM阵列读取
                        //         ram_b_rd_en <= {PE_SIZE{1'b1}};
                        //         for (i = 0; i < PE_SIZE; i = i + 1) begin
                        //             ram_b_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                        //                 (block_n_cnt << log2_k_div_epw) + elem_k_cnt;
                        //         end
                        //     end else begin
                        //         ram_a_rd_en   <= {PE_SIZE{1'b0}};
                        //         ram_a_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                        //         ram_b_rd_en   <= {PE_SIZE{1'b0}};
                        //         ram_b_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                        //     end
                        // end

                        DATA_WIDTH_TWO_BYTE: begin
                            if ((sub_elem_cnt == max_sub_elem - 1'b1) && (elem_k_cnt[0] == 1'b0) && (systolic_wr_cnt < max_systolic_wr_cnt - (PE_SIZE - 1'b1) - 16'd1)) begin
                                // A矩阵RAM阵列读取
                                ram_a_rd_en <= {PE_SIZE{1'b1}};
                                for (i = 0; i < PE_SIZE; i = i + 1) begin
                                    ram_a_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                                        (block_m_cnt << (log2_k_div_epw - 1)) + (elem_k_cnt >> 1);
                                end
                            end else begin
                                ram_a_rd_en   <= {PE_SIZE{1'b0}};
                                ram_a_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                            end

                            if ((sub_elem_cnt == max_sub_elem - 1'b1) && (systolic_wr_cnt < max_systolic_wr_cnt - (PE_SIZE - 1'b1) - 16'd1)) begin
                                // B矩阵RAM阵列读取
                                ram_b_rd_en <= {PE_SIZE{1'b1}};
                                for (i = 0; i < PE_SIZE; i = i + 1) begin
                                    ram_b_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                                        (block_n_cnt << log2_k_div_epw) + elem_k_cnt;
                                end
                            end else begin
                                ram_b_rd_en   <= {PE_SIZE{1'b0}};
                                ram_b_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                            end
                        end

                        // DATA_WIDTH_TWO_BYTE: begin
                        //     if ((sub_elem_cnt == max_sub_elem - 1'b1) && (systolic_wr_cnt < max_systolic_wr_cnt - (PE_SIZE - 1'b1) - 16'd1)) begin
                        //         // A矩阵RAM阵列读取
                        //         ram_a_rd_en <= {PE_SIZE{1'b1}};
                        //         for (i = 0; i < PE_SIZE; i = i + 1) begin
                        //             ram_a_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                        //                 (block_m_cnt << log2_k_div_epw) + elem_k_cnt;
                        //         end
                        //         // B矩阵RAM阵列读取
                        //         ram_b_rd_en <= {PE_SIZE{1'b1}};
                        //         for (i = 0; i < PE_SIZE; i = i + 1) begin
                        //             ram_b_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                        //                 (block_n_cnt << log2_k_div_epw) + elem_k_cnt;
                        //         end
                        //     end else begin
                        //         ram_a_rd_en   <= {PE_SIZE{1'b0}};
                        //         ram_a_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                        //         ram_b_rd_en   <= {PE_SIZE{1'b0}};
                        //         ram_b_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                        //     end
                        // end

                        DATA_WIDTH_FOUR_BYTE: begin
                            if ((sub_elem_cnt == max_sub_elem - 1'b1) && (elem_k_cnt[0] == 1'b0) && (systolic_wr_cnt < max_systolic_wr_cnt - (PE_SIZE - 1'b1) - 16'd1)) begin
                                // A矩阵RAM阵列读取
                                ram_a_rd_en <= {PE_SIZE{1'b1}};
                                for (i = 0; i < PE_SIZE; i = i + 1) begin
                                    ram_a_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                                        (block_m_cnt << (log2_k_div_epw - 1)) + (elem_k_cnt >> 1);
                                end
                            end else begin
                                ram_a_rd_en   <= {PE_SIZE{1'b0}};
                                ram_a_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                            end

                            if ((sub_elem_cnt == max_sub_elem - 1'b1) && (systolic_wr_cnt < max_systolic_wr_cnt - (PE_SIZE - 1'b1) - 16'd1)) begin
                                // B矩阵RAM阵列读取
                                ram_b_rd_en <= {PE_SIZE{1'b1}};
                                for (i = 0; i < PE_SIZE; i = i + 1) begin
                                    ram_b_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                                        (block_n_cnt << log2_k_div_epw) + elem_k_cnt;
                                end
                            end else begin
                                ram_b_rd_en   <= {PE_SIZE{1'b0}};
                                ram_b_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                            end
                        end

                        // DATA_WIDTH_FOUR_BYTE: begin
                        //     if ((sub_elem_cnt == max_sub_elem - 1'b1) && (systolic_wr_cnt < max_systolic_wr_cnt - (PE_SIZE - 1'b1) - 16'd1)) begin
                        //         // A矩阵RAM阵列读取
                        //         ram_a_rd_en <= {PE_SIZE{1'b1}};
                        //         for (i = 0; i < PE_SIZE; i = i + 1) begin
                        //             ram_a_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                        //                 (block_m_cnt << log2_k_div_epw) + elem_k_cnt;
                        //         end
                        //         // B矩阵RAM阵列读取
                        //         ram_b_rd_en <= {PE_SIZE{1'b1}};
                        //         for (i = 0; i < PE_SIZE; i = i + 1) begin
                        //             ram_b_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                        //                 (block_n_cnt << log2_k_div_epw) + elem_k_cnt;
                        //         end
                        //     end else begin
                        //         ram_a_rd_en   <= {PE_SIZE{1'b0}};
                        //         ram_a_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                        //         ram_b_rd_en   <= {PE_SIZE{1'b0}};
                        //         ram_b_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                        //     end
                        // end
                    endcase
                end
                
            end else begin
                ram_a_rd_en   <= {PE_SIZE{1'b0}};
                ram_a_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                ram_b_rd_en   <= {PE_SIZE{1'b0}};
                ram_b_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
            end
        end
    end

    // wr_en信号生成
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            systolic_a_wr_en <= {PE_SIZE{1'b0}};
            systolic_b_wr_en <= {PE_SIZE{1'b0}};
        end else begin
            if (curr_state == BUSY) begin
                if ((|ram_a_rd_en) && (|ram_b_rd_en)) begin
                    systolic_a_wr_en <= {PE_SIZE{1'b1}};
                    systolic_b_wr_en <= {PE_SIZE{1'b1}};
                end else if (systolic_wr_cnt == max_systolic_wr_cnt) begin
                    systolic_a_wr_en <= {PE_SIZE{1'b0}};
                    systolic_b_wr_en <= {PE_SIZE{1'b0}};
                end
            end else begin
                systolic_a_wr_en <= {PE_SIZE{1'b0}};
                systolic_b_wr_en <= {PE_SIZE{1'b0}};
            end
        end
    end

    always @(*) begin
        case(data_width_ab)
            DATA_WIDTH_ONE_BYTE:  sparse_elem_cnt = {!elem_k_cnt[0],sub_elem_cnt[2:0]};
            DATA_WIDTH_TWO_BYTE:  sparse_elem_cnt = {(elem_k_cnt[1:0]+2'b11),sub_elem_cnt[1:0]};
            DATA_WIDTH_FOUR_BYTE: sparse_elem_cnt = {(elem_k_cnt[2:0]-2'b01),sub_elem_cnt[2]};
            default:              sparse_elem_cnt = {elem_k_cnt[0],sub_elem_cnt[2:0]};
        endcase
    end
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 32; i = i + 1) begin
                sparse_index[i] <= 6'b0;
            end
            block_m_sparse_cnt <= 6'b0;
            block_n_sparse_cnt <= 6'b0;
        end else begin
            if (curr_state == BUSY && sparse_en && |systolic_a_wr_en && (systolic_wr_cnt <= max_systolic_wr_cnt - (PE_SIZE - 1'b1))) begin
                // if ((|ram_a_rd_en) && (|ram_b_rd_en) && sparse_en) begin
                    for (i = 0; i < PE_SIZE; i = i + 1) begin
                        if (a_meta_data_indices_sel[i]) begin
                            sparse_index[i+block_m_sparse_cnt*PE_SIZE] <= sparse_index[i+block_m_sparse_cnt*PE_SIZE] + 1'b1;
                        end
                    end
                // end else if (systolic_wr_cnt == max_systolic_wr_cnt) begin

                // end
                if (precision_mode != PM_FP32_ALL) begin
                    if (sparse_elem_cnt == 15) begin
                        // block_m_sparse_cnt <= block_m_sparse_cnt + 1'b1;
                        if (block_n_sparse_cnt == max_block_n) begin
                            block_n_sparse_cnt <= 8'd0;

                            if (block_m_sparse_cnt == max_block_m) begin
                                block_m_sparse_cnt <= 8'd0;
                            end else begin
                                block_m_sparse_cnt <= block_m_sparse_cnt + 8'd1;
                            end
                        end else begin
                            block_n_sparse_cnt <= block_n_sparse_cnt + 8'd1;
                        end
                    end
                end else begin
                    if (systolic_wr_cnt[5:0] == 6'b111111) begin
                        // block_m_sparse_cnt <= block_m_sparse_cnt + 1'b1;
                        if (block_n_sparse_cnt == max_block_n) begin
                            block_n_sparse_cnt <= 8'd0;

                            if (block_m_sparse_cnt == max_block_m) begin
                                block_m_sparse_cnt <= 8'd0;
                            end else begin
                                block_m_sparse_cnt <= block_m_sparse_cnt + 8'd1;
                            end
                        end else begin
                            block_n_sparse_cnt <= block_n_sparse_cnt + 8'd1;
                        end
                    end
                end
                
            end else begin
                for (i = 0; i < 32; i = i + 1) begin
                    sparse_index[i] <= 6'b0;
                end
                block_m_sparse_cnt <= 6'b0;
            end
        end
    end

    // FIFO写入数据
    always @(*) begin
        systolic_a_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
        systolic_b_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
        
        if (curr_state == BUSY && |systolic_a_wr_en && |systolic_b_wr_en) begin
            if (!sparse_en) begin
                case (data_width_ab)
                    DATA_WIDTH_HALF_BYTE: begin
                        if (systolic_wr_cnt <= max_systolic_wr_cnt - (PE_SIZE - 1'b1)) begin
                            // A矩阵FIFO写入数据
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                systolic_a_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                                    {{(SYS_DATA_WIDTH-8){1'b0}}, ram_a_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*8) +: 8]};
                            end
                            // B矩阵FIFO写入数据
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                systolic_b_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                                    {{(SYS_DATA_WIDTH-8){1'b0}}, ram_b_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*8) +: 8]};
                            end
                        end else begin
                            systolic_a_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                            systolic_b_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                        end
                    end

                    DATA_WIDTH_ONE_BYTE: begin
                        if (systolic_wr_cnt <= max_systolic_wr_cnt - (PE_SIZE - 1'b1)) begin
                            // A矩阵FIFO写入数据
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                systolic_a_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                                    {{(SYS_DATA_WIDTH-8){1'b0}}, ram_a_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*8) +: 8]};
                            end
                            // B矩阵FIFO写入数据
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                systolic_b_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                                    {{(SYS_DATA_WIDTH-8){1'b0}}, ram_b_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*8) +: 8]};
                            end
                        end else begin
                            systolic_a_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                            systolic_b_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                        end
                    end

                    DATA_WIDTH_TWO_BYTE: begin
                        if (systolic_wr_cnt <= max_systolic_wr_cnt - (PE_SIZE - 1'b1)) begin
                            // A矩阵FIFO写入数据
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                systolic_a_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                                    {{(SYS_DATA_WIDTH-16){1'b0}}, ram_a_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*16) +: 16]};
                            end
                            // B矩阵FIFO写入数据
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                systolic_b_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                                    {{(SYS_DATA_WIDTH-16){1'b0}}, ram_b_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*16) +: 16]};
                            end
                        end else begin
                            systolic_a_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                            systolic_b_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                        end
                    end

                    DATA_WIDTH_FOUR_BYTE: begin
                        if (systolic_wr_cnt <= max_systolic_wr_cnt - (PE_SIZE - 1'b1)) begin
                            // A矩阵FIFO写入数据
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                systolic_a_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                                    {{(SYS_DATA_WIDTH-32){1'b0}}, ram_a_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*32) +: 32]};
                            end
                            // B矩阵FIFO写入数据
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                systolic_b_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                                    {{(SYS_DATA_WIDTH-32){1'b0}}, ram_b_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*32) +: 32]};
                            end
                        end else begin
                            systolic_a_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                            systolic_b_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                        end
                    end

                    default: begin
                        if (systolic_wr_cnt <= max_systolic_wr_cnt - (PE_SIZE - 1'b1)) begin
                            // A矩阵FIFO写入数据
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                systolic_a_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                                    {{(SYS_DATA_WIDTH-8){1'b0}}, ram_a_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*8) +: 8]};
                            end
                            // B矩阵FIFO写入数据
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                systolic_b_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                                    {{(SYS_DATA_WIDTH-8){1'b0}}, ram_b_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*8) +: 8]};
                            end
                        end else begin
                            systolic_a_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                            systolic_b_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                        end
                    end
                endcase
            end else begin
                case (data_width_ab)
                    DATA_WIDTH_HALF_BYTE: begin
                        if (systolic_wr_cnt <= max_systolic_wr_cnt - (PE_SIZE - 1'b1)) begin
                            // A矩阵FIFO写入数据
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                systolic_a_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                                    {{(SYS_DATA_WIDTH-8){1'b0}}, ram_a_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*8) +: 8]};
                            end
                            // B矩阵FIFO写入数据
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                systolic_b_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                                    {{(SYS_DATA_WIDTH-8){1'b0}}, ram_b_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*8) +: 8]};
                            end
                        end else begin
                            systolic_a_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                            systolic_b_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                        end
                    end

                    DATA_WIDTH_ONE_BYTE: begin
                        if (systolic_wr_cnt <= max_systolic_wr_cnt - (PE_SIZE - 1'b1)) begin
                            // A矩阵FIFO写入数据
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                if (a_meta_data_indices_sel[i]) begin
                                    systolic_a_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                                        {{(SYS_DATA_WIDTH-8){1'b0}}, ram_a_rd_data[(i*RAM_DATA_WIDTH + sparse_index[i+block_m_sparse_cnt*PE_SIZE][2:0]*8) +: 8]};
                                end else begin
                                    systolic_a_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = {(SYS_DATA_WIDTH){1'b0}};
                                end
                            end
                        end else begin
                            systolic_a_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                        end

                        if (systolic_wr_cnt <= max_systolic_wr_cnt - (PE_SIZE - 1'b1)) begin
                            // B矩阵FIFO写入数据
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                systolic_b_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                                    {{(SYS_DATA_WIDTH-8){1'b0}}, ram_b_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*8) +: 8]};
                            end
                        end else begin
                            systolic_b_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                        end
                    end

                    // DATA_WIDTH_ONE_BYTE: begin
                    //     if (systolic_wr_cnt <= max_systolic_wr_cnt - (PE_SIZE - 1'b1)) begin
                    //         // A矩阵FIFO写入数据
                    //         for (i = 0; i < PE_SIZE; i = i + 1) begin
                    //             systolic_a_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                    //                 {{(SYS_DATA_WIDTH-8){1'b0}}, ram_a_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*8) +: 8]};
                    //         end
                    //         // B矩阵FIFO写入数据
                    //         for (i = 0; i < PE_SIZE; i = i + 1) begin
                    //             systolic_b_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                    //                 {{(SYS_DATA_WIDTH-8){1'b0}}, ram_b_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*8) +: 8]};
                    //         end
                    //     end else begin
                    //         systolic_a_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                    //         systolic_b_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                    //     end
                    // end

                    DATA_WIDTH_TWO_BYTE: begin
                        if (systolic_wr_cnt <= max_systolic_wr_cnt - (PE_SIZE - 1'b1)) begin
                            // A矩阵FIFO写入数据
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                if (a_meta_data_indices_sel[i]) begin
                                    systolic_a_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                                        {{(SYS_DATA_WIDTH-8){1'b0}}, ram_a_rd_data[(i*RAM_DATA_WIDTH + sparse_index[i+block_m_sparse_cnt*PE_SIZE][1:0]*16) +: 16]};
                                end else begin
                                    systolic_a_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = {(SYS_DATA_WIDTH){1'b0}};
                                end
                            end
                        end else begin
                            systolic_a_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                        end

                        if (systolic_wr_cnt <= max_systolic_wr_cnt - (PE_SIZE - 1'b1)) begin
                            // B矩阵FIFO写入数据
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                systolic_b_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                                    {{(SYS_DATA_WIDTH-16){1'b0}}, ram_b_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*16) +: 16]};
                            end
                        end else begin
                            systolic_b_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                        end
                    end

                    // DATA_WIDTH_TWO_BYTE: begin
                    //     if (systolic_wr_cnt <= max_systolic_wr_cnt - (PE_SIZE - 1'b1)) begin
                    //         // A矩阵FIFO写入数据
                    //         for (i = 0; i < PE_SIZE; i = i + 1) begin
                    //             systolic_a_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                    //                 {{(SYS_DATA_WIDTH-16){1'b0}}, ram_a_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*16) +: 16]};
                    //         end
                    //         // B矩阵FIFO写入数据
                    //         for (i = 0; i < PE_SIZE; i = i + 1) begin
                    //             systolic_b_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                    //                 {{(SYS_DATA_WIDTH-16){1'b0}}, ram_b_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*16) +: 16]};
                    //         end
                    //     end else begin
                    //         systolic_a_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                    //         systolic_b_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                    //     end
                    // end

                    DATA_WIDTH_FOUR_BYTE: begin
                        if (systolic_wr_cnt <= max_systolic_wr_cnt - (PE_SIZE - 1'b1)) begin
                            // A矩阵FIFO写入数据
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                if (a_meta_data_indices_sel[i]) begin
                                    systolic_a_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                                        {{(SYS_DATA_WIDTH-32){1'b0}}, ram_a_rd_data[(i*RAM_DATA_WIDTH + sparse_index[i+block_m_sparse_cnt*PE_SIZE][2]*32) +: 32]};
                                end else begin
                                    systolic_a_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = {(SYS_DATA_WIDTH){1'b0}};
                                end
                            end
                        end else begin
                            systolic_a_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                        end

                        if (systolic_wr_cnt <= max_systolic_wr_cnt - (PE_SIZE - 1'b1)) begin
                            // B矩阵FIFO写入数据
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                systolic_b_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                                    {{(SYS_DATA_WIDTH-32){1'b0}}, ram_b_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt[2]*32) +: 32]};
                            end
                        end else begin
                            systolic_b_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                        end
                    end

                    // DATA_WIDTH_FOUR_BYTE: begin
                    //     if (systolic_wr_cnt <= max_systolic_wr_cnt - (PE_SIZE - 1'b1)) begin
                    //         // A矩阵FIFO写入数据
                    //         for (i = 0; i < PE_SIZE; i = i + 1) begin
                    //             systolic_a_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                    //                 {{(SYS_DATA_WIDTH-32){1'b0}}, ram_a_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt[2]*32) +: 32]};
                    //         end
                    //         // B矩阵FIFO写入数据
                    //         for (i = 0; i < PE_SIZE; i = i + 1) begin
                    //             systolic_b_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                    //                 {{(SYS_DATA_WIDTH-32){1'b0}}, ram_b_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt[2]*32) +: 32]};
                    //         end
                    //     end else begin
                    //         systolic_a_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                    //         systolic_b_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                    //     end
                    // end

                    default: begin
                        if (systolic_wr_cnt <= max_systolic_wr_cnt - (PE_SIZE - 1'b1)) begin
                            // A矩阵FIFO写入数据
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                if (a_meta_data_indices_sel[i]) begin
                                    systolic_a_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                                        {{(SYS_DATA_WIDTH-8){1'b0}}, ram_a_rd_data[(i*RAM_DATA_WIDTH + sparse_index[i+block_m_sparse_cnt*PE_SIZE][2:0]*8) +: 8]};
                                end else begin
                                    systolic_a_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = {(SYS_DATA_WIDTH){1'b0}};
                                end
                            end
                        end else begin
                            systolic_a_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                        end

                        if (systolic_wr_cnt <= max_systolic_wr_cnt - (PE_SIZE - 1'b1)) begin
                            // B矩阵FIFO写入数据
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                systolic_b_wr_data[(i*SYS_DATA_WIDTH) +: SYS_DATA_WIDTH] = 
                                    {{(SYS_DATA_WIDTH-8){1'b0}}, ram_b_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*8) +: 8]};
                            end
                        end else begin
                            systolic_b_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
                        end
                    end
                endcase
            end
            
        end else begin
            systolic_a_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
            systolic_b_wr_data = {(SYS_DATA_WIDTH*PE_SIZE){1'b0}};
        end
    end

endmodule
