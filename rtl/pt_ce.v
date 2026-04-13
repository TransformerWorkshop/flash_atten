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

	// memory read controls for A/B bank paths
	output wire                       a_mem_rd_en,
	output reg                        exec_a_buf,
	output reg  [((A_BANK_DEPTH <= 1) ? 1 : $clog2(A_BANK_DEPTH))-1:0] exec_a_addr,
	output wire                       b_mem_rd_en,
	output reg                        exec_b_buf,
	output reg  [((B_BANK_DEPTH <= 1) ? 1 : $clog2(B_BANK_DEPTH))-1:0] exec_b_addr,

	// M-window read selects
	output reg                        exec_a_is_m,
	output reg                        exec_b_is_m,
	output reg                        exec_m_a_buf,
	output reg                        exec_m_b_buf,
	output reg  [((A_BANK_DEPTH <= 1) ? 1 : $clog2(A_BANK_DEPTH))-1:0] exec_m_a_addr,
	output reg  [((B_BANK_DEPTH <= 1) ? 1 : $clog2(B_BANK_DEPTH))-1:0] exec_m_b_addr,
	output wire                       exec_m_a_rd_en,
	output wire                       exec_m_b_rd_en,

	// gemm control/status
	output wire                       gemm_a_valid,
	output wire                       gemm_b_valid,
	output wire                       gemm_start,
	output wire [         DATA_WIDTH-1:0] gemm_num_acc,
	input  wire                       gemm_a_ready,
	input  wire                       gemm_b_ready,

	// quantized GEMM row input stream
	input  wire [GEMM_Y_DIM*DATA_WIDTH-1:0] quant_m_data,
	input  wire [               31:0] quant_m_idx,
	input  wire                       quant_m_valid,
	input  wire                       quant_m_last ,
	output wire                       quant_m_ready,

	// MATADD source row data
	input  wire [GEMM_Y_DIM*DATA_WIDTH-1:0] b_mem_row_data,
	input  wire [GEMM_Y_DIM*DATA_WIDTH-1:0] m_mem_row_data,

	// MATADD row stream toward GEMA
	output wire [GEMM_Y_DIM*DATA_WIDTH-1:0] gema_lhs_data,
	output wire [GEMM_Y_DIM*DATA_WIDTH-1:0] gema_rhs_data,
	output wire [               31:0] gema_in_idx,
	output wire                       gema_in_last,
	output wire                       gema_in_valid,
	input  wire                       gema_in_ready,

	// GEMA result row input stream
	input  wire [GEMM_Y_DIM*DATA_WIDTH-1:0] add_m_data,
	input  wire [               31:0] add_m_idx,
	input  wire                       add_m_valid,
	input  wire                       add_m_last,
	output wire                       add_m_ready,

	// serialized quantized M writeback toward PT_MEM_BANK
	output reg                        m_mem_wr_en,
	output reg                        m_mem_wr_buf,
	output reg  [((GEMM_Y_DIM <= 1) ? 1 : $clog2(GEMM_Y_DIM))-1:0] m_mem_wr_lane,
	output reg  [((A_BANK_DEPTH <= 1) ? 1 : $clog2(A_BANK_DEPTH))-1:0] m_mem_wr_addr,
	output reg  [         DATA_WIDTH-1:0] m_mem_wr_data,

	// response + completion irq
	output reg                        ce_resp_valid,
	output reg  [               31:0] ce_resp,
	output reg                        ce_irq
);

	localparam integer A_AW = (A_BANK_DEPTH <= 1) ? 1 : $clog2(A_BANK_DEPTH);
	localparam integer B_AW = (B_BANK_DEPTH <= 1) ? 1 : $clog2(B_BANK_DEPTH);
	localparam integer B_LW = (GEMM_Y_DIM <= 1) ? 1 : $clog2(GEMM_Y_DIM);
	localparam integer A_DIM_CONST = (GEMM_X_DIM <= 0) ? 1 : GEMM_X_DIM;
	localparam integer B_DIM_CONST = (GEMM_Y_DIM <= 0) ? 1 : GEMM_Y_DIM;
	localparam integer A_DIM_SHIFT = $clog2(A_DIM_CONST);
	localparam integer B_DIM_SHIFT = $clog2(B_DIM_CONST);

	localparam [2:0] ST_IDLE        = 3'd0;
	localparam [2:0] ST_EXEC_START  = 3'd1;
	localparam [2:0] ST_EXEC_FEED   = 3'd2;
	localparam [2:0] ST_WAIT_RESULT = 3'd3;
	localparam [2:0] ST_M_STORE     = 3'd4;
	localparam [2:0] ST_ADD_REQ     = 3'd5;
	localparam [2:0] ST_ADD_CAPTURE = 3'd6;
	localparam [2:0] ST_ADD_SEND    = 3'd7;

	reg [2:0] state;
	reg [2:0] next_state;
	reg [3:0] cur_opcode;
	reg [31:0] cur_id;
	reg [15:0] exec_issue_cnt;
	reg [15:0] exec_rsp_cnt;
	reg        cur_exec_a_is_m;
	reg        cur_exec_b_is_m;
	reg        cur_exec_a_buf;
	reg        cur_exec_b_buf;
	reg [7:0]  cur_a_row_base;
	reg [7:0]  cur_b_row_base;
	reg [7:0]  cur_m_row_base;
	reg        m_wr_buf_ptr;
	reg        cur_m_wr_buf;
	reg [A_AW-1:0] add_row_idx;
	reg [GEMM_Y_DIM*DATA_WIDTH-1:0] add_lhs_row;
	reg [GEMM_Y_DIM*DATA_WIDTH-1:0] add_rhs_row;

	reg [GEMM_Y_DIM*DATA_WIDTH-1:0] store_result_row;
	reg [A_AW-1:0] store_row_addr;
	reg            store_row_last;
	reg [B_LW-1:0] store_lane_cnt;

	wire cur_is_matmul = (cur_opcode == `PT_OP_MATMUL);
	wire cur_is_matadd = (cur_opcode == `PT_OP_MATADD);
	wire mm_exec_rsp_valid;
	wire mm_exec_rsp_fire;
	wire mm_exec_req_fire;
	wire add_send_fire;
	wire res_valid;
	wire res_ready;
	wire res_fire;
	wire [GEMM_Y_DIM*DATA_WIDTH-1:0] res_data;
	wire [31:0]                      res_idx;
	wire                             res_last;

	function is_pow2;
		input integer value;
		begin
			is_pow2 = (value > 0) ? (((value & (value - 1)) == 0) ? 1'b1 : 1'b0) : 1'b0;
		end
	endfunction

	initial begin
		if (!is_pow2(GEMM_X_DIM) || !is_pow2(GEMM_Y_DIM)) begin
			$fatal(1, "PT_CE requires power-of-two GEMM_X_DIM/GEMM_Y_DIM, got %0d x %0d", GEMM_X_DIM, GEMM_Y_DIM);
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

	assign ce_inst_ready  = (state == ST_IDLE);
	assign gemm_start     = (state == ST_EXEC_START) && cur_is_matmul;
	assign gemm_num_acc   = GEMM_X_DIM[DATA_WIDTH-1:0];
	assign mm_exec_rsp_valid = cur_is_matmul && (state == ST_EXEC_FEED) && (exec_rsp_cnt < exec_issue_cnt);
	assign mm_exec_rsp_fire  = mm_exec_rsp_valid && gemm_a_ready && gemm_b_ready;
	assign mm_exec_req_fire  = cur_is_matmul &&
	                           (state == ST_EXEC_FEED) &&
	                           (exec_issue_cnt < GEMM_X_DIM) &&
	                           ((exec_issue_cnt == 0) || mm_exec_rsp_fire);
	assign gemm_a_valid   = mm_exec_rsp_valid;
	assign gemm_b_valid   = mm_exec_rsp_valid;

	assign a_mem_rd_en    = mm_exec_req_fire && !exec_a_is_m;
	assign b_mem_rd_en    = (mm_exec_req_fire && !exec_b_is_m) || (state == ST_ADD_REQ);
	assign exec_m_a_rd_en = mm_exec_req_fire && exec_a_is_m;
	assign exec_m_b_rd_en = (mm_exec_req_fire && exec_b_is_m) || (state == ST_ADD_REQ);

	assign gema_lhs_data = add_lhs_row;
	assign gema_rhs_data = add_rhs_row;
	assign gema_in_idx   = {{(32-A_AW){1'b0}}, add_row_idx};
	assign gema_in_last  = (add_row_idx == (GEMM_X_DIM - 1));
	assign gema_in_valid = (state == ST_ADD_SEND);
	assign add_send_fire = gema_in_valid && gema_in_ready;

	assign quant_m_ready = (state == ST_WAIT_RESULT) && cur_is_matmul;
	assign add_m_ready   = (state == ST_WAIT_RESULT) && cur_is_matadd;
	assign res_valid     = cur_is_matadd ? add_m_valid : quant_m_valid;
	assign res_ready     = (state == ST_WAIT_RESULT);
	assign res_fire      = res_valid && res_ready;
	assign res_data      = cur_is_matadd ? add_m_data : quant_m_data;
	assign res_idx       = cur_is_matadd ? add_m_idx : quant_m_idx;
	assign res_last      = cur_is_matadd ? add_m_last : quant_m_last;

`ifdef VERILATOR
	ce_user_state_idle: cover property (@(posedge clk) state == ST_IDLE);
	ce_user_state_exec_start: cover property (@(posedge clk) state == ST_EXEC_START);
	ce_user_state_exec_feed: cover property (@(posedge clk) state == ST_EXEC_FEED);
	ce_user_state_wait_result: cover property (@(posedge clk) state == ST_WAIT_RESULT);
	ce_user_state_m_store: cover property (@(posedge clk) state == ST_M_STORE);
	ce_user_state_add_req: cover property (@(posedge clk) state == ST_ADD_REQ);
	ce_user_state_add_capture: cover property (@(posedge clk) state == ST_ADD_CAPTURE);
	ce_user_state_add_send: cover property (@(posedge clk) state == ST_ADD_SEND);

	ce_user_tr_idle_to_start: cover property (@(posedge clk) state == ST_IDLE && ce_inst_valid);
	ce_user_tr_start_to_matmul_feed: cover property (@(posedge clk) state == ST_EXEC_START && cur_is_matmul);
	ce_user_tr_start_to_matadd_req: cover property (@(posedge clk) state == ST_EXEC_START && cur_is_matadd);
	ce_user_tr_feed_to_wait_result: cover property (@(posedge clk) state == ST_EXEC_FEED && mm_exec_rsp_fire && (exec_rsp_cnt == (GEMM_X_DIM - 1)));
	ce_user_tr_add_req_to_capture: cover property (@(posedge clk) state == ST_ADD_REQ);
	ce_user_tr_add_capture_to_send: cover property (@(posedge clk) state == ST_ADD_CAPTURE);
	ce_user_tr_add_send_to_wait_result: cover property (@(posedge clk) state == ST_ADD_SEND && add_send_fire);
	ce_user_tr_wait_result_to_store: cover property (@(posedge clk) state == ST_WAIT_RESULT && res_fire);
	ce_user_tr_store_to_matadd_req: cover property (@(posedge clk) state == ST_M_STORE && (store_lane_cnt == (GEMM_Y_DIM - 1)) && !store_row_last && cur_is_matadd);
	ce_user_tr_store_to_wait_result: cover property (@(posedge clk) state == ST_M_STORE && (store_lane_cnt == (GEMM_Y_DIM - 1)) && !store_row_last && cur_is_matmul);
	ce_user_tr_store_to_idle: cover property (@(posedge clk) state == ST_M_STORE && (store_lane_cnt == (GEMM_Y_DIM - 1)) && store_row_last);
`endif

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
				if (cur_is_matadd) begin
					next_state = ST_ADD_REQ;
				end else begin
					next_state = ST_EXEC_FEED;
				end
			end

			ST_EXEC_FEED: begin
				if (mm_exec_rsp_fire && (exec_rsp_cnt == (GEMM_X_DIM - 1))) begin
					next_state = ST_WAIT_RESULT;
				end
			end

			ST_WAIT_RESULT: begin
				if (res_fire) begin
					next_state = ST_M_STORE;
				end
			end

			ST_M_STORE: begin
				if (store_lane_cnt == (GEMM_Y_DIM - 1)) begin
					if (store_row_last) begin
						next_state = ST_IDLE;
					end else if (cur_is_matadd) begin
						next_state = ST_ADD_REQ;
					end else begin
						next_state = ST_WAIT_RESULT;
					end
				end
			end

			ST_ADD_REQ: begin
				next_state = ST_ADD_CAPTURE;
			end

			ST_ADD_CAPTURE: begin
				next_state = ST_ADD_SEND;
			end

			ST_ADD_SEND: begin
				if (add_send_fire) begin
					next_state = ST_WAIT_RESULT;
				end
			end

			default: begin
				next_state = ST_IDLE;
			end
		endcase
	end

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			cur_opcode      <= 4'd0;
			cur_id          <= 32'd0;
			exec_issue_cnt  <= 16'd0;
			exec_rsp_cnt    <= 16'd0;
			exec_a_buf      <= 1'b0;
			exec_b_buf      <= 1'b0;
			exec_a_addr     <= {A_AW{1'b0}};
			exec_b_addr     <= {B_AW{1'b0}};
			exec_a_is_m     <= 1'b0;
			exec_b_is_m     <= 1'b0;
			exec_m_a_buf    <= 1'b0;
			exec_m_b_buf    <= 1'b0;
			exec_m_a_addr   <= {A_AW{1'b0}};
			exec_m_b_addr   <= {B_AW{1'b0}};
			cur_exec_a_is_m <= 1'b0;
			cur_exec_b_is_m <= 1'b0;
			cur_exec_a_buf  <= 1'b0;
			cur_exec_b_buf  <= 1'b0;
			cur_a_row_base  <= 8'd0;
			cur_b_row_base  <= 8'd0;
			cur_m_row_base  <= 8'd0;
			m_wr_buf_ptr    <= 1'b0;
			cur_m_wr_buf    <= 1'b0;
			add_row_idx     <= {A_AW{1'b0}};
			add_lhs_row     <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			add_rhs_row     <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			store_result_row <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			store_row_addr  <= {A_AW{1'b0}};
			store_row_last  <= 1'b0;
			store_lane_cnt  <= {B_LW{1'b0}};
			m_mem_wr_en     <= 1'b0;
			m_mem_wr_buf    <= 1'b0;
			m_mem_wr_lane   <= {B_LW{1'b0}};
			m_mem_wr_addr   <= {A_AW{1'b0}};
			m_mem_wr_data   <= {DATA_WIDTH{1'b0}};
			ce_resp_valid   <= 1'b0;
			ce_resp         <= 32'd0;
			ce_irq          <= 1'b0;
		end else if (clear) begin
			cur_opcode      <= 4'd0;
			cur_id          <= 32'd0;
			exec_issue_cnt  <= 16'd0;
			exec_rsp_cnt    <= 16'd0;
			exec_a_buf      <= 1'b0;
			exec_b_buf      <= 1'b0;
			exec_a_addr     <= {A_AW{1'b0}};
			exec_b_addr     <= {B_AW{1'b0}};
			exec_a_is_m     <= 1'b0;
			exec_b_is_m     <= 1'b0;
			exec_m_a_buf    <= 1'b0;
			exec_m_b_buf    <= 1'b0;
			exec_m_a_addr   <= {A_AW{1'b0}};
			exec_m_b_addr   <= {B_AW{1'b0}};
			cur_exec_a_is_m <= 1'b0;
			cur_exec_b_is_m <= 1'b0;
			cur_exec_a_buf  <= 1'b0;
			cur_exec_b_buf  <= 1'b0;
			cur_a_row_base  <= 8'd0;
			cur_b_row_base  <= 8'd0;
			cur_m_row_base  <= 8'd0;
			m_wr_buf_ptr    <= 1'b0;
			cur_m_wr_buf    <= 1'b0;
			add_row_idx     <= {A_AW{1'b0}};
			add_lhs_row     <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			add_rhs_row     <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			store_result_row <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			store_row_addr  <= {A_AW{1'b0}};
			store_row_last  <= 1'b0;
			store_lane_cnt  <= {B_LW{1'b0}};
			m_mem_wr_en     <= 1'b0;
			m_mem_wr_buf    <= 1'b0;
			m_mem_wr_lane   <= {B_LW{1'b0}};
			m_mem_wr_addr   <= {A_AW{1'b0}};
			m_mem_wr_data   <= {DATA_WIDTH{1'b0}};
			ce_resp_valid   <= 1'b0;
			ce_resp         <= 32'd0;
			ce_irq          <= 1'b0;
		end else begin
			ce_resp_valid <= 1'b0;
			ce_irq        <= 1'b0;
			m_mem_wr_en   <= 1'b0;

			case (state)
				ST_IDLE: begin
					if (ce_inst_valid) begin
						cur_opcode      <= ce_inst[`PT_INST_OPCODE_H:`PT_INST_OPCODE_L];
						cur_id          <= ce_id;
						cur_exec_a_is_m <= ce_inst[`PT_INST_A_OFF_H];
						cur_exec_b_is_m <= ce_inst[`PT_INST_B_OFF_H];
						cur_exec_a_buf  <= ce_inst[`PT_INST_A_OFF_H-1];
						cur_exec_b_buf  <= ce_inst[`PT_INST_B_OFF_H-1];
						cur_a_row_base  <= ce_inst[`PT_INST_A_OFF_L+7:`PT_INST_A_OFF_L] >> A_DIM_SHIFT;
						cur_b_row_base  <= ce_inst[`PT_INST_B_OFF_L+7:`PT_INST_B_OFF_L] >> B_DIM_SHIFT;
						cur_m_row_base  <= ce_inst[`PT_INST_A_OFF_L+7:`PT_INST_A_OFF_L] >> B_DIM_SHIFT;
						cur_m_wr_buf    <= m_wr_buf_ptr;
					end
				end

				ST_EXEC_START: begin
					exec_issue_cnt <= 16'd0;
					exec_rsp_cnt   <= 16'd0;
					add_row_idx    <= {A_AW{1'b0}};
					if (cur_is_matadd) begin
						exec_a_is_m   <= 1'b0;
						exec_b_is_m   <= 1'b0;
						exec_a_buf    <= 1'b0;
						exec_b_buf    <= cur_exec_b_buf;
						exec_a_addr   <= {A_AW{1'b0}};
						exec_b_addr   <= cur_b_row_base[B_AW-1:0];
						exec_m_a_buf  <= 1'b0;
						exec_m_b_buf  <= cur_exec_a_buf;
						exec_m_a_addr <= {A_AW{1'b0}};
						exec_m_b_addr <= cur_m_row_base[B_AW-1:0];
					end else begin
						exec_a_is_m   <= cur_exec_a_is_m;
						exec_b_is_m   <= cur_exec_b_is_m;
						exec_a_buf    <= cur_exec_a_buf;
						exec_b_buf    <= cur_exec_b_buf;
						exec_m_a_buf  <= cur_exec_a_buf;
						exec_m_b_buf  <= cur_exec_b_buf;
						exec_a_addr   <= cur_a_row_base[A_AW-1:0];
						exec_b_addr   <= cur_b_row_base[B_AW-1:0];
						exec_m_a_addr <= cur_a_row_base[A_AW-1:0];
						exec_m_b_addr <= cur_b_row_base[B_AW-1:0];
					end
				end

				ST_EXEC_FEED: begin
					if (mm_exec_req_fire) begin
						exec_issue_cnt <= exec_issue_cnt + 1'b1;
						if (exec_issue_cnt != (GEMM_X_DIM - 1)) begin
							exec_a_addr   <= cur_a_row_base[A_AW-1:0] + exec_issue_cnt[A_AW-1:0] + 1'b1;
							exec_b_addr   <= cur_b_row_base[B_AW-1:0] + exec_issue_cnt[B_AW-1:0] + 1'b1;
							exec_m_a_addr <= cur_a_row_base[A_AW-1:0] + exec_issue_cnt[A_AW-1:0] + 1'b1;
							exec_m_b_addr <= cur_b_row_base[B_AW-1:0] + exec_issue_cnt[B_AW-1:0] + 1'b1;
						end
					end
					if (mm_exec_rsp_fire) begin
						exec_rsp_cnt <= exec_rsp_cnt + 1'b1;
					end
				end

				ST_WAIT_RESULT: begin
					if (res_fire) begin
						store_result_row <= res_data;
						store_row_addr   <= res_idx[A_AW-1:0];
						store_row_last   <= res_last;
						store_lane_cnt   <= {B_LW{1'b0}};
					end
				end

				ST_M_STORE: begin
					m_mem_wr_en   <= 1'b1;
					m_mem_wr_buf  <= cur_m_wr_buf;
					m_mem_wr_lane <= store_lane_cnt;
					m_mem_wr_addr <= store_row_addr;
					m_mem_wr_data <= store_result_row[store_lane_cnt*DATA_WIDTH +: DATA_WIDTH];

					if (store_lane_cnt == (GEMM_Y_DIM - 1)) begin
						if (store_row_last) begin
							ce_resp       <= pack_resp(1'b0, cur_m_wr_buf, cur_id);
							ce_resp_valid <= 1'b1;
							ce_irq        <= 1'b1;
							m_wr_buf_ptr  <= ~m_wr_buf_ptr;
						end else if (cur_is_matadd) begin
							exec_b_addr   <= cur_b_row_base[B_AW-1:0] + add_row_idx[B_AW-1:0];
							exec_m_b_addr <= cur_m_row_base[B_AW-1:0] + add_row_idx[B_AW-1:0];
						end
					end else begin
						store_lane_cnt <= store_lane_cnt + 1'b1;
					end
				end

				ST_ADD_REQ: begin
				end

				ST_ADD_CAPTURE: begin
					add_lhs_row <= m_mem_row_data;
					add_rhs_row <= b_mem_row_data;
				end

				ST_ADD_SEND: begin
					if (add_send_fire && (add_row_idx != (GEMM_X_DIM - 1))) begin
						add_row_idx <= add_row_idx + 1'b1;
					end
				end

				default: begin
				end
			endcase
		end
	end

endmodule
