module data_flow_load_c #(
    parameter PE_SIZE              = 8 ,   // PE数量/阵列大小
    parameter MATRIX_DIM_WIDTH     = 8 ,   // 矩阵维度宽度
    parameter PRECISION_MODE_WIDTH = 4 ,   // 精度模式宽度
    parameter RAM_ADDR_WIDTH       = 12,   // RAM地址宽度
    parameter RAM_DATA_WIDTH       = 32,   // RAM数据宽度
    parameter FIFO_DATA_WIDTH      = 32    // FIFO数据宽度，通常与RAM_DATA_WIDTH相同
) (
    // 时钟和复位
    input  wire                               clk               ,
    input  wire                               rst_n             ,
    
    // CSR 寄存器配置
    input  wire [       MATRIX_DIM_WIDTH-1:0] matrix_m          ,
    input  wire [       MATRIX_DIM_WIDTH-1:0] matrix_n          ,
    input  wire [   PRECISION_MODE_WIDTH-1:0] precision_mode    ,
    
    // 控制信号
    input  wire                               ram_c_read_ready  , // C矩阵RAM准备好信号
    input  wire                               ram_d_write_ready ,
    output reg                                rctf_busy         , // 忙状态指示
    output reg                                rctf_done         , // 传输完成指示

    input  wire                               compute_done      ,
    
    // C矩阵RAM读接口
    output reg  [               PE_SIZE-1:0]  ram_c_rd_en       ,
    output reg  [RAM_ADDR_WIDTH*PE_SIZE-1:0]  ram_c_rd_addr     ,
    input  wire [RAM_DATA_WIDTH*PE_SIZE-1:0]  ram_c_rd_data     ,
    
    // C矩阵FIFO写接口
    output reg  [                PE_SIZE-1:0] fifo_c_wr_en      ,
    output reg  [FIFO_DATA_WIDTH*PE_SIZE-1:0] fifo_c_wr_data    ,
    input  wire [                PE_SIZE-1:0] fifo_c_full       , // FIFO满信号
    input  wire [                PE_SIZE-1:0] fifo_c_almost_full  // FIFO接近满信号
);

    // 精度模式定义
    localparam PM_INT8_ALL    = 4'd1; // ABC 矩阵均为 INT8
    localparam PM_INT8_INT32  = 4'd3; // AB 为 INT8，C 为 INT32

    // 数据宽度类型定义
    localparam DATA_WIDTH_HALF_BYTE = 2'd0;
    localparam DATA_WIDTH_ONE_BYTE  = 2'd1;
    localparam DATA_WIDTH_TWO_BYTE  = 2'd2;
    localparam DATA_WIDTH_FOUR_BYTE = 2'd3;
    
    // 计算PE_SIZE的对数
    localparam LOG2_PE_SIZE = $clog2(PE_SIZE);
    
    // 状态定义
    localparam IDLE       = 3'd0; // 空闲状态
    localparam PREPARE    = 3'd1; // 准备状态
    localparam BUSY       = 3'd2; // 工作状态
    localparam WAIT_FIFO  = 3'd3; // 等待FIFO状态
    localparam WAIT       = 3'd4; // 等待状态
    localparam DONE       = 3'd5; // 完成状态

    // 模块状态
    reg [2:0]  state;

    wire ram_data_ready;

    // 计数器
    reg [5:0] sub_elem_cnt;  // 子元素计数器
    reg [5:0] elem_n_cnt;    // 列计数器
    reg [5:0] block_m_cnt;   // 块计数器

    reg [5:0] prepare_cnt; // 准备状态计数器
    
    // 计数器上限
    reg [5:0] max_sub_elem;  // 每RAM字的最大子元素索引
    reg [5:0] max_elem_n;    // 每次迭代的最大列索引
    reg [5:0] max_block_m;   // 最大块索引
    reg [5:0] row_groups_m;

    reg [15:0] fifo_wr_cnt;     // FIFO写入计数器
    reg [15:0] max_fifo_wr_cnt; // FIFO写入计数器上限

    reg [3:0] log2_n_div_epw;
    
    wire fifo_ready;
    reg  pending_data;

    integer i;

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

    // 根据precision_mode解析为C矩阵内部数据类型
    reg [1:0] data_width_c;
    
    always @(*) begin
        case (precision_mode)
            PM_INT8_ALL:
                data_width_c = DATA_WIDTH_ONE_BYTE;
            PM_INT8_INT32:
                data_width_c = DATA_WIDTH_FOUR_BYTE;
            default:
                data_width_c = DATA_WIDTH_ONE_BYTE; // 默认使用INT8
        endcase
    end

    assign ram_data_ready = ram_c_read_ready;
    assign fifo_ready = (!(|fifo_c_almost_full)); // FIFO可用信号

    // 矩阵维度和计数器上限计算 - 使用时序逻辑
    always @(*) begin
        if (matrix_m == 0) begin
            row_groups_m = 6'd0;
        end else begin
            // Match the load side row-group definition so partial M tiles
            // (especially m=1) keep one active group instead of wrapping.
            row_groups_m = (matrix_m + PE_SIZE - 1) >> LOG2_PE_SIZE;
        end
        max_block_m = (row_groups_m == 0) ? 6'd0 : (row_groups_m - 6'd1);
        max_fifo_wr_cnt = (row_groups_m == 0)
            ? 16'd0
            : (({8'd0, matrix_n} * {10'd0, row_groups_m}) - 16'd1);
        
        // 根据数据类型设置参数
        case (data_width_c)
            DATA_WIDTH_HALF_BYTE: begin
                max_sub_elem   = 5'd15;  // 8个元素每个RAM字，索引0-7
                max_elem_n     = (matrix_n >> 4) - 8'd1;  // k/8-1
                log2_n_div_epw = get_log2(matrix_n) > 4 ? get_log2(matrix_n) - 4 : 0;
            end
            
            DATA_WIDTH_ONE_BYTE: begin
                max_sub_elem   = 5'd7;  // 4个元素每个RAM字，索引0-3
                max_elem_n     = (matrix_n >> 3) - 8'd1;  // k/8-1
                log2_n_div_epw = get_log2(matrix_n) > 3 ? get_log2(matrix_n) - 3 : 0;
            end
            
            DATA_WIDTH_TWO_BYTE: begin
                max_sub_elem   = 5'd3;  // 2个元素每个RAM字，索引0-1
                max_elem_n     = (matrix_n >> 2) - 8'd1;  // k/8-1
                log2_n_div_epw = get_log2(matrix_n) > 2 ? get_log2(matrix_n) - 2 : 0;
            end
            
            DATA_WIDTH_FOUR_BYTE: begin
                max_sub_elem   = 5'd1;  // 1个元素每个RAM字，索引0
                max_elem_n     = (matrix_n >> 1) - 8'd1;  // k/8-1
                log2_n_div_epw = get_log2(matrix_n) > 1 ? get_log2(matrix_n) - 1 : 0;
            end
        endcase
    end

    // 状态机
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            rctf_busy    <= 1'b0;
            rctf_done    <= 1'b0;
            sub_elem_cnt <= 5'd0;
            elem_n_cnt   <= 8'd0;
            block_m_cnt  <= 8'd0;
            fifo_wr_cnt  <= 16'd0;
            prepare_cnt  <= 5'd0;
        end else begin
            case (state)
                IDLE: begin
                    if (ram_data_ready && ram_d_write_ready && ~(|fifo_c_almost_full)) begin
                        state     <= PREPARE;
                        rctf_busy <= 1'b1;
                        rctf_done <= 1'b0;
                    end else begin
                        state     <= IDLE;
                        rctf_busy <= 1'b0;
                        rctf_done <= 1'b0;
                    end
                end

                PREPARE:begin
                    sub_elem_cnt <= max_sub_elem - 5'd1;
                    prepare_cnt <= prepare_cnt + 1'b1;
                    if (prepare_cnt == 5'd2) begin
                        prepare_cnt <= 5'd0;
                        state <= BUSY;
                    end else begin
                        state <= PREPARE;
                    end
                end
                
                BUSY: begin
                    if (fifo_ready) begin
                        // 循环计数逻辑
                        if (sub_elem_cnt == max_sub_elem) begin
                            sub_elem_cnt <= 5'd0;
                            
                            if (elem_n_cnt == max_elem_n) begin
                                elem_n_cnt <= 8'd0;

                                if (block_m_cnt == max_block_m) begin
                                    block_m_cnt <= 8'd0;

                                end else begin
                                    block_m_cnt <= block_m_cnt + 8'd1;
                                end
                            end else begin
                                elem_n_cnt <= elem_n_cnt + 8'd1;
                            end
                        end else begin
                            sub_elem_cnt <= sub_elem_cnt + 5'd1;
                        end
                    end
                    
                    // FIFO写入计数
                    if (|fifo_c_wr_en) begin
                        fifo_wr_cnt <= fifo_wr_cnt + 16'd1;
                        if (fifo_wr_cnt == max_fifo_wr_cnt) begin
                            fifo_wr_cnt <= 16'd0;
                        end
                    end

                    if (fifo_wr_cnt == max_fifo_wr_cnt) begin
                        state <= WAIT;
                    end else if (!fifo_ready) begin
                        state <= WAIT_FIFO;
                    end else begin
                        state <= BUSY;
                    end
                end

                WAIT_FIFO: begin
                    if (fifo_ready) begin
                        state <= BUSY;
                    end else begin
                        state <= WAIT_FIFO;
                    end
                end

                WAIT: begin
                    if (compute_done) begin
                        rctf_done <= 1'b1;
                        state <= DONE;
                    end else begin
                        state <= WAIT;
                    end
                end
                
                DONE: begin
                    state        <= IDLE;
                    rctf_busy    <= 1'b0;
                    rctf_done    <= 1'b0;
                    sub_elem_cnt <= 5'd0;
                    elem_n_cnt      <= 8'd0;
                    block_m_cnt      <= 8'd0;
                    fifo_wr_cnt  <= 16'd0;
                end
                
                default: state <= IDLE;
            endcase
        end
    end

    // RAM读取逻辑
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ram_c_rd_en   <= {PE_SIZE{1'b0}};
            ram_c_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
        end else begin
            if (state == BUSY && fifo_ready) begin
                case (data_width_c)
                    DATA_WIDTH_HALF_BYTE: begin
                        if ((sub_elem_cnt == max_sub_elem - 1'b1) && (fifo_wr_cnt < max_fifo_wr_cnt - 16'd1)) begin
                            // C矩阵RAM阵列读取
                            ram_c_rd_en <= {PE_SIZE{1'b1}};
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                ram_c_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                                    (block_m_cnt << log2_n_div_epw) + elem_n_cnt;
                            end
                        end else begin
                            ram_c_rd_en   <= {PE_SIZE{1'b0}};
                            ram_c_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                        end
                    end

                    DATA_WIDTH_ONE_BYTE: begin
                        if ((sub_elem_cnt == max_sub_elem - 1'b1) && (fifo_wr_cnt < max_fifo_wr_cnt - 16'd1)) begin
                            // C矩阵RAM阵列读取
                            ram_c_rd_en <= {PE_SIZE{1'b1}};
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                ram_c_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                                    (block_m_cnt << log2_n_div_epw) + elem_n_cnt;
                            end
                        end else begin
                            ram_c_rd_en   <= {PE_SIZE{1'b0}};
                            ram_c_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                        end
                    end

                    DATA_WIDTH_TWO_BYTE: begin
                        if ((sub_elem_cnt == max_sub_elem - 1'b1) && (fifo_wr_cnt < max_fifo_wr_cnt - 16'd1)) begin
                            // C矩阵RAM阵列读取
                            ram_c_rd_en <= {PE_SIZE{1'b1}};
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                ram_c_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                                    (block_m_cnt << log2_n_div_epw) + elem_n_cnt;
                            end
                        end else begin
                            ram_c_rd_en   <= {PE_SIZE{1'b0}};
                            ram_c_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                        end
                    end

                    DATA_WIDTH_FOUR_BYTE: begin
                        if ((sub_elem_cnt == max_sub_elem - 1'b1) && (fifo_wr_cnt < max_fifo_wr_cnt - 16'd1)) begin
                            // C矩阵RAM阵列读取
                            ram_c_rd_en <= {PE_SIZE{1'b1}};
                            for (i = 0; i < PE_SIZE; i = i + 1) begin
                                ram_c_rd_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] <= 
                                    (block_m_cnt << log2_n_div_epw) + elem_n_cnt;
                            end
                        end else begin
                            ram_c_rd_en   <= {PE_SIZE{1'b0}};
                            ram_c_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
                        end
                    end
                endcase
            end else begin
                ram_c_rd_en   <= {PE_SIZE{1'b0}};
                ram_c_rd_addr <= {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}};
            end
        end
    end

    // FIFO fifo_wr_en信号生成
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fifo_c_wr_en <= {PE_SIZE{1'b0}};
            pending_data <= 1'b0;
        end else begin
            if (state == BUSY && fifo_ready) begin
                if (|ram_c_rd_en) begin
                    fifo_c_wr_en <= {PE_SIZE{1'b1}};
                end else if (pending_data) begin
                    fifo_c_wr_en <= {PE_SIZE{1'b1}};
                    pending_data <= 1'b0;
                end else if (fifo_wr_cnt == max_fifo_wr_cnt) begin
                    fifo_c_wr_en <= {PE_SIZE{1'b0}};
                end
            end else if (state == WAIT_FIFO) begin
                fifo_c_wr_en <= {PE_SIZE{1'b0}};
                pending_data <= 1'b1;
            end else begin
                fifo_c_wr_en <= {PE_SIZE{1'b0}};
            end
        end
    end

    // FIFO写入数据
    always @(*) begin
        fifo_c_wr_data = {(FIFO_DATA_WIDTH*PE_SIZE){1'b0}};
        
        if (state == BUSY && |fifo_c_wr_en) begin
            case (data_width_c)
                DATA_WIDTH_HALF_BYTE: begin
                    if (fifo_wr_cnt <= max_fifo_wr_cnt) begin
                        // C矩阵FIFO写入数据
                        for (i = 0; i < PE_SIZE; i = i + 1) begin
                            fifo_c_wr_data[(i*FIFO_DATA_WIDTH) +: FIFO_DATA_WIDTH] = 
                                {{(FIFO_DATA_WIDTH-4){1'b0}}, ram_c_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*4) +: 4]};
                        end
                    end else begin
                        fifo_c_wr_data = {(FIFO_DATA_WIDTH*PE_SIZE){1'b0}};
                    end
                end

                DATA_WIDTH_ONE_BYTE: begin
                    if (fifo_wr_cnt <= max_fifo_wr_cnt) begin
                        // C矩阵FIFO写入数据
                        for (i = 0; i < PE_SIZE; i = i + 1) begin
                            fifo_c_wr_data[(i*FIFO_DATA_WIDTH) +: FIFO_DATA_WIDTH] = 
                                {{(FIFO_DATA_WIDTH-8){1'b0}}, ram_c_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*8) +: 8]};
                        end
                    end else begin
                        fifo_c_wr_data = {(FIFO_DATA_WIDTH*PE_SIZE){1'b0}};
                    end
                end

                DATA_WIDTH_TWO_BYTE: begin
                    if (fifo_wr_cnt <= max_fifo_wr_cnt) begin
                        // C矩阵FIFO写入数据
                        for (i = 0; i < PE_SIZE; i = i + 1) begin
                            fifo_c_wr_data[(i*FIFO_DATA_WIDTH) +: FIFO_DATA_WIDTH] = 
                                {{(FIFO_DATA_WIDTH-16){1'b0}}, ram_c_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*16) +: 16]};
                        end
                    end else begin
                        fifo_c_wr_data = {(FIFO_DATA_WIDTH*PE_SIZE){1'b0}};
                    end
                end

                DATA_WIDTH_FOUR_BYTE: begin
                    if (fifo_wr_cnt <= max_fifo_wr_cnt) begin
                        // C矩阵FIFO写入数据
                        for (i = 0; i < PE_SIZE; i = i + 1) begin
                            fifo_c_wr_data[(i*FIFO_DATA_WIDTH) +: FIFO_DATA_WIDTH] = 
                                {{(FIFO_DATA_WIDTH-32){1'b0}}, ram_c_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*32) +: 32]};
                        end
                    end else begin
                        fifo_c_wr_data = {(FIFO_DATA_WIDTH*PE_SIZE){1'b0}};
                    end
                end

                default: begin
                    if (fifo_wr_cnt <= max_fifo_wr_cnt) begin
                        // C矩阵FIFO写入数据
                        for (i = 0; i < PE_SIZE; i = i + 1) begin
                            fifo_c_wr_data[(i*FIFO_DATA_WIDTH) +: FIFO_DATA_WIDTH] = 
                                {{(FIFO_DATA_WIDTH-8){1'b0}}, ram_c_rd_data[(i*RAM_DATA_WIDTH + sub_elem_cnt*8) +: 8]};
                        end
                    end else begin
                        fifo_c_wr_data = {(FIFO_DATA_WIDTH*PE_SIZE){1'b0}};
                    end
                end
            endcase
        end else begin
            fifo_c_wr_data = {(FIFO_DATA_WIDTH*PE_SIZE){1'b0}};
        end
    end

endmodule
