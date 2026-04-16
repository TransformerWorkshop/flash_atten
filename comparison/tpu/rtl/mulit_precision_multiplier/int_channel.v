module int_channel #(
    parameter DATA_WIDTH = 32,
    parameter PREC_WIDTH = 4
)(
    input                       clk,
    input      [DATA_WIDTH-1:0] num1,
    input      [DATA_WIDTH-1:0] num2,
    input      [25:0]           product_mantissa,
    input                       int_en,
    input      [PREC_WIDTH-1:0] precision_mode,
    output reg [12:0]           num1_extended,
    output reg [12:0]           num2_extended,
    output reg [DATA_WIDTH-1:0] product
);

localparam INT4     = 4'd0;
localparam INT8     = 4'd1;
localparam INT4_32  = 4'd2;
localparam INT8_32  = 4'd3;
localparam FP16     = 4'd4;
localparam BF16     = 4'd5;
localparam FP32     = 4'd6;
localparam FP16_MIX = 4'd7;
localparam BF16_MIX = 4'd8;

//int4双乘法符号位
wire sign_a1b1 = num2[3] ^ num1[3];
wire sign_a2b2 = num2[7] ^ num1[7];

wire [3:0] num1_low_abs  = num1[3] ? ~num1[3:0] + 1 : num1[3:0];
wire [3:0] num2_low_abs  = num2[3] ? ~num2[3:0] + 1 : num2[3:0];
wire [3:0] num1_high_abs = num1[7] ? ~num1[7:4] + 1 : num1[7:4];
wire [3:0] num2_high_abs = num2[7] ? ~num2[7:4] + 1 : num2[7:4];

wire [7:0] a1b1 = sign_a1b1 ? (~product_mantissa[7:0] + 1)   : product_mantissa[7:0];
wire [7:0] a2b2 = sign_a2b2 ? (~product_mantissa[25:18] + 1) : product_mantissa[25:18];

//int 8
wire sign_num1 = num1[7];
wire sign_num2 = num2[7];
wire [7:0] num1_extended_8  = sign_num1 ? (~num1[7:0] + 1) : num1[7:0];
wire [7:0] num2_extended_8  = sign_num2 ? (~num2[7:0] + 1) : num2[7:0];

always @(*) begin
  if (int_en) begin
    case(precision_mode)
      INT4,INT4_32:begin//int4双乘法
        num1_extended = {num1_high_abs,5'd0,num1_low_abs};//将低位的a1 b1转换为正数
        num2_extended = {num2_high_abs,5'd0,num2_low_abs};
      end
      INT8, INT8_32:begin
        num1_extended = {5'd0,num1_extended_8};
        num2_extended = {5'd0,num2_extended_8};
      end
      default:begin
        num1_extended = 0;
        num2_extended = 0;    
      end
    endcase
  end else begin
    num1_extended = 0;
    num2_extended = 0;
  end
end

wire sign = sign_num1 ^ sign_num2;

always @(posedge clk ) begin
  if (int_en)begin
    if (precision_mode == INT4 || precision_mode == INT4_32) begin
      product <= {3'd0,{5{a2b2[7]}},a2b2, 3'd0,{5{a1b1[7]}},a1b1};
    end else begin
      product <= sign ? ~product_mantissa+1 : product_mantissa;
    end
  end
end
endmodule