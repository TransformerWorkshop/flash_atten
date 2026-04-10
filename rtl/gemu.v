module GEMU #(parameter WIDTH = 32) (
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
	input  wire [  WIDTH-1:0] num_acc
);

	localparam STATE_IDLE = 2'b00;
	localparam STATE_ACCM = 2'b01;


	reg  [4*WIDTH-1:0] accm                           ;
	reg  [  WIDTH-1:0] acc_cnt                        ;
	wire               acc_done = (acc_cnt == num_acc);
	// FIFO interfaces
	wire [  WIDTH-1:0] fifo_a_out  ;
	wire               fifo_a_valid, fifo_a_ready;
	wire [  WIDTH-1:0] fifo_b_out  ;
	wire               fifo_b_valid, fifo_b_ready;
	wire [4*WIDTH-1:0] fifo_m_in   ;
	wire               fifo_m_valid, fifo_m_ready;
	wire [4*WIDTH-1:0] fifo_m_out  ;


	wire is_a = fifo_a_valid && fifo_a_ready;
	wire is_b = fifo_b_valid && fifo_b_ready;

	// state registers
	reg [1:0] current_state, next_state;

	// combinational assign
	assign fifo_m_in    = accm;
	assign fifo_m_valid = acc_done;
	assign fifo_a_ready = !acc_done;
	assign fifo_b_ready = !acc_done;
	assign m            = m_valid ? fifo_m_out : 0;

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
		case(current_state)
			STATE_IDLE : begin
				next_state = start ? STATE_ACCM : STATE_IDLE;
			end
			STATE_ACCM : begin
				next_state = (acc_done || clear) ? STATE_IDLE : STATE_ACCM;
			end
		endcase
	end

	always@(posedge clk or negedge rstn) begin
		if(!rstn) begin
			accm    <= 0;
			acc_cnt <= 0;
		end else begin
			case(next_state)
				STATE_IDLE : begin
					accm    <= 0;
					acc_cnt <= 0;
				end
				STATE_ACCM : begin
					if(is_a && is_b) begin
						accm    <= accm + fifo_a_out * fifo_b_out;
						acc_cnt <= acc_cnt + 1;
					end
				end
			endcase
		end
	end
endmodule