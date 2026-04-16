module transfer_d_data_to_uartlite #(
    parameter DATA_WIDTH = 64,
    parameter ADDR_WIDTH = 13 
) (
    input  wire                       clk                  ,
    input  wire                       rst_n                ,

    // D矩阵RAM读接口
    output wire                       ram_d_rd_en          ,
    output wire [     ADDR_WIDTH-1:0] ram_d_rd_addr        ,
    input  wire [     DATA_WIDTH-1:0] ram_d_rd_data        ,

    // UART-Lite写接口
    output wire [              3 : 0] uart_axi_awaddr      ,
    output wire                       uart_axi_awvalid     ,
    input  wire                       uart_axi_awready     ,
    output wire [             32-1:0] uart_axi_wdata       ,
    output wire [              3 : 0] uart_axi_wstrb       ,
    output wire                       uart_axi_wvalid      ,
    input  wire                       uart_axi_wready      ,
    input  wire [              1 : 0] uart_axi_bresp       ,
    input  wire                       uart_axi_bvalid      ,
    output wire                       uart_axi_bready      ,

    // 控制接口
    input  wire                       uart_tx_start        ,
    input  wire [     DATA_WIDTH-1:0] uart_tx_cfg_data     ,
    input  wire [     ADDR_WIDTH-1:0] uart_tx_cfg_addr     ,
    input  wire [               15:0] uart_tx_cfg_count    ,
    output reg                        uart_tx_done         ,
    output reg                        uart_tx_busy          
);

    // UART寄存器地址定义
    localparam [3:0] UART_TX_FIFO = 4'h4;  // 发送数据寄存器

    // 状态机状态定义
    localparam IDLE          = 3'd0;  // 空闲状态
    localparam SEND_CFG_DATA = 3'd1;  // 发送配置数据
    localparam WAIT_DELAY    = 3'd2;  // 延时等待
    localparam READ_RAM      = 3'd3;  // 从RAM读取数据
    localparam SEND_RAM_DATA = 3'd4;  // 发送RAM数据
    localparam DONE          = 3'd5;  // 传输完成

    localparam MAX_DELAY_CNT = 32'd80000;

    reg [2:0] curr_state, next_state;
    
    // 数据寄存器和计数器
    reg [DATA_WIDTH-1:0] tx_data;          // 当前发送的64位数据
    reg [2:0]            byte_cnt;         // 字节计数器(0-7)
    reg [15:0]           data_cnt;         // 已发送的数据计数
    reg [31:0]           delay_cnt;        // 延时计数器
    reg [ADDR_WIDTH-1:0] ram_addr;         // RAM读地址

    reg                  ram_d_rd_data_vld;
    
    // 标志位
    reg                  send_cfg_done;    // 配置数据发送完成标志
    reg                  ram_rd_req;       // RAM读请求信号
    reg                  byte_send;        // 字节发送标志
    
    // 控制信号
    reg [3:0]            axi_addr;
    reg                  axi_write_start;
    reg [31:0]           axi_write_data;

    // AXI写接口连接
    assign uart_axi_awaddr  = axi_addr;
    assign uart_axi_awvalid = axi_write_start;
    assign uart_axi_wdata   = axi_write_data;
    assign uart_axi_wstrb   = 4'h1;        // 只写入低8位
    assign uart_axi_wvalid  = axi_write_start;
    assign uart_axi_bready  = 1'b1;
    
    // RAM读接口连接
    assign ram_d_rd_en     = ram_rd_req;
    assign ram_d_rd_addr   = ram_addr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ram_d_rd_data_vld <= 1'b0;
        end else begin
            ram_d_rd_data_vld <= ram_rd_req;
        end
    end

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
                if (uart_tx_start) begin
                    next_state = SEND_CFG_DATA;
                end
            end
            
            SEND_CFG_DATA: begin
                if (byte_cnt == 3'd7 && byte_send && uart_axi_wready) begin
                    next_state = WAIT_DELAY;
                end
            end
            
            WAIT_DELAY: begin
                if (delay_cnt >= MAX_DELAY_CNT) begin
                    if (send_cfg_done) begin
                        if (data_cnt >= uart_tx_cfg_count) begin
                            next_state = DONE;
                        end else begin
                            next_state = READ_RAM;
                        end
                    end else begin
                        next_state = SEND_CFG_DATA;
                    end
                end
            end
            
            READ_RAM: begin
                if (ram_d_rd_data_vld) begin
                    next_state = SEND_RAM_DATA;
                end
            end
            
            SEND_RAM_DATA: begin
                if (byte_cnt == 3'd7 && byte_send && uart_axi_wready) begin
                    next_state = WAIT_DELAY;
                end
            end
            
            DONE: begin
                next_state = IDLE;
            end
            
            default:
                next_state = IDLE;
        endcase
    end
    
    // 状态输出逻辑 
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_data <= 64'h0;
            byte_cnt <= 3'b0;
            data_cnt <= 16'h0;
            delay_cnt <= 32'h0;
            ram_addr <= {ADDR_WIDTH{1'b0}};
            
            send_cfg_done <= 1'b0;
            ram_rd_req <= 1'b0;
            byte_send <= 1'b0;
            
            axi_addr <= 4'h0;
            axi_write_start <= 1'b0;
            axi_write_data <= 32'h0;
            
            uart_tx_done <= 1'b0;
            uart_tx_busy <= 1'b0;
        end else begin
            // 默认值
            axi_write_start <= 1'b0;
            ram_rd_req <= 1'b0;
            byte_send <= 1'b0;
            uart_tx_done <= 1'b0;

            case (curr_state)
                IDLE: begin
                    byte_cnt <= 2'b0;
                    data_cnt <= 16'h0;
                    delay_cnt <= 32'h0;
                    send_cfg_done <= 1'b0;
                    uart_tx_busy <= 1'b0;
                    
                    if (uart_tx_start) begin
                        // 加载配置数据
                        tx_data <= uart_tx_cfg_data;
                        ram_addr <= uart_tx_cfg_addr;
                        uart_tx_busy <= 1'b1;
                    end
                end
                
                SEND_CFG_DATA: begin
                    if (uart_axi_wready || !axi_write_start) begin
                        // 选择当前要发送的字节
                        case (byte_cnt)
                            3'd0: axi_write_data <= {24'h0, tx_data[7:0]};
                            3'd1: axi_write_data <= {24'h0, tx_data[15:8]};
                            3'd2: axi_write_data <= {24'h0, tx_data[23:16]};
                            3'd3: axi_write_data <= {24'h0, tx_data[31:24]};
                            3'd4: axi_write_data <= {24'h0, tx_data[39:32]};
                            3'd5: axi_write_data <= {24'h0, tx_data[47:40]};
                            3'd6: axi_write_data <= {24'h0, tx_data[55:48]};
                            3'd7: axi_write_data <= {24'h0, tx_data[63:56]};
                        endcase
                        
                        axi_addr <= UART_TX_FIFO;
                        axi_write_start <= 1'b1;
                        byte_send <= 1'b1;
                        
                        // 发送完一个字节后更新计数器
                        if (byte_send) begin
                            if (byte_cnt == 3'd7) begin
                                byte_cnt <= 3'b0;
                                send_cfg_done <= 1'b1;  // 配置数据发送完成
                            end else begin
                                byte_cnt <= byte_cnt + 1'b1;
                            end
                        end
                    end
                end
                
                WAIT_DELAY: begin
                    // 等待延时
                    if (delay_cnt < MAX_DELAY_CNT) begin
                        delay_cnt <= delay_cnt + 1'b1;
                    end else begin
                        delay_cnt <= 32'h0;
                    end
                end
                
                READ_RAM: begin
                    // 从RAM读取数据
                    ram_rd_req <= 1'b1;
                    
                    if (ram_d_rd_data_vld) begin
                        tx_data <= ram_d_rd_data;
                        ram_addr <= ram_addr + 1'b1;
                    end
                end
                
                SEND_RAM_DATA: begin
                    if (uart_axi_wready || !axi_write_start) begin
                        // 选择当前要发送的字节
                        case (byte_cnt)
                            3'd0: axi_write_data <= {24'h0, tx_data[7:0]};
                            3'd1: axi_write_data <= {24'h0, tx_data[15:8]};
                            3'd2: axi_write_data <= {24'h0, tx_data[23:16]};
                            3'd3: axi_write_data <= {24'h0, tx_data[31:24]};
                            3'd4: axi_write_data <= {24'h0, tx_data[39:32]};
                            3'd5: axi_write_data <= {24'h0, tx_data[47:40]};
                            3'd6: axi_write_data <= {24'h0, tx_data[55:48]};
                            3'd7: axi_write_data <= {24'h0, tx_data[63:56]};
                        endcase
                        
                        axi_addr <= UART_TX_FIFO;
                        axi_write_start <= 1'b1;
                        byte_send <= 1'b1;
                        
                        // 发送完一个字节后更新计数器
                        if (byte_send) begin
                            if (byte_cnt == 3'd7) begin
                                byte_cnt <= 3'b0;
                                data_cnt <= data_cnt + 1'b1;  // 数据计数增加
                            end else begin
                                byte_cnt <= byte_cnt + 1'b1;
                            end
                        end
                    end
                end
                
                DONE: begin
                    uart_tx_done <= 1'b1;
                end
                
                default: begin
                    // 默认不做操作
                end
            endcase
        end
    end

endmodule
