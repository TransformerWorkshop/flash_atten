module mux4to1_mul #(
    parameter DATA_WIDTH = 26,
    parameter PREC_WIDTH = 4
)(
    input       [DATA_WIDTH-1:0] fp16,
    input       [DATA_WIDTH-1:0] bf16,
    //input       [DATA_WIDTH-1:0] fp32,
    input       [DATA_WIDTH-1:0] int_wire,
    input       [PREC_WIDTH-1:0] precision_mode,
    output  reg [DATA_WIDTH-1:0] result                 
);

localparam INT4     = 4'd0;
localparam INT8     = 4'd1;
localparam INT4_32  = 4'd2;
localparam INT8_32  = 4'd3;
localparam FP16     = 4'd4;
localparam BF16     = 4'd5;
//localparam FP32     = 4'd6;
localparam FP16_MIX = 4'd7;
localparam BF16_MIX = 4'd8;


always @(*)begin
    case(precision_mode)
        INT4,INT8,INT4_32,INT8_32: result = int_wire;
        FP16,FP16_MIX:             result = fp16;
        BF16,BF16_MIX:             result = bf16;
        //FP32:                      result = fp32;
        default:                   result = 0; 
    endcase
end

endmodule