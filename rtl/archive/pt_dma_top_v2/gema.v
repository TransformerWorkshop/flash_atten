module GEMA #(
	parameter DATA_WIDTH = 32,
	parameter GEMM_Y_DIM = 4
) (
	input  wire                              clk,
	input  wire                              rstn,
	input  wire                              clear,
	input  wire                              in_valid,
	output wire                              in_ready,
	input  wire [GEMM_Y_DIM*DATA_WIDTH-1:0]  lhs_data,
	input  wire [GEMM_Y_DIM*DATA_WIDTH-1:0]  rhs_data,
	input  wire [31:0]                       in_idx,
	input  wire                              in_last,
	output wire                              out_valid,
	input  wire                              out_ready,
	output wire [GEMM_Y_DIM*DATA_WIDTH-1:0]  out_data,
	output wire [31:0]                       out_idx,
	output wire                              out_last
);

	localparam [DATA_WIDTH-1:0] SAT_MAX = {1'b0, {(DATA_WIDTH-1){1'b1}}};
	localparam [DATA_WIDTH-1:0] SAT_MIN = {1'b1, {(DATA_WIDTH-1){1'b0}}};

	reg                              out_valid_r;
	reg [GEMM_Y_DIM*DATA_WIDTH-1:0]  out_data_r;
	reg [31:0]                       out_idx_r;
	reg                              out_last_r;

	wire [GEMM_Y_DIM*DATA_WIDTH-1:0] sat_sum_data;
	wire                             pipe_ready = !out_valid_r || out_ready;

	assign in_ready  = pipe_ready;
	assign out_valid = out_valid_r;
	assign out_data  = out_data_r;
	assign out_idx   = out_idx_r;
	assign out_last  = out_last_r;

	generate
		genvar li;
		for (li = 0; li < GEMM_Y_DIM; li = li + 1) begin : gen_sat_add_lane
			wire signed [DATA_WIDTH-1:0] lhs_lane = lhs_data[li*DATA_WIDTH +: DATA_WIDTH];
			wire signed [DATA_WIDTH-1:0] rhs_lane = rhs_data[li*DATA_WIDTH +: DATA_WIDTH];
			wire signed [DATA_WIDTH:0]   sum_lane = $signed({lhs_lane[DATA_WIDTH-1], lhs_lane}) +
			                                       $signed({rhs_lane[DATA_WIDTH-1], rhs_lane});
			wire signed [DATA_WIDTH:0]   sat_max_ext = {1'b0, SAT_MAX};
			wire signed [DATA_WIDTH:0]   sat_min_ext = {1'b1, SAT_MIN};

			assign sat_sum_data[li*DATA_WIDTH +: DATA_WIDTH] =
				(sum_lane > sat_max_ext) ? SAT_MAX :
				(sum_lane < sat_min_ext) ? SAT_MIN :
				sum_lane[DATA_WIDTH-1:0];
		end
	endgenerate

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			out_valid_r <= 1'b0;
			out_data_r  <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			out_idx_r   <= 32'd0;
			out_last_r  <= 1'b0;
		end else if (clear) begin
			out_valid_r <= 1'b0;
			out_data_r  <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			out_idx_r   <= 32'd0;
			out_last_r  <= 1'b0;
		end else if (pipe_ready) begin
			out_valid_r <= in_valid;
			if (in_valid) begin
				out_data_r <= sat_sum_data;
				out_idx_r  <= in_idx;
				out_last_r <= in_last;
			end
		end
	end

endmodule
