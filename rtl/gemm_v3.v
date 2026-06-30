module GEMM_V3 #(
	parameter WIDTH         = 32,
	parameter ELEM_WIDTH    = 8,
	parameter PACK_LANES    = 4,
	parameter X_DIM         = 4 ,
	parameter Y_DIM         = 4 ,
	parameter OUTPUT_BY_ROW = 1,
	parameter ACC_COUNT_WIDTH = WIDTH,
	parameter GROUP_IDX_WIDTH = 32
) (
	input  wire                   clk                  ,
	input  wire                   rstn                 ,
	input  wire                   clear                ,
	input  wire                   start                ,
	input  wire [ACC_COUNT_WIDTH-1:0] num_acc          ,
	input  wire                   a_valid              ,
	output wire                   a_ready              ,
	input  wire [X_DIM*WIDTH-1:0] a                    ,
	input  wire                   b_valid              ,
	output wire                   b_ready              ,
	input  wire [Y_DIM*WIDTH-1:0] b                    ,
	output wire                   start_ready          ,
	output                        wire [((OUTPUT_BY_ROW  != 0) ? Y_DIM : X_DIM)*4*WIDTH-1:0] m_group_data,
	output wire                   m_group_valid        ,
	input  wire                   m_group_ready        ,
	output wire [GROUP_IDX_WIDTH-1:0] m_group_idx      ,
	output wire                   m_last
);

	localparam integer TOTAL_PE    = X_DIM * Y_DIM                       ;
	localparam integer GROUP_SIZE  = (OUTPUT_BY_ROW != 0) ? Y_DIM : X_DIM;
	localparam integer GROUP_COUNT = (OUTPUT_BY_ROW != 0) ? X_DIM : Y_DIM;

	reg [GROUP_IDX_WIDTH-1:0] stream_idx;
	localparam integer TILE_COUNT_W = 2;
	reg [TILE_COUNT_W-1:0] ready_tile_count_r;

	wire [TOTAL_PE-1:0] pe_a_ready              ;
	wire [TOTAL_PE-1:0] pe_b_ready              ;
	wire [TOTAL_PE-1:0] pe_m_valid              ;
	wire [TOTAL_PE-1:0] pe_m_ready              ;
	wire [ 4*WIDTH-1:0] pe_m_data [0:TOTAL_PE-1];
	wire [TOTAL_PE-1:0] pe_start_ready          ;
	wire [TOTAL_PE-1:0] pe_tile_done            ;
	wire [X_DIM-1:0]    row_a_ready             ;
	wire [X_DIM-1:0]    row_b_ready             ;

	wire               stream_active;
	wire               all_start_ready;
	wire               tile_done_fire;
	wire               start_accept;
	wire               cur_group_valid;
	wire               stream_fire    ;

	reg [4*WIDTH-1:0] group_word[0:GROUP_SIZE-1];

	integer q;

	assign a_ready = &row_a_ready;
	assign b_ready = &row_b_ready;
	assign stream_active = (ready_tile_count_r != {TILE_COUNT_W{1'b0}});
	assign all_start_ready = &pe_start_ready;
	assign tile_done_fire = &pe_tile_done;
	assign start_ready = all_start_ready && (ready_tile_count_r < 2);
	assign start_accept = start && start_ready;

	// Check whether all PEs in the current streaming group have valid output
	generate
		if (OUTPUT_BY_ROW != 0) begin : gen_group_valid_row
			wire [GROUP_COUNT-1:0] group_all_valid;
			genvar gv;
			for (gv = 0; gv < GROUP_COUNT; gv = gv + 1) begin : gen_gv
				assign group_all_valid[gv] = &pe_m_valid[gv*Y_DIM +: Y_DIM];
			end
			assign cur_group_valid = stream_active && group_all_valid[stream_idx[($clog2(GROUP_COUNT > 1 ? GROUP_COUNT : 2))-1:0]];
		end else begin : gen_group_valid_col
			wire [GROUP_COUNT-1:0] group_all_valid;
			genvar gv;
			for (gv = 0; gv < GROUP_COUNT; gv = gv + 1) begin : gen_gv
				wire [GROUP_SIZE-1:0] col_valid;
				genvar cv;
				for (cv = 0; cv < GROUP_SIZE; cv = cv + 1) begin : gen_cv
					assign col_valid[cv] = pe_m_valid[cv * Y_DIM + gv];
				end
				assign group_all_valid[gv] = &col_valid;
			end
			assign cur_group_valid = stream_active && group_all_valid[stream_idx[($clog2(GROUP_COUNT > 1 ? GROUP_COUNT : 2))-1:0]];
		end
	endgenerate

	assign stream_fire  = m_group_valid && m_group_ready;
	assign m_group_valid = cur_group_valid;
	assign m_group_idx   = stream_idx;
	assign m_last        = cur_group_valid && (stream_idx == (GROUP_COUNT - 1));

	generate
		genvar gr;
		for (gr = 0; gr < X_DIM; gr = gr + 1) begin : gen_row_reduce
			assign row_a_ready[gr] = &pe_a_ready[gr*Y_DIM +: Y_DIM];
			assign row_b_ready[gr] = &pe_b_ready[gr*Y_DIM +: Y_DIM];
		end
	endgenerate

	generate
		genvar gw;
		for (gw = 0; gw < GROUP_SIZE; gw = gw + 1) begin : gen_group_data
			assign m_group_data[(gw+1)*4*WIDTH-1:gw*4*WIDTH] =
				m_group_valid ? group_word[gw] : {4*WIDTH{1'b0}};
		end
	endgenerate

	// PE array: drain PEs only for the current streaming group
	generate
		genvar i;
		genvar j;
		for (i = 0; i < X_DIM; i = i + 1) begin : gen_gemu_row
			for (j = 0; j < Y_DIM; j = j + 1) begin : gen_gemu_col
				localparam integer PE = i * Y_DIM + j;

				if (OUTPUT_BY_ROW != 0) begin : gen_ready_row
					assign pe_m_ready[PE] = stream_active &&
					                        (stream_idx[($clog2(X_DIM > 1 ? X_DIM : 2))-1:0] == i[($clog2(X_DIM > 1 ? X_DIM : 2))-1:0]) &&
					                        cur_group_valid && m_group_ready;
				end else begin : gen_ready_col
					assign pe_m_ready[PE] = stream_active &&
					                        (stream_idx[($clog2(Y_DIM > 1 ? Y_DIM : 2))-1:0] == j[($clog2(Y_DIM > 1 ? Y_DIM : 2))-1:0]) &&
					                        cur_group_valid && m_group_ready;
				end

				GEMU_V3 #(
					.WIDTH(WIDTH),
					.ELEM_WIDTH(ELEM_WIDTH),
					.PACK_LANES(PACK_LANES),
					.ACC_COUNT_WIDTH(ACC_COUNT_WIDTH)
				) gemu_unit (
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
		.start  (start_accept            ),
		.num_acc(num_acc                 ),
		.start_ready(pe_start_ready[PE]  ),
		.tile_done(pe_tile_done[PE]      )
				);
			end
		end
	endgenerate

	// Read PE output FIFOs directly for the current group
	always @(*) begin
		for (q = 0; q < GROUP_SIZE; q = q + 1) begin
			group_word[q] = {4*WIDTH{1'b0}};
		end

		if (stream_active) begin
			for (q = 0; q < GROUP_SIZE; q = q + 1) begin
				if (OUTPUT_BY_ROW != 0) begin
					group_word[q] = pe_m_data[stream_idx * Y_DIM + q];
				end else begin
					group_word[q] = pe_m_data[q * Y_DIM + stream_idx];
				end
			end
		end
	end

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			ready_tile_count_r <= {TILE_COUNT_W{1'b0}};
		end else if (clear) begin
			ready_tile_count_r <= {TILE_COUNT_W{1'b0}};
		end else begin
			case ({tile_done_fire, stream_fire && (stream_idx == (GROUP_COUNT - 1))})
				2'b10: ready_tile_count_r <= ready_tile_count_r + 1'b1;
				2'b01: ready_tile_count_r <= ready_tile_count_r - 1'b1;
				default: ready_tile_count_r <= ready_tile_count_r;
			endcase
		end
	end

	// Stream index register
	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			stream_idx <= 32'd0;
		end else if (clear) begin
			stream_idx <= 32'd0;
		end else begin
			if (!stream_active) begin
				stream_idx <= 32'd0;
			end else begin
				if (stream_fire) begin
					if (stream_idx == (GROUP_COUNT - 1)) begin
						stream_idx <= 32'd0;
					end else begin
						stream_idx <= stream_idx + 1'b1;
					end
				end
			end
		end
	end

endmodule
