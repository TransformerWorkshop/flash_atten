module GEMU_V3 #(
	parameter WIDTH = 32,
	parameter ELEM_WIDTH = 8,
	parameter PACK_LANES = 4
) (
	// clock, reset and soft reset
	input  wire               clk    ,
	input  wire               rstn   ,
	input  wire               clear  , // soft reset
	// interface
	input  wire [  WIDTH-1:0] a      ,
	input  wire               a_valid,
	output wire               a_ready,
	input  wire [  WIDTH-1:0] b      ,
	input  wire               b_valid,
	output wire               b_ready,
	output wire [4*WIDTH-1:0] m      ,
	output wire               m_valid,
	input  wire               m_ready,
	// control signals
	input  wire               start  ,
	input  wire [  WIDTH-1:0] num_acc,
	output wire               start_ready,
	output wire               tile_done
);

	localparam STATE_IDLE = 2'b00;
	localparam STATE_ACCM = 2'b01;


	reg signed [4*WIDTH-1:0] accm                           ;
	reg        [  WIDTH-1:0] acc_cnt                        ;
	reg [1:0] current_state, next_state;
	wire                      in_accm = (current_state == STATE_ACCM);
	wire                      acc_done = (acc_cnt == num_acc) && (num_acc != 0);
	// FIFO interfaces
	wire        [  WIDTH-1:0] fifo_a_out  ;
	wire                      fifo_a_valid, fifo_a_ready;
	wire        [  WIDTH-1:0] fifo_b_out  ;
	wire                      fifo_b_valid, fifo_b_ready;
	wire        [4*WIDTH-1:0] fifo_m_in   ;
	wire                      fifo_m_valid, fifo_m_ready;
	wire        [4*WIDTH-1:0] fifo_m_out  ;
	wire signed [4*WIDTH-1:0] mult_signed_ext  ;


	wire is_a = fifo_a_valid && fifo_a_ready;
	wire is_b = fifo_b_valid && fifo_b_ready;

	// combinational assign
	genvar li;
	generate
		if (PACK_LANES <= 1) begin : gen_scalar_mult
			wire signed [WIDTH-1:0] fifo_a_out_signed = fifo_a_out;
			wire signed [WIDTH-1:0] fifo_b_out_signed = fifo_b_out;
			wire signed [2*WIDTH-1:0] mult_signed = fifo_a_out_signed * fifo_b_out_signed;
			assign mult_signed_ext = {{(2*WIDTH){mult_signed[2*WIDTH-1]}}, mult_signed};
		end else begin : gen_packed_dot
			wire signed [4*WIDTH-1:0] lane_sum_ext [0:PACK_LANES];
			assign lane_sum_ext[0] = {4*WIDTH{1'b0}};
			for (li = 0; li < PACK_LANES; li = li + 1) begin : gen_lane
				wire signed [ELEM_WIDTH-1:0] a_lane = fifo_a_out[(li*ELEM_WIDTH) +: ELEM_WIDTH];
				wire signed [ELEM_WIDTH-1:0] b_lane = fifo_b_out[(li*ELEM_WIDTH) +: ELEM_WIDTH];
				wire signed [(2*ELEM_WIDTH)-1:0] lane_mult = a_lane * b_lane;
				wire signed [4*WIDTH-1:0] lane_mult_ext = {{(4*WIDTH-(2*ELEM_WIDTH)){lane_mult[(2*ELEM_WIDTH)-1]}}, lane_mult};
				assign lane_sum_ext[li+1] = lane_sum_ext[li] + lane_mult_ext;
			end
			assign mult_signed_ext = lane_sum_ext[PACK_LANES];
		end
	endgenerate
	assign fifo_m_in    = accm;
	assign fifo_m_valid = in_accm && acc_done;
	assign fifo_a_ready = in_accm && !acc_done;
	assign fifo_b_ready = in_accm && !acc_done;
	assign m            = m_valid ? fifo_m_out : {4*WIDTH{1'b0}};
	assign start_ready  = (current_state == STATE_IDLE);
	assign tile_done    = fifo_m_valid && fifo_m_ready;

	sync_fifo #(.WIDTH(WIDTH), .DEPTH(4)) fifo_a (
		.clk      (clk         ),
		.resetn   (rstn        ),
		.clear    (clear       ),
		.data_in  (a           ),
		.valid_in (a_valid     ),
		.ready_in (a_ready     ),
		.data_out (fifo_a_out  ),
		.valid_out(fifo_a_valid),
		.ready_out(fifo_a_ready)
	);

	sync_fifo #(.WIDTH(WIDTH), .DEPTH(4)) fifo_b (
		.clk      (clk         ),
		.resetn   (rstn        ),
		.clear    (clear       ),
		.data_in  (b           ),
		.valid_in (b_valid     ),
		.ready_in (b_ready     ),
		.data_out (fifo_b_out  ),
		.valid_out(fifo_b_valid),
		.ready_out(fifo_b_ready)
	);

	sync_fifo #(.WIDTH(4*WIDTH), .DEPTH(4)) fifo_m (
		.clk      (clk         ),
		.resetn   (rstn        ),
		.clear    (clear       ),
		.data_in  (fifo_m_in   ),
		.valid_in (fifo_m_valid),
		.ready_in (fifo_m_ready),
		.data_out (fifo_m_out  ),
		.valid_out(m_valid     ),
		.ready_out(m_ready     )
	);




	always@(posedge clk or negedge rstn) begin
		if(!rstn) begin
			current_state <= STATE_IDLE;
		end else begin
			current_state <= next_state;
		end
	end

	always@(*) begin
		next_state = current_state;
		case(current_state)
			STATE_IDLE : begin
				next_state = start ? STATE_ACCM : STATE_IDLE;
			end
			STATE_ACCM : begin
				next_state = (clear || (acc_done && fifo_m_ready)) ? STATE_IDLE : STATE_ACCM;
			end
			default : begin
				next_state = STATE_IDLE;
			end
		endcase
	end

	always@(posedge clk or negedge rstn) begin
		if(!rstn) begin
			accm    <= 0;
			acc_cnt <= 0;
		end else if (clear) begin
			accm    <= 0;
			acc_cnt <= 0;
		end else begin
			case(current_state)
				STATE_IDLE : begin
					accm    <= 0;
					acc_cnt <= 0;
				end
				STATE_ACCM : begin
					if(acc_done) begin
						if (fifo_m_ready) begin
							accm    <= 0;
							acc_cnt <= 0;
						end
					end else if(is_a && is_b) begin
						accm    <= accm + mult_signed_ext;
						acc_cnt <= acc_cnt + 1;
					end
				end
				default : begin
					accm    <= 0;
					acc_cnt <= 0;
				end
			endcase
		end
	end
endmodule
