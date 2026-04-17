module delay_array #(
    parameter PE_SIZE         = 16,
    parameter DATA_WIDTH      = 32 
) (
    // 时钟和复位
    input  wire                          clk           ,
    input  wire                          rst_n         ,

    input  wire [           PE_SIZE-1:0] wr_en         ,
    input  wire [DATA_WIDTH*PE_SIZE-1:0] data_in       ,

    output wire [DATA_WIDTH*PE_SIZE-1:0] data_out       
);

    wire delay_en = |wr_en  ;// 延迟链使能信号

    genvar i;
    generate
        for (i = 0; i < PE_SIZE; i = i + 1) begin : u_delay
            data_delay #(
                .DATA_WIDTH  (DATA_WIDTH),
                .DELAY_STAGES(i)
            ) u_data_delay (
                .clk     (clk),
                .rst_n   (rst_n),
                .en      (delay_en),                           // 连接使能信号
                .data_in (data_in[i*DATA_WIDTH +: DATA_WIDTH]),
                .data_out(data_out[i*DATA_WIDTH +: DATA_WIDTH])
            );
        end
    endgenerate

endmodule
