module SHIFT_REG #(
	parameter WIDTH    = 32,
	parameter DEPTH    = 4 ,
	parameter USE_SIPO = 0
) (
	input  wire                   clk          ,
	input  wire                   rstn         ,
	input  wire                   clear        , // Optional soft reset for shift register contents
	input  wire [      WIDTH-1:0] data_in      ,
	input  wire                   valid_in     ,
	output wire                   ready_in     ,
	// SIPO interface
	output      [DEPTH*WIDTH-1:0] sipo_data_out,
	input       [      DEPTH-1:0] sipo_ready   ,
	output      [      DEPTH-1:0] sipo_valid   ,
	// SISO interface
	output      [      WIDTH-1:0] siso_data_out,
	input                         siso_ready   ,
	output                        siso_valid
);

	reg  [WIDTH-1:0] shift_reg    [0:DEPTH-1];
	reg              valid_reg    [0:DEPTH-1];
	wire [DEPTH-1:0] valid_vec               ;
	wire             siso_shift_ok           ;
	wire             sipo_shift_ok           ;
	wire             shift_en                ;

	assign siso_data_out = shift_reg[DEPTH-1];
	assign siso_shift_ok = ~valid_reg[DEPTH-1] | siso_ready;
	assign sipo_shift_ok = &((~valid_vec) | sipo_ready); // Only shift when all stages are either empty or ready to accept new data
	assign shift_en      = (USE_SIPO != 0) ? sipo_shift_ok : siso_shift_ok;
	assign ready_in      = shift_en;
	assign siso_valid    = valid_reg[DEPTH-1];

	genvar i;
	generate
		for (i = 0; i < DEPTH; i = i + 1) begin : gen_sipo
			assign valid_vec[i]                         = valid_reg[i];
			assign sipo_data_out[(i+1)*WIDTH-1:i*WIDTH] = shift_reg[i];
			assign sipo_valid[i]                        = valid_reg[i];
		end
	endgenerate

	integer j;
	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			for (j = 0; j < DEPTH; j = j + 1) begin
				shift_reg[j] <= {WIDTH{1'b0}};
				valid_reg[j] <= 1'b0;
			end
		end else if (clear) begin
			for (j = 0; j < DEPTH; j = j + 1) begin
				shift_reg[j] <= {WIDTH{1'b0}};
				valid_reg[j] <= 1'b0;
			end
		end else if (shift_en) begin
			shift_reg[0] <= data_in;
			valid_reg[0] <= valid_in;

			for (j = 1; j < DEPTH; j = j + 1) begin
				shift_reg[j] <= shift_reg[j-1];
				valid_reg[j] <= valid_reg[j-1];
			end
		end
	end
endmodule