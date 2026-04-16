module adder_array_8 #(
    parameter DATA_WIDTH = 32,
    parameter PREC_WIDTH = 4
)(
    input                         clk,
    input     [PREC_WIDTH-1:0]    precision_mode,
    input     [DATA_WIDTH*16-1:0] num_16,
    output    [DATA_WIDTH*8-1:0]  num_8
);

reg  [31:0]  mem      [0:15];

wire [31:0]  out      [0:7] ;
reg  [255:0] out_all        ;

assign num_8 = out_all;
integer k,j;
always @(*) begin
    for (k = 0; k<16; k = k+1) begin
        mem[k] = num_16[k*DATA_WIDTH +: 32];
    end
end

always @(*) begin
    for (j = 0; j<8; j = j+1) begin
        out_all[j*DATA_WIDTH +: 32] = out[j];
    end
end

genvar i;
generate
    // for (i = 0; i < 16; i = i + 2) begin : gen_mixed_adder_8
    //     // 例化模块
    //     multi_precision_adder #(
    //         .DATA_WIDTH(DATA_WIDTH)
    //     )u_multi_precision_adder(
    //         .clk             (clk)           ,
    //         .num1            (mem[i])        ,
    //         .num2            (mem[i+1])      ,
    //         .precision_mode  (precision_mode),
    //         .location        (1'b1)             ,
    //         .sum             (out[i>>1])    
    //     );
    // end
    for (i = 0; i < 16; i = i + 2) begin : gen_mixed_adder_8
        // 例化模块
        multi_precision_adder u_multi_precision_adder(
            .clk             (clk)           ,
            .num1            (mem[i])        ,
            .num2            (mem[i+1])      ,
            .precision_mode  (precision_mode),
            .location        (2'd1)          ,
            .sum             (out[i>>1])    
        );
    end
endgenerate

endmodule