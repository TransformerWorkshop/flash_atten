module sync_fifo #(
    parameter DATA_WIDTH            = 8  ,   // 数据宽度
    parameter FIFO_DEPTH            = 32 ,   // FIFO深度
    parameter ALMOST_FULL_TH        = 3  ,   // 接近满阈值
    parameter ALMOST_EMPTY_TH       = 3      // 接近空阈值
) (
    input  wire                      clk            ,
    input  wire                      rst_n          ,
    input  wire                      wr_en          ,
    input  wire                      rd_en          ,
    input  wire    [DATA_WIDTH-1:0]  data_in        ,
    output wire                      full           ,
    output wire                      empty          ,
    output wire                      almost_full    ,
    output wire                      almost_empty   ,
    output wire    [DATA_WIDTH-1:0]  data_out          
);

    // 计算地址宽度
    localparam ADDR_WIDTH = $clog2(FIFO_DEPTH);
    
    // 定义指针和计数器
    reg [ADDR_WIDTH-1:0] wr_ptr;         // 写指针
    reg [ADDR_WIDTH-1:0] rd_ptr;         // 读指针
    reg [ADDR_WIDTH:0]   cnt;            // 数据计数，比地址宽度多一位，用于区分空和满
    
    // 状态信号生成
    assign full         = (cnt == FIFO_DEPTH);
    assign empty        = (cnt == 0);
    assign almost_full  = (cnt >= (FIFO_DEPTH - ALMOST_FULL_TH));
    assign almost_empty = (cnt <= ALMOST_EMPTY_TH);
    
    // 写入逻辑
    wire wr_ram_en = wr_en & ~full;      // 当FIFO不满时才写入RAM
    
    // 写指针更新
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= {ADDR_WIDTH{1'b0}};
        end else if (wr_ram_en) begin
            if (wr_ptr == FIFO_DEPTH-1)
                wr_ptr <= {ADDR_WIDTH{1'b0}};
            else
                wr_ptr <= wr_ptr + 1'b1;
        end
    end
    
    // 读取逻辑
    wire rd_ram_en = rd_en & ~empty;     // 当FIFO不空时才从RAM读取
    
    // 读指针更新
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr <= {ADDR_WIDTH{1'b0}};
        end else if (rd_ram_en) begin
            if (rd_ptr == FIFO_DEPTH-1)
                rd_ptr <= {ADDR_WIDTH{1'b0}};
            else
                rd_ptr <= rd_ptr + 1'b1;
        end
    end
    
    // 数据计数器更新
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= {(ADDR_WIDTH+1){1'b0}};
        end else begin
            case ({wr_ram_en, rd_ram_en})
                2'b10:   // 只写不读
                    cnt <= cnt + 1'b1;
                2'b01:   // 只读不写
                    cnt <= cnt - 1'b1;
                2'b11:   // 同时读写
                    cnt <= cnt;
                default: // 不读不写
                    cnt <= cnt;
            endcase
        end
    end
    
    // 连接数据输出
    wire [DATA_WIDTH-1:0] ram_rd_data;
    
    assign data_out = ram_rd_data;
    
    // 例化sdp_ram模块
    sdp_ram #(
        .RAM_DATA_WIDTH (DATA_WIDTH),
        .RAM_ADDR_WIDTH (ADDR_WIDTH)
    ) fifo_ram (
        .clk          (clk),
        .wr_en        (wr_ram_en),
        .wr_addr      (wr_ptr),
        .wr_data      (data_in),
        .wr_strb      ({(DATA_WIDTH/8){1'b1}}),
        .rd_en        (rd_ram_en),
        .rd_addr      (rd_ptr),
        .rd_data      (ram_rd_data)
    );
    
endmodule