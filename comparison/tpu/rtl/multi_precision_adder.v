module multi_precision_adder(
    input                      clk,
    input      [31:0]          num1,
    input      [31:0]          num2,
    input      [3:0]           precision_mode,
    input      [1:0]           location,
    output reg [31:0]          sum
);

    localparam INT4     = 4'd0;
    localparam INT8     = 4'd1;
    localparam INT4_32  = 4'd2;
    localparam INT8_32  = 4'd3;

    reg [31:0] num1_reg;
    reg [31:0] num2_reg;
    reg [3:0]  precision_mode_reg;

    reg  signed [31:0] addend1;
    reg  signed [31:0] addend2;
    wire signed [31:0] sum_32 = addend1 + addend2;

    wire int4_en = (precision_mode_reg == INT4);
    wire int8_en = (precision_mode_reg == INT8);
    wire int4_32_en = (precision_mode_reg == INT4_32);
    wire int8_32_en = (precision_mode_reg == INT8_32);
    wire int_wire = int4_en || int8_en || int4_32_en || int8_32_en;

    always @(posedge clk) begin
        num1_reg <= num1;
        num2_reg <= num2;
        precision_mode_reg <= precision_mode;
    end

    always @(*) begin
        addend1 = 32'sd0;
        addend2 = 32'sd0;

        if ((int_wire && (location == 2'd0 || location == 2'd2)) || int4_32_en || int8_32_en) begin
            addend1 = $signed(num1_reg);
            addend2 = $signed(num2_reg);
        end else if (int4_en) begin
            addend1 = {{28{num1_reg[3]}}, num1_reg[3:0]};
            addend2 = $signed(num2_reg);
        end else if (int8_en) begin
            addend1 = {{24{num1_reg[7]}}, num1_reg[7:0]};
            addend2 = $signed(num2_reg);
        end
    end

    always @(posedge clk) begin
        if (!int_wire) begin
            sum <= 32'd0;
        end else if (!addend1[31] && !addend2[31] && sum_32[31]) begin
            sum <= 32'h7fffffff;
        end else if (addend1[31] && addend2[31] && !sum_32[31]) begin
            sum <= 32'h80000000;
        end else if ((int4_en || int4_32_en) && location == 2'd0) begin
            sum <= {3'd0, sum_32[28:16], 3'd0, sum_32[12:0]};
        end else begin
            sum <= sum_32;
        end
    end
endmodule
