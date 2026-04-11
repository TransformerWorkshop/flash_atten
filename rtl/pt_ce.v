`include "param.vh"

module PT_CE #(
	parameter DATA_WIDTH   = 32,
	parameter GEMM_X_DIM   = 4 ,
	parameter GEMM_Y_DIM   = 4 ,
	parameter A_BANK_DEPTH = 16,
	parameter B_BANK_DEPTH = 16
) (
	input  wire                       clk ,
	input  wire                       rstn,
	input  wire                       clear,

	// issue queue from MD
	input  wire                       ce_inst_valid,
	output wire                       ce_inst_ready,
	input  wire [`INST_WIDTH-1:0]     ce_inst,
	input  wire [               31:0] ce_id  ,

	// memory read controls
	output wire                       a_mem_rd_en,
	output reg                        exec_a_buf,
	output reg  [((A_BANK_DEPTH <= 1) ? 1 : $clog2(A_BANK_DEPTH))-1:0] exec_a_addr,
	output wire                       b_mem_rd_en,
	output reg                        exec_b_buf,
	output reg  [((B_BANK_DEPTH <= 1) ? 1 : $clog2(B_BANK_DEPTH))-1:0] exec_b_addr,

	// gemm control/status
	output wire                       gemm_a_valid,
	output wire                       gemm_b_valid,
	output wire                       gemm_start,
	output wire [         DATA_WIDTH-1:0] gemm_num_acc,
	input  wire                       gemm_a_ready,
	input  wire                       gemm_b_ready,
	input  wire                       gemm_m_valid,
	input  wire                       gemm_m_last ,

	// response
	output reg                        ce_resp_valid,
	output reg  [               31:0] ce_resp
);

	localparam integer A_AW = (A_BANK_DEPTH <= 1) ? 1 : $clog2(A_BANK_DEPTH);
	localparam integer B_AW = (B_BANK_DEPTH <= 1) ? 1 : $clog2(B_BANK_DEPTH);

	localparam [1:0] ST_IDLE       = 2'd0;
	localparam [1:0] ST_EXEC_START = 2'd1;
	localparam [1:0] ST_EXEC_FEED  = 2'd2;
	localparam [1:0] ST_WAIT_GEMM  = 2'd3;

	reg [1:0] state;
	reg [1:0] next_state;
	reg [31:0] cur_id;
	reg [9:0] cur_a_off;
	reg [9:0] cur_b_off;
	reg [15:0] exec_k_cnt;

	assign ce_inst_ready = (state == ST_IDLE);
	assign gemm_start    = (state == ST_EXEC_START);
	assign gemm_num_acc  = GEMM_X_DIM[DATA_WIDTH-1:0];
	assign gemm_a_valid  = (state == ST_EXEC_FEED);
	assign gemm_b_valid  = (state == ST_EXEC_FEED);
	assign a_mem_rd_en   = (state == ST_EXEC_FEED);
	assign b_mem_rd_en   = (state == ST_EXEC_FEED);

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			state <= ST_IDLE;
		end else if (clear) begin
			state <= ST_IDLE;
		end else begin
			state <= next_state;
		end
	end

	always @(*) begin
		next_state = state;
		case (state)
			ST_IDLE: begin
				if (ce_inst_valid) begin
					next_state = ST_EXEC_START;
				end
			end

			ST_EXEC_START: begin
				next_state = ST_EXEC_FEED;
			end

			ST_EXEC_FEED: begin
				if (gemm_a_ready && gemm_b_ready && (exec_k_cnt == (GEMM_X_DIM - 1))) begin
					next_state = ST_WAIT_GEMM;
				end
			end

			ST_WAIT_GEMM: begin
				if (gemm_m_valid && gemm_m_last) begin
					next_state = ST_IDLE;
				end
			end

			default: begin
				next_state = ST_IDLE;
			end
		endcase
	end

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			cur_id       <= 32'd0;
			cur_a_off    <= 10'd0;
			cur_b_off    <= 10'd0;
			exec_k_cnt   <= 16'd0;
			exec_a_buf   <= 1'b0;
			exec_b_buf   <= 1'b0;
			exec_a_addr  <= {A_AW{1'b0}};
			exec_b_addr  <= {B_AW{1'b0}};
			ce_resp_valid <= 1'b0;
			ce_resp      <= 32'd0;
		end else if (clear) begin
			cur_id       <= 32'd0;
			cur_a_off    <= 10'd0;
			cur_b_off    <= 10'd0;
			exec_k_cnt   <= 16'd0;
			exec_a_buf   <= 1'b0;
			exec_b_buf   <= 1'b0;
			exec_a_addr  <= {A_AW{1'b0}};
			exec_b_addr  <= {B_AW{1'b0}};
			ce_resp_valid <= 1'b0;
			ce_resp      <= 32'd0;
		end else begin
			ce_resp_valid <= 1'b0;

			case (state)
				ST_IDLE: begin
					if (ce_inst_valid) begin
						cur_id    <= ce_id;
						cur_a_off <= ce_inst[`PT_INST_A_OFF_H:`PT_INST_A_OFF_L];
						cur_b_off <= ce_inst[`PT_INST_B_OFF_H:`PT_INST_B_OFF_L];
						exec_a_buf <= ce_inst[`PT_INST_A_OFF_H];
						exec_b_buf <= ce_inst[`PT_INST_B_OFF_H];
					end
				end

				ST_EXEC_START: begin
					exec_k_cnt   <= 16'd0;
					exec_a_addr  <= cur_a_off[A_AW-1:0];
					exec_b_addr  <= cur_b_off[B_AW-1:0];
				end

				ST_EXEC_FEED: begin
					exec_a_addr <= cur_a_off[A_AW-1:0] + exec_k_cnt[A_AW-1:0];
					exec_b_addr <= cur_b_off[B_AW-1:0] + exec_k_cnt[B_AW-1:0];
					if (gemm_a_ready && gemm_b_ready) begin
						if (exec_k_cnt != (GEMM_X_DIM - 1)) begin
							exec_k_cnt <= exec_k_cnt + 1'b1;
						end
					end
				end

				ST_WAIT_GEMM: begin
					if (gemm_m_valid && gemm_m_last) begin
						ce_resp       <= cur_id;
						ce_resp_valid <= 1'b1;
					end
				end

				default: begin
				end
			endcase
		end
	end

endmodule
