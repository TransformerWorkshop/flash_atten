module MM_SKEW #(
	parameter WIDTH = 32,
	parameter X_DIM = 4 ,
	parameter Y_DIM = 4
) (
	input  wire                   clk           ,
	input  wire                   rstn          ,
	input  wire                   clear         , // soft reset for skewing logic
	input  wire [X_DIM*WIDTH-1:0] a             , // Flattened input matrix A
	input  wire                   a_valid       ,
	output wire                   a_ready       ,
	input  wire [Y_DIM*WIDTH-1:0] b             , // Flattened input matrix B
	input  wire                   b_valid       ,
	output wire                   b_ready       ,
	output wire [X_DIM*WIDTH-1:0] a_skewed      ,
	input  wire                   a_skewed_ready,
	output wire [      X_DIM-1:0] a_skewed_valid,
	output wire [Y_DIM*WIDTH-1:0] b_skewed      ,
	input  wire                   b_skewed_ready,
	output wire [      Y_DIM-1:0] b_skewed_valid
);

	wire [X_DIM-1:0] a_ready_vec;
	wire [Y_DIM-1:0] b_ready_vec;
	assign a_ready = &a_ready_vec;
	assign b_ready = &b_ready_vec;

	genvar i, j;
	generate
		for (i = 0; i < X_DIM; i = i + 1) begin: gen_skew
			if (i > 0) begin
				SHIFT_REG #(
					.WIDTH(WIDTH),
					.DEPTH(i),
					.USE_SIPO(0)
				) shift_reg (
					.clk(clk),
					.rstn(rstn),
					.clear(clear),
					.data_in(a[(i+1)*WIDTH-1:i*WIDTH]),
					.valid_in(a_valid),
					.ready_in(a_ready_vec[i]),
					.siso_data_out(a_skewed[(i+1)*WIDTH-1:i*WIDTH]),
					.siso_valid(a_skewed_valid[i]),
					.siso_ready(a_skewed_ready)
				);
			end else begin
				assign a_skewed[WIDTH-1:0] = a[WIDTH-1:0];
				assign a_skewed_valid[0]   = a_valid;
				assign a_ready_vec[0]      = a_ready;
			end
		end

		for (j = 0; j < Y_DIM; j = j + 1) begin: gen_skew_b
			if (j > 0) begin
				SHIFT_REG #(
					.WIDTH(WIDTH),
					.DEPTH(j),
					.USE_SIPO(0)
				) shift_reg (
					.clk(clk),
					.rstn(rstn),
					.clear(clear),
					.data_in(b[(j+1)*WIDTH-1:j*WIDTH]),
					.valid_in(b_valid),
					.ready_in(b_ready_vec[j]),
					.siso_data_out(b_skewed[(j+1)*WIDTH-1:j*WIDTH]),
					.siso_valid(b_skewed_valid[j]),
					.siso_ready(b_skewed_ready)
				);
			end else begin
				assign b_skewed[WIDTH-1:0] = b[WIDTH-1:0];
				assign b_skewed_valid[0]   = b_valid;
				assign b_ready_vec[0]      = b_ready;
			end
		end
	endgenerate
endmodule