module tree_adder #(
    parameter DATA_WIDTH = 32,
    parameter PREC_WIDTH = 4,
    parameter ROW_IDX    = 0
)(
    input                      clk,
    input  [PREC_WIDTH-1:0]    precision_mode,
    input  [DATA_WIDTH*8-1:0]  num,
    output [DATA_WIDTH-1:0]    out
);

wire [DATA_WIDTH*4-1:0] num_4;
wire [DATA_WIDTH*2-1:0] num_2;

reg [PREC_WIDTH-1:0] precision_mode_reg;
// 寄存减少信号扇出
always @(posedge clk) begin
    precision_mode_reg <= precision_mode;
end


genvar j;  
generate
    for (j = 0; j < 8; j = j + 2) begin : gen_mixed_adder_4
        // 例化模块
        // multi_precision_adder #(
        //     .DATA_WIDTH(DATA_WIDTH)
        // )u_multi_precision_adder_4(
        //     .clk             (clk),
        //     .num1            (num[j*DATA_WIDTH +: DATA_WIDTH]),
        //     .num2            (num[(j+1)*DATA_WIDTH +: DATA_WIDTH]),
        //     .precision_mode  (precision_mode_reg),
        //     .location        (1'b0)                 ,
        //     .sum             (num_4[(j/2)*DATA_WIDTH +: DATA_WIDTH])   
        // );
        multi_precision_adder u_multi_precision_adder_4(
            .clk             (clk),
            .num1            (num[j*DATA_WIDTH +: DATA_WIDTH]),
            .num2            (num[(j+1)*DATA_WIDTH +: DATA_WIDTH]),
            .precision_mode  (precision_mode_reg),
            .location        (2'd0)                 ,
            .sum             (num_4[(j/2)*DATA_WIDTH +: DATA_WIDTH])   
        );
    end
endgenerate

genvar k;  
generate
    for (k = 0; k < 4; k = k + 2) begin : gen_mixed_adder_2
        // 例化模块
        // multi_precision_adder #(
        //     .DATA_WIDTH(DATA_WIDTH)
        // )u_multi_precision_adder_2(
        //     .clk             (clk),
        //     .num1            (num_4[k*DATA_WIDTH +: DATA_WIDTH]),
        //     .num2            (num_4[(k+1)*DATA_WIDTH +: DATA_WIDTH]),
        //     .precision_mode  (precision_mode_reg),
        //     .location        (1'b0)                 ,
        //     .sum             (num_2[(k/2)*DATA_WIDTH +: DATA_WIDTH])  
        // );
        multi_precision_adder u_multi_precision_adder_2(
            .clk             (clk),
            .num1            (num_4[k*DATA_WIDTH +: DATA_WIDTH]),
            .num2            (num_4[(k+1)*DATA_WIDTH +: DATA_WIDTH]),
            .precision_mode  (precision_mode_reg),
            .location        (2'd0)                 ,
            .sum             (num_2[(k/2)*DATA_WIDTH +: DATA_WIDTH])  
        );
    end
endgenerate

// multi_precision_adder #(
//         .DATA_WIDTH(DATA_WIDTH)
//     )u_multi_precision_adder_2(
//     .clk             (clk),
//     .num1            (num_2[DATA_WIDTH-1:0]),
//     .num2            (num_2[2*DATA_WIDTH-1:DATA_WIDTH]),
//     .precision_mode  (precision_mode_reg),
//     .location        (1'b0)                 ,
//     .sum             (out)   
// );

multi_precision_adder u_multi_precision_adder_2(
    .clk             (clk),
    .num1            (num_2[DATA_WIDTH-1:0]),
    .num2            (num_2[2*DATA_WIDTH-1:DATA_WIDTH]),
    .precision_mode  (precision_mode_reg),
    .location        (2'd0)                 ,
    .sum             (out)   
);
endmodule