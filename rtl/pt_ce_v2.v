`include "param.vh"

module PT_CE_V2 #(
	parameter DATA_WIDTH   = 32,
	parameter GEMM_X_DIM   = 4,
	parameter GEMM_Y_DIM   = 4,
	parameter A_BANK_DEPTH = 8,
	parameter B_BANK_DEPTH = 16,
	parameter M_BANK_DEPTH = 16,
	parameter M_WRITE_LANES = GEMM_Y_DIM
) (
	input  wire                       clk,
	input  wire                       rstn,
	input  wire                       clear,
	input  wire                       ce_cmd_valid,
	output wire                       ce_cmd_ready,
	input  wire [`INST_WIDTH-1:0]     ce_cmd_ctrl,
	input  wire [31:0]                ce_cmd_id,
	input  wire [`PT_LOCAL_ADDR_W-1:0] ce_a_local_base,
	input  wire [`PT_LOCAL_ADDR_W-1:0] ce_b_local_base,
	output wire                       a_mem_rd_en,
	output reg                        exec_a_buf,
	output reg  [(((A_BANK_DEPTH * GEMM_X_DIM) <= 1) ? 1 : $clog2(A_BANK_DEPTH * GEMM_X_DIM))-1:0] exec_a_addr,
	output wire                       b_mem_rd_en,
	output reg                        exec_b_buf,
	output reg  [(((B_BANK_DEPTH * GEMM_Y_DIM) <= 1) ? 1 : $clog2(B_BANK_DEPTH * GEMM_Y_DIM))-1:0] exec_b_addr,
	output reg                        exec_m_b_buf,
	output reg  [(((M_BANK_DEPTH * GEMM_X_DIM) <= 1) ? 1 : $clog2(M_BANK_DEPTH * GEMM_X_DIM))-1:0] exec_m_b_addr,
	output wire                       exec_m_b_rd_en,
	output wire                       gemm_a_valid,
	output wire                       gemm_b_valid,
	output wire                       gemm_start,
	output wire [DATA_WIDTH-1:0]      gemm_num_acc,
	input  wire                       gemm_a_ready,
	input  wire                       gemm_b_ready,
	input  wire [GEMM_Y_DIM*DATA_WIDTH-1:0] quant_m_data,
	input  wire [31:0]                quant_m_idx,
	input  wire                       quant_m_valid,
	input  wire                       quant_m_last,
	output wire                       quant_m_ready,
	input  wire [GEMM_Y_DIM*DATA_WIDTH-1:0] b_mem_row_data,
	input  wire [GEMM_Y_DIM*DATA_WIDTH-1:0] m_mem_row_data,
	output wire [GEMM_Y_DIM*DATA_WIDTH-1:0] gema_lhs_data,
	output wire [GEMM_Y_DIM*DATA_WIDTH-1:0] gema_rhs_data,
	output wire [31:0]                gema_in_idx,
	output wire                       gema_in_last,
	output wire                       gema_in_valid,
	input  wire                       gema_in_ready,
	input  wire [GEMM_Y_DIM*DATA_WIDTH-1:0] add_m_data,
	input  wire [31:0]                add_m_idx,
	input  wire                       add_m_valid,
	input  wire                       add_m_last,
	output wire                       add_m_ready,
	output reg                        m_mem_wr_en,
	output reg                        m_mem_wr_buf,
	output reg  [GEMM_Y_DIM-1:0]      m_mem_wr_mask,
	output reg  [(((M_BANK_DEPTH * GEMM_X_DIM) <= 1) ? 1 : $clog2(M_BANK_DEPTH * GEMM_X_DIM))-1:0] m_mem_wr_addr,
	output reg  [GEMM_Y_DIM*DATA_WIDTH-1:0]      m_mem_wr_data,
	output reg                        ce_resp_valid,
	output reg  [31:0]                ce_resp,
	output reg                        ce_irq
);

	localparam integer A_DEPTH = A_BANK_DEPTH * GEMM_X_DIM;
	localparam integer B_DEPTH = B_BANK_DEPTH * GEMM_Y_DIM;
	localparam integer M_DEPTH = M_BANK_DEPTH * GEMM_X_DIM;
	localparam integer A_AW = (A_DEPTH <= 1) ? 1 : $clog2(A_DEPTH);
	localparam integer B_AW = (B_DEPTH <= 1) ? 1 : $clog2(B_DEPTH);
	localparam integer M_AW = (M_DEPTH <= 1) ? 1 : $clog2(M_DEPTH);
	localparam integer A_DIM_SHIFT = $clog2((GEMM_X_DIM <= 0) ? 1 : GEMM_X_DIM);
	localparam integer B_DIM_SHIFT = $clog2((GEMM_Y_DIM <= 0) ? 1 : GEMM_Y_DIM);
	localparam integer STORE_BASE_W = (GEMM_Y_DIM <= 1) ? 1 : $clog2(GEMM_Y_DIM + 1);

	localparam [2:0] ST_IDLE        = 3'd0;
	localparam [2:0] ST_EXEC_START  = 3'd1;
	localparam [2:0] ST_EXEC_FEED   = 3'd2;
	localparam [2:0] ST_WAIT_RESULT = 3'd3;
	localparam [2:0] ST_M_STORE     = 3'd4;
	localparam [2:0] ST_ADD_REQ     = 3'd5;
	localparam [2:0] ST_ADD_CAPTURE = 3'd6;
	localparam [2:0] ST_ADD_SEND    = 3'd7;

	reg [2:0] state_r, state_n;
	reg [3:0] cur_opcode_r;
	reg [31:0] cur_ctrl_r;
	reg [31:0] cur_id_r;
	reg [15:0] exec_issue_cnt_r, exec_rsp_cnt_r;
	reg cur_a_buf_r, cur_b_buf_r, cur_m_src_buf_r;
	reg [A_AW-1:0] cur_a_row_base_r;
	reg [B_AW-1:0] cur_b_row_base_r;
	reg m_wr_buf_ptr_r, cur_m_wr_buf_r;
	reg [M_AW-1:0] add_row_idx_r;
	reg [GEMM_Y_DIM*DATA_WIDTH-1:0] add_lhs_row_r, add_rhs_row_r;
	reg [GEMM_Y_DIM*DATA_WIDTH-1:0] store_result_row_r;
	reg [M_AW-1:0] store_row_addr_r;
	reg store_row_last_r;
	reg [STORE_BASE_W-1:0] store_chunk_base_r;

	wire cur_is_matmul = (cur_opcode_r == `PT_OP_MATMUL);
	wire cur_is_matadd = (cur_opcode_r == `PT_OP_MATADD);
	wire mm_exec_rsp_valid = cur_is_matmul && (state_r == ST_EXEC_FEED) && (exec_rsp_cnt_r < exec_issue_cnt_r);
	wire mm_exec_rsp_fire  = mm_exec_rsp_valid && gemm_a_ready && gemm_b_ready;
	wire mm_exec_req_fire  = cur_is_matmul &&
	                         (state_r == ST_EXEC_FEED) &&
	                         (exec_issue_cnt_r < GEMM_X_DIM) &&
	                         ((exec_issue_cnt_r == 0) || mm_exec_rsp_fire);
	wire add_send_fire = (state_r == ST_ADD_SEND) && gema_in_ready;
	wire res_valid = cur_is_matadd ? add_m_valid : quant_m_valid;
	wire res_ready = (state_r == ST_WAIT_RESULT);
	wire res_fire = res_valid && res_ready;
	wire [GEMM_Y_DIM*DATA_WIDTH-1:0] res_data = cur_is_matadd ? add_m_data : quant_m_data;
	wire [31:0] res_idx = cur_is_matadd ? add_m_idx : quant_m_idx;
	wire res_last = cur_is_matadd ? add_m_last : quant_m_last;
	wire [STORE_BASE_W:0] store_chunk_limit = store_chunk_base_r + M_WRITE_LANES;
	wire store_chunk_last = (store_chunk_limit >= GEMM_Y_DIM);

	function is_pow2;
		input integer value;
		begin
			is_pow2 = (value > 0) ? (((value & (value - 1)) == 0) ? 1'b1 : 1'b0) : 1'b0;
		end
	endfunction

	initial begin
		if (!is_pow2(GEMM_X_DIM) || !is_pow2(GEMM_Y_DIM)) begin
			$fatal(1, "PT_CE_V2 requires power-of-two GEMM_X_DIM/GEMM_Y_DIM, got %0d x %0d", GEMM_X_DIM, GEMM_Y_DIM);
		end
		if ((M_WRITE_LANES <= 0) || (M_WRITE_LANES > GEMM_Y_DIM)) begin
			$fatal(1, "PT_CE_V2 requires 0 < M_WRITE_LANES <= GEMM_Y_DIM, got %0d for Y=%0d", M_WRITE_LANES, GEMM_Y_DIM);
		end
	end

	function [31:0] pack_resp;
		input err;
		input m_buf;
		input [31:0] id;
		begin
			pack_resp = {err, m_buf, id[29:0]};
		end
	endfunction

	integer wi;

	assign ce_cmd_ready = (state_r == ST_IDLE);
	assign gemm_start   = (state_r == ST_EXEC_START) && cur_is_matmul;
	assign gemm_num_acc = GEMM_X_DIM[DATA_WIDTH-1:0];
	assign gemm_a_valid = mm_exec_rsp_valid;
	assign gemm_b_valid = mm_exec_rsp_valid;
	assign a_mem_rd_en  = mm_exec_req_fire;
	assign b_mem_rd_en  = (mm_exec_req_fire && cur_is_matmul) || (state_r == ST_ADD_REQ);
	assign exec_m_b_rd_en = (state_r == ST_ADD_REQ);
	assign quant_m_ready = (state_r == ST_WAIT_RESULT) && cur_is_matmul;
	assign add_m_ready   = (state_r == ST_WAIT_RESULT) && cur_is_matadd;
	assign gema_lhs_data = add_lhs_row_r;
	assign gema_rhs_data = add_rhs_row_r;
	assign gema_in_idx   = {{(32-M_AW){1'b0}}, add_row_idx_r};
	assign gema_in_last  = (add_row_idx_r == (GEMM_X_DIM - 1));
	assign gema_in_valid = (state_r == ST_ADD_SEND);

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			state_r <= ST_IDLE;
		end else if (clear) begin
			state_r <= ST_IDLE;
		end else begin
			state_r <= state_n;
		end
	end

	always @(*) begin
		state_n = state_r;
		case (state_r)
			ST_IDLE: if (ce_cmd_valid) state_n = ST_EXEC_START;
			ST_EXEC_START: state_n = cur_is_matadd ? ST_ADD_REQ : ST_EXEC_FEED;
			ST_EXEC_FEED: if (mm_exec_rsp_fire && (exec_rsp_cnt_r == (GEMM_X_DIM - 1))) state_n = ST_WAIT_RESULT;
			ST_WAIT_RESULT: if (res_fire) state_n = ST_M_STORE;
			ST_M_STORE: begin
				if (store_chunk_last) begin
					if (store_row_last_r) begin
						state_n = ST_IDLE;
					end else if (cur_is_matadd) begin
						state_n = ST_ADD_REQ;
					end else begin
						state_n = ST_WAIT_RESULT;
					end
				end
			end
			ST_ADD_REQ: state_n = ST_ADD_CAPTURE;
			ST_ADD_CAPTURE: state_n = ST_ADD_SEND;
			ST_ADD_SEND: if (add_send_fire) state_n = ST_WAIT_RESULT;
			default: state_n = ST_IDLE;
		endcase
	end

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			cur_opcode_r      <= 4'd0;
			cur_ctrl_r        <= 32'd0;
			cur_id_r          <= 32'd0;
			exec_issue_cnt_r  <= 16'd0;
			exec_rsp_cnt_r    <= 16'd0;
			exec_a_buf        <= 1'b0;
			exec_b_buf        <= 1'b0;
			exec_a_addr       <= {A_AW{1'b0}};
			exec_b_addr       <= {B_AW{1'b0}};
			exec_m_b_buf      <= 1'b0;
			exec_m_b_addr     <= {M_AW{1'b0}};
			cur_a_buf_r       <= 1'b0;
			cur_b_buf_r       <= 1'b0;
			cur_m_src_buf_r   <= 1'b0;
			cur_a_row_base_r  <= {A_AW{1'b0}};
			cur_b_row_base_r  <= {B_AW{1'b0}};
			m_wr_buf_ptr_r    <= 1'b0;
			cur_m_wr_buf_r    <= 1'b0;
			add_row_idx_r     <= {M_AW{1'b0}};
			add_lhs_row_r     <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			add_rhs_row_r     <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			store_result_row_r <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			store_row_addr_r  <= {M_AW{1'b0}};
			store_row_last_r  <= 1'b0;
			store_chunk_base_r <= {STORE_BASE_W{1'b0}};
			m_mem_wr_en       <= 1'b0;
			m_mem_wr_buf      <= 1'b0;
			m_mem_wr_mask     <= {GEMM_Y_DIM{1'b0}};
			m_mem_wr_addr     <= {M_AW{1'b0}};
			m_mem_wr_data     <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			ce_resp_valid     <= 1'b0;
			ce_resp           <= 32'd0;
			ce_irq            <= 1'b0;
		end else if (clear) begin
			cur_opcode_r      <= 4'd0;
			cur_ctrl_r        <= 32'd0;
			cur_id_r          <= 32'd0;
			exec_issue_cnt_r  <= 16'd0;
			exec_rsp_cnt_r    <= 16'd0;
			exec_a_buf        <= 1'b0;
			exec_b_buf        <= 1'b0;
			exec_a_addr       <= {A_AW{1'b0}};
			exec_b_addr       <= {B_AW{1'b0}};
			exec_m_b_buf      <= 1'b0;
			exec_m_b_addr     <= {M_AW{1'b0}};
			cur_a_buf_r       <= 1'b0;
			cur_b_buf_r       <= 1'b0;
			cur_m_src_buf_r   <= 1'b0;
			cur_a_row_base_r  <= {A_AW{1'b0}};
			cur_b_row_base_r  <= {B_AW{1'b0}};
			m_wr_buf_ptr_r    <= 1'b0;
			cur_m_wr_buf_r    <= 1'b0;
			add_row_idx_r     <= {M_AW{1'b0}};
			add_lhs_row_r     <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			add_rhs_row_r     <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			store_result_row_r <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			store_row_addr_r  <= {M_AW{1'b0}};
			store_row_last_r  <= 1'b0;
			store_chunk_base_r <= {STORE_BASE_W{1'b0}};
			m_mem_wr_en       <= 1'b0;
			m_mem_wr_buf      <= 1'b0;
			m_mem_wr_mask     <= {GEMM_Y_DIM{1'b0}};
			m_mem_wr_addr     <= {M_AW{1'b0}};
			m_mem_wr_data     <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			ce_resp_valid     <= 1'b0;
			ce_resp           <= 32'd0;
			ce_irq            <= 1'b0;
		end else begin
			ce_resp_valid <= 1'b0;
			ce_irq        <= 1'b0;
			m_mem_wr_en   <= 1'b0;
			m_mem_wr_mask <= {GEMM_Y_DIM{1'b0}};

			case (state_r)
				ST_IDLE: begin
					if (ce_cmd_valid) begin
						cur_opcode_r     <= ce_cmd_ctrl[`PT_INST_OPCODE_H:`PT_INST_OPCODE_L];
						cur_ctrl_r       <= ce_cmd_ctrl;
						cur_id_r         <= ce_cmd_id;
						cur_a_buf_r      <= ce_a_local_base[`PT_LOCAL_BUF_BIT];
						cur_b_buf_r      <= ce_b_local_base[`PT_LOCAL_BUF_BIT];
						cur_m_src_buf_r  <= ce_cmd_ctrl[`PT_INST_A_OFF_L+8];
						cur_a_row_base_r <= ce_a_local_base[`PT_LOCAL_ELEM_H:`PT_LOCAL_ELEM_L] >> A_DIM_SHIFT;
						cur_b_row_base_r <= ce_b_local_base[`PT_LOCAL_ELEM_H:`PT_LOCAL_ELEM_L] >> B_DIM_SHIFT;
						cur_m_wr_buf_r   <= m_wr_buf_ptr_r;
					end
				end

				ST_EXEC_START: begin
					exec_issue_cnt_r <= 16'd0;
					exec_rsp_cnt_r   <= 16'd0;
					add_row_idx_r    <= {M_AW{1'b0}};
					exec_a_buf       <= cur_a_buf_r;
					exec_b_buf       <= cur_b_buf_r;
					exec_a_addr      <= cur_a_row_base_r[A_AW-1:0];
					exec_b_addr      <= cur_b_row_base_r[B_AW-1:0];
					exec_m_b_buf     <= cur_m_src_buf_r;
					exec_m_b_addr    <= {M_AW{1'b0}};
				end

				ST_EXEC_FEED: begin
					if (mm_exec_req_fire) begin
						exec_issue_cnt_r <= exec_issue_cnt_r + 1'b1;
						if (exec_issue_cnt_r != (GEMM_X_DIM - 1)) begin
							exec_a_addr <= cur_a_row_base_r[A_AW-1:0] + exec_issue_cnt_r[A_AW-1:0] + 1'b1;
							exec_b_addr <= cur_b_row_base_r[B_AW-1:0] + exec_issue_cnt_r[B_AW-1:0] + 1'b1;
						end
					end
					if (mm_exec_rsp_fire) begin
						exec_rsp_cnt_r <= exec_rsp_cnt_r + 1'b1;
					end
				end

				ST_WAIT_RESULT: begin
					if (res_fire) begin
						store_result_row_r <= res_data;
						store_row_addr_r   <= res_idx[M_AW-1:0];
						store_row_last_r   <= res_last;
						store_chunk_base_r <= {STORE_BASE_W{1'b0}};
					end
				end

				ST_M_STORE: begin
					m_mem_wr_en   <= 1'b1;
					m_mem_wr_buf  <= cur_m_wr_buf_r;
					m_mem_wr_mask <= {GEMM_Y_DIM{1'b0}};
					m_mem_wr_addr <= store_row_addr_r;
					m_mem_wr_data <= store_result_row_r;
					for (wi = 0; wi < GEMM_Y_DIM; wi = wi + 1) begin
						if ((wi >= store_chunk_base_r) && (wi < (store_chunk_base_r + M_WRITE_LANES))) begin
							m_mem_wr_mask[wi] <= 1'b1;
						end
					end
					if (store_chunk_last) begin
						if (store_row_last_r) begin
							ce_resp       <= pack_resp(1'b0, cur_m_wr_buf_r, cur_id_r);
							ce_resp_valid <= 1'b1;
							ce_irq        <= 1'b1;
							m_wr_buf_ptr_r <= ~m_wr_buf_ptr_r;
						end else if (cur_is_matadd) begin
							exec_b_addr   <= cur_b_row_base_r[B_AW-1:0] + add_row_idx_r[B_AW-1:0];
							exec_m_b_addr <= add_row_idx_r;
						end
					end else begin
						store_chunk_base_r <= store_chunk_base_r + M_WRITE_LANES;
					end
				end

				ST_ADD_CAPTURE: begin
					add_lhs_row_r <= m_mem_row_data;
					add_rhs_row_r <= b_mem_row_data;
				end

				ST_ADD_SEND: begin
					if (add_send_fire && (add_row_idx_r != (GEMM_X_DIM - 1))) begin
						add_row_idx_r <= add_row_idx_r + 1'b1;
					end
				end
				default: begin
				end
			endcase
		end
	end

endmodule
