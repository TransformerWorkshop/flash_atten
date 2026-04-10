module GEMM #(
	parameter WIDTH = 32,
	parameter X_DIM = 4 ,
	parameter Y_DIM = 4
) (
	input  wire                   clk    ,
	input  wire                   rstn   ,
	input  wire                   clear  , // soft reset
	input  wire                   a_valid,
	output wire                   a_ready,
	input  wire [X_DIM*WIDTH-1:0] a      , // Flattened input matrix A
	input  wire                   b_valid,
	output wire                   b_ready,
	input  wire [Y_DIM*WIDTH-1:0] b        // Flattened input matrix B
);

	genvar i, j;




	// MM_SKEW - SHIFT_REG interfaces
	wire [      X_DIM-1:0] a_shift_ready_vec;
	wire [      X_DIM-1:0] a_skewed_valid   ;
	wire [X_DIM*WIDTH-1:0] a_skewed         ;

	wire [      Y_DIM-1:0] b_shift_ready_vec;
	wire [      Y_DIM-1:0] b_skewed_valid   ;
	wire [Y_DIM*WIDTH-1:0] b_skewed         ;



	// GEMU - SHIFT_REG interfaces
	wire [Y_DIM*WIDTH-1:0] a_shift_out  [0:X_DIM-1];
	wire [X_DIM*WIDTH-1:0] b_shift_out  [0:Y_DIM-1];
	wire [      Y_DIM-1:0] a_gemu_ready [0:X_DIM-1];
	wire [      X_DIM-1:0] b_gemu_ready [0:Y_DIM-1];
	wire [      Y_DIM-1:0] a_shift_valid[0:X_DIM-1];
	wire [      X_DIM-1:0] b_shift_valid[0:Y_DIM-1];

	MM_SKEW #(
		.WIDTH(WIDTH),
		.X_DIM(X_DIM),
		.Y_DIM(Y_DIM)
	) mm_skew (
		.clk           (clk               ),
		.rstn          (rstn              ),
		.clear         (clear             ),
		.a             (a                 ),
		.a_valid       (a_valid           ),
		.a_ready       (a_ready           ),
		.b             (b                 ),
		.b_valid       (b_valid           ),
		.b_ready       (b_ready           ),
		.a_skewed      (a_skewed          ),
		.a_skewed_ready(&a_shift_ready_vec),
		.a_skewed_valid(a_skewed_valid    ),
		.b_skewed      (b_skewed          ),
		.b_skewed_ready(&b_shift_ready_vec),
		.b_skewed_valid(b_skewed_valid    )
	);

	// shift registers
	generate
		for (i = 0; i < X_DIM; i = i + 1) begin: gen_a_shift_reg
			SHIFT_REG #(
				.WIDTH(WIDTH),
				.DEPTH(Y_DIM),
				.USE_SIPO(1)
			) shift_reg_a (
				.clk(clk),
				.rstn(rstn),
				.clear(clear),
				.data_in(a_skewed[(i+1)*WIDTH-1:i*WIDTH]),
				.valid_in(a_skewed_valid[i]),
				.ready_in(a_shift_ready_vec[i]),
				.sipo_data_out(a_shift_out[i]),
				.sipo_ready(a_gemu_ready[i]),
				.sipo_valid(a_shift_valid[i])
			);
		end
		for (j = 0; j < Y_DIM; j = j + 1) begin: gen_b_shift_reg
			SHIFT_REG #(
				.WIDTH(WIDTH),
				.DEPTH(X_DIM),
				.USE_SIPO(1)
			) shift_reg_b (
				.clk(clk),
				.rstn(rstn),
				.clear(clear),
				.data_in(b_skewed[(j+1)*WIDTH-1:j*WIDTH]),
				.valid_in(b_skewed_valid[j]),
				.ready_in(b_shift_ready_vec[j]), // TODO: connect to MM_SKEW unit
				.sipo_data_out(b_shift_out[j]),
				.sipo_ready(b_gemu_ready[j]),
				.sipo_valid(b_shift_valid[j])
			);
		end

		for(i = 0; i < X_DIM; i = i + 1) begin: gen_gemu_horizontal
			for (j = 0; j < Y_DIM; j = j + 1) begin: gen_gemu_vertical
				GEMU #(
					.WIDTH(WIDTH)
				) gemu_unit (
					.clk(clk),
					.rstn(rstn),
					.clear(clear),
					.a(a_shift_out[i][(j+1)*WIDTH-1:j*WIDTH]),
					.a_valid(a_shift_valid[i][j]),
					.a_ready(a_gemu_ready[i][j]),
					.b(b_shift_out[j][(i+1)*WIDTH-1:i*WIDTH]),
					.b_valid(b_shift_valid[j][i]),
					.b_ready(b_gemu_ready[j][i]),
					.m(), // TODO: connect to output matrix
					.m_valid(), // TODO: connect to output matrix
					.m_ready(1'b1), // TODO: connect to output matrix
					.start(1'b0) // TODO: control signal for starting computation
				);
			end
		end
	endgenerate


endmodule 