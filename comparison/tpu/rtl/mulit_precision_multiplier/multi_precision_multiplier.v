module multi_precision_multiplier#(
    parameter DATA_WIDTH = 32,
    parameter PREC_WIDTH = 4
)(
    input                        clk,
    input                        rst_n,
    input                        input_valid,
    input      [DATA_WIDTH-1:0]  num1,
    input      [DATA_WIDTH-1:0]  num2,
    input      [PREC_WIDTH-1:0]  precision_mode,
    output     [DATA_WIDTH-1:0]  product,
    output                       output_valid
);
localparam INT4     = 4'd0;
localparam INT8     = 4'd1;
localparam INT4_32  = 4'd2;
localparam INT8_32  = 4'd3;

reg  [DATA_WIDTH-1:0] num1_reg, num2_reg;
wire [DATA_WIDTH-1:0] product_int;
wire [12:0]           multi_num1_int, multi_num2_int;
wire [25:0]           product_mantissa;

wire int_en  = (precision_mode == INT4)
            || (precision_mode == INT8)
            || (precision_mode == INT4_32)
            || (precision_mode == INT8_32);

always @(posedge clk ) begin
    num1_reg <= num1;
    num2_reg <= num2;
end

// Preserve the validated integer datapath and timing.
int_channel #(
    .DATA_WIDTH(32),
    .PREC_WIDTH(PREC_WIDTH)
) int_channel_inst (
    .clk              (clk),
    .int_en           (int_en),
    .num1             (num1_reg),
    .num2             (num2_reg),
    .precision_mode   (precision_mode),
    .num1_extended    (multi_num1_int),
    .num2_extended    (multi_num2_int),
    .product_mantissa (product_mantissa),
    .product          (product_int)
);

assign product_mantissa = multi_num1_int * multi_num2_int;
assign product = product_int;
assign output_valid = 1'b0;
endmodule
