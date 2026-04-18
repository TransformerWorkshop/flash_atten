module sram #(
	parameter DATA_WIDTH = 32,
	parameter DEPTH      = 16,
	parameter ADDR_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
	input  wire                  clk ,
	input  wire                  en  ,
	input  wire                  we  ,
	input  wire [ADDR_WIDTH-1:0] addr,
	input  wire [ DATA_WIDTH-1:0] din ,
	output reg  [ DATA_WIDTH-1:0] dout
);

	reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

	always @(posedge clk) begin
		if (en) begin
			if (we) begin
				mem[addr] <= din;
				dout <= {DATA_WIDTH{1'b0}};
			end else begin
				dout <= mem[addr];
			end
		end else begin
			dout <= {DATA_WIDTH{1'b0}};
		end
	end

endmodule
