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
	reg signed [4*WIDTH-1:0] m_data_r                       ;
	reg                      m_valid_r                      ;
	reg [1:0] current_state, next_state;
	wire                      in_accm = (current_state == STATE_ACCM);
	wire                      acc_done = (acc_cnt == num_acc) && (num_acc != 0);
	wire signed [4*WIDTH-1:0] mult_signed_ext  ;
	wire                      pair_ready;
	wire                      pair_fire;


	assign pair_ready = ((current_state == STATE_IDLE) && !m_valid_r) || (in_accm && !acc_done);
	assign pair_fire = a_valid && b_valid && pair_ready;

	// combinational assign
	genvar li;
	generate
		if (PACK_LANES <= 1) begin : gen_scalar_mult
			wire signed [WIDTH-1:0] a_signed = a;
			wire signed [WIDTH-1:0] b_signed = b;
			wire signed [2*WIDTH-1:0] mult_signed = a_signed * b_signed;
			assign mult_signed_ext = {{(2*WIDTH){mult_signed[2*WIDTH-1]}}, mult_signed};
		end else begin : gen_packed_dot
			wire signed [4*WIDTH-1:0] lane_sum_ext [0:PACK_LANES];
			assign lane_sum_ext[0] = {4*WIDTH{1'b0}};
			for (li = 0; li < PACK_LANES; li = li + 1) begin : gen_lane
				wire signed [ELEM_WIDTH-1:0] a_lane = a[(li*ELEM_WIDTH) +: ELEM_WIDTH];
				wire signed [ELEM_WIDTH-1:0] b_lane = b[(li*ELEM_WIDTH) +: ELEM_WIDTH];
				wire signed [(2*ELEM_WIDTH)-1:0] lane_mult = a_lane * b_lane;
				wire signed [4*WIDTH-1:0] lane_mult_ext = {{(4*WIDTH-(2*ELEM_WIDTH)){lane_mult[(2*ELEM_WIDTH)-1]}}, lane_mult};
				assign lane_sum_ext[li+1] = lane_sum_ext[li] + lane_mult_ext;
			end
			assign mult_signed_ext = lane_sum_ext[PACK_LANES];
		end
	endgenerate
	assign a_ready      = pair_ready;
	assign b_ready      = pair_ready;
	assign m            = m_valid ? m_data_r : {4*WIDTH{1'b0}};
	assign m_valid      = m_valid_r;
	assign start_ready  = (current_state == STATE_IDLE) && !m_valid_r;
	assign tile_done    = in_accm && acc_done && !m_valid_r;


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
				next_state = (clear || (acc_done && !m_valid_r)) ? STATE_IDLE : STATE_ACCM;
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
			m_data_r <= 0;
			m_valid_r <= 1'b0;
		end else if (clear) begin
			accm    <= 0;
			acc_cnt <= 0;
			m_data_r <= 0;
			m_valid_r <= 1'b0;
		end else begin
			if (m_valid_r && m_ready) begin
				m_valid_r <= 1'b0;
			end
			case(current_state)
				STATE_IDLE : begin
					if (start && pair_fire) begin
						accm    <= mult_signed_ext;
						acc_cnt <= 1;
					end else begin
						accm    <= 0;
						acc_cnt <= 0;
					end
				end
				STATE_ACCM : begin
					if(acc_done) begin
						if (!m_valid_r) begin
							m_data_r <= accm;
							m_valid_r <= 1'b1;
							accm    <= 0;
							acc_cnt <= 0;
						end
					end else if(pair_fire) begin
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
