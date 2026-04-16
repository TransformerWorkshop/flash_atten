module fp32_channel #(
    parameter DATA_WIDTH = 32,
    parameter EXPO_WIDTH = 8 ,
    parameter MANT_WIDTH = 23
)(
    input                     clk,
    input                     rst_n,
    input                     en,//门控时钟使能
    input  [DATA_WIDTH-1:0]   num1_wire,
    input  [DATA_WIDTH-1:0]   num2_wire,
    input                     input_valid,
    input  [23:0]             product_mantissa,
    output reg [11:0]         multi_num1,
    output reg [11:0]         multi_num2,
    output reg [31:0]         product,
    output reg                output_valid//提前一个周期输出，配合PE控制
);

//reg 1
reg  [DATA_WIDTH-1:0]      num1, num2;
reg                        input_valid_r;
reg  [1:0]                 mul_phase;
reg                        mul_done, mul_done_reg1;

wire                       nan, inf_pos, inf_neg;
reg                        nan_r1, inf_pos_r1, inf_neg_r1;
reg                        nan_r2, inf_pos_r2, inf_neg_r2;

wire [MANT_WIDTH:0]        num1_mantissa, num2_mantissa;
wire                       num1_is_nan, num1_is_inf_pos, num1_is_inf_neg, num1_is_zero;
wire                       num2_is_nan, num2_is_inf_pos, num2_is_inf_neg, num2_is_zero;
wire                       num1_sign, num2_sign;
wire [EXPO_WIDTH-1:0]      num1_exponent, num2_exponent;
wire [11:0]                mant1_low, mant2_low, mant1_high, mant2_high;

reg  [EXPO_WIDTH+1:0]      exponent;//拓展2bit，最高位是符号位，第二位是进�?
reg                        sign;


reg   [EXPO_WIDTH+1:0]     exponent_r1;
reg                        sign_r1;
// reg 3
reg   [2*MANT_WIDTH+1:0]   fraction, product_mantissa_reg;
reg   [EXPO_WIDTH+1:0]     exponent_r2;
reg                        sign_r2;
reg   [4:0]                shift_num;
// reg 4
wire  [EXPO_WIDTH+1:0]     expo_diff;
wire  [EXPO_WIDTH+1:0]     shift_num_nonstd;
// reg 5
wire                       sign_final;
reg   [2*MANT_WIDTH+1:0]   fraction_final;
reg   [EXPO_WIDTH:0]       exponent_final;

reg   [1:0]                norm_case;
reg   [2:0]                product_case;

// reg 1
always @(posedge clk ) begin
    if (en)begin
        if (input_valid)begin
            num1 <= num1_wire;
            num2 <= num2_wire;
        end
    end
end

always @(posedge clk ) begin
    if(en)begin
        if (input_valid)begin
            input_valid_r <= 1;
        end else if (mul_phase == 2'b11) begin
            input_valid_r <= 0;
        end else begin
            input_valid_r <= input_valid_r;
        end
    end
end

assign mant1_low  = num1_mantissa[11:0];
assign mant2_low  = num2_mantissa[11:0];
assign mant1_high = num1_mantissa[23:12];
assign mant2_high = num2_mantissa[23:12];

////////////////////////////////
// detect inf/nan input
////////////////////////////////
assign num1_is_nan     = ((num1[30:23]==8'hff)&&(num1[22:0] != 0));          
assign num1_is_inf_pos = ((num1[30:23]==8'hff)&&(num1[22:0] == 0)&&!num1[31]); // 判断-inf
assign num1_is_inf_neg = ((num1[30:23]==8'hff)&&(num1[22:0] == 0)&& num1[31]); // 判断+inf
assign num1_is_zero    = (num1[30:0]==0);

assign num2_is_nan     = ((num2[30:23]==8'hff)&&(num2[22:0] != 0));          
assign num2_is_inf_pos = ((num2[30:23]==8'hff)&&(num2[22:0] == 0)&&!num2[31]); // 判断-inf
assign num2_is_inf_neg = ((num2[30:23]==8'hff)&&(num2[22:0] == 0)&& num2[31]); // 判断+inf
assign num2_is_zero    = (num2[30:0]==0);

assign nan = num2_is_nan || num1_is_nan || (num1_is_zero && (num2_is_inf_pos || num2_is_inf_neg)) || (num2_is_zero && (num1_is_inf_pos || num1_is_inf_neg)); // 任意输入为nan，或0×inf
wire out_is_inf =
       // �???个操作数�??? ±∞，另一个既非零也非 NaN
       ( (num1_is_inf_pos || num1_is_inf_neg) && !num2_is_zero && !num2_is_nan )
    || ( (num2_is_inf_pos || num2_is_inf_neg) && !num1_is_zero && !num1_is_nan );

assign inf_pos = out_is_inf && (num1_sign ^ num2_sign) == 1'b0 ;//  +�??? 
assign inf_neg = out_is_inf && (num1_sign ^ num2_sign) == 1'b1 ;//  -�??? 

always @(posedge clk) begin
    if (en) begin
        nan_r1     <= nan;
        inf_pos_r1 <= inf_pos;
        inf_neg_r1 <= inf_neg;
    end
end

always @(posedge clk) begin
    if (en) begin
        nan_r2     <= nan_r1;
        inf_pos_r2 <= inf_pos_r1;
        inf_neg_r2 <= inf_neg_r1;
    end
end

////////////////////////////////
// decode
////////////////////////////////
assign num1_sign     = num1[DATA_WIDTH-1];
assign num2_sign     = num2[DATA_WIDTH-1];
assign num1_exponent = (num1[DATA_WIDTH-2:DATA_WIDTH-1-EXPO_WIDTH] != 0 ) ? num1[DATA_WIDTH-2:DATA_WIDTH-1-EXPO_WIDTH] : 8'd1;
assign num2_exponent = (num2[DATA_WIDTH-2:DATA_WIDTH-1-EXPO_WIDTH] != 0 ) ? num2[DATA_WIDTH-2:DATA_WIDTH-1-EXPO_WIDTH] : 8'd1;
assign num1_mantissa = (num1[DATA_WIDTH-2:DATA_WIDTH-1-EXPO_WIDTH] != 0 ) ? {1'b1,num1[MANT_WIDTH-1:0]} : {1'b0,num1[MANT_WIDTH-1:0]};
assign num2_mantissa = (num2[DATA_WIDTH-2:DATA_WIDTH-1-EXPO_WIDTH] != 0 ) ? {1'b1,num2[MANT_WIDTH-1:0]} : {1'b0,num2[MANT_WIDTH-1:0]};

////////////////////
// calculate 
////////////////////
//reg 2
always @ (posedge clk) begin
    if (en) begin
        exponent <= num1_exponent + num2_exponent - 127;
        sign <= num1_sign ^ num2_sign;
    end
end

//  打一拍
always @ (posedge clk) begin
    if (en)begin
        exponent_r1 <= exponent;
        sign_r1     <= sign;
    end
end

//  打第二拍
always @ (posedge clk) begin
    if (en)begin
        exponent_r2 <= exponent_r1;
        sign_r2     <= sign_r1;
    end
end

// ----- 乘法器输入选择逻辑 -----
always @(*) begin
    case (mul_phase)
        2'b00: begin  // MUL1: A_H * B_H
            multi_num1 = mant1_high;
            multi_num2 = mant2_high;
        end
        2'b01: begin  // MUL2: A_H * B_L
            multi_num1 = mant1_high;
            multi_num2 = mant2_low;
        end
        2'b10: begin  // MUL3: A_L * B_H
            multi_num1 = mant1_low;
            multi_num2 = mant2_high;
        end
        default: begin  // MUL4: A_L * B_L
            multi_num1 = mant1_low;
            multi_num2 = mant2_low;
        end
    endcase
end

// reg 2 - 4
// ----- 乘法处理逻辑 -----
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        mul_phase <= 2'b00;
    end else if (en)begin
        mul_done <= 1'b0;
        if (input_valid_r) begin
            case (mul_phase)
                2'b00: begin  // MUL1: A_H * B_H
                    product_mantissa_reg <= {product_mantissa,24'd0}; 
                    mul_phase <= 2'b01;
                end
                2'b01: begin  // MUL2: A_H * B_L
                    product_mantissa_reg <= {12'd0, product_mantissa,12'd0};
                    mul_phase <= 2'b10;
                end
                2'b10: begin  // MUL3: A_L * B_H
                    product_mantissa_reg <= {12'd0, product_mantissa,12'd0};
                    mul_phase <= 2'b11;
                end
                2'b11: begin  // MUL4: A_L * B_L
                    product_mantissa_reg <= {24'd0,product_mantissa};
                    // 完成乘法
                    mul_done <= 1'b1;
                    
                    // 重置乘法阶段
                    mul_phase <= 2'b00;
                end
            endcase
        end
    end
end

always @ (posedge clk) begin
    if (en) begin
        if (mul_phase==2'b01) begin
            fraction <= product_mantissa_reg;
        end else begin
            fraction <= fraction + product_mantissa_reg;
        end
    end
end

/////////////////////////////////////
// Detect the first 1 in the sequence
/////////////////////////////////////
always @(*) begin
    casez (fraction[47:23])//想要规格化，尾数需要左移的位数
        25'b1????????????????????????: shift_num = 6'd1;
        25'b01???????????????????????: shift_num = 6'd2;
        25'b001??????????????????????: shift_num = 6'd3;
        25'b0001?????????????????????: shift_num = 6'd4;
        25'b00001????????????????????: shift_num = 6'd5;
        25'b000001???????????????????: shift_num = 6'd6;
        25'b0000001??????????????????: shift_num = 6'd7;
        25'b00000001?????????????????: shift_num = 6'd8;
        25'b000000001????????????????: shift_num = 6'd9;
        25'b0000000001???????????????: shift_num = 6'd10;
        25'b00000000001??????????????: shift_num = 6'd11;
        25'b000000000001?????????????: shift_num = 6'd12;
        25'b0000000000001????????????: shift_num = 6'd13;
        25'b00000000000001???????????: shift_num = 6'd14;
        25'b000000000000001??????????: shift_num = 6'd15;
        25'b0000000000000001?????????: shift_num = 6'd16;
        25'b00000000000000001????????: shift_num = 6'd17;
        25'b000000000000000001???????: shift_num = 6'd18;
        25'b0000000000000000001??????: shift_num = 6'd19;
        25'b00000000000000000001?????: shift_num = 6'd20;
        25'b000000000000000000001????: shift_num = 6'd21;
        25'b0000000000000000000001???: shift_num = 6'd22;
        25'b00000000000000000000001??: shift_num = 6'd23;
        25'b000000000000000000000001?: shift_num = 6'd24;
        25'b0000000000000000000000001: shift_num = 6'd25;
        default: shift_num = 6'd0;
    endcase
end


///////////////////////////////////////////
// calculate the parameter of normalization
///////////////////////////////////////////
//阶码 + 2 - 平移数，以确认输出是规格数还是非规格
assign expo_diff        = exponent_r2 + 2'd2 - shift_num;
assign shift_num_nonstd = exponent_r2 + 1'b1;//左移至exp=1，左移n位，exp=2-n
assign sign_final       = sign_r2;

///////////////////////////////////////////
// normalization
///////////////////////////////////////////

always @ (*) begin
	if (exponent_r2[EXPO_WIDTH+1] == 1) begin //exp < 0 必定是非规格数，移位使阶码为1
		norm_case = 2'd0;
	end else if (fraction == 48'd0) begin
        norm_case = 2'd1;
    end else if (expo_diff[EXPO_WIDTH+1] == 1 || expo_diff==0) begin //<= 0说明是非规格�?
        norm_case = 2'd2;
    end else begin //>0 说明是规�?
        norm_case = 2'd3;
    end
end

wire [9:0] diff = ~(exponent_r2-1) - 1'd1;
always @ (*) begin
    case (norm_case)
	2'd0: fraction_final = fraction >> diff;//必定是非规格数，操作步骤�?? 移位使阶码为1
    2'd1: fraction_final = 0;
    2'd2: fraction_final = fraction << shift_num_nonstd;//<=0 说明是非规格
    2'd3: fraction_final = fraction << shift_num;//>= 0说明是规格数
    endcase
end

always @ (*) begin
    case (norm_case)//必定是非规格数，操作步骤�?? 移位使阶码为1
	2'd3:    exponent_final = expo_diff;
    default: exponent_final = 0;
    endcase
end

// reg 7
///////////////////////////////////
// overflow detect and ouput select
//////////////////////////////////

always @ (*) begin
    if (exponent_final>254 & !nan_r2) begin
		product_case = 3'd0;
    end else if (nan_r2) begin
        product_case = 3'd1;
    end else if (inf_pos_r2) begin
        product_case = 3'd2;
    end else if (inf_neg_r2) begin
        product_case = 3'd3;
    end else begin
		product_case = 3'd4;
	end
end

always @ (posedge clk) begin
    if (en) begin
    case (product_case)
        3'd0: product <= {sign_final, 8'hFF, 23'h0};
        3'd1: product <= {1'b0, 8'hFF, 23'h7FFFFF};
        3'd2: product <= {1'b0, 8'hFF, 23'h0};
        3'd3: product <= {1'b1, 8'hFF, 23'h0};
        default: product <= {sign_final, exponent_final[EXPO_WIDTH-1:0], 
                fraction_final[MANT_WIDTH*2+1 -: MANT_WIDTH]};
        endcase
    end
end

//打一拍等待加法
always @(posedge clk ) begin
    if (en)
    mul_done_reg1 <= mul_done;
end

always @(posedge clk ) begin
    if (en)
    output_valid <= mul_done_reg1;
end
endmodule