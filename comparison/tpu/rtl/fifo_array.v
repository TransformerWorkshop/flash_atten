module fifo_array #(
    parameter PE_SIZE                = 16,  // FIFO数量/阵列大小
    parameter DATA_WIDTH             = 32,  // 每个FIFO的数据宽度
    parameter FIFO_DEPTH             = 32,  // 每个FIFO的深度
    parameter ALMOST_FULL_TH         = 3,   // 接近满阈值
    parameter ALMOST_EMPTY_TH        = 3    // 接近空阈值
) (
    // 时钟和复位
    input  wire                          clk           ,
    input  wire                          rst_n         ,

    // 写接口
    input  wire [           PE_SIZE-1:0] wr_en         ,
    input  wire [DATA_WIDTH*PE_SIZE-1:0] data_in       ,

    // 读接口
    input  wire [           PE_SIZE-1:0] rd_en         ,
    output wire [DATA_WIDTH*PE_SIZE-1:0] data_out      ,

    // 状态信号
    output wire [           PE_SIZE-1:0] full          ,
    output wire [           PE_SIZE-1:0] empty         ,
    output wire [           PE_SIZE-1:0] almost_full   ,
    output wire [           PE_SIZE-1:0] almost_empty
);

    // 生成PE_SIZE个sync_fifo实例
    genvar i;
    generate
        for (i = 0; i < PE_SIZE; i = i + 1) begin : fifo_instances
            sync_fifo #(
                .DATA_WIDTH     (DATA_WIDTH),
                .FIFO_DEPTH     (FIFO_DEPTH),
                .ALMOST_FULL_TH (ALMOST_FULL_TH),
                .ALMOST_EMPTY_TH(ALMOST_EMPTY_TH)
            ) u_fifo (
                .clk           (clk),
                .rst_n         (rst_n),
                .wr_en         (wr_en[i]),
                .rd_en         (rd_en[i]),
                .data_in       (data_in[i*DATA_WIDTH+:DATA_WIDTH]),
                .full          (full[i]),
                .empty         (empty[i]),
                .almost_full   (almost_full[i]),
                .almost_empty  (almost_empty[i]),
                .data_out      (data_out[i*DATA_WIDTH+:DATA_WIDTH])
            );
        end
    endgenerate

endmodule
