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
	output wire [ DATA_WIDTH-1:0] dout_a,
	// Port B
	input  wire                  en_b  ,
	input  wire                  we_b  ,
	input  wire [ADDR_WIDTH-1:0] addr_b,
	input  wire [ DATA_WIDTH-1:0] din_b ,
	output wire [ DATA_WIDTH-1:0] dout_b
);

	reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

	integer mi;
	initial begin
		for (mi = 0; mi < DEPTH; mi = mi + 1) begin
			mem[mi] = {DATA_WIDTH{1'b0}};
		end
	end

	always @(posedge clk) begin
		if (en_a && we_a) begin
			mem[addr_a] <= din_a;
		end
		if (en_b && we_b) begin
			mem[addr_b] <= din_b;
		end
	end

	// Combinational read behavior to match current PT datapath timing.
	assign dout_a = en_a ? mem[addr_a] : {DATA_WIDTH{1'b0}};
	assign dout_b = en_b ? mem[addr_b] : {DATA_WIDTH{1'b0}};

endmodule

