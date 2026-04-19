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

`ifdef SYNTHESIS
	localparam USE_TSMC_64X32 = (DATA_WIDTH == 32) && (DEPTH == 64);

	generate
		if (USE_TSMC_64X32) begin : gen_tsmc_sram
			wire [DATA_WIDTH-1:0] macro_q;
			wire                  macro_ceb = ~en;
			wire                  macro_web = ~we;
			wire [DATA_WIDTH-1:0] macro_bweb = we ? {DATA_WIDTH{1'b0}} : {DATA_WIDTH{1'b1}};

			TEM5N28HPCPLVTA64X32M4SWSO u_tsmc_sram (
				.SLP (1'b0      ),
				.SD  (1'b0      ),
				.A   (addr       ),
				.D   (din        ),
				.BWEB(macro_bweb ),
				.Q   (macro_q    ),
				.WEB (macro_web  ),
				.CEB (macro_ceb  ),
				.CLK (clk        )
			);

			always @(*) begin
				if (en && !we) begin
					dout = macro_q;
				end else begin
					dout = {DATA_WIDTH{1'b0}};
				end
			end
		end else begin : gen_unsup_cfg
			always @(*) begin
				dout = {DATA_WIDTH{1'b0}};
			end
		end
	endgenerate
`else
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
`endif

endmodule
