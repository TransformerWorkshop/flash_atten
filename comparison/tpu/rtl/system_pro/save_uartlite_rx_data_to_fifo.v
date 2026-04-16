module save_uartlite_rx_data_to_fifo #(
    parameter FIFO_DATA_WIDTH = 8   ,    // FIFO数据宽度
    parameter FIFO_DEPTH      = 2048     // FIFO深度
)(
    input  wire                              clk               ,
    input  wire                              rst_n             ,

    // AXI Lite接口
    output wire [                     4-1:0] uart_axi_araddr   ,
    output wire                              uart_axi_arvalid  ,
    input  wire                              uart_axi_arready  ,
    input  wire [                    32-1:0] uart_axi_rdata    ,
    input  wire [                       1:0] uart_axi_rresp    ,
    input  wire                              uart_axi_rvalid   ,
    output wire                              uart_axi_rready   ,

    // FIFO状态输出
    output wire                              fifo_full         ,
    output wire                              fifo_empty        ,
    output wire                              fifo_almost_full  ,
    output wire                              fifo_almost_empty ,
    
    // FIFO读取接口
    input  wire                              fifo_rd_en        ,
    output wire [      FIFO_DATA_WIDTH-1:0]  fifo_data_out      
);

    // UART寄存器地址定义
    localparam [3:0] UART_RX_FIFO   = 4'h0;    // 接收数据寄存器
    localparam [3:0] UART_STAT_REG  = 4'h8;    // 状态寄存器

    // 状态寄存器位定义
    localparam RX_VALID_BIT = 0;    // RX FIFO有数据标志位

    // 状态机定义
    localparam [1:0] IDLE        = 2'b00;   // 空闲状态
    localparam [1:0] CHECK_RX    = 2'b01;   // 检查是否有数据可读
    localparam [1:0] READ_DATA   = 2'b10;   // 读取数据
    localparam [1:0] WRITE_FIFO  = 2'b11;   // 写入FIFO

    reg [1:0] curr_state, next_state;
    reg [7:0] rx_data;                // 存储接收到的数据(只使用低8位)
    reg       fifo_wr_en;             // FIFO写使能信号

    // AXI控制信号
    reg [3:0]  axi_addr;
    reg        axi_read_start;
    
    // AXI接口控制
    assign uart_axi_araddr  = axi_addr;
    assign uart_axi_arvalid = axi_read_start;
    assign uart_axi_rready  = 1'b1;

    // 实例化FIFO
    sync_fifo #(
        .DATA_WIDTH(FIFO_DATA_WIDTH),           // UART数据通常是8位
        .FIFO_DEPTH(FIFO_DEPTH),          // 32个深度的FIFO
        .ALMOST_FULL_TH(3),       // 接近满阈值
        .ALMOST_EMPTY_TH(3)       // 接近空阈值
    ) uart_rx_fifo (
        .clk          (clk),
        .rst_n        (rst_n),
        .wr_en        (fifo_wr_en),
        .rd_en        (fifo_rd_en),
        .data_in      (rx_data),
        .full         (fifo_full),
        .empty        (fifo_empty),
        .almost_full  (fifo_almost_full),
        .almost_empty (fifo_almost_empty),
        .data_out     (fifo_data_out)
    );

    // 状态寄存器更新
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
                next_state = CHECK_RX;
            end
            
            CHECK_RX: begin
                if (uart_axi_arready && uart_axi_arvalid) begin
                    next_state = READ_DATA;
                end
            end
            
            READ_DATA: begin
                if (uart_axi_rvalid) begin
                    // 如果状态寄存器读回来，检查是否有数据
                    if (axi_addr == UART_STAT_REG) begin
                        if (uart_axi_rdata[RX_VALID_BIT]) begin
                            next_state = READ_DATA; // 继续读取接收到的数据
                        end else begin
                            next_state = CHECK_RX;  // 无数据，继续检查
                        end
                    end
                    // 如果是接收数据读回来，准备写入FIFO
                    else if (axi_addr == UART_RX_FIFO) begin
                        next_state = WRITE_FIFO;
                    end
                end
            end
            
            WRITE_FIFO: begin
                // 写入FIFO后返回空闲状态
                next_state = IDLE;
            end
            
            default:
                next_state = IDLE;
        endcase
    end
    
    // 状态输出逻辑 
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            axi_addr <= 4'h0;
            axi_read_start <= 1'b0;
            rx_data <= 8'h0;
            fifo_wr_en <= 1'b0;
        end else begin
            // 默认值
            axi_read_start <= 1'b0;
            fifo_wr_en <= 1'b0;
            
            case (curr_state)
                IDLE: begin
                    // 空闲状态不做操作
                end
                
                CHECK_RX: begin
                    // 读取状态寄存器
                    axi_addr <= UART_STAT_REG;
                    axi_read_start <= 1'b1;
                end
                
                READ_DATA: begin
                    if (uart_axi_rvalid) begin
                        if (axi_addr == UART_STAT_REG) begin
                            // 如果RX FIFO有数据，准备读取
                            if (uart_axi_rdata[RX_VALID_BIT]) begin
                                axi_addr <= UART_RX_FIFO;
                                axi_read_start <= 1'b1;
                            end
                        end
                        else if (axi_addr == UART_RX_FIFO) begin
                            // 保存读取到的数据(只取低8位)
                            rx_data <= uart_axi_rdata[7:0];
                        end
                    end
                end
                
                WRITE_FIFO: begin
                    // 只有当FIFO未满时才写入
                    if (!fifo_full) begin
                        fifo_wr_en <= 1'b1;
                    end
                end
                
                default: begin
                    // 默认不做操作
                end
            endcase
        end
    end

endmodule