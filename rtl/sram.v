module sram #(
	parameter DATA_WIDTH = 32,
	parameter DEPTH      = 16,
	parameter ADDR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
	input  wire                  clk   ,
	// Port A
	input  wire                  en_a  ,
	input  wire                  we_a  ,
	input  wire [ADDR_WIDTH-1:0] addr_a,
	input  wire [ DATA_WIDTH-1:0] din_a ,
	output reg  [ DATA_WIDTH-1:0] dout_a,
	// Port B
	input  wire                  en_b  ,
	input  wire                  we_b  ,
	input  wire [ADDR_WIDTH-1:0] addr_b,
	input  wire [ DATA_WIDTH-1:0] din_b ,
	output reg  [ DATA_WIDTH-1:0] dout_b
);

	reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

	always @(posedge clk) begin
		if (en_a && we_a) begin
			mem[addr_a] <= din_a;
		end
		if (en_b && we_b) begin
			mem[addr_b] <= din_b;
		end
		if (en_a) begin
			dout_a <= mem[addr_a];
		end else begin
			dout_a <= {DATA_WIDTH{1'b0}};
		end
		if (en_b) begin
			dout_b <= mem[addr_b];
		end else begin
			dout_b <= {DATA_WIDTH{1'b0}};
		end
	end

endmodule
