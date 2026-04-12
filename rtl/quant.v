`include "param.vh"

module QUANT #(
	parameter DATA_WIDTH = 32,
	parameter GEMM_X_DIM = 4,
	parameter GEMM_Y_DIM = 4
) (
	input  wire                               clk,
	input  wire                               rstn,
	input  wire                               clear,
	input  wire                              in_valid,
	output wire                              in_ready,
	input  wire [GEMM_Y_DIM*4*DATA_WIDTH-1:0] in_data,
	input  wire [31:0]                       in_idx,
	input  wire                              in_last,
	input  wire [2:0]                        quant_mode,
	input  wire [((GEMM_X_DIM >= GEMM_Y_DIM) ? GEMM_X_DIM : GEMM_Y_DIM)*32-1:0] quant_inv_scale,
	output wire                              out_valid,
	input  wire                              out_ready,
	output wire [GEMM_Y_DIM*DATA_WIDTH-1:0]  out_data,
	output wire [31:0]                       out_idx,
	output wire                              out_last
);

	localparam integer MAX_DIM = (GEMM_X_DIM >= GEMM_Y_DIM) ? GEMM_X_DIM : GEMM_Y_DIM;
	localparam integer SCALE_IDX_W = (MAX_DIM <= 1) ? 1 : $clog2(MAX_DIM);
	localparam integer IN_W = 4 * DATA_WIDTH;
	localparam integer PROD_W = IN_W + 32;
	localparam [PROD_W:0] ROUND_BIAS = {{(PROD_W-15){1'b0}}, 16'h8000};

	localparam [DATA_WIDTH-1:0] SAT_MAX = {1'b0, {(DATA_WIDTH-1){1'b1}}};
	localparam [DATA_WIDTH-1:0] SAT_MIN = {1'b1, {(DATA_WIDTH-1){1'b0}}};

	reg                               s1_valid;
	reg  [GEMM_Y_DIM*IN_W-1:0]        s1_data;
	reg  [31:0]                       s1_idx;
	reg                               s1_last;
	reg  [GEMM_Y_DIM*32-1:0]          s1_inv_scale;

	reg                               s2_valid;
	reg  [GEMM_Y_DIM*DATA_WIDTH-1:0]  s2_data;
	reg  [31:0]                       s2_idx;
	reg                               s2_last;

	wire s2_ready = !s2_valid || out_ready;
	wire s1_ready = !s1_valid || s2_ready;

	wire [SCALE_IDX_W-1:0] row_scale_idx = in_idx[SCALE_IDX_W-1:0];
	wire [SCALE_IDX_W-1:0] row_half_scale_idx = row_scale_idx >> 1;
	wire [GEMM_Y_DIM*32-1:0]         s1_inv_scale_next;
	wire [GEMM_Y_DIM*DATA_WIDTH-1:0] s2_data_next;

	assign in_ready  = s1_ready;
	assign out_valid = s2_valid;
	assign out_data  = s2_data;
	assign out_idx   = s2_idx;
	assign out_last  = s2_last;

	generate
		genvar li;
		for (li = 0; li < GEMM_Y_DIM; li = li + 1) begin : gen_quant_lane
			localparam [SCALE_IDX_W-1:0] LANE_SCALE_IDX = li;
			localparam [SCALE_IDX_W-1:0] LANE_HALF_SCALE_IDX = (li >> 1);

			wire [SCALE_IDX_W-1:0] scale_idx =
				(quant_mode == `PT_QGRAN_X_WISE) ? row_scale_idx :
				(quant_mode == `PT_QGRAN_Y_WISE) ? LANE_SCALE_IDX :
				(quant_mode == `PT_QGRAN_X_WISE_DIV2) ? row_half_scale_idx :
				(quant_mode == `PT_QGRAN_Y_WISE_DIV2) ? LANE_HALF_SCALE_IDX :
				{SCALE_IDX_W{1'b0}};

			assign s1_inv_scale_next[li*32 +: 32] = quant_inv_scale[scale_idx*32 +: 32];

			wire signed [31:0] inv_scale_q16_16 = s1_inv_scale[li*32 +: 32];
			wire signed [IN_W-1:0] lane_in = s1_data[li*IN_W +: IN_W];
			wire signed [PROD_W-1:0] prod = lane_in * inv_scale_q16_16;

			wire [PROD_W:0] prod_mag = prod[PROD_W-1] ? ({1'b0, ~prod} + 1'b1) : {1'b0, prod};
			wire [PROD_W:0] prod_mag_round = prod_mag + ROUND_BIAS;
			wire [PROD_W:0] q_mag = prod_mag_round >> 16;
			wire signed [PROD_W:0] q_signed = prod[PROD_W-1] ? -$signed(q_mag) : $signed(q_mag);

			wire signed [PROD_W:0] sat_max_ext = {{(PROD_W+1-DATA_WIDTH){1'b0}}, SAT_MAX};
			wire signed [PROD_W:0] sat_min_ext = {{(PROD_W+1-DATA_WIDTH){SAT_MIN[DATA_WIDTH-1]}}, SAT_MIN};

			wire [DATA_WIDTH-1:0] lane_out =
				(q_signed > sat_max_ext) ? SAT_MAX :
				(q_signed < sat_min_ext) ? SAT_MIN :
				q_signed[DATA_WIDTH-1:0];

			assign s2_data_next[li*DATA_WIDTH +: DATA_WIDTH] = lane_out;
		end
	endgenerate

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			s1_valid     <= 1'b0;
			s1_data      <= {GEMM_Y_DIM*IN_W{1'b0}};
			s1_idx       <= 32'd0;
			s1_last      <= 1'b0;
			s1_inv_scale <= {GEMM_Y_DIM*32{1'b0}};
			s2_valid     <= 1'b0;
			s2_data      <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			s2_idx       <= 32'd0;
			s2_last      <= 1'b0;
		end else if (clear) begin
			s1_valid     <= 1'b0;
			s1_data      <= {GEMM_Y_DIM*IN_W{1'b0}};
			s1_idx       <= 32'd0;
			s1_last      <= 1'b0;
			s1_inv_scale <= {GEMM_Y_DIM*32{1'b0}};
			s2_valid     <= 1'b0;
			s2_data      <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			s2_idx       <= 32'd0;
			s2_last      <= 1'b0;
		end else begin
			if (s2_ready) begin
				s2_valid <= s1_valid;
				if (s1_valid) begin
					s2_data <= s2_data_next;
					s2_idx  <= s1_idx;
					s2_last <= s1_last;
				end
			end

			if (s1_ready) begin
				s1_valid <= in_valid;
				if (in_valid) begin
					s1_data      <= in_data;
					s1_idx       <= in_idx;
					s1_last      <= in_last;
					s1_inv_scale <= s1_inv_scale_next;
				end
			end
		end
	end

endmodule
