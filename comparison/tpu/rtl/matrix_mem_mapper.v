module matrix_mem_mapper #(
    parameter PE_SIZE              = 8            ,
    parameter MATRIX_DIM_WIDTH     = 8            ,   // 矩阵维度宽度
    parameter PRECISION_MODE_WIDTH = 4            ,   // 精度模式宽度
    parameter AXI_DATA_WIDTH       = 128          ,
    parameter AXI_ADDR_WIDTH       = 32           ,
    parameter RAM_ADDR_WIDTH       = 8            ,
    parameter RAM_C_ADDR_WIDTH     = 4            ,
    parameter RAM_DATA_WIDTH       = 128          ,
    parameter MATRIX_A_BASE_ADDR   = 32'h0000_0000,
    parameter MATRIX_B_BASE_ADDR   = 32'h0000_4000,
    parameter MATRIX_C_BASE_ADDR   = 32'h0000_8000,
    parameter MATRIX_D_BASE_ADDR   = 32'h0000_C000 
) (
    // 时钟和复位
    input  wire                                  clk               ,
    input  wire                                  rst_n             ,
    
    // AXI RAM 写接口
    input  wire                                  ram_wr_en         ,
    input  wire [            AXI_ADDR_WIDTH-1:0] ram_wr_addr       ,
    input  wire [            AXI_DATA_WIDTH-1:0] ram_wr_data       ,
    input  wire [        (AXI_DATA_WIDTH/8)-1:0] ram_wr_strb       ,
    
    // CSR 寄存器配置
    input  wire [          MATRIX_DIM_WIDTH-1:0] matrix_m          ,
    input  wire [          MATRIX_DIM_WIDTH-1:0] matrix_n          ,
    input  wire [          MATRIX_DIM_WIDTH-1:0] matrix_k          ,
    input  wire [      PRECISION_MODE_WIDTH-1:0] precision_mode    ,
    input  wire                                  sparse_en         ,

    // RAM阵列A写入接口
    output reg  [                   PE_SIZE-1:0] ram_a_wr_en       ,
    output reg  [    RAM_ADDR_WIDTH*PE_SIZE-1:0] ram_a_wr_addr     ,
    output reg  [    RAM_DATA_WIDTH*PE_SIZE-1:0] ram_a_wr_data     ,
    output reg  [(RAM_DATA_WIDTH/8)*PE_SIZE-1:0] ram_a_wr_strb     ,

    output reg                                   a_index_wr_en     ,
    output reg  [            RAM_ADDR_WIDTH-1:0] a_index_wr_addr   ,
    output reg  [            RAM_DATA_WIDTH-1:0] a_index_wr_data   ,
    
    // RAM阵列B写入接口
    output reg  [                   PE_SIZE-1:0] ram_b_wr_en       ,
    output reg  [    RAM_ADDR_WIDTH*PE_SIZE-1:0] ram_b_wr_addr     ,
    output reg  [    RAM_DATA_WIDTH*PE_SIZE-1:0] ram_b_wr_data     ,
    output reg  [(RAM_DATA_WIDTH/8)*PE_SIZE-1:0] ram_b_wr_strb     ,

    // RAM阵列C写入接口
    output reg  [                   PE_SIZE-1:0] ram_c_wr_en       ,
    output reg  [  RAM_C_ADDR_WIDTH*PE_SIZE-1:0] ram_c_wr_addr     ,
    output reg  [    RAM_DATA_WIDTH*PE_SIZE-1:0] ram_c_wr_data     ,
    output reg  [(RAM_DATA_WIDTH/8)*PE_SIZE-1:0] ram_c_wr_strb     ,

    // 矩阵写入完成信号
    output reg                                   ram_a_wr_done     ,  // A矩阵写入完成信号
    output reg                                   ram_b_wr_done     ,  // B矩阵写入完成信号  
    output reg                                   ram_c_wr_done     ,  // C矩阵写入完成信号

    // 调试导出: mapper内部一拍后的矩阵写入活动
    output wire                                  mapper_a_active   ,
    output wire                                  mapper_b_active   ,
    output wire                                  mapper_c_active
);

    localparam LOG2_PE_SIZE         = $clog2(PE_SIZE);
    localparam REL_RAM_ADDR_WIDTH   = RAM_ADDR_WIDTH + $clog2(PE_SIZE);
    localparam REL_RAM_C_ADDR_WIDTH = RAM_C_ADDR_WIDTH + $clog2(PE_SIZE);
    localparam AXI_BYTES            = AXI_DATA_WIDTH / 8;
    localparam RAM_BYTES            = RAM_DATA_WIDTH / 8;
    localparam LOG2_AXI_BYTES       = $clog2(AXI_BYTES);
    localparam LOG2_RAM_BYTES       = $clog2(RAM_BYTES);
    localparam AXI_INT32S_PER_WORD  = AXI_DATA_WIDTH / 32;
    localparam LOG2_AXI_INT32S_PER_WORD = $clog2(AXI_INT32S_PER_WORD);
    localparam B_REPLAY_QUEUE_DEPTH = 256;
    localparam B_REPLAY_PTR_WIDTH   = $clog2(B_REPLAY_QUEUE_DEPTH);
    localparam B_DIRECT_BYTE_COUNT  = (AXI_BYTES > PE_SIZE) ? PE_SIZE : AXI_BYTES;

    // 精度模式定义
    localparam PM_INT8_ALL    = 4'd1; // ABC 矩阵均为 INT8
    localparam PM_INT8_INT32  = 4'd3; // AB 为 INT8，C 为 INT32

    // 数据宽度类型定义
    localparam DATA_WIDTH_HALF_BYTE = 2'd0;
    localparam DATA_WIDTH_ONE_BYTE  = 2'd1;
    localparam DATA_WIDTH_TWO_BYTE  = 2'd2;
    localparam DATA_WIDTH_FOUR_BYTE = 2'd3;

    // 计算每种数据类型每个AXI字包含的元素数
    localparam HALF_BYTE_PER_WORD  = 5'd16;
    localparam ONE_BYTE_PER_WORD   = 5'd8;
    localparam TWO_BYTE_PER_WORD   = 5'd4;
    localparam FOUR_BYTE_PER_WORD  = 5'd2;

    localparam ADDR_BYTE_SHIFT = LOG2_AXI_BYTES;

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

    function has_b_replay_upper_bytes;
        input [(AXI_DATA_WIDTH/8)-1:0] strb;
        integer idx;
        begin
            has_b_replay_upper_bytes = 1'b0;
            for (idx = PE_SIZE; idx < AXI_BYTES; idx = idx + 1) begin
                if (strb[idx]) begin
                    has_b_replay_upper_bytes = 1'b1;
                end
            end
        end
    endfunction

    reg [16-1:0] matrix_a_index_base_addr;
    
    // 根据地址范围判断现在是哪个矩阵的写入
    wire is_matrix_a = (ram_wr_addr >= MATRIX_A_BASE_ADDR && ram_wr_addr < MATRIX_B_BASE_ADDR);
    wire is_matrix_b = (ram_wr_addr >= MATRIX_B_BASE_ADDR && ram_wr_addr < MATRIX_C_BASE_ADDR);
    wire is_matrix_c = (ram_wr_addr >= MATRIX_C_BASE_ADDR && ram_wr_addr < MATRIX_D_BASE_ADDR);
    wire is_matrix_a_index = (sparse_en && is_matrix_a && (ram_wr_addr >= (matrix_a_index_base_addr << ADDR_BYTE_SHIFT)));
    
    // 将AXI字节地址转换为相对字地址
    wire [REL_RAM_ADDR_WIDTH-1:0] rel_word_addr_a = is_matrix_a ? (ram_wr_addr - MATRIX_A_BASE_ADDR) >> ADDR_BYTE_SHIFT : 0;
    wire [REL_RAM_ADDR_WIDTH-1:0] rel_word_addr_b = is_matrix_b ? (ram_wr_addr - MATRIX_B_BASE_ADDR) >> ADDR_BYTE_SHIFT : 0;
    wire [REL_RAM_C_ADDR_WIDTH-1:0] rel_word_addr_c = is_matrix_c ? (ram_wr_addr - MATRIX_C_BASE_ADDR) >> ADDR_BYTE_SHIFT : 0;

    // 数据路径寄存
    reg                              ram_wr_en_r       ;
    reg [AXI_DATA_WIDTH-1:0]         ram_wr_data_r     ;
    reg [(AXI_DATA_WIDTH/8)-1:0]     ram_wr_strb_r     ;
    reg [REL_RAM_ADDR_WIDTH-1:0]     rel_word_addr_a_r ;
    reg [REL_RAM_ADDR_WIDTH-1:0]     rel_word_addr_b_r ;
    reg [REL_RAM_C_ADDR_WIDTH-1:0]   rel_word_addr_c_r ;
    reg                              is_matrix_a_r     ;
    reg                              is_matrix_b_r     ;
    reg                              is_matrix_c_r     ;
    reg                              is_matrix_a_index_r;
    reg                              b_replay_needed_r ;

    assign mapper_a_active = is_matrix_a_r && ram_wr_en_r;
    assign mapper_b_active = is_matrix_b_r && ram_wr_en_r;
    assign mapper_c_active = is_matrix_c_r && ram_wr_en_r;

    // 计算矩阵维度的对数值
    wire [3:0] log2_matrix_m = get_log2(matrix_m);
    wire [3:0] log2_matrix_n = get_log2(matrix_n);
    wire [3:0] log2_matrix_k = get_log2(matrix_k);
    // wire [3:0] log2_matrix_k = get_log2(sparse_en ? (matrix_k >> 1) : matrix_k);
    
    reg [3:0] log2_k_div_epw_a;
    reg [3:0] log2_n_div_epw_b;
    reg [3:0] log2_n_div_epw_c;

    // A矩阵索引计算
    wire [7:0] a_axi_row_idx = rel_word_addr_a_r >> log2_k_div_epw_a           ; // 行号：AXI地址 / (k/elems_per_word)
    wire [7:0] a_axi_col_idx = rel_word_addr_a_r & ((1 << log2_k_div_epw_a) - 1); // 列偏移：AXI地址 % (k/elems_per_word)
    
    // B矩阵索引计算
    wire [7:0] b_axi_row_idx = rel_word_addr_b_r >> log2_n_div_epw_b           ; // 行号：AXI地址 / (n/elems_per_word)
    wire [7:0] b_axi_col_idx = rel_word_addr_b_r & ((1 << log2_n_div_epw_b) - 1); // 列偏移：AXI地址 % (n/elems_per_word)
    
    // C矩阵索引计算
    wire [7:0] c_axi_row_idx = rel_word_addr_c_r >> log2_n_div_epw_c           ; // 行号：AXI地址 / (n/elems_per_word)
    wire [7:0] c_axi_col_idx = rel_word_addr_c_r & ((1 << log2_n_div_epw_c) - 1); // 列偏移：AXI地址 % (n/elems_per_word)
    
    // 检测矩阵的最大行列索引
    wire a_last_row = (a_axi_row_idx == matrix_m - 1);
    wire a_last_col = (a_axi_col_idx == (1 << log2_k_div_epw_a) - 1);
    wire a_last_data = is_matrix_a_r && ram_wr_en_r && a_last_row && a_last_col;

    // wire b_last_row = (b_axi_row_idx == (sparse_en ? (matrix_k >> 1) : (matrix_k - 1)));
    wire b_last_row = (b_axi_row_idx == matrix_k - 1);
    wire b_last_col = (b_axi_col_idx == (1 << log2_n_div_epw_b) - 1);
    wire b_last_data = is_matrix_b_r && ram_wr_en_r && b_last_row && b_last_col;

    wire c_last_row = (c_axi_row_idx == matrix_m - 1);
    wire c_last_col = (c_axi_col_idx == (1 << log2_n_div_epw_c) - 1);
    wire c_last_data = is_matrix_c_r && ram_wr_en_r && c_last_row && c_last_col;

    // 根据precision_mode确定不同矩阵的数据类型
    reg [2:0] data_width_a;
    reg [2:0] data_width_b;
    reg [2:0] data_width_c;

    wire [7:0] b_axi_row_idx_temp = rel_word_addr_b >> log2_n_div_epw_b           ;
    wire [7:0] b_axi_col_idx_temp = rel_word_addr_b & ((1 << log2_n_div_epw_b) - 1);
    
    reg  [63:0] b_buffer1 [0:7]; // 用于存储B矩阵的AXI数据缓冲
    reg  [63:0] b_buffer2 [0:7]; // 用于存储B矩阵的AXI数据缓冲

    reg       ram_b_wr_done_temp;
    reg       ram_b_wr_done_temp2;
    reg       ram_b_wr_done_temp3;
    reg       ram_b_wr_done_temp4;
    reg [2:0] ram_b_wr_done_cnt;

    reg [PE_SIZE-1:0]              b_wr_en_i_temp                  ;
    reg [RAM_ADDR_WIDTH-1:0]       b_wr_addr_i_temp [0:PE_SIZE-1]  ;
    reg [RAM_DATA_WIDTH-1:0]       b_wr_data_i_temp [0:PE_SIZE-1]  ;
    reg [(RAM_DATA_WIDTH/8)-1:0]   b_wr_strb_i_temp [0:PE_SIZE-1]  ; // 写选通
    reg [REL_RAM_ADDR_WIDTH-1:0]   b_replay_rel_word_addr_q [0:B_REPLAY_QUEUE_DEPTH-1];
    reg [AXI_DATA_WIDTH-1:0]       b_replay_data_q          [0:B_REPLAY_QUEUE_DEPTH-1];
    reg [(AXI_DATA_WIDTH/8)-1:0]   b_replay_strb_q          [0:B_REPLAY_QUEUE_DEPTH-1];
    reg [B_REPLAY_PTR_WIDTH:0]     b_replay_wr_ptr_r;
    reg [B_REPLAY_PTR_WIDTH:0]     b_replay_rd_ptr_r;
    reg                            b_replay_done_pulse_r;
    wire [B_REPLAY_PTR_WIDTH:0]    b_replay_count = b_replay_wr_ptr_r - b_replay_rd_ptr_r;
    wire                           b_replay_empty = (b_replay_count == {B_REPLAY_PTR_WIDTH+1{1'b0}});
    wire                           b_replay_full  = (b_replay_count == B_REPLAY_QUEUE_DEPTH);
    wire [B_REPLAY_PTR_WIDTH-1:0]  b_replay_wr_idx = b_replay_wr_ptr_r[B_REPLAY_PTR_WIDTH-1:0];
    wire [B_REPLAY_PTR_WIDTH-1:0]  b_replay_rd_idx = b_replay_rd_ptr_r[B_REPLAY_PTR_WIDTH-1:0];
    wire [REL_RAM_ADDR_WIDTH-1:0]  b_replay_rel_word_addr = b_replay_rel_word_addr_q[b_replay_rd_idx];
    wire [AXI_DATA_WIDTH-1:0]      b_replay_data = b_replay_data_q[b_replay_rd_idx];
    wire [(AXI_DATA_WIDTH/8)-1:0]  b_replay_strb = b_replay_strb_q[b_replay_rd_idx];
    wire [7:0]                     b_replay_axi_row_idx =
        b_replay_rel_word_addr >> log2_n_div_epw_b;
    wire [7:0]                     b_replay_axi_col_idx =
        b_replay_rel_word_addr & ((1 << log2_n_div_epw_b) - 1);
    wire                           b_replay_head_is_last =
        (b_replay_axi_row_idx == matrix_k - 1) &&
        (b_replay_axi_col_idx == ((1 << log2_n_div_epw_b) - 1));
    wire                           b_current_b_write = is_matrix_b_r && ram_wr_en_r;
    wire                           b_replay_issue = !b_current_b_write && !b_replay_empty;

    // 生成完成信号
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ram_a_wr_done <= 1'b0;
            ram_b_wr_done_temp <= 1'b0;
            ram_c_wr_done <= 1'b0;
            ram_b_wr_done <= 1'b0;
            ram_b_wr_done_temp2 <= 1'b0;
            ram_b_wr_done_temp3 <= 1'b0;
            ram_b_wr_done_temp4 <= 1'b0;
        end else begin
            ram_a_wr_done <= a_last_data;
            ram_b_wr_done <= 1'b0;
            ram_b_wr_done_temp4 <= ram_b_wr_done_temp3;
            ram_b_wr_done_temp3 <= ram_b_wr_done_temp2;
            ram_b_wr_done_temp2 <= ram_b_wr_done_temp;
            if (matrix_n == 8 && data_width_b == DATA_WIDTH_HALF_BYTE) begin
                // 特殊处理8列矩阵的完成信号
                if (is_matrix_b_r && ram_wr_en_r && b_last_col) begin
                    // 当B矩阵的行写入完成时，设置完成信号
                    if (b_axi_row_idx == 7) begin
                        ram_b_wr_done_temp <= 1'b1;
                    end else begin
                        ram_b_wr_done_temp <= 1'b0;
                    end
                end else begin
                    ram_b_wr_done_temp <= 1'b0;
                end
            end else if ((matrix_n == 16 || matrix_n == 32) && data_width_b == DATA_WIDTH_HALF_BYTE) begin
                ram_b_wr_done <= ram_b_wr_done_temp4;
                ram_b_wr_done_temp <= b_last_data;
            end else begin
                ram_b_wr_done <= b_replay_done_pulse_r || (b_last_data && !b_replay_needed_r);
                ram_b_wr_done_temp <= 1'b0;
            end

            if (matrix_n == 8 && data_width_c == DATA_WIDTH_HALF_BYTE) begin
                // 特殊处理8列矩阵的完成信号
                if (is_matrix_c_r && ram_wr_en_r && c_last_col) begin
                    // 当C矩阵的行写入完成时，设置完成信号
                    if (c_axi_row_idx == 15) begin
                        ram_c_wr_done <= 1'b1;
                    end else begin
                        ram_c_wr_done <= 1'b0;
                    end
                end else begin
                    ram_c_wr_done <= 1'b0;
                end
            end else begin
                ram_c_wr_done <= c_last_data;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_replay_wr_ptr_r <= {B_REPLAY_PTR_WIDTH+1{1'b0}};
            b_replay_rd_ptr_r <= {B_REPLAY_PTR_WIDTH+1{1'b0}};
            b_replay_done_pulse_r <= 1'b0;
        end else begin
            b_replay_done_pulse_r <= 1'b0;

            if (ram_wr_en_r && is_matrix_b_r && b_replay_needed_r && !b_replay_full) begin
                b_replay_rel_word_addr_q[b_replay_wr_idx] <= rel_word_addr_b_r;
                b_replay_data_q[b_replay_wr_idx] <= ram_wr_data_r;
                b_replay_strb_q[b_replay_wr_idx] <= ram_wr_strb_r;
                b_replay_wr_ptr_r <= b_replay_wr_ptr_r + 1'b1;
            end

            if (b_replay_issue) begin
                b_replay_rd_ptr_r <= b_replay_rd_ptr_r + 1'b1;
                if (b_replay_head_is_last) begin
                    b_replay_done_pulse_r <= 1'b1;
                end
            end
        end
    end
    
    integer m;
    reg flag_temp, flag_temp1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ram_b_wr_done_cnt <= 3'b0;
            flag_temp <= 1'b0;
            flag_temp1 <= 1'b0;
            for (m = 0; m < PE_SIZE; m = m + 1) begin
                b_wr_en_i_temp[m]   <= 1'b0;
                b_wr_addr_i_temp[m] <= 0;
                b_wr_data_i_temp[m] <= 0;
                b_wr_strb_i_temp[m] <= 0;
            end
        end else begin
            if (is_matrix_b_r && data_width_b == DATA_WIDTH_HALF_BYTE && ram_b_wr_done_temp) begin
                flag_temp <= 1'b1;
            end
            if (is_matrix_b_r && ram_wr_en_r && data_width_b == DATA_WIDTH_HALF_BYTE) begin
                flag_temp1 <= 1'b1;
            end
            if (flag_temp) begin
                // if (flag_temp) begin
                    if (ram_b_wr_done_cnt == 0) begin
                        for (m = 0; m < PE_SIZE; m = m + 1) begin
                            b_wr_en_i_temp[m]   <= 1'b1;
                            b_wr_addr_i_temp[m] <= 1;
                            b_wr_data_i_temp[m] <= b_buffer1[m];  
                            b_wr_strb_i_temp[m] <= 8'b11111111;
                        end
                        ram_b_wr_done_cnt <= 3'b1;
                    end else if (ram_b_wr_done_cnt == 1) begin
                        for (m = 0; m < PE_SIZE; m = m + 1) begin
                            b_wr_en_i_temp[m]   <= 1'b1;
                            b_wr_addr_i_temp[m] <= 3;
                            b_wr_data_i_temp[m] <= b_buffer2[m];  
                            b_wr_strb_i_temp[m] <= 8'b11111111;
                        end
                        ram_b_wr_done_cnt <= 2;
                    end else if (ram_b_wr_done_cnt == 2) begin
                        b_wr_en_i_temp <= 0;
                        ram_b_wr_done_cnt <= 0;
                        flag_temp <= 1'b0;
                        flag_temp1 <= 1'b0;
                    end
                // end
            end
        end
    end

    always @(*) begin
        if (sparse_en) begin
            case (precision_mode)
                PM_INT8_ALL, PM_INT8_INT32: begin
                    case (matrix_m)
                        8'd32:   matrix_a_index_base_addr = MATRIX_A_BASE_ADDR + 32;
                        8'd16:   matrix_a_index_base_addr = MATRIX_A_BASE_ADDR + 16;
                        8'd8:    matrix_a_index_base_addr = MATRIX_A_BASE_ADDR + 8 ;
                        default: matrix_a_index_base_addr = MATRIX_A_BASE_ADDR + 64;
                    endcase
                end

                default: matrix_a_index_base_addr = MATRIX_A_BASE_ADDR;
            endcase
        end else begin
            matrix_a_index_base_addr = MATRIX_A_BASE_ADDR;
        end
    end

    always @(*) begin
        case (precision_mode)
            PM_INT8_ALL: begin
                data_width_a = DATA_WIDTH_ONE_BYTE;
                data_width_b = DATA_WIDTH_ONE_BYTE;
                data_width_c = DATA_WIDTH_ONE_BYTE;
            end
            PM_INT8_INT32: begin
                data_width_a = DATA_WIDTH_ONE_BYTE;
                data_width_b = DATA_WIDTH_ONE_BYTE;
                data_width_c = DATA_WIDTH_FOUR_BYTE;
            end

            default: begin
                data_width_a = DATA_WIDTH_ONE_BYTE;
                data_width_b = DATA_WIDTH_ONE_BYTE;
                data_width_c = DATA_WIDTH_ONE_BYTE;
            end
        endcase
    end
    
    // 为A矩阵计算参数
    always @(*) begin
        if (!sparse_en) begin
            case (data_width_a)
                DATA_WIDTH_HALF_BYTE: begin
                    log2_k_div_epw_a = (log2_matrix_k > 4) ? (log2_matrix_k - 4) : 0;
                end
                DATA_WIDTH_ONE_BYTE: begin
                    log2_k_div_epw_a = (log2_matrix_k > LOG2_AXI_BYTES) ? (log2_matrix_k - LOG2_AXI_BYTES) : 0;
                end
                DATA_WIDTH_TWO_BYTE: begin
                    log2_k_div_epw_a = (log2_matrix_k > 2) ? (log2_matrix_k - 2) : 0;
                end
                DATA_WIDTH_FOUR_BYTE: begin
                    log2_k_div_epw_a = (log2_matrix_k > LOG2_AXI_INT32S_PER_WORD) ?
                        (log2_matrix_k - LOG2_AXI_INT32S_PER_WORD) : 0;
                end
                default: begin
                    log2_k_div_epw_a = (log2_matrix_k > LOG2_AXI_BYTES) ? (log2_matrix_k - LOG2_AXI_BYTES) : 0;
                end
            endcase
        end else begin
            case (data_width_a)
                DATA_WIDTH_HALF_BYTE: begin
                    log2_k_div_epw_a = (log2_matrix_k > 5) ? (log2_matrix_k - 5) : 0;
                end
                DATA_WIDTH_ONE_BYTE: begin
                    log2_k_div_epw_a = (log2_matrix_k > 4) ? (log2_matrix_k - 4) : 0;
                end
                DATA_WIDTH_TWO_BYTE: begin
                    log2_k_div_epw_a = (log2_matrix_k > 3) ? (log2_matrix_k - 3) : 0;
                end
                DATA_WIDTH_FOUR_BYTE: begin
                    log2_k_div_epw_a = (log2_matrix_k > 2) ? (log2_matrix_k - 2) : 0;
                end
                default: begin
                    log2_k_div_epw_a = (log2_matrix_k > 4) ? (log2_matrix_k - 4) : 0;
                end
            endcase
        end
        
    end
    
    // 为B矩阵计算参数
    always @(*) begin
        case (data_width_b)
            DATA_WIDTH_HALF_BYTE: begin
                log2_n_div_epw_b = (log2_matrix_n > 4) ? (log2_matrix_n - 4) : 0;
            end
            DATA_WIDTH_ONE_BYTE: begin
                    log2_n_div_epw_b = (log2_matrix_n > LOG2_AXI_BYTES) ? (log2_matrix_n - LOG2_AXI_BYTES) : 0;
                end
                DATA_WIDTH_TWO_BYTE: begin
                    log2_n_div_epw_b = (log2_matrix_n > 2) ? (log2_matrix_n - 2) : 0;
                end
                DATA_WIDTH_FOUR_BYTE: begin
                    log2_n_div_epw_b = (log2_matrix_n > LOG2_AXI_INT32S_PER_WORD) ?
                        (log2_matrix_n - LOG2_AXI_INT32S_PER_WORD) : 0;
                end
                default: begin
                    log2_n_div_epw_b = (log2_matrix_n > LOG2_AXI_BYTES) ? (log2_matrix_n - LOG2_AXI_BYTES) : 0;
                end
            endcase
    end
    
    // 为C矩阵计算参数
    always @(*) begin
        case (data_width_c)
            DATA_WIDTH_HALF_BYTE: begin
                log2_n_div_epw_c = (log2_matrix_n > 4) ? (log2_matrix_n - 4) : 0;
            end
            DATA_WIDTH_ONE_BYTE: begin
                    log2_n_div_epw_c = (log2_matrix_n > LOG2_AXI_BYTES) ? (log2_matrix_n - LOG2_AXI_BYTES) : 0;
                end
                DATA_WIDTH_TWO_BYTE: begin
                    log2_n_div_epw_c = (log2_matrix_n > 2) ? (log2_matrix_n - 2) : 0;
                end
                DATA_WIDTH_FOUR_BYTE: begin
                    log2_n_div_epw_c = (log2_matrix_n > LOG2_AXI_INT32S_PER_WORD) ?
                        (log2_matrix_n - LOG2_AXI_INT32S_PER_WORD) : 0;
                end
                default: begin
                    log2_n_div_epw_c = (log2_matrix_n > LOG2_AXI_BYTES) ? (log2_matrix_n - LOG2_AXI_BYTES) : 0;
                end
            endcase
    end
    
    // 寄存输入信号 - 提高时序稳定性
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ram_wr_en_r       <= 1'b0                       ;
            ram_wr_data_r     <= {AXI_DATA_WIDTH{1'b0}}     ;
            ram_wr_strb_r     <= {(AXI_DATA_WIDTH/8){1'b0}} ;
            rel_word_addr_a_r <= {REL_RAM_ADDR_WIDTH{1'b0}} ;
            rel_word_addr_b_r <= {REL_RAM_ADDR_WIDTH{1'b0}} ;
            rel_word_addr_c_r <= {REL_RAM_C_ADDR_WIDTH{1'b0}} ;
            is_matrix_a_r     <= 1'b0                       ;
            is_matrix_b_r     <= 1'b0                       ;
            is_matrix_c_r     <= 1'b0                       ;
            is_matrix_a_index_r <= 1'b0                     ;
            b_replay_needed_r <= 1'b0                       ;
        end else begin
            ram_wr_en_r       <= ram_wr_en            ;
            ram_wr_data_r     <= ram_wr_data          ;
            ram_wr_strb_r     <= ram_wr_strb          ;
            rel_word_addr_a_r <= rel_word_addr_a      ;
            rel_word_addr_b_r <= rel_word_addr_b      ;
            rel_word_addr_c_r <= rel_word_addr_c      ;
            is_matrix_a_r     <= is_matrix_a          ;
            is_matrix_b_r     <= is_matrix_b          ;
            is_matrix_c_r     <= is_matrix_c          ;
            is_matrix_a_index_r <= is_matrix_a_index  ;
            b_replay_needed_r <= is_matrix_b && (data_width_b == DATA_WIDTH_ONE_BYTE) &&
                                 has_b_replay_upper_bytes(ram_wr_strb);
        end
    end

    
    // A矩阵写控制信号
    reg [PE_SIZE-1:0]              a_wr_en_i                  ;
    reg [RAM_ADDR_WIDTH-1:0]       a_wr_addr_i [0:PE_SIZE-1]  ;
    reg [RAM_DATA_WIDTH-1:0]       a_wr_data_i [0:PE_SIZE-1]  ;
    reg [(RAM_DATA_WIDTH/8)-1:0]   a_wr_strb_i [0:PE_SIZE-1]  ; // 写选通
    
    // A矩阵写控制逻辑
    integer i;
    reg [LOG2_PE_SIZE-1:0] a_ram_idx;
    reg [RAM_ADDR_WIDTH-1:0] a_ram_addr;
    
    always @(*) begin
        // 初始化所有信号
        a_wr_en_i = {PE_SIZE{1'b0}};
        for (i = 0; i < PE_SIZE; i = i + 1) begin
            a_wr_addr_i[i] = {RAM_ADDR_WIDTH{1'b0}}    ;
            a_wr_data_i[i] = {RAM_DATA_WIDTH{1'b0}}    ;
            a_wr_strb_i[i] = {(RAM_DATA_WIDTH/8){1'b0}};
        end
        
        // 处理A矩阵写入 - A矩阵按行分配到不同RAM
        if (is_matrix_a_r && ram_wr_en_r) begin
            // 确定当前数据属于哪一行
            a_ram_idx = a_axi_row_idx[LOG2_PE_SIZE-1:0];  // 行索引 % PE_SIZE
            
            // 计算RAM内存地址：(行索引/PE_SIZE) * (k/elems_per_word) + 列偏移
            a_ram_addr = ((a_axi_row_idx >> LOG2_PE_SIZE) << log2_k_div_epw_a) + a_axi_col_idx;
            
            // 使能对应RAM并设置地址和数据
            a_wr_en_i[a_ram_idx]   = 1'b1         ;
            a_wr_addr_i[a_ram_idx] = a_ram_addr   ;
            a_wr_data_i[a_ram_idx] = ram_wr_data_r;
            a_wr_strb_i[a_ram_idx] = ram_wr_strb_r; // 使用AXI的写选通信号
        end
    end

    always @(*) begin
        if (is_matrix_a_index_r && ram_wr_en_r) begin
            a_index_wr_en   = 1'b1;
            a_index_wr_addr = rel_word_addr_a_r[RAM_ADDR_WIDTH-1:0] - matrix_a_index_base_addr;
            a_index_wr_data = ram_wr_data_r[RAM_DATA_WIDTH-1:0];
        end else if (a_last_data) begin
            a_index_wr_en   = 1'b1;
            a_index_wr_addr = {RAM_ADDR_WIDTH{1'b0}};
            a_index_wr_data = {RAM_DATA_WIDTH{1'b0}};
        end else begin
            a_index_wr_en   = 1'b0;
            a_index_wr_addr = {RAM_ADDR_WIDTH{1'b0}};
            a_index_wr_data = {RAM_DATA_WIDTH{1'b0}};
        end
    end
    
    // B矩阵写控制信号
    reg [PE_SIZE-1:0]              b_wr_en_i                  ;
    reg [RAM_ADDR_WIDTH-1:0]       b_wr_addr_i [0:PE_SIZE-1]  ;
    reg [RAM_DATA_WIDTH-1:0]       b_wr_data_i [0:PE_SIZE-1]  ;
    reg [(RAM_DATA_WIDTH/8)-1:0]   b_wr_strb_i [0:PE_SIZE-1]  ; // 写选通
    
    // 用于B矩阵写入控制的临时变量
    reg [7:0]                b_col_base        ; // 8位足够表示列基址
    reg [7:0]                curr_col          ; // 当前处理的列
    reg [RAM_ADDR_WIDTH-1:0] b_ram_addr        ; // RAM地址
    reg [LOG2_RAM_BYTES-1:0] byte_pos          ; // 字节位置
    reg [1:0]                byte_pair_pos     ; // 半字位置 (0-3)
    reg                      byte_four_pos     ; // 四字节位置 (0-1)
    reg [7:0]                data_bytes  [0:AXI_BYTES-1] ; // 拆分AXI数据的字节

    reg [127:0]              buf_bytes_n32[0:1] ;
    reg [127:0]              buf_bytes_n16      ;
    reg [7:0]                buf_bytes_n8[0:7]  ;

    integer j;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (j = 0; j < 2; j = j + 1) begin
                buf_bytes_n32[j] <= 128'b0;
            end
            for (j = 0; j < 8; j = j + 1) begin
                buf_bytes_n8[j] <= 8'b0;
            end
            buf_bytes_n16 <= 128'b0;
        end else begin
            if (is_matrix_b && ram_wr_en) begin
                if (data_width_b == DATA_WIDTH_HALF_BYTE) begin
                    if (!b_axi_row_idx_temp[0]) begin
                        // 当行索引为偶数时，处理低4位
                        for (j = 0; j < HALF_BYTE_PER_WORD; j = j + 1) begin
                            buf_bytes_n32[b_axi_col_idx_temp][j*8+:4] <= ram_wr_data[j*4+:4];
                            buf_bytes_n16[j*8+:4] <= ram_wr_data[j*4+:4];
                        end
                    end else begin
                        // 当行索引为奇数时，处理高4位
                        for (j = 0; j < HALF_BYTE_PER_WORD; j = j + 1) begin
                            buf_bytes_n32[b_axi_col_idx_temp][(j*8+4)+:4] <= ram_wr_data[j*4+:4];
                            buf_bytes_n16[(j*8+4)+:4] <= ram_wr_data[j*4+:4];
                        end
                    end
                    for (j = 0; j < 8; j = j + 1) begin
                        buf_bytes_n8[j] <= {ram_wr_data[(j*4+32)+:4],ram_wr_data[j*4+:4]};
                    end
                end
            end
        end
    end
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < 8; k = k + 1) begin
                b_buffer1[k] <= 64'b0;
                b_buffer2[k] <= 64'b0;
            end
        end else begin
            if (is_matrix_b_r && ram_wr_en_r && data_width_b == DATA_WIDTH_HALF_BYTE) begin
                if (matrix_n == 32) begin
                    if (b_axi_col_idx == 0) begin
                        for (k = 0; k < 8; k = k + 1) begin
                            b_buffer1[k][(b_axi_row_idx*4)+:4] <= ram_wr_data_r[(k*4+32)+:4];
                        end
                    end else if (b_axi_col_idx == 1) begin
                        for (k = 0; k < 8; k = k + 1) begin
                            b_buffer2[k][(b_axi_row_idx*4)+:4] <= ram_wr_data_r[(k*4+32)+:4];
                        end
                    end
                end else if (matrix_n == 16) begin
                    for (k = 0; k < 8; k = k + 1) begin
                        b_buffer1[k][(b_axi_row_idx*4)+:4] <= ram_wr_data_r[(k*4+32)+:4];
                    end
                end
                
            end
        end
    end

    // B矩阵写控制逻辑
    always @(*) begin
        // 初始化所有信号
        b_wr_en_i = {PE_SIZE{1'b0}};
        for (i = 0; i < PE_SIZE; i = i + 1) begin
            b_wr_addr_i[i] = {RAM_ADDR_WIDTH{1'b0}}    ;
            b_wr_data_i[i] = {RAM_DATA_WIDTH{1'b0}}    ;
            b_wr_strb_i[i] = {(RAM_DATA_WIDTH/8){1'b0}};
        end
        
        // 解析AXI数据字节 (小端序)
        for (i = 0; i < AXI_BYTES; i = i + 1) begin
            data_bytes[i] = ram_wr_data_r[(i*8) +: 8];
        end
        
        // 处理B矩阵replay写入
        if (b_replay_issue) begin
            byte_pos = b_replay_axi_row_idx[LOG2_RAM_BYTES-1:0];
            b_ram_addr = b_replay_axi_row_idx >> LOG2_RAM_BYTES;
            b_col_base = (b_replay_axi_col_idx << LOG2_AXI_BYTES) + PE_SIZE;

            for (i = 0; i < PE_SIZE; i = i + 1) begin
                curr_col = b_col_base + i;
                if (curr_col < matrix_n && b_replay_strb[PE_SIZE + i]) begin
                    b_wr_en_i[curr_col[LOG2_PE_SIZE-1:0]] = 1'b1;
                    b_wr_addr_i[curr_col[LOG2_PE_SIZE-1:0]] =
                        ((curr_col >> LOG2_PE_SIZE) << log2_k_div_epw_a) + b_ram_addr;
                    b_wr_strb_i[curr_col[LOG2_PE_SIZE-1:0]] =
                        ({{(RAM_BYTES-1){1'b0}}, 1'b1}) << byte_pos;
                    b_wr_data_i[curr_col[LOG2_PE_SIZE-1:0]] =
                        {{(RAM_DATA_WIDTH-8){1'b0}}, b_replay_data[((PE_SIZE + i) * 8) +: 8]} << (byte_pos * 8);
                end
            end
        end else if (is_matrix_b_r && ram_wr_en_r) begin
            // 计算AXI数据所携带元素的起始列索引
            case (data_width_b)
                DATA_WIDTH_HALF_BYTE:  b_col_base = {b_axi_col_idx, 4'b0000}; // 乘以16
                DATA_WIDTH_ONE_BYTE:   b_col_base = {b_axi_col_idx, 3'b000 }; // 乘以8
                DATA_WIDTH_TWO_BYTE:   b_col_base = {b_axi_col_idx, 2'b00  }; // 乘以4
                DATA_WIDTH_FOUR_BYTE:  b_col_base = {b_axi_col_idx, 1'b0   }; // 乘以2
                default:               b_col_base = {b_axi_col_idx, 3'b000 };
            endcase
            
            case (data_width_b)
                DATA_WIDTH_HALF_BYTE: begin
                    if (matrix_n == 32 || matrix_n == 16) begin
                        // 确定行在32位字中的位置，决定写入的字节位置
                        byte_pos = b_axi_row_idx[3:1];  // 行索引 % 4，对应字节位置
                        
                        // 计算RAM基址：b_axi_row_idx / 8
                        b_ram_addr = b_axi_row_idx >> 4;

                        // 处理每个INT4元素 (一个AXI字包含8个INT4)
                        for (i = 0; i < HALF_BYTE_PER_WORD / 2; i = i + 1) begin
                            curr_col = b_col_base + i;
                            if (curr_col < matrix_n) begin
                                // 确定RAM ID: 列号 % PE_SIZE
                                b_wr_en_i[curr_col[LOG2_PE_SIZE-1:0]] = 1'b1;
                                
                                // 列的基地址: (列号/PE_SIZE) * (k/8)
                                b_wr_addr_i[curr_col[LOG2_PE_SIZE-1:0]] = 
                                    ((curr_col >> LOG2_PE_SIZE) << (log2_matrix_k - 4)) + b_ram_addr;
                                
                                // 写选通：对应行位置的字节(第byte_pos个字节)
                                b_wr_strb_i[curr_col[LOG2_PE_SIZE-1:0]] = 8'b00000001 << byte_pos;
                                
                                // 数据：将对应字节放在正确位置
                                // 第i个字节放在第byte_pos个字节位置
                                b_wr_data_i[curr_col[LOG2_PE_SIZE-1:0]] = {56'b0, buf_bytes_n32[b_axi_col_idx][i*8+:8]} << (byte_pos * 8);
                            end
                        end
                    end else if (matrix_n == 8) begin
                        byte_pos = b_axi_row_idx[2:0];  // 行索引 % 8，对应字节位置
                        for (i = 0; i < 8; i = i + 1) begin
                            b_wr_en_i[i] = 1'b1;
                            b_wr_addr_i[i] = {{RAM_ADDR_WIDTH{1'b0}}};
                            b_wr_strb_i[i] = 8'b00000001 << byte_pos;
                            b_wr_data_i[i] = {56'b0, buf_bytes_n8[i]} << (byte_pos * 8);
                        end
                    end
                    
                end

                DATA_WIDTH_ONE_BYTE: begin
                    // 确定行在RAM字中的位置，决定写入的字节位置
                    byte_pos = b_axi_row_idx[LOG2_RAM_BYTES-1:0];

                    // 计算RAM基址：b_axi_row_idx / (RAM_DATA_WIDTH/8)
                    b_ram_addr = b_axi_row_idx >> LOG2_RAM_BYTES;

                    // 当前拍只直写前PE_SIZE个字节，后半段通过queue在后续cycle replay
                    b_col_base = b_axi_col_idx << LOG2_AXI_BYTES;
                    for (i = 0; i < B_DIRECT_BYTE_COUNT; i = i + 1) begin
                        curr_col = b_col_base + i;
                        if (curr_col < matrix_n && ram_wr_strb_r[i]) begin
                            // 确定RAM ID: 列号 % PE_SIZE
                            b_wr_en_i[curr_col[LOG2_PE_SIZE-1:0]] = 1'b1;
                            
                            // 列的基地址: (列号/PE_SIZE) * ceil(k/RAM字节数) + 行块偏移
                            b_wr_addr_i[curr_col[LOG2_PE_SIZE-1:0]] = 
                                ((curr_col >> LOG2_PE_SIZE) << log2_k_div_epw_a) + b_ram_addr;
                            
                            // 写选通：对应行位置的字节(第byte_pos个字节)
                            b_wr_strb_i[curr_col[LOG2_PE_SIZE-1:0]] =
                                ({{(RAM_BYTES-1){1'b0}}, 1'b1}) << byte_pos;
                            
                            // 数据：将对应字节放在正确位置
                            b_wr_data_i[curr_col[LOG2_PE_SIZE-1:0]] =
                                {{(RAM_DATA_WIDTH-8){1'b0}}, data_bytes[i]} << (byte_pos * 8);
                        end
                    end
                end

                DATA_WIDTH_TWO_BYTE: begin
                    // 确定行在16位半字中的位置
                    byte_pair_pos = b_axi_row_idx[1:0];  // 行索引 % 4

                    // 计算RAM基址：b_axi_row_idx / 4
                    b_ram_addr = b_axi_row_idx >> 2;
                    
                    // 处理每个16位元素 (一个AXI字包含4个16位数)
                    for (i = 0; i < TWO_BYTE_PER_WORD; i = i + 1) begin
                        curr_col = b_col_base + i;
                        if (curr_col < matrix_n) begin
                            // 确定RAM ID
                            b_wr_en_i[curr_col[LOG2_PE_SIZE-1:0]] = 1'b1;
                            
                            // 列的基地址
                            b_wr_addr_i[curr_col[LOG2_PE_SIZE-1:0]] = 
                                ((curr_col >> LOG2_PE_SIZE) << (log2_matrix_k - 2)) + b_ram_addr;
                            
                            // 写选通：对应半字位置 (2字节)
                            b_wr_strb_i[curr_col[LOG2_PE_SIZE-1:0]] = 8'b00000011 << (byte_pair_pos * 2);
                            
                            // 数据：从AXI数据中提取16位数据并放置到正确位置
                            case (i)
                                0: b_wr_data_i[curr_col[LOG2_PE_SIZE-1:0]] = {48'b0, ram_wr_data_r[15:0]} << (byte_pair_pos * 16);
                                1: b_wr_data_i[curr_col[LOG2_PE_SIZE-1:0]] = {48'b0, ram_wr_data_r[31:16]} << (byte_pair_pos * 16);
                                2: b_wr_data_i[curr_col[LOG2_PE_SIZE-1:0]] = {48'b0, ram_wr_data_r[47:32]} << (byte_pair_pos * 16);
                                3: b_wr_data_i[curr_col[LOG2_PE_SIZE-1:0]] = {48'b0, ram_wr_data_r[63:48]} << (byte_pair_pos * 16);
                            endcase
                        end
                    end
                end

                DATA_WIDTH_FOUR_BYTE: begin
                    // 确定行在32位字中的位置
                    byte_four_pos = b_axi_row_idx[0];  // 行索引 % 2
                    
                    // 计算RAM基址：b_axi_row_idx / 2
                    b_ram_addr = b_axi_row_idx >> 1;

                    // 处理每个FP32元素 (一个AXI字包含2个FP32)
                    for (i = 0; i < FOUR_BYTE_PER_WORD; i = i + 1) begin
                        curr_col = b_col_base + i;
                        if (curr_col < matrix_n) begin
                            // 确定RAM ID
                            b_wr_en_i[curr_col[LOG2_PE_SIZE-1:0]] = 1'b1;
                            
                            // 列的基地址
                            b_wr_addr_i[curr_col[LOG2_PE_SIZE-1:0]] = 
                                ((curr_col >> LOG2_PE_SIZE) << (log2_matrix_k - 1)) + b_ram_addr;
                            
                            // 写选通：对应半字位置
                            b_wr_strb_i[curr_col[LOG2_PE_SIZE-1:0]] = 
                                byte_four_pos ? 8'b11110000 : 8'b00001111;

                            // 数据：将FP32字放在正确位置
                            if (i == 0) begin
                                b_wr_data_i[curr_col[LOG2_PE_SIZE-1:0]] = 
                                    byte_four_pos ? {ram_wr_data_r[31:0], 32'b0} : {32'b0, ram_wr_data_r[31:0]};
                            end else begin
                                b_wr_data_i[curr_col[LOG2_PE_SIZE-1:0]] = 
                                    byte_four_pos ? {ram_wr_data_r[63:32], 32'b0} : {32'b0, ram_wr_data_r[63:32]};
                            end
                        end
                    end
                end

                default: begin
                    // 默认按INT8处理
                    byte_pos = b_axi_row_idx[LOG2_RAM_BYTES-1:0];
                    b_ram_addr = b_axi_row_idx >> LOG2_RAM_BYTES;
                    b_col_base = b_axi_col_idx << LOG2_AXI_BYTES;
                    for (i = 0; i < B_DIRECT_BYTE_COUNT; i = i + 1) begin
                        curr_col = b_col_base + i;
                        if (curr_col < matrix_n && ram_wr_strb_r[i]) begin
                            // 确定RAM ID: 列号 % PE_SIZE
                            b_wr_en_i[curr_col[LOG2_PE_SIZE-1:0]] = 1'b1;
                            
                            b_wr_addr_i[curr_col[LOG2_PE_SIZE-1:0]] = 
                                ((curr_col >> LOG2_PE_SIZE) << log2_k_div_epw_a) + b_ram_addr;
                            
                            b_wr_strb_i[curr_col[LOG2_PE_SIZE-1:0]] =
                                ({{(RAM_BYTES-1){1'b0}}, 1'b1}) << byte_pos;
                            
                            b_wr_data_i[curr_col[LOG2_PE_SIZE-1:0]] =
                                {{(RAM_DATA_WIDTH-8){1'b0}}, data_bytes[i]} << (byte_pos * 8);
                        end
                    end
                end
            endcase
        end
    end
    
    // C矩阵写控制信号
    reg [PE_SIZE-1:0]              c_wr_en_i                  ;
    reg [RAM_C_ADDR_WIDTH-1:0]     c_wr_addr_i [0:PE_SIZE-1]  ;
    reg [RAM_DATA_WIDTH-1:0]       c_wr_data_i [0:PE_SIZE-1]  ;
    reg [(RAM_DATA_WIDTH/8)-1:0]   c_wr_strb_i [0:PE_SIZE-1]  ; // 写选通
    
    // C矩阵写控制逻辑
    reg [LOG2_PE_SIZE-1:0]     c_ram_idx;
    reg [RAM_C_ADDR_WIDTH-1:0] c_ram_addr;
    reg                        byte_pos_c;
    reg [2:0]                  c_ram_idx_temp;
    
    always @(*) begin
        // 初始化所有信号
        c_wr_en_i = {PE_SIZE{1'b0}};
        for (i = 0; i < PE_SIZE; i = i + 1) begin
            c_wr_addr_i[i] = {RAM_C_ADDR_WIDTH{1'b0}}    ;
            c_wr_data_i[i] = {RAM_DATA_WIDTH{1'b0}}    ;
            c_wr_strb_i[i] = {(RAM_DATA_WIDTH/8){1'b0}};
        end
        byte_pos_c = 1'b0;
        
        // 处理C矩阵写入 - C矩阵与A矩阵逻辑相似，按行分配到不同RAM
        if (is_matrix_c_r && ram_wr_en_r) begin

            if (data_width_c == DATA_WIDTH_HALF_BYTE && matrix_n == 8) begin

                byte_pos_c = c_axi_row_idx[2];
                c_ram_idx_temp = {c_axi_row_idx[1:0],1'b0};
                c_ram_addr = c_axi_row_idx[3];

                c_wr_en_i[c_ram_idx_temp] = 1'b1;
                c_wr_addr_i[c_ram_idx_temp] = c_ram_addr;
                c_wr_data_i[c_ram_idx_temp] = {32'b0,ram_wr_data_r[31:0]} << (byte_pos_c ? 32 : 0);
                c_wr_strb_i[c_ram_idx_temp] = 8'b00001111 << (byte_pos_c ? 4 : 0);

                c_wr_en_i[c_ram_idx_temp+1] = 1'b1;
                c_wr_addr_i[c_ram_idx_temp+1] = c_ram_addr;
                c_wr_data_i[c_ram_idx_temp+1] = {32'b0,ram_wr_data_r[63:32]} << (byte_pos_c ? 32 : 0);
                c_wr_strb_i[c_ram_idx_temp+1] = 8'b00001111 << (byte_pos_c ? 4 : 0);

            end else begin
                // 确定当前数据属于哪一行
                c_ram_idx = c_axi_row_idx[LOG2_PE_SIZE-1:0];  // 行索引 % PE_SIZE
                
                // 计算RAM内存地址：(行索引/PE_SIZE) * (n/elems_per_word) + 列偏移
                c_ram_addr = ((c_axi_row_idx >> LOG2_PE_SIZE) << log2_n_div_epw_c) + c_axi_col_idx;
                
                // 使能对应RAM并设置地址和数据
                c_wr_en_i[c_ram_idx]   = 1'b1         ;
                c_wr_addr_i[c_ram_idx] = c_ram_addr   ;
                c_wr_data_i[c_ram_idx] = ram_wr_data_r;
                c_wr_strb_i[c_ram_idx] = ram_wr_strb_r; // 使用AXI的写选通信号
            end
            
        end
    end
    
    // 输出压缩 - A矩阵RAM接口信号
    always @(*) begin
        ram_a_wr_en = a_wr_en_i;
        
        // 初始化输出端口
        ram_a_wr_addr = {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}}    ;
        ram_a_wr_data = {(RAM_DATA_WIDTH*PE_SIZE){1'b0}}    ;
        ram_a_wr_strb = {((RAM_DATA_WIDTH/8)*PE_SIZE){1'b0}};
        
        // 将数组压平为位宽扩展的输出向量
        for (i = 0; i < PE_SIZE; i = i + 1) begin
            ram_a_wr_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] = a_wr_addr_i[i];
            ram_a_wr_data[i*RAM_DATA_WIDTH +: RAM_DATA_WIDTH] = a_wr_data_i[i];
            ram_a_wr_strb[i*(RAM_DATA_WIDTH/8) +: (RAM_DATA_WIDTH/8)] = a_wr_strb_i[i];
        end
    end
    
    // 输出压缩 - B矩阵RAM接口信号
    always @(*) begin
        ram_b_wr_en = {PE_SIZE{1'b0}};
        
        // 初始化输出端口
        ram_b_wr_addr = {(RAM_ADDR_WIDTH*PE_SIZE){1'b0}}    ;
        ram_b_wr_data = {(RAM_DATA_WIDTH*PE_SIZE){1'b0}}    ;
        ram_b_wr_strb = {((RAM_DATA_WIDTH/8)*PE_SIZE){1'b0}};
        
        if (flag_temp) begin
            // 如果B矩阵写入完成信号被设置，使用临时变量
            for (i = 0; i < PE_SIZE; i = i + 1) begin
                ram_b_wr_en[i] = b_wr_en_i_temp[i];
                ram_b_wr_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] = b_wr_addr_i_temp[i];
                ram_b_wr_data[i*RAM_DATA_WIDTH +: RAM_DATA_WIDTH] = b_wr_data_i_temp[i];
                ram_b_wr_strb[i*(RAM_DATA_WIDTH/8) +: (RAM_DATA_WIDTH/8)] = b_wr_strb_i_temp[i];
            end
        end else begin
            // 将数组压平为位宽扩展的输出向量
            for (i = 0; i < PE_SIZE; i = i + 1) begin
                ram_b_wr_en[i] = b_wr_en_i[i];
                ram_b_wr_addr[i*RAM_ADDR_WIDTH +: RAM_ADDR_WIDTH] = b_wr_addr_i[i];
                ram_b_wr_data[i*RAM_DATA_WIDTH +: RAM_DATA_WIDTH] = b_wr_data_i[i];
                ram_b_wr_strb[i*(RAM_DATA_WIDTH/8) +: (RAM_DATA_WIDTH/8)] = b_wr_strb_i[i];
            end
        end
        
    end
    
    // 输出压缩 - C矩阵RAM接口信号
    always @(*) begin
        ram_c_wr_en = c_wr_en_i;
        
        // 初始化输出端口
        ram_c_wr_addr = {(RAM_C_ADDR_WIDTH*PE_SIZE){1'b0}}    ;
        ram_c_wr_data = {(RAM_DATA_WIDTH*PE_SIZE){1'b0}}    ;
        ram_c_wr_strb = {((RAM_DATA_WIDTH/8)*PE_SIZE){1'b0}};
        
        // 将数组压平为位宽扩展的输出向量
        for (i = 0; i < PE_SIZE; i = i + 1) begin
            ram_c_wr_addr[i*RAM_C_ADDR_WIDTH +: RAM_C_ADDR_WIDTH] = c_wr_addr_i[i];
            ram_c_wr_data[i*RAM_DATA_WIDTH +: RAM_DATA_WIDTH] = c_wr_data_i[i];
            ram_c_wr_strb[i*(RAM_DATA_WIDTH/8) +: (RAM_DATA_WIDTH/8)] = c_wr_strb_i[i];
        end
    end

endmodule
