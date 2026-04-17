module adder_array_8 #(
    parameter DATA_WIDTH = 32,
    parameter PE_SIZE    = 16,
    parameter PREC_WIDTH = 4
)(
    input                         clk,
    input     [PREC_WIDTH-1:0]    precision_mode,
    input     [DATA_WIDTH*PE_SIZE*2-1:0] num_in,
    output    [DATA_WIDTH*PE_SIZE-1:0]   num_out
);

reg  [DATA_WIDTH-1:0] mem      [0:PE_SIZE*2-1];

wire [DATA_WIDTH-1:0] out      [0:PE_SIZE-1];
reg  [DATA_WIDTH*PE_SIZE-1:0] out_all;

assign num_out = out_all;
integer k,j;
always @(*) begin
    for (k = 0; k < (PE_SIZE * 2); k = k + 1) begin
        mem[k] = num_in[k*DATA_WIDTH +: DATA_WIDTH];
    end
end

always @(*) begin
    for (j = 0; j < PE_SIZE; j = j + 1) begin
        out_all[j*DATA_WIDTH +: DATA_WIDTH] = out[j];
    end
end

genvar i;
generate
    for (i = 0; i < (PE_SIZE * 2); i = i + 2) begin : gen_mixed_adder_8
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
