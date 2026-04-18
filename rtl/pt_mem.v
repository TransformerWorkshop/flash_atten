module PT_MEM_BANK #(
	parameter DATA_WIDTH = 32,
	parameter LANES      = 4 ,
	parameter DEPTH      = 16
) (
	input  wire                            clk     ,
	input  wire                            rstn    ,
	input  wire                            clear   ,
	input  wire                            wr_en   ,
	input  wire                            wr_buf  ,
	input  wire [LANES-1:0]                wr_mask ,
	input  wire [$clog2(DEPTH)-1:0]        wr_addr ,
	input  wire [LANES*DATA_WIDTH-1:0]     wr_data ,
	input  wire                            rd_en   ,
	input  wire                            rd_buf  ,
	input  wire [$clog2(DEPTH)-1:0]        rd_addr ,
	output reg  [LANES*DATA_WIDTH-1:0]     rd_data
);

	localparam integer TOTAL_LANES = 2 * LANES;
	localparam integer ADDR_W      = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

	wire [DATA_WIDTH-1:0] lane_rd_ping [0:LANES-1];
	wire [DATA_WIDTH-1:0] lane_rd_pong [0:LANES-1];

	genvar gi;
	generate
		for (gi = 0; gi < TOTAL_LANES; gi = gi + 1) begin : gen_sram_bank
			localparam integer LANE_IDX = (gi < LANES) ? gi : (gi - LANES);
			wire this_wr_hit = wr_en &&
			                   wr_mask[LANE_IDX] &&
			                   (wr_buf ? (gi >= LANES) : (gi < LANES));
			wire this_rd_hit = rd_en &&
			                   (rd_buf ? (gi >= LANES) : (gi < LANES));

			wire [DATA_WIDTH-1:0] dout_a_i;
			wire [DATA_WIDTH-1:0] dout_b_i;

			sram #(
				.DATA_WIDTH(DATA_WIDTH),
				.DEPTH     (DEPTH),
				.ADDR_WIDTH(ADDR_W)
			) u_sram (
				.clk   (clk             ),
				.en_a  (this_wr_hit     ),
				.we_a  (this_wr_hit     ),
				.addr_a(wr_addr         ),
				.din_a (wr_data[LANE_IDX*DATA_WIDTH +: DATA_WIDTH]),
				.dout_a(dout_a_i        ),
				.en_b  (this_rd_hit     ),
				.we_b  (1'b0            ),
				.addr_b(rd_addr         ),
				.din_b ({DATA_WIDTH{1'b0}}),
				.dout_b(dout_b_i        )
			);

			if (gi < LANES) begin : gen_rd_pack0
				assign lane_rd_ping[gi] = dout_b_i;
			end else begin : gen_rd_pack1
				assign lane_rd_pong[gi-LANES] = dout_b_i;
			end
		end
	endgenerate

	integer ri;
	always @(*) begin
		rd_data = {LANES*DATA_WIDTH{1'b0}};
		for (ri = 0; ri < LANES; ri = ri + 1) begin
			rd_data[ri*DATA_WIDTH +: DATA_WIDTH] = rd_buf ? lane_rd_pong[ri] : lane_rd_ping[ri];
		end
	end

endmodule

module PT_M_MEM #(
	parameter DATA_WIDTH = 32,
	parameter B_LANES    = 4 ,
	parameter DEPTH      = 16,
	parameter M_PHYSICAL_COPIES = 2
) (
	input  wire                            clk      ,
	input  wire                            rstn     ,
	input  wire                            clear    ,
	input  wire                            wr_en    ,
	input  wire                            wr_buf   ,
	input  wire [B_LANES-1:0]              wr_mask  ,
	input  wire [$clog2(DEPTH)-1:0]        wr_addr  ,
	input  wire [B_LANES*DATA_WIDTH-1:0]   wr_data  ,
	input  wire                            rd_b_en  ,
	input  wire                            rd_b_buf ,
	input  wire [$clog2(DEPTH)-1:0]        rd_b_addr,
	output reg  [B_LANES*DATA_WIDTH-1:0]   rd_b_data,
	input  wire                            rd_exp_en ,
	input  wire                            rd_exp_buf,
	input  wire [$clog2(DEPTH)-1:0]        rd_exp_addr,
	output reg  [B_LANES*DATA_WIDTH-1:0]   rd_exp_data
);

// synthesis translate_off
`ifndef SYNTHESIS
	initial begin
		if ((M_PHYSICAL_COPIES != 2) && (M_PHYSICAL_COPIES != 3)) begin
			$fatal(1, "PT_M_MEM requires M_PHYSICAL_COPIES to be 2 or 3, got %0d", M_PHYSICAL_COPIES);
		end
	end
`endif
// synthesis translate_on

	wire [B_LANES*DATA_WIDTH-1:0] row_rd_data_w;
	wire [B_LANES*DATA_WIDTH-1:0] exp_rd_data_w;

	PT_MEM_BANK #(
		.DATA_WIDTH(DATA_WIDTH),
		.LANES     (B_LANES),
		.DEPTH     (DEPTH)
	) u_mem_row_b (
		.clk    (clk),
		.rstn   (rstn),
		.clear  (clear),
		.wr_en  (wr_en),
		.wr_buf (wr_buf),
		.wr_mask(wr_mask),
		.wr_addr(wr_addr),
		.wr_data(wr_data),
		.rd_en  (rd_b_en),
		.rd_buf (rd_b_buf),
		.rd_addr(rd_b_addr),
		.rd_data(row_rd_data_w)
	);

	PT_MEM_BANK #(
		.DATA_WIDTH(DATA_WIDTH),
		.LANES     (B_LANES),
		.DEPTH     (DEPTH)
	) u_mem_row_exp (
		.clk    (clk),
		.rstn   (rstn),
		.clear  (clear),
		.wr_en  (wr_en),
		.wr_buf (wr_buf),
		.wr_mask(wr_mask),
		.wr_addr(wr_addr),
		.wr_data(wr_data),
		.rd_en  (rd_exp_en),
		.rd_buf (rd_exp_buf),
		.rd_addr(rd_exp_addr),
		.rd_data(exp_rd_data_w)
	);

	always @(*) begin
		rd_b_data = row_rd_data_w;
		rd_exp_data = exp_rd_data_w;
	end

endmodule
