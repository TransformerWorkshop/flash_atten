module GEMM #(
	parameter WIDTH         = 32,
	parameter X_DIM         = 4 ,
	parameter Y_DIM         = 4 ,
	parameter OUTPUT_BY_ROW = 1
) (
	input  wire                   clk                  ,
	input  wire                   rstn                 ,
	input  wire                   clear                ,
	input  wire                   start                ,
	input  wire [      WIDTH-1:0] num_acc              ,
	input  wire                   a_valid              ,
	output wire                   a_ready              ,
	input  wire [X_DIM*WIDTH-1:0] a                    ,
	input  wire                   b_valid              ,
	output wire                   b_ready              ,
	input  wire [Y_DIM*WIDTH-1:0] b                    ,
	output                        wire [((OUTPUT_BY_ROW  != 0) ? Y_DIM : X_DIM)*4*WIDTH-1:0] m_group_data,
	output wire                   m_group_valid        ,
	input  wire                   m_group_ready        ,
	output wire [           31:0] m_group_idx          ,
	output wire                   m_last
);

	localparam integer TOTAL_PE    = X_DIM * Y_DIM                       ;
	localparam integer GROUP_SIZE  = (OUTPUT_BY_ROW != 0) ? Y_DIM : X_DIM;
	localparam integer GROUP_COUNT = (OUTPUT_BY_ROW != 0) ? X_DIM : Y_DIM;

	localparam [1:0] STATE_IDLE    = 2'b00;
	localparam [1:0] STATE_COLLECT = 2'b01;
	localparam [1:0] STATE_STREAM  = 2'b10;

	reg [ 1:0] state     ;
	reg [ 1:0] next_state;
	reg [31:0] stream_idx;

	reg [ 4*WIDTH-1:0] result_buf[0:TOTAL_PE-1];
	reg [TOTAL_PE-1:0] collected               ;

	wire [TOTAL_PE-1:0] pe_a_ready              ;
	wire [TOTAL_PE-1:0] pe_b_ready              ;
	wire [TOTAL_PE-1:0] pe_m_valid              ;
	wire [TOTAL_PE-1:0] pe_m_ready              ;
	wire [ 4*WIDTH-1:0] pe_m_data [0:TOTAL_PE-1];

	wire collect_done;
	wire stream_fire ;

	reg [4*WIDTH-1:0] group_word[0:GROUP_SIZE-1];

	integer p      ;
	integer q      ;
	integer row_idx;
	integer col_idx;

	assign a_ready = &pe_a_ready;
	assign b_ready = &pe_b_ready;

	assign collect_done = &collected;
	assign stream_fire  = (state == STATE_STREAM) && m_group_valid && m_group_ready;

	assign m_group_valid = (state == STATE_STREAM);
	assign m_group_idx   = stream_idx;
	assign m_last        = (state == STATE_STREAM) && (stream_idx == (GROUP_COUNT - 1));

	// 3-process FSM: next-state combinational logic
	always @(*) begin
		next_state = state;
		case (state)
			STATE_IDLE : begin
				if (start) begin
					next_state = STATE_COLLECT;
				end
			end
			STATE_COLLECT : begin
				if (collect_done) begin
					next_state = STATE_STREAM;
				end
			end
			STATE_STREAM : begin
				if (stream_fire && (stream_idx == (GROUP_COUNT - 1))) begin
					next_state = STATE_IDLE;
				end
			end
			default : begin
				next_state = STATE_IDLE;
			end
		endcase
	end
	generate
		genvar gw;
		for (gw = 0; gw < GROUP_SIZE; gw = gw + 1) begin : gen_group_data
			assign m_group_data[(gw+1)*4*WIDTH-1:gw*4*WIDTH] =
				m_group_valid ? group_word[gw] : {4*WIDTH{1'b0}};
		end
	endgenerate

	generate
		genvar i;
		genvar j;
		for (i = 0; i < X_DIM; i = i + 1) begin : gen_gemu_row
			for (j = 0; j < Y_DIM; j = j + 1) begin : gen_gemu_col
				localparam integer PE = i * Y_DIM + j;

				assign pe_m_ready[PE] = (state == STATE_COLLECT) && !collected[PE];

				GEMU #(.WIDTH(WIDTH)) gemu_unit (
					.clk    (clk                     ),
					.rstn   (rstn                    ),
					.clear  (clear                   ),
					.a      (a[(i+1)*WIDTH-1:i*WIDTH]),
					.a_valid(a_valid                 ),
					.a_ready(pe_a_ready[PE]          ),
					.b      (b[(j+1)*WIDTH-1:j*WIDTH]),
					.b_valid(b_valid                 ),
					.b_ready(pe_b_ready[PE]          ),
					.m      (pe_m_data[PE]           ),
					.m_valid(pe_m_valid[PE]          ),
					.m_ready(pe_m_ready[PE]          ),
					.start  (start                   ),
					.num_acc(num_acc                 )
				);
			end
		end
	endgenerate

	always @(*) begin
		for (q = 0; q < GROUP_SIZE; q = q + 1) begin
			group_word[q] = {4*WIDTH{1'b0}};
		end

		if (state == STATE_STREAM) begin
			for (q = 0; q < GROUP_SIZE; q = q + 1) begin
				if (OUTPUT_BY_ROW != 0) begin
					group_word[q] = result_buf[stream_idx * Y_DIM + q];
				end else begin
					group_word[q] = result_buf[q * Y_DIM + stream_idx];
				end
			end
		end
	end

	// 3-process FSM: state register
	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			state <= STATE_IDLE;
		end else if (clear) begin
			state <= STATE_IDLE;
		end else begin
			state <= next_state;
		end
	end

	// 3-process FSM: state-dependent sequential datapath updates
	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			stream_idx <= 32'd0;
			collected  <= {TOTAL_PE{1'b0}};
			for (p = 0; p < TOTAL_PE; p = p + 1) begin
				result_buf[p] <= {4*WIDTH{1'b0}};
			end
		end else if (clear) begin
			stream_idx <= 32'd0;
			collected  <= {TOTAL_PE{1'b0}};
			for (p = 0; p < TOTAL_PE; p = p + 1) begin
				result_buf[p] <= {4*WIDTH{1'b0}};
			end
		end else begin
			case (state)
				STATE_IDLE : begin
					stream_idx <= 32'd0;
					if (start) begin
						collected <= {TOTAL_PE{1'b0}};
					end
				end

				STATE_COLLECT : begin
					for (row_idx = 0; row_idx < X_DIM; row_idx = row_idx + 1) begin
						for (col_idx = 0; col_idx < Y_DIM; col_idx = col_idx + 1) begin
							if (pe_m_valid[row_idx * Y_DIM + col_idx] && pe_m_ready[row_idx * Y_DIM + col_idx]) begin
								result_buf[row_idx*Y_DIM+col_idx] <= pe_m_data[row_idx * Y_DIM + col_idx];
								collected[row_idx*Y_DIM+col_idx]  <= 1'b1;
							end
						end
					end

					if (collect_done) begin
						stream_idx <= 32'd0;
					end
				end

				STATE_STREAM : begin
					if (stream_fire) begin
						if (stream_idx == (GROUP_COUNT - 1)) begin
							stream_idx <= 32'd0;
						end else begin
							stream_idx <= stream_idx + 1'b1;
						end
					end
				end

				default : begin
					stream_idx <= 32'd0;
				end
			endcase
		end
	end

endmodule
