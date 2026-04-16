module ram_array #(
    parameter PE_SIZE        = 8 ,   // PE数量/阵列大小
    parameter RAM_ADDR_WIDTH = 12,   // RAM地址宽度
    parameter RAM_DATA_WIDTH = 32    // RAM数据宽度
) (
    // 全局时钟
    input wire                                   clk            ,

    // 写接口
    input wire  [                   PE_SIZE-1:0] ram_wr_en      ,
    input wire  [    RAM_ADDR_WIDTH*PE_SIZE-1:0] ram_wr_addr    ,
    input wire  [    RAM_DATA_WIDTH*PE_SIZE-1:0] ram_wr_data    ,
    input wire  [(RAM_DATA_WIDTH/8)*PE_SIZE-1:0] ram_wr_strb    ,

    // 读接口
    input  wire [                   PE_SIZE-1:0] ram_rd_en      ,
    input  wire [    RAM_ADDR_WIDTH*PE_SIZE-1:0] ram_rd_addr    ,
    output wire [    RAM_DATA_WIDTH*PE_SIZE-1:0] ram_rd_data     
);

    // 生成PE_SIZE个sdp_ram实例
    genvar i;
    generate
        for (i = 0; i < PE_SIZE; i = i + 1) begin : ram_instances
            sdp_ram #(
                .RAM_DATA_WIDTH(RAM_DATA_WIDTH),
                .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH)
            ) u_ram (
                .clk        (clk),
                .wr_en      (ram_wr_en[i]),
                .wr_addr    (ram_wr_addr[i*RAM_ADDR_WIDTH+:RAM_ADDR_WIDTH]),
                .wr_data    (ram_wr_data[i*RAM_DATA_WIDTH+:RAM_DATA_WIDTH]),
                .wr_strb    (ram_wr_strb[i*(RAM_DATA_WIDTH/8)+:(RAM_DATA_WIDTH/8)]),
                .rd_en      (ram_rd_en[i]),
                .rd_addr    (ram_rd_addr[i*RAM_ADDR_WIDTH+:RAM_ADDR_WIDTH]),
                .rd_data    (ram_rd_data[i*RAM_DATA_WIDTH+:RAM_DATA_WIDTH])
            );
        end
    endgenerate

endmodule
