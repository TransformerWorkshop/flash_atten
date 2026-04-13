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
	input  wire [$clog2(LANES)-1:0]        wr_lane ,
	input  wire [$clog2(DEPTH)-1:0]        wr_addr ,
	input  wire [         DATA_WIDTH-1:0]  wr_data ,
	input  wire                            rd_en   ,
	input  wire                            rd_buf  ,
	input  wire [$clog2(DEPTH)-1:0]        rd_addr ,
	output reg  [LANES*DATA_WIDTH-1:0]     rd_data
);

	localparam integer TOTAL_LANES = 2 * LANES;
	localparam integer LANE_SEL_W  = (TOTAL_LANES <= 1) ? 1 : $clog2(TOTAL_LANES);
	localparam integer ADDR_W      = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

	wire [LANE_SEL_W-1:0] wr_lane_sel;
	assign wr_lane_sel = (wr_buf ? LANES[LANE_SEL_W-1:0] : {LANE_SEL_W{1'b0}}) + wr_lane;

	wire [DATA_WIDTH-1:0] lane_rd_ping [0:LANES-1];
	wire [DATA_WIDTH-1:0] lane_rd_pong [0:LANES-1];

	genvar gi;
	generate
		for (gi = 0; gi < TOTAL_LANES; gi = gi + 1) begin : gen_sram_bank
			wire this_wr_hit = wr_en && (wr_lane_sel == gi[LANE_SEL_W-1:0]);
			wire this_rd_hit = rd_en &&
			                   (rd_buf ? (gi >= LANES) : (gi < LANES));

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
				.din_a (wr_data         ),
				.dout_a(               ),
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

	// keep reset/clear referenced for lint; SRAM macro content is not actively cleared.
	wire _unused_rst = rstn | clear;

endmodule

module PT_M_MEM #(
	parameter DATA_WIDTH = 32,
	parameter A_LANES    = 4 ,
	parameter B_LANES    = 4 ,
	parameter DEPTH      = 16
) (
	input  wire                            clk      ,
	input  wire                            rstn     ,
	input  wire                            clear    ,
	input  wire                            wr_en    ,
	input  wire                            wr_buf   ,
	input  wire [$clog2(B_LANES)-1:0]      wr_lane  ,
	input  wire [$clog2(DEPTH)-1:0]        wr_addr  ,
	input  wire [         DATA_WIDTH-1:0]  wr_data  ,
	input  wire                            rd_a_en  ,
	input  wire                            rd_a_buf ,
	input  wire [$clog2(DEPTH)-1:0]        rd_a_addr,
	output wire [A_LANES*DATA_WIDTH-1:0]   rd_a_data,
	input  wire                            rd_b_en  ,
	input  wire                            rd_b_buf ,
	input  wire [$clog2(DEPTH)-1:0]        rd_b_addr,
	output wire [B_LANES*DATA_WIDTH-1:0]   rd_b_data,
	input  wire                            rd_exp_en ,
	input  wire                            rd_exp_buf,
	input  wire [$clog2(DEPTH)-1:0]        rd_exp_addr,
	output wire [B_LANES*DATA_WIDTH-1:0]   rd_exp_data
);

	// Store M in both row-major and column-major views so the same buffer can be
	// reused as either the left or right operand without DMA reshaping.
	wire [$clog2(A_LANES)-1:0] col_wr_lane = wr_addr;
	wire [$clog2(DEPTH)-1:0]   col_wr_addr = wr_lane;

	PT_MEM_BANK #(
		.DATA_WIDTH(DATA_WIDTH),
		.LANES     (A_LANES),
		.DEPTH     (DEPTH)
	) u_mem_col (
		.clk    (clk     ),
		.rstn   (rstn    ),
		.clear  (clear   ),
		.wr_en  (wr_en   ),
		.wr_buf (wr_buf  ),
		.wr_lane(col_wr_lane),
		.wr_addr(col_wr_addr),
		.wr_data(wr_data ),
		.rd_en  (rd_a_en ),
		.rd_buf (rd_a_buf),
		.rd_addr(rd_a_addr),
		.rd_data(rd_a_data)
	);

	PT_MEM_BANK #(
		.DATA_WIDTH(DATA_WIDTH),
		.LANES     (B_LANES),
		.DEPTH     (DEPTH)
	) u_mem_row_b (
		.clk    (clk     ),
		.rstn   (rstn    ),
		.clear  (clear   ),
		.wr_en  (wr_en   ),
		.wr_buf (wr_buf  ),
		.wr_lane(wr_lane ),
		.wr_addr(wr_addr ),
		.wr_data(wr_data ),
		.rd_en  (rd_b_en ),
		.rd_buf (rd_b_buf),
		.rd_addr(rd_b_addr),
		.rd_data(rd_b_data)
	);

	PT_MEM_BANK #(
		.DATA_WIDTH(DATA_WIDTH),
		.LANES     (B_LANES),
		.DEPTH     (DEPTH)
	) u_mem_row_exp (
		.clk    (clk      ),
		.rstn   (rstn     ),
		.clear  (clear    ),
		.wr_en  (wr_en    ),
		.wr_buf (wr_buf   ),
		.wr_lane(wr_lane  ),
		.wr_addr(wr_addr  ),
		.wr_data(wr_data  ),
		.rd_en  (rd_exp_en),
		.rd_buf (rd_exp_buf),
		.rd_addr(rd_exp_addr),
		.rd_data(rd_exp_data)
	);

endmodule
