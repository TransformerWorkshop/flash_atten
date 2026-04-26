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

	localparam integer ADDR_W      = (DEPTH <= 1) ? 1 : $clog2(DEPTH);

	wire [DATA_WIDTH-1:0] lane_rd_ping [0:LANES-1];
	wire [DATA_WIDTH-1:0] lane_rd_pong [0:LANES-1];

	genvar gi;
	generate
		for (gi = 0; gi < LANES; gi = gi + 1) begin : gen_sram_bank
			localparam integer LANE_IDX = gi;

			wire ping_wr_hit;
			wire ping_rd_hit;
			wire pong_wr_hit;
			wire pong_rd_hit;
			wire ping_en;
			wire pong_en;
			wire ping_we;
			wire pong_we;
			wire ping_conflict;
			wire pong_conflict;
			wire [ADDR_W-1:0] ping_addr;
			wire [ADDR_W-1:0] pong_addr;
			wire [DATA_WIDTH-1:0] ping_dout_i;
			wire [DATA_WIDTH-1:0] pong_dout_i;

			assign ping_wr_hit = wr_en && wr_mask[LANE_IDX] && !wr_buf;
			assign ping_rd_hit = rd_en && !rd_buf;
			assign pong_wr_hit = wr_en && wr_mask[LANE_IDX] && wr_buf;
			assign pong_rd_hit = rd_en && rd_buf;
			assign ping_en = ping_wr_hit || ping_rd_hit || (ping_conflict && 1'b0) || (rstn && 1'b0) || (clear && 1'b0);
			assign pong_en = pong_wr_hit || pong_rd_hit || (pong_conflict && 1'b0);
			assign ping_we = ping_wr_hit;
			assign pong_we = pong_wr_hit;
			assign ping_conflict = ping_wr_hit && ping_rd_hit;
			assign pong_conflict = pong_wr_hit && pong_rd_hit;
			assign ping_addr = ping_wr_hit ? wr_addr : rd_addr;
			assign pong_addr = pong_wr_hit ? wr_addr : rd_addr;

// synthesis translate_off
`ifndef SYNTHESIS
			always @(posedge clk) begin
				if (ping_conflict) begin
					$fatal(1, "PT_MEM_BANK lane %0d ping bank saw simultaneous read/write on single-port SRAM", LANE_IDX);
				end
				if (pong_conflict) begin
					$fatal(1, "PT_MEM_BANK lane %0d pong bank saw simultaneous read/write on single-port SRAM", LANE_IDX);
				end
			end
`endif
// synthesis translate_on

			sram #(
				.DATA_WIDTH(DATA_WIDTH),
				.DEPTH     (DEPTH),
				.ADDR_WIDTH(ADDR_W)
			) u_sram_ping (
				.clk (clk                                       ),
				.en  (ping_en                                   ),
				.we  (ping_we                                   ),
				.addr(ping_addr                                 ),
				.din (wr_data[LANE_IDX*DATA_WIDTH +: DATA_WIDTH]),
				.dout(ping_dout_i                               )
			);

			sram #(
				.DATA_WIDTH(DATA_WIDTH),
				.DEPTH     (DEPTH),
				.ADDR_WIDTH(ADDR_W)
			) u_sram_pong (
				.clk (clk                                       ),
				.en  (pong_en                                   ),
				.we  (pong_we                                   ),
				.addr(pong_addr                                 ),
				.din (wr_data[LANE_IDX*DATA_WIDTH +: DATA_WIDTH]),
				.dout(pong_dout_i                               )
			);

			assign lane_rd_ping[gi] = ping_dout_i;
			assign lane_rd_pong[gi] = pong_dout_i;
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
