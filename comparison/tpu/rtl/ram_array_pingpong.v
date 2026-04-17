module ram_array_pingpong #(
    parameter PE_SIZE        = 16,   // PE数量/阵列大小
    parameter RAM_ADDR_WIDTH = 12,   // RAM地址宽度
    parameter RAM_DATA_WIDTH = 32    // RAM数据宽度
) (
    // 全局信号
    input  wire                                  clk           ,
    input  wire                                  rst_n         ,
    
    // 缓冲区控制信号
    input  wire                                  write_complete,  // 写入完成，触发缓冲区切换的脉冲信号
    input  wire                                  read_complete ,  // 读取完成信号，标记当前读缓冲区已读完
    output wire                                  buffer_select ,  // 当前读取的缓冲区(0或1)
    output wire                                  read_ready    ,  // 当前读取缓冲区有有效数据可读
    output wire                                  write_ready   ,  // 当前写入缓冲区可以接收数据
    
    // 写接口 (写入非活动缓冲区)
    input  wire [                   PE_SIZE-1:0] ram_wr_en     ,
    input  wire [    RAM_ADDR_WIDTH*PE_SIZE-1:0] ram_wr_addr   ,
    input  wire [    RAM_DATA_WIDTH*PE_SIZE-1:0] ram_wr_data   ,
    input  wire [(RAM_DATA_WIDTH/8)*PE_SIZE-1:0] ram_wr_strb   ,
    
    // 读接口 (读取活动缓冲区)
    input  wire [                   PE_SIZE-1:0] ram_rd_en     ,
    input  wire [    RAM_ADDR_WIDTH*PE_SIZE-1:0] ram_rd_addr   ,
    output wire [    RAM_DATA_WIDTH*PE_SIZE-1:0] ram_rd_data    
);

    // 缓冲区选择寄存器 - 指示当前活动缓冲区(用于读取)
    reg buffer_sel_reg;
    assign buffer_select = buffer_sel_reg;
    
    // 缓冲区状态: 0=空, 1=满
    reg [1:0] buffer_status;  // [0]=buffer0状态, [1]=buffer1状态
    
    // 状态信号
    assign read_ready = buffer_status[buffer_sel_reg];       // 当前读缓冲区满时可读
    assign write_ready = !buffer_status[~buffer_sel_reg];    // 当前写缓冲区空时可写
    
    // 缓冲区切换和状态管理
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buffer_sel_reg <= 1'b0;
            buffer_status <= 2'b00;
        end else begin
            // 使用case处理组合情况，明确优先级
            case ({write_complete, read_complete})
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
    
    // 为两个缓冲区准备控制信号
    wire [PE_SIZE-1:0] ram0_wr_en, ram1_wr_en;
    wire [PE_SIZE-1:0] ram0_rd_en, ram1_rd_en;
    wire [RAM_DATA_WIDTH*PE_SIZE-1:0] ram0_rd_data, ram1_rd_data;
        
    // 写入控制 - 始终写入非读取的缓冲区
    assign ram0_wr_en = ram_wr_en & {PE_SIZE{buffer_sel_reg}};    // 当缓冲区1用于读取时，写入缓冲区0
    assign ram1_wr_en = ram_wr_en & {PE_SIZE{~buffer_sel_reg}};   // 当缓冲区0用于读取时，写入缓冲区1
    
    // 读取控制 - 始终从当前活动缓冲区读取
    assign ram0_rd_en = ram_rd_en & {PE_SIZE{~buffer_sel_reg}};   // 当缓冲区0用于读取时读取缓冲区0
    assign ram1_rd_en = ram_rd_en & {PE_SIZE{buffer_sel_reg}};    // 当缓冲区1用于读取时读取缓冲区1
    
    // 输出多路复用器 - 选择活动缓冲区的数据输出
    assign ram_rd_data = buffer_sel_reg ? ram1_rd_data : ram0_rd_data;
    
    // 实例化缓冲区0的RAM阵列
    ram_array #(
        .PE_SIZE(PE_SIZE),
        .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
        .RAM_DATA_WIDTH(RAM_DATA_WIDTH)
    ) u_ram_array_0 (
        .clk            (clk),
        .ram_wr_en      (ram0_wr_en),
        .ram_wr_addr    (ram_wr_addr),
        .ram_wr_data    (ram_wr_data),
        .ram_wr_strb    (ram_wr_strb),
        .ram_rd_en      (ram0_rd_en),
        .ram_rd_addr    (ram_rd_addr),
        .ram_rd_data    (ram0_rd_data)
    );
    
    // 实例化缓冲区1的RAM阵列
    ram_array #(
        .PE_SIZE(PE_SIZE),
        .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
        .RAM_DATA_WIDTH(RAM_DATA_WIDTH)
    ) u_ram_array_1 (
        .clk            (clk),
        .ram_wr_en      (ram1_wr_en),
        .ram_wr_addr    (ram_wr_addr),
        .ram_wr_data    (ram_wr_data),
        .ram_wr_strb    (ram_wr_strb),
        .ram_rd_en      (ram1_rd_en),
        .ram_rd_addr    (ram_rd_addr),
        .ram_rd_data    (ram1_rd_data)
    );

endmodule
