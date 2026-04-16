module fp16_channel #(
    parameter DATA_WIDTH = 16,
    parameter EXPO_WIDTH = 5 ,
    parameter MANT_WIDTH = 10
)(
    input                     clk,
    input                     en,//门控时钟使能
    input  [DATA_WIDTH-1:0]   num1,
    input  [DATA_WIDTH-1:0]   num2,
    input  [2*MANT_WIDTH+1:0] product_mantissa,
    output [MANT_WIDTH:0]     multi_num1,
    output [MANT_WIDTH:0]     multi_num2,
    output reg [DATA_WIDTH-1:0]         product
);

wire                       nan, inf_pos, inf_neg;
wire [MANT_WIDTH:0]        num1_mantissa, num2_mantissa;
wire                       num1_is_nan, num1_is_inf_pos, num1_is_inf_neg, num1_is_zero;
wire                       num2_is_nan, num2_is_inf_pos, num2_is_inf_neg, num2_is_zero;
wire                       num1_sign, num2_sign;
wire [EXPO_WIDTH-1:0]      num1_exponent, num2_exponent;

reg  [EXPO_WIDTH+1:0]      exponent;//拓展2bit，最高位是符号位，第二位是进位
reg                        sign;
reg                        nan_r, inf_pos_r, inf_neg_r;

// reg 2
reg   [2*MANT_WIDTH+1:0]   fraction;
reg   [3:0]                shift_num;
// reg 3
wire  [EXPO_WIDTH+1:0]     expo_diff;
wire  [EXPO_WIDTH+1:0]     shift_num_nonstd;

wire                       sign_final;
reg   [2*MANT_WIDTH+1:0]   fraction_final;
reg   [EXPO_WIDTH:0]       exponent_final;

reg   [1:0]                norm_case;
reg   [2:0]                product_case;

////////////////////////////////
// detect inf/nan input
////////////////////////////////

assign multi_num1 = num1_mantissa;//bit extension for MUX
assign multi_num2 = num2_mantissa;

assign num1_is_nan     = ((num1[14:10]==5'b11111)&(num1[9:0] != 0));          
assign num1_is_inf_pos = ((num1[14:10]==5'b11111)&(num1[9:0] == 0)&!num1[15]); // 判断-inf
assign num1_is_inf_neg = ((num1[14:10]==5'b11111)&(num1[9:0] == 0)& num1[15]); // 判断+inf
assign num1_is_zero    = (num1[14:0]==0);

assign num2_is_nan     = ((num2[14:10]==5'b11111)&(num2[9:0] != 0));          
assign num2_is_inf_pos = ((num2[14:10]==5'b11111)&(num2[9:0] == 0)&!num2[15]); // 判断-inf
assign num2_is_inf_neg = ((num2[14:10]==5'b11111)&(num2[9:0] == 0)& num2[15]); // 判断+inf
assign num2_is_zero    = (num2[14:0]==0);

assign nan = num2_is_nan | num1_is_nan | (num1_is_zero & (num2_is_inf_pos | num2_is_inf_neg)) | (num2_is_zero & (num1_is_inf_pos | num1_is_inf_neg)); // 任意输入为nan，或0×inf
wire out_is_inf =
       // �?个操作数�? ±∞，另一个既非零也非 NaN
       ( (num1_is_inf_pos || num1_is_inf_neg) && !num2_is_zero && !num2_is_nan )
    || ( (num2_is_inf_pos || num2_is_inf_neg) && !num1_is_zero && !num1_is_nan );

assign inf_pos = out_is_inf && (num1_sign ^ num2_sign) == 1'b0 ;//  +�? 
assign inf_neg = out_is_inf && (num1_sign ^ num2_sign) == 1'b1 ;//  -�? 

always @(posedge clk) begin // 打拍至最后一级，用于溢出检测
    nan_r     <= nan;
    inf_pos_r <= inf_pos;
    inf_neg_r <= inf_neg;
end

////////////////////////////////
// decode
////////////////////////////////

assign num1_sign     = num1[DATA_WIDTH-1];
assign num2_sign     = num2[DATA_WIDTH-1];
assign num1_exponent = (num1[DATA_WIDTH-2:DATA_WIDTH-1-EXPO_WIDTH] != 0 ) ? num1[DATA_WIDTH-2:DATA_WIDTH-1-EXPO_WIDTH] : 5'd1;
assign num2_exponent = (num2[DATA_WIDTH-2:DATA_WIDTH-1-EXPO_WIDTH] != 0 ) ? num2[DATA_WIDTH-2:DATA_WIDTH-1-EXPO_WIDTH] : 5'd1;
assign num1_mantissa = (num1[DATA_WIDTH-2:DATA_WIDTH-1-EXPO_WIDTH] != 0 ) ? {1'b1,num1[MANT_WIDTH-1:0]} : {1'b0,num1[MANT_WIDTH-1:0]};//9:0
assign num2_mantissa = (num2[DATA_WIDTH-2:DATA_WIDTH-1-EXPO_WIDTH] != 0 ) ? {1'b1,num2[MANT_WIDTH-1:0]} : {1'b0,num2[MANT_WIDTH-1:0]};

////////////////////
// calculate 
////////////////////
//reg 2
always @(posedge clk ) begin
    if(en) begin
        sign <= num1_sign ^ num2_sign;
    end
end

always @ (posedge clk) begin
    if(en) begin
	    exponent <= num1_exponent + num2_exponent - 6'sd15;
    end
end

always @(posedge clk ) begin
    if(en) begin
        fraction <= product_mantissa;
    end
end

/////////////////////////////////////
// Detect the first 1 in the sequence
/////////////////////////////////////
always @(*) begin
    casez (fraction[21:10])
        12'b1???????????: shift_num = 4'd1;
        12'b01??????????: shift_num = 4'd2;
        12'b001?????????: shift_num = 4'd3;
        12'b0001????????: shift_num = 4'd4;
        12'b00001???????: shift_num = 4'd5;
        12'b000001??????: shift_num = 4'd6;
        12'b0000001?????: shift_num = 4'd7;
        12'b00000001????: shift_num = 4'd8;
        12'b000000001???: shift_num = 4'd9;
        12'b0000000001??: shift_num = 4'd10;
        12'b00000000001?: shift_num = 4'd11;
        12'b000000000001: shift_num = 4'd12;
        default: shift_num = 4'd0;
    endcase
end


///////////////////////////////////////////
// calculate the parameter of normalization
///////////////////////////////////////////
// reg 3
//阶码 + 2 - 平移数，以确认输出是规格数还是非规格
assign expo_diff        = exponent + 2'd2 - shift_num;
assign shift_num_nonstd = exponent + 1'b1;//左移至exp=1，左移n位，exp=2-n
assign sign_final       = sign;
///////////////////////////////////////////
// normalization
///////////////////////////////////////////
always @ (*) begin
	if (exponent[EXPO_WIDTH+1] == 1) begin //exp < 0 必定是非规格数，移位使阶码为1
		norm_case = 2'd0;
	end else if (fraction == 22'd0) begin
        norm_case = 2'd1;
    end else if (expo_diff[EXPO_WIDTH+1] == 1 || expo_diff==0) begin //<= 0说明是非规格数
        norm_case = 2'd2;
    end else begin //>0 说明是规格
        norm_case = 2'd3;
    end
end

wire [6:0] diff = ~(exponent-1) - 1'd1;
always @ (*) begin
    case (norm_case)
	2'd0: fraction_final = fraction >> diff;//必定是非规格数，操作步骤�? 移位使阶码为1
    2'd1: fraction_final = 0;
    2'd2: fraction_final = fraction << shift_num_nonstd;//<=0 说明是非规格
    2'd3: fraction_final = fraction << shift_num;//>= 0说明是规格数
    endcase
end

always @ (*) begin
    case (norm_case)//必定是非规格数，操作步骤�? 移位使阶码为1
	2'd3:    exponent_final = expo_diff;
    default: exponent_final = 0;
    endcase
end

////////////////////////
// overflow detect
///////////////////////
always @ (*) begin
    if (exponent_final>30 & !nan_r) begin
		product_case = 3'd0;
    end else if (nan_r) begin
        product_case = 3'd1;
    end else if (inf_pos_r) begin
        product_case = 3'd2;
    end else if (inf_neg_r) begin
        product_case = 3'd3;
    end else begin
		product_case = 3'd4;
	end
end

always @ (posedge clk) begin
    if (en) begin
        case (product_case)
        3'd0: product <= {sign_final, 5'h1F, 10'h0};
        3'd1: product <= {1'b0, 5'h1F, 10'h3FF};
        3'd2: product <= {1'b0, 5'h1F, 10'h0};
        3'd3: product <= {1'b1, 5'h1F, 10'h0};
        default: product <= {sign_final, exponent_final[EXPO_WIDTH-1:0], 
                fraction_final[MANT_WIDTH*2+1 -: MANT_WIDTH]};
        endcase
    end
end

endmodule
