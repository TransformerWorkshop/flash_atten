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

	localparam [2:0] ST_IDLE       = 3'd0;
	localparam [2:0] ST_EXEC_START = 3'd1;
	localparam [2:0] ST_EXEC_FEED  = 3'd2;
	localparam [2:0] ST_WAIT_GEMM  = 3'd3;
	localparam [2:0] ST_M_STORE    = 3'd4;

	reg [2:0] state;
	reg [2:0] next_state;
	reg [31:0] cur_id;
	reg [9:0] cur_a_off;
	reg [9:0] cur_b_off;
	reg [15:0] exec_k_cnt;
	reg        cur_exec_a_is_m;
	reg        cur_exec_b_is_m;
	reg        cur_exec_a_buf;
	reg        cur_exec_b_buf;
	reg [7:0]  cur_a_row_base;
	reg [7:0]  cur_b_row_base;
	reg        m_wr_buf_ptr;
	reg        cur_m_wr_buf;

	reg [GEMM_Y_DIM*DATA_WIDTH-1:0] store_quant_row;
	reg [A_AW-1:0] store_row_addr;
	reg            store_row_last;
	reg [B_LW-1:0] store_lane_cnt;

	function [31:0] pack_resp;
		input err;
		input m_buf;
		input [31:0] id;
		begin
			pack_resp = {err, m_buf, id[29:0]};
		end
	endfunction

	assign ce_inst_ready = (state == ST_IDLE);
	assign gemm_start    = (state == ST_EXEC_START);
	assign gemm_num_acc  = GEMM_X_DIM[DATA_WIDTH-1:0];
	assign gemm_a_valid  = (state == ST_EXEC_FEED);
	assign gemm_b_valid  = (state == ST_EXEC_FEED);
	assign a_mem_rd_en   = (state == ST_EXEC_FEED) && !cur_exec_a_is_m;
	assign b_mem_rd_en   = (state == ST_EXEC_FEED) && !cur_exec_b_is_m;
	assign quant_m_ready = (state == ST_WAIT_GEMM);

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
					if (quant_m_valid && quant_m_ready) begin
						next_state = ST_M_STORE;
					end
				end

			ST_M_STORE: begin
				if (store_lane_cnt == (GEMM_Y_DIM - 1)) begin
					if (store_row_last) begin
						next_state = ST_IDLE;
					end else begin
						next_state = ST_WAIT_GEMM;
					end
				end
			end

			default: begin
				next_state = ST_IDLE;
			end
		endcase
	end

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			cur_id          <= 32'd0;
			cur_a_off       <= 10'd0;
			cur_b_off       <= 10'd0;
			exec_k_cnt      <= 16'd0;
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
			m_wr_buf_ptr    <= 1'b0;
			cur_m_wr_buf    <= 1'b0;
			store_quant_row <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
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
			cur_id          <= 32'd0;
			cur_a_off       <= 10'd0;
			cur_b_off       <= 10'd0;
			exec_k_cnt      <= 16'd0;
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
			m_wr_buf_ptr    <= 1'b0;
			cur_m_wr_buf    <= 1'b0;
			store_quant_row <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
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
						cur_id          <= ce_id;
						cur_a_off       <= ce_inst[`PT_INST_A_OFF_H:`PT_INST_A_OFF_L];
						cur_b_off       <= ce_inst[`PT_INST_B_OFF_H:`PT_INST_B_OFF_L];
						cur_exec_a_is_m <= ce_inst[`PT_INST_A_OFF_H];
						cur_exec_b_is_m <= ce_inst[`PT_INST_B_OFF_H];
						cur_exec_a_buf  <= ce_inst[`PT_INST_A_OFF_H-1];
						cur_exec_b_buf  <= ce_inst[`PT_INST_B_OFF_H-1];
						cur_a_row_base  <= ce_inst[`PT_INST_A_OFF_L+7:`PT_INST_A_OFF_L] / A_DIM_CONST;
						cur_b_row_base  <= ce_inst[`PT_INST_B_OFF_L+7:`PT_INST_B_OFF_L] / B_DIM_CONST;
						cur_m_wr_buf    <= m_wr_buf_ptr;
					end
				end

				ST_EXEC_START: begin
					exec_k_cnt    <= 16'd0;
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

				ST_EXEC_FEED: begin
					if (gemm_a_ready && gemm_b_ready) begin
						if (exec_k_cnt != (GEMM_X_DIM - 1)) begin
							exec_k_cnt <= exec_k_cnt + 1'b1;
							exec_a_addr <= cur_a_row_base[A_AW-1:0] + exec_k_cnt[A_AW-1:0] + 1'b1;
							exec_b_addr <= cur_b_row_base[B_AW-1:0] + exec_k_cnt[B_AW-1:0] + 1'b1;
							exec_m_a_addr <= cur_a_row_base[A_AW-1:0] + exec_k_cnt[A_AW-1:0] + 1'b1;
							exec_m_b_addr <= cur_b_row_base[B_AW-1:0] + exec_k_cnt[B_AW-1:0] + 1'b1;
						end
					end
				end

				ST_WAIT_GEMM: begin
					if (quant_m_valid && quant_m_ready) begin
						store_quant_row <= quant_m_data;
						store_row_addr <= quant_m_idx[A_AW-1:0];
						store_row_last <= quant_m_last;
						store_lane_cnt <= {B_LW{1'b0}};
					end
				end

				ST_M_STORE: begin
					m_mem_wr_en   <= 1'b1;
					m_mem_wr_buf  <= cur_m_wr_buf;
					m_mem_wr_lane <= store_lane_cnt;
					m_mem_wr_addr <= store_row_addr;
					m_mem_wr_data <= store_quant_row[store_lane_cnt*DATA_WIDTH +: DATA_WIDTH];

					if (store_lane_cnt == (GEMM_Y_DIM - 1)) begin
						if (store_row_last) begin
							ce_resp       <= pack_resp(1'b0, cur_m_wr_buf, cur_id);
							ce_resp_valid <= 1'b1;
							ce_irq        <= 1'b1;
							m_wr_buf_ptr  <= ~m_wr_buf_ptr;
						end
					end else begin
						store_lane_cnt <= store_lane_cnt + 1'b1;
					end
				end

				default: begin
				end
			endcase
		end
	end

endmodule
